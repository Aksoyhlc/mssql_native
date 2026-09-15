import 'dart:async';
import 'dart:collection';

import 'cancellation.dart';
import 'connection.dart';
import 'exception.dart';
import 'metadata_cache.dart';
import 'models/bulk.dart';
import 'models/config.dart';
import 'models/result.dart';
import 'models/types.dart';
import 'query_options.dart';
import 'session.dart';
import 'transaction.dart';

class _IdleConnection {
  _IdleConnection(this.connection) : releasedAt = DateTime.now();
  final MssqlConnection connection;
  final DateTime releasedAt;
}

class _PoolWaiter {
  _PoolWaiter(this.deadline, this.cancellationToken);

  /// The acquire's budget and signal, carried so a replacement connection
  /// opened for this waiter stays bound by both.
  ///
  /// Taking a waiter off the queue cancels its timer, so the open that follows
  /// is the only thing left that can honour [MssqlPoolConfig.acquireTimeout].
  final DateTime deadline;
  final MssqlCancellationToken? cancellationToken;

  final completer = Completer<MssqlConnection>();
  Timer? timer;
  void Function()? unregisterCancellation;

  void dispose() {
    timer?.cancel();
    timer = null;
    unregisterCancellation?.call();
    unregisterCancellation = null;
  }
}

/// The pool seen as a session: one lease per command.
///
/// Every method borrows a connection, runs, and returns it, so two calls may
/// land on different connections. That suits a single statement and not
/// anything spanning statements, hence [MssqlSession.inTransaction] is false
/// and streaming holds its lease for the life of the stream.
class _PooledSession with MssqlSession {
  _PooledSession(this._pool);

  final MssqlConnectionPool _pool;

  @override
  MssqlConnectionConfig get config => _pool.connectionConfig;

  @override
  bool get inTransaction => false;

  @override
  void invalidateMetadata({String? object}) =>
      _pool.invalidateMetadata(object: object);

  @override
  Future<void> ping({MssqlCancellationToken? cancellationToken}) =>
      _pool.withConnection(
        cancellationToken: cancellationToken,
        (connection) => connection.ping(cancellationToken: cancellationToken),
      );

  @override
  Future<MssqlExecutionResult> query(
    String sql, {
    Object parameters = const <String, Object?>{},
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
    int? batchRows,
    int? maximumRows,
    int? maximumBytes,
    MssqlRetryPolicy? retry,
  }) => _pool.withConnection(
    cancellationToken: cancellationToken ?? options.cancellationToken,
    (connection) => connection.query(
      sql,
      parameters: parameters,
      options: options,
      timeout: timeout,
      cancellationToken: cancellationToken,
      batchRows: batchRows,
      maximumRows: maximumRows,
      maximumBytes: maximumBytes,
      retry: retry,
    ),
  );

  @override
  Future<MssqlExecutionResult> callProcedure(
    String procedure, {
    Object parameters = const <String, Object?>{},
    Set<String> outputParameters = const <String>{},
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
    int? batchRows,
    int? maximumRows,
    int? maximumBytes,
    MssqlProcedureMetadata? declared,
    MssqlMetadataDriftPolicy driftPolicy =
        MssqlMetadataDriftPolicy.preferDeclared,
  }) => _pool.withConnection(
    cancellationToken: cancellationToken ?? options.cancellationToken,
    (connection) => connection.callProcedure(
      procedure,
      parameters: parameters,
      outputParameters: outputParameters,
      options: options,
      timeout: timeout,
      cancellationToken: cancellationToken,
      batchRows: batchRows,
      maximumRows: maximumRows,
      maximumBytes: maximumBytes,
      declared: declared,
      driftPolicy: driftPolicy,
    ),
  );

  /// Holds the lease until the stream ends or the subscriber cancels.
  ///
  /// Releasing when the call returns would give the connection away while its
  /// rows were still arriving on it.
  @override
  Stream<MssqlStreamEvent> stream(
    String sql, {
    Object parameters = const <String, Object?>{},
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
    int? batchRows,
    int? maximumRows,
    int? maximumBytes,
  }) async* {
    final connection = await _pool.acquire(
      cancellationToken: cancellationToken ?? options.cancellationToken,
    );
    try {
      yield* connection.stream(
        sql,
        parameters: parameters,
        options: options,
        timeout: timeout,
        cancellationToken: cancellationToken,
        batchRows: batchRows,
        maximumRows: maximumRows,
        maximumBytes: maximumBytes,
      );
    } finally {
      await _pool.release(connection);
    }
  }

