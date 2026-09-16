import 'package:meta/meta.dart';

import 'exception.dart';
import 'models/bulk.dart';
import 'models/result.dart';
import 'models/types.dart';

/// The kind of logical database operation observed by [MssqlObserver].
enum MssqlQueryKind { query, procedure, stream }

/// How a transaction ended successfully.
enum MssqlTransactionOutcome { committed, rolledBack }

/// What the driver knows about a transaction after an error.
enum MssqlTransactionSettlement { committed, rolledBack, unknown }

/// How a real wait in a bounded connection pool ended.
enum MssqlPoolWaitOutcome { acquired, timedOut, cancelled, poolClosed, failed }

/// A credential-free description of the database endpoint.
@immutable
final class MssqlObservationTarget {
  const MssqlObservationTarget({
    required this.host,
    required this.port,
    required this.database,
  });

  final String host;
  final int port;
  final String database;
}

/// A safe projection of an error for telemetry.
///
/// It deliberately excludes the exception object, message, stack trace and
/// server diagnostics. Those values can contain application data.
@immutable
final class MssqlObservedError {
  const MssqlObservedError({
    required this.canonicalType,
    this.driverType,
    this.code = 0,
    this.state = 0,
    this.retryable = false,
    this.cancelled = false,
    this.mayHaveRun = false,
    this.transactionSettlement,
  });

  final String canonicalType;
  final MssqlErrorType? driverType;
  final int code;
  final int state;
  final bool retryable;
  final bool cancelled;
  final bool mayHaveRun;
  final MssqlTransactionSettlement? transactionSettlement;
}

/// A point-in-time view of a connection pool.
@immutable
final class MssqlPoolMetricsSnapshot {
  const MssqlPoolMetricsSnapshot({
    required this.created,
    required this.idle,
    required this.borrowed,
    required this.opening,
    required this.waiting,
    required this.maximumSize,
  });

  final int created;
  final int idle;
  final int borrowed;
  final int opening;
  final int waiting;
  final int maximumSize;
}

@immutable
final class MssqlQueryStartEvent {
  const MssqlQueryStartEvent({
    required this.operationId,
    required this.kind,
    required this.target,
    required this.inTransaction,
    this.queryName,
    this.connectionId,
    this.poolId,
    this.transactionId,
  });

  final int operationId;
  final MssqlQueryKind kind;
  final String? queryName;
  final MssqlObservationTarget target;
  final bool inTransaction;
  final int? connectionId;
  final int? poolId;
  final int? transactionId;
}

@immutable
final class MssqlQueryCompleteEvent {
  const MssqlQueryCompleteEvent({
    required this.operationId,
    required this.kind,
    required this.target,
    required this.inTransaction,
    required this.elapsed,
    required this.attemptCount,
    required this.connectionRepaired,
    required this.connectionRepairCount,
    required this.metrics,
    required this.returnedRows,
    required this.affectedRows,
    this.queryName,
    this.connectionId,
    this.poolId,
    this.transactionId,
  });

  final int operationId;
  final MssqlQueryKind kind;
  final String? queryName;
  final MssqlObservationTarget target;
  final bool inTransaction;
  final Duration elapsed;
  final int attemptCount;
  final bool connectionRepaired;
  final int connectionRepairCount;
  final MssqlExecutionMetrics metrics;
  final int returnedRows;
  final int affectedRows;
  final int? connectionId;
  final int? poolId;
  final int? transactionId;
}

@immutable
final class MssqlQueryErrorEvent {
  const MssqlQueryErrorEvent({
    required this.operationId,
    required this.kind,
    required this.target,
    required this.inTransaction,
    required this.elapsed,
    required this.attemptCount,
    required this.connectionRepaired,
    required this.connectionRepairCount,
    required this.error,
    this.queryName,
    this.connectionId,
    this.poolId,
    this.transactionId,
  });

  final int operationId;
  final MssqlQueryKind kind;
  final String? queryName;
  final MssqlObservationTarget target;
  final bool inTransaction;
  final Duration elapsed;
  final int attemptCount;
  final bool connectionRepaired;
  final int connectionRepairCount;
  final MssqlObservedError error;
  final int? connectionId;
  final int? poolId;
  final int? transactionId;
}

