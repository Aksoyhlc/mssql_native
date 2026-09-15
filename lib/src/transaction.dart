import 'cancellation.dart';
import 'connection.dart';
import 'exception.dart';
import 'metadata_cache.dart';
import 'models/bulk.dart';
import 'models/config.dart';
import 'models/result.dart';
import 'models/types.dart';
import 'native/worker.dart';
import 'query_options.dart';
import 'session.dart';

/// One open transaction, holding one connection for as long as it lives.
///
/// An [MssqlSession] like the connection and the pool, so code written against
/// a session runs unchanged inside a transaction. Nothing here is ever retried:
/// reconnecting would abandon the transaction.
class MssqlTransaction with MssqlSession {
  MssqlTransaction.internal(this.connection, this._worker);

  final MssqlConnection connection;
  final ConnectionWorker _worker;
  bool _completed = false;
  bool _closed = false;
  bool _doomed = false;

  @override
  MssqlConnectionConfig get config => connection.config;

  @override
  String get currentDatabase => connection.currentDatabase;

  @override
  bool get inTransaction => true;

  @override
  void invalidateMetadata({String? object}) =>
      connection.invalidateMetadata(object: object);

  /// Whether the server has refused further work on this transaction.
  ///
  /// A unique-key collision alone does not doom a transaction; a failed
  /// `ROLLBACK TO SAVEPOINT` does, and a later statement would only hide the
  /// first error.
  bool get isDoomed => _doomed;

  @override
  Future<void> ping({MssqlCancellationToken? cancellationToken}) {
    _ensureActive();
    return connection.ping(
      cancellationToken: cancellationToken,
      allowTransaction: true,
    );
  }

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
  }) {
    _ensureActive();
    return connection.executeWithinTransaction(
      sql,
      parameters: parameters,
      options: options.merge(
        timeout: timeout,
        cancellationToken: cancellationToken,
        batchRows: batchRows,
        maximumRows: maximumRows,
        maximumBytes: maximumBytes,
        retry: retry,
      ),
    );
  }

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
  }) {
    _ensureActive();
    return connection.callProcedure(
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
      allowTransaction: true,
    );
  }

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
  }) {
    _ensureActive();
    return connection.stream(
      sql,
      parameters: parameters,
      options: options,
      timeout: timeout,
      cancellationToken: cancellationToken,
      batchRows: batchRows,
      maximumRows: maximumRows,
      maximumBytes: maximumBytes,
      allowTransaction: true,
    );
  }

  @override
  Future<MssqlBulkResult> bulkInsert({
    required String tableName,
    required Iterable<Object> rows,
    Object? columns,
    MssqlBulkOptions options = const MssqlBulkOptions(),
    MssqlCancellationToken? cancellationToken,
    void Function(int sentRows)? onProgress,
  }) {
    _ensureActive();
    return connection.bulkInsert(
      tableName: tableName,
      rows: rows,
      columns: columns,
      options: options,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
      allowTransaction: true,
    );
  }

  int _savepoints = 0;

  /// Runs [callback] inside a savepoint of this transaction.
  ///
  /// A nested BEGIN TRANSACTION only raises `@@TRANCOUNT`, so an inner ROLLBACK
  /// would discard the outer transaction too. Rolling back to a savepoint undoes
  /// only the callback and leaves this transaction open.
  ///
  /// It does not promise recovery from a doomed transaction: when an error
  /// kills the batch, SQL Server refuses ROLLBACK TO SAVEPOINT and the whole
  /// transaction fails rather than the inner scope being contained.
  Future<T> savepoint<T>(Future<T> Function() callback) async {
    _ensureActive();
    final name = 'mssql_native_sp_${++_savepoints}';
    await connection.executeWithinTransaction('SAVE TRANSACTION [$name];');
    try {
      return await callback();
    } catch (error, stack) {
      try {
        await connection.executeWithinTransaction(
          'ROLLBACK TRANSACTION [$name];',
        );
      } catch (_) {
        // ROLLBACK TO SAVEPOINT was refused, so the transaction is doomed and
        // no later statement should be sent into it. The caller's rollback path
        // takes over.
        _doomed = true;
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<void> commit() async {
    _ensureActive();
    try {
      await connection.runTransactionNative(
        () => _worker.runSql(
          'COMMIT TRANSACTION;',
          connection.config.defaultQueryTimeout,
        ),
      );
    } on MssqlException catch (error) {
      // A COMMIT that was sent but never answered has an unknown outcome, so
      // reporting it as a plain connection loss would invite a retry that can
      // apply the work twice.
      _completed = true;
      _closed = true;
      if (error.type == MssqlErrorType.connection ||
          error.type == MssqlErrorType.connectionLost) {
        await connection.discardAfterTransactionFailure();
        throw MssqlUnknownCommitOutcomeException(error.message);
      }
      // Any other failed COMMIT must still release the connection. A failed
      // commit leaves the same ambiguity as a failed rollback, so
      // `settleAfterFailedRollback` reads `@@TRANCOUNT` and releases the lease
      // only when the session proves it holds no transaction.
      await connection.settleAfterFailedRollback();
      rethrow;
    }
    _completed = true;
  }

  Future<void> rollback() async {
    if (_closed || _completed) return;
    try {
      await _rollbackNative();
    } catch (_) {
      // The server never confirmed the rollback. The connection survives only
      // if it can prove it has no transaction left open.
      _completed = true;
      _closed = true;
      await connection.settleAfterFailedRollback();
      rethrow;
    }
    _completed = true;
  }

  Future<void> _rollbackNative() => connection.runTransactionNative(
    () => _worker.runSql(
      'ROLLBACK TRANSACTION;',
      connection.config.defaultQueryTimeout,
    ),
  );

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_completed) {
      await connection.releaseAfterTransaction();
      return;
    }
    _completed = true;
    try {
      await _rollbackNative();
    } catch (_) {
      // close() never throws, so the session is inspected instead: it is
      // released if it is provably clean and discarded otherwise.
      await connection.settleAfterFailedRollback();
      return;
    }
    await connection.releaseAfterTransaction();
  }

  void _ensureActive() {
    if (_closed) throw StateError('The transaction is closed.');
    if (_completed) throw StateError('The transaction has already completed.');
    if (_doomed) {
      throw StateError(
        'The transaction is doomed: the server refused to roll back to a '
        'savepoint, so nothing further can run on it. Roll it back and start '
        'again.',
      );
    }
  }
}