  @override
  Future<MssqlBulkResult> bulkInsert({
    required String tableName,
    required Iterable<Object> rows,
    Object? columns,
    MssqlBulkOptions options = const MssqlBulkOptions(),
    MssqlCancellationToken? cancellationToken,
    void Function(int sentRows)? onProgress,
  }) => _pool.withConnection(
    cancellationToken: cancellationToken,
    (connection) => connection.bulkInsert(
      tableName: tableName,
      rows: rows,
      columns: columns,
      options: options,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    ),
  );
}

/// A bounded pool of connections to one database.
///
/// [session] borrows a connection per command; [withConnection] and
/// [transaction] hold one for a whole operation. [close] waits for in-flight
/// releases and closes every idle connection. A connection whose session state
/// cannot be restored is closed rather than reused.
class MssqlConnectionPool {
  MssqlConnectionPool(
    this.connectionConfig, {
    this.poolConfig = const MssqlPoolConfig(),
    MssqlMetadataCache? metadataCache,
  }) : metadataCache =
           metadataCache ??
           MssqlMetadataCache(
             maxEntries: connectionConfig.metadataCacheSize,
             ttl: connectionConfig.metadataCacheTtl,
           ) {
    connectionConfig.validate();
    poolConfig.validate();
  }

  final MssqlConnectionConfig connectionConfig;
  final MssqlPoolConfig poolConfig;

  /// Procedure and bulk-table describes shared by every lease, so two
  /// statements on different leases do not describe the same procedure twice.
  final MssqlMetadataCache metadataCache;
  final Queue<_IdleConnection> _idle = Queue<_IdleConnection>();
  final Queue<_PoolWaiter> _waiters = Queue<_PoolWaiter>();
  final Set<MssqlConnection> _owned = HashSet<MssqlConnection>.identity();
  final Set<MssqlConnection> _borrowed = HashSet<MssqlConnection>.identity();
  int _created = 0;
  int _opening = 0;
  bool _closed = false;
  Completer<void>? _opensDrained;
  Future<void>? _warming;
  Future<void>? _closeFuture;

  int get createdCount => _created;
  int get idleCount => _idle.length;
  int get waitingCount => _waiters.length;

  /// Drops cached procedure and bulk-table metadata for every lease.
  void invalidateMetadata({String? object}) {
    if (object == null) {
      metadataCache.clear();
    } else {
      metadataCache.invalidate(key: object);
    }
    for (final connection in _owned) {
      connection.invalidateMetadata(object: object);
    }
  }

  Future<void> warmUp() {
    if (_closed) return Future.error(StateError('The pool is closed.'));
    final active = _warming;
    if (active != null) return active;
    final future = _warmUpOnce();
    _warming = future;
    return future.whenComplete(() {
      if (identical(_warming, future)) _warming = null;
    });
  }

  Future<void> _warmUpOnce() async {
    final opens = <Future<void>>[];
    for (var i = _created; i < poolConfig.minimumSize; i++) {
      opens.add(_openForWarmUp());
    }
    await Future.wait(opens);
  }

  Future<void> _openForWarmUp() async {
    _reserveOpen();
    MssqlConnection? connection;
    try {
      connection = await _openWithRetry();
      if (_closed) {
        await connection.close();
        throw StateError('The pool was closed.');
      }
      _owned.add(connection);
      final result = connection;
      connection = null;
      _offer(result);
    } catch (_) {
      if (connection != null) await connection.close();
      _created--;
      rethrow;
    } finally {
      _finishOpen();
    }
  }

  /// A session that borrows a connection for one command and gives it back.
  ///
  /// Use this for a statement with no connection affinity. Transactions,
  /// streams, staged temporary tables and consistent page counts must hold one
  /// connection through [withConnection] or [transaction].
  late final MssqlSession session = _PooledSession(this);

  /// [cancellationToken] covers the wait for a connection as well as the
  /// callback, so a cancelled command leaves the queue instead of holding its
  /// place until [MssqlPoolConfig.acquireTimeout].
  Future<T> withConnection<T>(
    Future<T> Function(MssqlConnection connection) callback, {
    MssqlCancellationToken? cancellationToken,
  }) async {
    final connection = await acquire(cancellationToken: cancellationToken);
    try {
      return await callback(connection);
    } finally {
      await release(connection);
    }
  }

  Future<T> transaction<T>(
    Future<T> Function(MssqlTransaction transaction) callback, {
    MssqlIsolationLevel isolationLevel = MssqlIsolationLevel.baseline,
    MssqlCancellationToken? cancellationToken,
  }) => withConnection(
    cancellationToken: cancellationToken,
    (connection) => connection.transaction(
      callback,
      isolationLevel: isolationLevel,
      cancellationToken: cancellationToken,
    ),
  );