@immutable
final class MssqlBulkStartEvent {
  const MssqlBulkStartEvent({
    required this.operationId,
    required this.target,
    required this.inTransaction,
    this.bulkName,
    this.connectionId,
    this.poolId,
    this.transactionId,
  });

  final int operationId;
  final String? bulkName;
  final MssqlObservationTarget target;
  final bool inTransaction;
  final int? connectionId;
  final int? poolId;
  final int? transactionId;
}

@immutable
final class MssqlBulkCompleteEvent {
  const MssqlBulkCompleteEvent({
    required this.operationId,
    required this.target,
    required this.inTransaction,
    required this.elapsed,
    required this.totalRows,
    required this.insertedRows,
    required this.committedBatches,
    required this.connectionRepairCount,
    this.bulkName,
    this.failedRowIndex,
    this.connectionId,
    this.poolId,
    this.transactionId,
  });

  final int operationId;
  final String? bulkName;
  final MssqlObservationTarget target;
  final bool inTransaction;
  final Duration elapsed;
  final int totalRows;
  final int insertedRows;
  final int committedBatches;
  final int? failedRowIndex;
  final int connectionRepairCount;
  final int? connectionId;
  final int? poolId;
  final int? transactionId;
}

@immutable
final class MssqlBulkErrorEvent {
  const MssqlBulkErrorEvent({
    required this.operationId,
    required this.target,
    required this.inTransaction,
    required this.elapsed,
    required this.connectionRepairCount,
    required this.error,
    this.bulkName,
    this.connectionId,
    this.poolId,
    this.transactionId,
  });

  final int operationId;
  final String? bulkName;
  final MssqlObservationTarget target;
  final bool inTransaction;
  final Duration elapsed;
  final int connectionRepairCount;
  final MssqlObservedError error;
  final int? connectionId;
  final int? poolId;
  final int? transactionId;
}

@immutable
final class MssqlTransactionStartEvent {
  const MssqlTransactionStartEvent({
    required this.operationId,
    required this.transactionId,
    required this.target,
    this.transactionName,
    this.connectionId,
    this.poolId,
  });

  final int operationId;
  final int transactionId;
  final String? transactionName;
  final MssqlObservationTarget target;
  final int? connectionId;
  final int? poolId;
}

@immutable
final class MssqlTransactionCompleteEvent {
  const MssqlTransactionCompleteEvent({
    required this.operationId,
    required this.transactionId,
    required this.target,
    required this.elapsed,
    required this.outcome,
    this.transactionName,
    this.connectionId,
    this.poolId,
  });

  final int operationId;
  final int transactionId;
  final String? transactionName;
  final MssqlObservationTarget target;
  final Duration elapsed;
  final MssqlTransactionOutcome outcome;
  final int? connectionId;
  final int? poolId;
}

@immutable
final class MssqlTransactionErrorEvent {
  const MssqlTransactionErrorEvent({
    required this.operationId,
    required this.transactionId,
    required this.target,
    required this.elapsed,
    required this.error,
    required this.settlement,
    this.transactionName,
    this.connectionId,
    this.poolId,
  });

  final int operationId;
  final int transactionId;
  final String? transactionName;
  final MssqlObservationTarget target;
  final Duration elapsed;
  final MssqlObservedError error;
  final MssqlTransactionSettlement settlement;
  final int? connectionId;
  final int? poolId;
}

@immutable
final class MssqlConnectionOpenEvent {
  const MssqlConnectionOpenEvent({
    required this.connectionId,
    required this.target,
    required this.elapsed,
    this.poolId,
  });

  final int connectionId;
  final int? poolId;
  final MssqlObservationTarget target;
  final Duration elapsed;
}

@immutable
final class MssqlConnectionCloseEvent {
  const MssqlConnectionCloseEvent({
    required this.connectionId,
    required this.target,
    required this.lifetime,
    required this.repairCount,
    this.poolId,
  });

  final int connectionId;
  final int? poolId;
  final MssqlObservationTarget target;
  final Duration lifetime;
  final int repairCount;
}

@immutable
final class MssqlPoolWaitEvent {
  const MssqlPoolWaitEvent({
    required this.operationId,
    required this.poolId,
    required this.target,
    required this.elapsed,
    required this.outcome,
    required this.metrics,
  });

