import 'cancellation.dart';
import 'connection.dart';
import 'exception.dart';
import 'metadata_cache.dart';
import 'models/bulk.dart';
import 'models/config.dart';
import 'models/result.dart';
import 'models/types.dart';
import 'native/worker.dart';
import 'observability.dart';
import 'query_options.dart';
import 'session.dart';

/// One open transaction, holding one connection for as long as it lives.
///
/// An [MssqlSession] like the connection and the pool, so code written against
/// a session runs unchanged inside a transaction. Nothing here is ever retried:
/// reconnecting would abandon the transaction.
class MssqlTransaction with MssqlSession {
  MssqlTransaction._(
    this.connection,
    this._worker, {
    required MssqlTransactionObservation? observation,
  }) : _observation = observation;

  final MssqlConnection connection;
  final ConnectionWorker _worker;
  final MssqlTransactionObservation? _observation;
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
  int? get transactionId => _observation?.transactionId;

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
    final settings = options
        .merge(
          timeout: timeout,
          cancellationToken: cancellationToken,
          batchRows: batchRows,
          maximumRows: maximumRows,
          maximumBytes: maximumBytes,
          retry: retry,
        )
        .withoutRetry;
    final observation = mssqlStartConnectionQueryObservation(
      connection,
      kind: MssqlQueryKind.query,
      queryName: settings.queryName,
      inTransaction: true,
      transactionId: transactionId,
    );
    return mssqlRunDelegatedQuery(
      connection,
      observation: observation,
      sql: sql,
      parameters: parameters,
      options: settings,
      allowTransaction: true,
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
    final settings = options
        .merge(
          timeout: timeout,
          cancellationToken: cancellationToken,
          batchRows: batchRows,
          maximumRows: maximumRows,
          maximumBytes: maximumBytes,
        )
        .withoutRetry;
    final observation = mssqlStartConnectionQueryObservation(
      connection,
      kind: MssqlQueryKind.procedure,
      queryName: settings.queryName,
      inTransaction: true,
      transactionId: transactionId,
    );
    return mssqlRunDelegatedProcedure(
      connection,
      observation: observation,
      procedure: procedure,
      parameters: parameters,
      outputParameters: outputParameters,
      options: settings,
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
  }) async* {
    _ensureActive();
    final settings = options.merge(
      timeout: timeout,
      cancellationToken: cancellationToken,
      batchRows: batchRows,
      maximumRows: maximumRows,
      maximumBytes: maximumBytes,
    );
    final observation = mssqlStartConnectionQueryObservation(
      connection,
      kind: MssqlQueryKind.stream,
      queryName: settings.queryName,
      inTransaction: true,
      transactionId: transactionId,
    );
    yield* mssqlRunDelegatedStream(
      connection,
      observation: observation,
      sql: sql,
      parameters: parameters,
      options: settings,
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
    final observation = mssqlStartConnectionBulkObservation(
      connection,
      bulkName: options.bulkName,
      inTransaction: true,
      transactionId: transactionId,
    );
    return mssqlRunDelegatedBulk(
      connection,
      observation: observation,
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
    await mssqlExecuteWithinTransaction(
      connection,
      'SAVE TRANSACTION [$name];',
    );
    try {
      return await callback();
    } catch (error, stack) {
      try {
        await mssqlExecuteWithinTransaction(
          connection,
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
      await mssqlRunTransactionNative(
        connection,
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
        await mssqlDiscardAfterTransactionFailure(connection);
        final unknown = MssqlUnknownCommitOutcomeException(error.message);
        _observation?.fail(unknown, MssqlTransactionSettlement.unknown);
        throw unknown;
      }
      // Any other failed COMMIT must still release the connection. A failed
      // commit leaves the same ambiguity as a failed rollback, so
      // `settleAfterFailedRollback` reads `@@TRANCOUNT` and releases the lease
      // only when the session proves it holds no transaction.
      await mssqlSettleAfterFailedRollback(connection);
      _observation?.fail(error, MssqlTransactionSettlement.unknown);
      rethrow;
    }
    _completed = true;
    _observation?.complete(MssqlTransactionOutcome.committed);
  }

  Future<void> rollback() async {
    if (_closed || _completed) return;
    try {
      await _rollbackNative();
    } catch (error) {
      // The server never confirmed the rollback. The connection survives only
      // if it can prove it has no transaction left open.
      _completed = true;
      _closed = true;
      await mssqlSettleAfterFailedRollback(connection);
      _observation?.fail(error, MssqlTransactionSettlement.unknown);
      rethrow;
    }
    _completed = true;
    _observation?.complete(MssqlTransactionOutcome.rolledBack);
  }

  Future<void> _rollbackNative() => mssqlRunTransactionNative(
    connection,
    () => _worker.runSql(
      'ROLLBACK TRANSACTION;',
      connection.config.defaultQueryTimeout,
    ),
  );

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_completed) {
      await mssqlReleaseAfterTransaction(connection);
      return;
    }
    _completed = true;
    try {
      await _rollbackNative();
    } catch (error) {
      // close() never throws, so the session is inspected instead: it is
      // released if it is provably clean and discarded otherwise.
      await mssqlSettleAfterFailedRollback(connection);
      _observation?.fail(error, MssqlTransactionSettlement.unknown);
      return;
    }
    _observation?.complete(MssqlTransactionOutcome.rolledBack);
    await mssqlReleaseAfterTransaction(connection);
  }

  Future<void> _rollbackAfterCallbackError(Object callbackError) async {
    if (_closed || _completed) {
      _observation?.fail(callbackError, MssqlTransactionSettlement.unknown);
      return;
    }
    try {
      await _rollbackNative();
      _completed = true;
      _observation?.fail(callbackError, MssqlTransactionSettlement.rolledBack);
    } catch (_) {
      _completed = true;
      _closed = true;
      await mssqlSettleAfterFailedRollback(connection);
      _observation?.fail(callbackError, MssqlTransactionSettlement.unknown);
    }
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

MssqlTransaction mssqlCreateTransaction(
  MssqlConnection connection,
  ConnectionWorker worker, {
  required MssqlTransactionObservation? observation,
}) => MssqlTransaction._(connection, worker, observation: observation);

Future<void> mssqlRollbackAfterCallbackError(
  MssqlTransaction transaction,
  Object callbackError,
) => transaction._rollbackAfterCallbackError(callbackError);