  /// Borrows a connection.
  ///
  /// [MssqlPoolConfig.acquireTimeout] is the budget for the whole operation:
  /// queueing, validating an idle connection and opening a new one, retries
  /// included.
  Future<MssqlConnection> acquire({
    MssqlCancellationToken? cancellationToken,
  }) async {
    if (_closed) throw StateError('The pool is closed.');
    cancellationToken?.throwIfCancelled();
    final deadline = DateTime.now().add(poolConfig.acquireTimeout);
    while (_idle.isNotEmpty) {
      final entry = _idle.removeFirst();
      final candidate = entry.connection;
      if (candidate.isClosed) {
        _discard(candidate);
        continue;
      }
      final idleFor = DateTime.now().difference(entry.releasedAt);
      if (idleFor > poolConfig.idleTimeout &&
          _created > poolConfig.minimumSize) {
        _discard(candidate);
        await candidate.close();
        continue;
      }
      if (idleFor >= poolConfig.validationGracePeriod) {
        try {
          await candidate.ping(cancellationToken: cancellationToken);
          _checkAcquireBudget(deadline, cancellationToken);
        } catch (_) {
          _discard(candidate);
          await candidate.close();
          continue;
        }
      }
      if (_closed) {
        _discard(candidate);
        await candidate.close();
        throw StateError('The pool was closed.');
      }
      _borrowed.add(candidate);
      return candidate;
    }
    if (_created < poolConfig.maximumSize) {
      return _openForAcquire(deadline, cancellationToken);
    }
    return _waitForConnection(deadline, cancellationToken);
  }

  /// Stops the acquire when its budget is spent or the caller cancelled.
  ///
  /// Checked between stages so a slow ping plus a slow open cannot together
  /// outlast the timeout.
  void _checkAcquireBudget(
    DateTime deadline,
    MssqlCancellationToken? cancellationToken,
  ) {
    cancellationToken?.throwIfCancelled();
    if (!DateTime.now().isAfter(deadline)) return;
    throw MssqlPoolTimeoutException(
      message:
          'Timed out after ${poolConfig.acquireTimeout.inMilliseconds}ms while '
          'acquiring a SQL connection. The budget covers queueing, validating '
          'an idle connection and opening a new one; this one was spent '
          'validating or opening. Raise MssqlPoolConfig.acquireTimeout, or '
          'find out why opening a connection is slow.',
    );
  }

  Future<MssqlConnection> _openForAcquire(
    DateTime deadline,
    MssqlCancellationToken? cancellationToken,
  ) async {
    _reserveOpen();
    MssqlConnection? connection;
    try {
      connection = await _openWithRetry(
        deadline: deadline,
        cancellationToken: cancellationToken,
      );
      if (_closed) {
        await connection.close();
        throw StateError('The pool was closed.');
      }
      _owned.add(connection);
      _borrowed.add(connection);
      final result = connection;
      connection = null;
      return result;
    } catch (_) {
      if (connection != null) await connection.close();
      _created--;
      rethrow;
    } finally {
      _finishOpen();
      _serviceWaiters();
    }
  }