  final int operationId;
  final int poolId;
  final MssqlObservationTarget target;
  final Duration elapsed;
  final MssqlPoolWaitOutcome outcome;
  final MssqlPoolMetricsSnapshot metrics;
}

/// Synchronous, dependency-free hooks for tracing and metrics adapters.
///
/// Implementations must be lightweight. Exporting spans or metrics should be
/// delegated to the telemetry SDK's own batching mechanism.
class MssqlObserver {
  const MssqlObserver();

  Object? onQueryStart(MssqlQueryStartEvent event) => null;
  void onQueryComplete(MssqlQueryCompleteEvent event, Object? state) {}
  void onQueryError(MssqlQueryErrorEvent event, Object? state) {}

  Object? onBulkStart(MssqlBulkStartEvent event) => null;
  void onBulkComplete(MssqlBulkCompleteEvent event, Object? state) {}
  void onBulkError(MssqlBulkErrorEvent event, Object? state) {}

  Object? onTransactionStart(MssqlTransactionStartEvent event) => null;
  void onTransactionComplete(
    MssqlTransactionCompleteEvent event,
    Object? state,
  ) {}
  void onTransactionError(MssqlTransactionErrorEvent event, Object? state) {}

  void onConnectionOpen(MssqlConnectionOpenEvent event) {}
  void onConnectionClose(MssqlConnectionCloseEvent event) {}
  void onPoolWait(MssqlPoolWaitEvent event) {}

  /// Receives an error thrown by another observer callback.
  ///
  /// Errors thrown here are swallowed as well: observability never changes a
  /// database operation's result.
  void onObserverError(String callback, Object error, StackTrace stackTrace) {}
}

/// Internal callback dispatcher. It is intentionally not exported.
final class MssqlObservationDispatcher {
  MssqlObservationDispatcher(this.observer, {this.poolId});

  static int _nextOperationId = 1;
  static int _nextConnectionId = 1;
  static int _nextPoolId = 1;
  static int _nextTransactionId = 1;

  final MssqlObserver? observer;
  final int? poolId;

  bool get enabled => observer != null;
  int newOperationId() => _nextOperationId++;
  static int newPoolId() => _nextPoolId++;
  static int newConnectionId() => _nextConnectionId++;
  static int newTransactionId() => _nextTransactionId++;

  MssqlQueryObservation? startQuery({
    required MssqlQueryKind kind,
    required String? queryName,
    required MssqlObservationTarget target,
    required bool inTransaction,
    required int? connectionId,
    required int? transactionId,
  }) {
    final sink = observer;
    if (sink == null) return null;
    final operationId = _nextOperationId++;
    try {
      final state = sink.onQueryStart(
        MssqlQueryStartEvent(
          operationId: operationId,
          kind: kind,
          queryName: queryName,
          target: target,
          inTransaction: inTransaction,
          connectionId: connectionId,
          poolId: poolId,
          transactionId: transactionId,
        ),
      );
      return MssqlQueryObservation(
        this,
        operationId: operationId,
        kind: kind,
        queryName: queryName,
        target: target,
        inTransaction: inTransaction,
        connectionId: connectionId,
        transactionId: transactionId,
        state: state,
      );
    } catch (error, stack) {
      _observerError('onQueryStart', error, stack);
      return null;
    }
  }

  MssqlBulkObservation? startBulk({
    required String? bulkName,
    required MssqlObservationTarget target,
    required bool inTransaction,
    required int? connectionId,
    required int? transactionId,
  }) {
    final sink = observer;
    if (sink == null) return null;
    final operationId = _nextOperationId++;
    try {
      final state = sink.onBulkStart(
        MssqlBulkStartEvent(
          operationId: operationId,
          bulkName: bulkName,
          target: target,
          inTransaction: inTransaction,
          connectionId: connectionId,
          poolId: poolId,
          transactionId: transactionId,
        ),
      );
      return MssqlBulkObservation(
        this,
        operationId: operationId,
        bulkName: bulkName,
        target: target,
        inTransaction: inTransaction,
        connectionId: connectionId,
        transactionId: transactionId,
        state: state,
      );
    } catch (error, stack) {
      _observerError('onBulkStart', error, stack);
      return null;
    }
  }