  Future<MssqlConnection> _waitForConnection(
    DateTime deadline,
    MssqlCancellationToken? cancellationToken,
  ) {
    final waiter = _PoolWaiter(deadline, cancellationToken);
    _waiters.addLast(waiter);
    void fail(MssqlException error) {
      // The waiter may already have been handed a connection; then that
      // connection is the answer.
      if (!_waiters.remove(waiter) || waiter.completer.isCompleted) return;
      waiter.completer.completeError(error);
    }

    final remaining = deadline.difference(DateTime.now());
    waiter.timer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () => fail(
        MssqlPoolTimeoutException(
          message:
              'Timed out after '
              '${poolConfig.acquireTimeout.inMilliseconds}ms waiting for one '
              'of the pool\'s ${poolConfig.maximumSize} connections. Every '
              'one of them is still held by another caller. Give connections '
              'back sooner, or raise MssqlPoolConfig.maximumSize against a '
              'measured workload.',
        ),
      ),
    );
    // A cancelled caller stops queueing immediately rather than holding its
    // place until the timeout.
    waiter.unregisterCancellation = cancellationToken?.register(
      () => fail(
        const MssqlCancelledException(
          message: 'The SQL connection acquire was cancelled.',
        ),
      ),
    );
    return waiter.completer.future.whenComplete(waiter.dispose);
  }

  Future<MssqlConnection> _openWithRetry({
    DateTime? deadline,
    MssqlCancellationToken? cancellationToken,
  }) async {
    const delays = [
      Duration.zero,
      Duration(milliseconds: 250),
      Duration(seconds: 1),
    ];
    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 0; attempt < delays.length; attempt++) {
      if (attempt > 0) await Future<void>.delayed(delays[attempt]);
      if (deadline != null) _checkAcquireBudget(deadline, cancellationToken);
      cancellationToken?.throwIfCancelled();
      try {
        return await MssqlConnection.open(
          connectionConfig,
          metadataCache: metadataCache,
        );
      } catch (error, stack) {
        lastError = error;
        lastStack = stack;
        if (error is! MssqlException || !error.retryable) rethrow;
      }
    }
    Error.throwWithStackTrace(lastError!, lastStack!);
  }

  /// Gives a connection back.
  ///
  /// Asynchronous because returning a connection includes restoring its session
  /// baseline. A session that cannot be restored is closed rather than reused,
  /// so one caller's state cannot become the next caller's default.
  Future<void> release(MssqlConnection connection) {
    // The ownership check is synchronous, so a foreign or duplicate release is
    // rejected before the pool touches anything.
    if (!_owned.contains(connection) || !_borrowed.remove(connection)) {
      return Future<void>.error(
        StateError('The connection is not borrowed from this pool.'),
        StackTrace.current,
      );
    }
    // Tracked because between the check above and `_offer` the connection
    // belongs to neither `_borrowed` nor `_idle`. `close()` inspects only those
    // two sets, so a release still in flight would otherwise be invisible and
    // close could return while an open connection is still running a query.
    late final Future<void> pending;
    pending = _releaseOnce(connection).whenComplete(() {
      _releasing.remove(pending);
    });
    _releasing.add(pending);
    return pending;
  }

  /// Releases still running, so [close] can wait for them.
  final Set<Future<void>> _releasing = <Future<void>>{};

  Future<void> _releaseOnce(MssqlConnection connection) async {
    if (_closed || connection.isClosed) {
      _discard(connection);
      await connection.close();
      if (!_closed) _serviceWaiters();
      return;
    }
    await connection.restoreSessionBaseline();
    if (connection.isSessionDirty) {
      _discard(connection);
      await connection.close();
      _serviceWaiters();
      return;
    }
    if (_closed) {
      // The pool closed while this release was restoring the session; offering
      // now would leave a connection in an idle queue nothing drains.
      _discard(connection);
      await connection.close();
      return;
    }
    _offer(connection);
  }

  void _offer(MssqlConnection connection) {
    final waiter = _takeWaiter();
    if (waiter == null) {
      _idle.addLast(_IdleConnection(connection));
    } else {
      _borrowed.add(connection);
      waiter.completer.complete(connection);
    }
  }

  _PoolWaiter? _takeWaiter() {
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      waiter.timer?.cancel();
      if (!waiter.completer.isCompleted) return waiter;
    }
    return null;
  }

  void _serviceWaiters() {
    if (_closed) return;
    while (_waiters.isNotEmpty && _created < poolConfig.maximumSize) {
      final waiter = _takeWaiter();
      if (waiter == null) return;
      unawaited(_openForWaiter(waiter));
    }
  }

  Future<void> _openForWaiter(_PoolWaiter waiter) async {
    _reserveOpen();
    MssqlConnection? connection;
    try {
      connection = await _openWithRetry(
        deadline: waiter.deadline,
        cancellationToken: waiter.cancellationToken,
      );
      if (_closed) {
        await connection.close();
        throw StateError('The pool was closed.');
      }
      _owned.add(connection);
      final result = connection;
      connection = null;
      if (waiter.completer.isCompleted) {
        _offer(result);
      } else {
        _borrowed.add(result);
        waiter.completer.complete(result);
      }
    } catch (error, stack) {
      if (connection != null) await connection.close();
      _created--;
      if (!waiter.completer.isCompleted) {
        waiter.completer.completeError(error, stack);
      }
    } finally {
      _finishOpen();
      _serviceWaiters();
    }
  }

  void _reserveOpen() {
    _created++;
    _opening++;
  }

  void _finishOpen() {
    _opening--;
    if (_opening == 0) {
      _opensDrained?.complete();
      _opensDrained = null;
    }
  }

  void _discard(MssqlConnection connection) {
    if (_owned.remove(connection)) _created--;
    _borrowed.remove(connection);
  }

  Future<void> close() => _closeFuture ??= _closeOnce();

  Future<void> _closeOnce() async {
    _closed = true;
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      waiter.timer?.cancel();
      if (!waiter.completer.isCompleted) {
        waiter.completer.completeError(StateError('The pool was closed.'));
      }
    }
    // Before the idle queue: a release finishing during this drain decides for
    // itself whether to offer or discard, and must do so before the queue is
    // emptied.
    while (_releasing.isNotEmpty) {
      await Future.wait(
        _releasing.toList(),
      ).catchError((Object _) => const <void>[]);
    }
    final closes = <Future<void>>[];
    while (_idle.isNotEmpty) {
      final connection = _idle.removeFirst().connection;
      _discard(connection);
      closes.add(connection.close());
    }
    if (_opening > 0) {
      _opensDrained ??= Completer<void>();
      await _opensDrained!.future;
    }
    await Future.wait(closes);
  }
}