  MssqlTransactionObservation? startTransaction({
    required String? transactionName,
    required MssqlObservationTarget target,
    required int? connectionId,
  }) {
    final sink = observer;
    if (sink == null) return null;
    final operationId = _nextOperationId++;
    final transactionId = newTransactionId();
    try {
      final state = sink.onTransactionStart(
        MssqlTransactionStartEvent(
          operationId: operationId,
          transactionId: transactionId,
          transactionName: transactionName,
          target: target,
          connectionId: connectionId,
          poolId: poolId,
        ),
      );
      return MssqlTransactionObservation(
        this,
        operationId: operationId,
        transactionId: transactionId,
        transactionName: transactionName,
        target: target,
        connectionId: connectionId,
        state: state,
      );
    } catch (error, stack) {
      _observerError('onTransactionStart', error, stack);
      return null;
    }
  }

  void connectionOpen(MssqlConnectionOpenEvent event) =>
      _call('onConnectionOpen', () => observer?.onConnectionOpen(event));

  void connectionClose(MssqlConnectionCloseEvent event) =>
      _call('onConnectionClose', () => observer?.onConnectionClose(event));

  void poolWait(MssqlPoolWaitEvent event) =>
      _call('onPoolWait', () => observer?.onPoolWait(event));

  void _call(String callback, void Function() action) {
    if (observer == null) return;
    try {
      action();
    } catch (error, stack) {
      _observerError(callback, error, stack);
    }
  }

  void _observerError(String callback, Object error, StackTrace stack) {
    try {
      observer?.onObserverError(callback, error, stack);
    } catch (_) {}
  }
}

abstract base class MssqlOperationObservation {
  MssqlOperationObservation(
    this.dispatcher, {
    required this.operationId,
    required this.target,
    required this.connectionId,
    required this.state,
  }) : watch = Stopwatch()..start();

  final MssqlObservationDispatcher dispatcher;
  final int operationId;
  final MssqlObservationTarget target;
  int? connectionId;
  final Object? state;
  final Stopwatch watch;
  bool ended = false;
}

final class MssqlQueryObservation extends MssqlOperationObservation {
  MssqlQueryObservation(
    super.dispatcher, {
    required super.operationId,
    required this.kind,
    required this.queryName,
    required super.target,
    required this.inTransaction,
    required super.connectionId,
    required this.transactionId,
    required super.state,
  });

  final MssqlQueryKind kind;
  final String? queryName;
  final bool inTransaction;
  final int? transactionId;
  int repairCountAtStart = 0;
  int attemptCount = 1;

  void complete(MssqlExecutionResult result, int repairCount) {
    if (ended) return;
    ended = true;
    final repaired = repairCount > repairCountAtStart;
    dispatcher._call(
      'onQueryComplete',
      () => dispatcher.observer?.onQueryComplete(
        MssqlQueryCompleteEvent(
          operationId: operationId,
          kind: kind,
          queryName: queryName,
          target: target,
          inTransaction: inTransaction,
          elapsed: watch.elapsed,
          attemptCount: attemptCount,
          connectionRepaired: repaired,
          connectionRepairCount: repairCount,
          metrics: result.metrics,
          returnedRows: result.metrics.rowCount,
          affectedRows: result.affectedRows,
          connectionId: connectionId,
          poolId: dispatcher.poolId,
          transactionId: transactionId,
        ),
        state,
      ),
    );
  }

  void completeStream(MssqlExecutionComplete result, int repairCount) {
    complete(
      MssqlExecutionResult(
        resultSets: const <MssqlResultSet>[],
        affectedRows: result.affectedRows,
        outputParameters: result.outputParameters,
        messages: result.messages,
        returnStatus: result.returnStatus,
        statementRowCounts: result.statementRowCounts,
        metrics: result.metrics,
      ),
      repairCount,
    );
  }

  void fail(Object error, int repairCount) {
    if (ended) return;
    ended = true;
    final repaired = repairCount > repairCountAtStart;
    dispatcher._call(
      'onQueryError',
      () => dispatcher.observer?.onQueryError(
        MssqlQueryErrorEvent(
          operationId: operationId,
          kind: kind,
          queryName: queryName,
          target: target,
          inTransaction: inTransaction,
          elapsed: watch.elapsed,
          attemptCount: attemptCount,
          connectionRepaired: repaired,
          connectionRepairCount: repairCount,
          error: observedError(error),
          connectionId: connectionId,
          poolId: dispatcher.poolId,
          transactionId: transactionId,
        ),
        state,
      ),
    );
  }
}

final class MssqlBulkObservation extends MssqlOperationObservation {
  MssqlBulkObservation(
    super.dispatcher, {
    required super.operationId,
    required this.bulkName,
    required super.target,
    required this.inTransaction,
    required super.connectionId,
    required this.transactionId,
    required super.state,
  });

  final String? bulkName;
  final bool inTransaction;
  final int? transactionId;

  void complete(MssqlBulkResult result, int repairCount) {
    if (ended) return;
    ended = true;
    dispatcher._call(
      'onBulkComplete',
      () => dispatcher.observer?.onBulkComplete(
        MssqlBulkCompleteEvent(
          operationId: operationId,
          bulkName: bulkName,
          target: target,
          inTransaction: inTransaction,
          elapsed: watch.elapsed,
          totalRows: result.totalRows,
          insertedRows: result.insertedRows,
          committedBatches: result.committedBatches,
          failedRowIndex: result.failedRowIndex,
          connectionRepairCount: repairCount,
          connectionId: connectionId,
          poolId: dispatcher.poolId,
          transactionId: transactionId,
        ),
        state,
      ),
    );
  }

  void fail(Object error, int repairCount) {
    if (ended) return;
    ended = true;
    dispatcher._call(
      'onBulkError',
      () => dispatcher.observer?.onBulkError(
        MssqlBulkErrorEvent(
          operationId: operationId,
          bulkName: bulkName,
          target: target,
          inTransaction: inTransaction,
          elapsed: watch.elapsed,
          connectionRepairCount: repairCount,
          error: observedError(error),
          connectionId: connectionId,
          poolId: dispatcher.poolId,
          transactionId: transactionId,
        ),
        state,
      ),
    );
  }
}

final class MssqlTransactionObservation extends MssqlOperationObservation {
  MssqlTransactionObservation(
    super.dispatcher, {
    required super.operationId,
    required this.transactionId,
    required this.transactionName,
    required super.target,
    required super.connectionId,
    required super.state,
  });

  final int transactionId;
  final String? transactionName;

  void complete(MssqlTransactionOutcome outcome) {
    if (ended) return;
    ended = true;
    dispatcher._call(
      'onTransactionComplete',
      () => dispatcher.observer?.onTransactionComplete(
        MssqlTransactionCompleteEvent(
          operationId: operationId,
          transactionId: transactionId,
          transactionName: transactionName,
          target: target,
          elapsed: watch.elapsed,
          outcome: outcome,
          connectionId: connectionId,
          poolId: dispatcher.poolId,
        ),
        state,
      ),
    );
  }

  void fail(Object error, MssqlTransactionSettlement settlement) {
    if (ended) return;
    ended = true;
    dispatcher._call(
      'onTransactionError',
      () => dispatcher.observer?.onTransactionError(
        MssqlTransactionErrorEvent(
          operationId: operationId,
          transactionId: transactionId,
          transactionName: transactionName,
          target: target,
          elapsed: watch.elapsed,
          error: observedError(error, transactionSettlement: settlement),
          settlement: settlement,
          connectionId: connectionId,
          poolId: dispatcher.poolId,
        ),
        state,
      ),
    );
  }
}

MssqlObservedError observedError(
  Object error, {
  MssqlTransactionSettlement? transactionSettlement,
}) {
  if (error is MssqlException) {
    return MssqlObservedError(
      canonicalType: error.runtimeType.toString(),
      driverType: error.type,
      code: error.code,
      state: error.state,
      retryable: error.retryable,
      cancelled: error.type == MssqlErrorType.cancelled,
      mayHaveRun: error is MssqlConnectionException && error.mayHaveRun,
      transactionSettlement: transactionSettlement,
    );
  }
  return MssqlObservedError(
    canonicalType: error.runtimeType.toString(),
    transactionSettlement: transactionSettlement,
  );
}

MssqlObservedError observedCancellation() => const MssqlObservedError(
  canonicalType: 'MssqlCancelledException',
  driverType: MssqlErrorType.cancelled,
  cancelled: true,
);
