import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_native/src/observability.dart';
import 'package:test/test.dart';

import 'support/observability.dart';

void main() {
  const target = MssqlObservationTarget(
    host: 'db.internal',
    port: 1433,
    database: 'warehouse',
  );

  group('observer callback isolation', () {
    test('a successful null start still receives its terminal callback', () {
      final observer = RecordingMssqlObserver();
      final dispatcher = MssqlObservationDispatcher(observer);
      final observation = dispatcher.startQuery(
        kind: MssqlQueryKind.query,
        queryName: 'reports.dailyTurnover',
        target: target,
        inTransaction: false,
        connectionId: 7,
        transactionId: null,
      );

      expect(observation, isNotNull);
      observation!.complete(
        const MssqlExecutionResult(
          resultSets: <MssqlResultSet>[],
          affectedRows: 420,
          outputParameters: <String, Object?>{},
          messages: <MssqlServerMessage>[],
          metrics: MssqlExecutionMetrics(
            queueWait: Duration(milliseconds: 2),
            executionElapsed: Duration(milliseconds: 38),
            rowCount: 5,
            decodedBytes: 64,
            resultSets: <MssqlResultSetMetrics>[],
          ),
        ),
        0,
      );

      expect(observer.queryStarts, hasLength(1));
      expect(observer.queryCompletes, hasLength(1));
      expect(observer.queryCompleteStates.single, isNull);
      expect(observer.queryCompletes.single.affectedRows, 420);
      expect(observer.queryCompletes.single.returnedRows, 5);
    });

    test('a throwing start reports observer error and has no terminal', () {
      final observer = RecordingMssqlObserver(
        throwCallbacks: <String>{'onQueryStart'},
      );
      final dispatcher = MssqlObservationDispatcher(observer);

      final observation = dispatcher.startQuery(
        kind: MssqlQueryKind.query,
        queryName: 'orders.byId',
        target: target,
        inTransaction: false,
        connectionId: 8,
        transactionId: null,
      );

      expect(observation, isNull);
      expect(observer.observerErrors, <String>['onQueryStart']);
      expect(observer.queryCompletes, isEmpty);
      expect(observer.queryErrors, isEmpty);
    });

    test('a throwing terminal callback is isolated', () {
      final observer = RecordingMssqlObserver(
        throwCallbacks: <String>{'onQueryComplete'},
      );
      final dispatcher = MssqlObservationDispatcher(observer);
      final observation = dispatcher.startQuery(
        kind: MssqlQueryKind.query,
        queryName: null,
        target: target,
        inTransaction: false,
        connectionId: 9,
        transactionId: null,
      );

      expect(
        () => observation!.complete(
          const MssqlExecutionResult(
            resultSets: <MssqlResultSet>[],
            affectedRows: 0,
            outputParameters: <String, Object?>{},
            messages: <MssqlServerMessage>[],
          ),
          0,
        ),
        returnsNormally,
      );
      expect(observer.observerErrors, <String>['onQueryComplete']);
    });

    test('non-null state is returned to the matching terminal callback', () {
      final queryState = Object();
      final bulkState = Object();
      final transactionState = Object();
      final observer = RecordingMssqlObserver(
        queryStartState: queryState,
        bulkStartState: bulkState,
        transactionStartState: transactionState,
      );
      final dispatcher = MssqlObservationDispatcher(observer);

      dispatcher
          .startQuery(
            kind: MssqlQueryKind.query,
            queryName: 'state.query',
            target: target,
            inTransaction: false,
            connectionId: 10,
            transactionId: null,
          )!
          .fail(StateError('query failed'), 0);
      dispatcher
          .startBulk(
            bulkName: 'state.bulk',
            target: target,
            inTransaction: false,
            connectionId: 10,
            transactionId: null,
          )!
          .complete(MssqlBulkResult.empty, 0);
      dispatcher
          .startTransaction(
            transactionName: 'state.transaction',
            target: target,
            connectionId: 10,
          )!
          .complete(MssqlTransactionOutcome.committed);

      expect(observer.queryErrorStates.single, same(queryState));
      expect(observer.bulkCompleteStates.single, same(bulkState));
      expect(observer.transactionCompleteStates.single, same(transactionState));
    });

    test('bulk and transaction start failures suppress their terminals', () {
      final observer = RecordingMssqlObserver(
        throwCallbacks: <String>{'onBulkStart', 'onTransactionStart'},
      );
      final dispatcher = MssqlObservationDispatcher(observer);

      final bulk = dispatcher.startBulk(
        bulkName: 'start.bulk',
        target: target,
        inTransaction: false,
        connectionId: 12,
        transactionId: null,
      );
      final transaction = dispatcher.startTransaction(
        transactionName: 'start.transaction',
        target: target,
        connectionId: 12,
      );

      expect(bulk, isNull);
      expect(transaction, isNull);
      expect(observer.observerErrors, <String>[
        'onBulkStart',
        'onTransactionStart',
      ]);
      expect(observer.bulkCompletes, isEmpty);
      expect(observer.bulkErrors, isEmpty);
      expect(observer.transactionCompletes, isEmpty);
      expect(observer.transactionErrors, isEmpty);
    });

    test('all terminal callback failures remain isolated', () {
      final observer = RecordingMssqlObserver(
        throwCallbacks: <String>{
          'onQueryError',
          'onBulkComplete',
          'onBulkError',
          'onTransactionComplete',
          'onTransactionError',
        },
        throwObserverError: true,
      );
      final dispatcher = MssqlObservationDispatcher(observer);

      expect(
        () => dispatcher
            .startQuery(
              kind: MssqlQueryKind.query,
              queryName: null,
              target: target,
              inTransaction: false,
              connectionId: 13,
              transactionId: null,
            )!
            .fail(StateError('query'), 0),
        returnsNormally,
      );
      expect(
        () => dispatcher
            .startBulk(
              bulkName: null,
              target: target,
              inTransaction: false,
              connectionId: 13,
              transactionId: null,
            )!
            .complete(MssqlBulkResult.empty, 0),
        returnsNormally,
      );
      expect(
        () => dispatcher
            .startBulk(
              bulkName: null,
              target: target,
              inTransaction: false,
              connectionId: 13,
              transactionId: null,
            )!
            .fail(StateError('bulk'), 0),
        returnsNormally,
      );
      expect(
        () => dispatcher
            .startTransaction(
              transactionName: null,
              target: target,
              connectionId: 13,
            )!
            .complete(MssqlTransactionOutcome.committed),
        returnsNormally,
      );
      expect(
        () => dispatcher
            .startTransaction(
              transactionName: null,
              target: target,
              connectionId: 13,
            )!
            .fail(
              StateError('transaction'),
              MssqlTransactionSettlement.unknown,
            ),
        returnsNormally,
      );

      expect(observer.observerErrors, <String>[
        'onQueryError',
        'onBulkComplete',
        'onBulkError',
        'onTransactionComplete',
        'onTransactionError',
      ]);
    });

    test('connection and pool callback failures remain isolated', () {
      final observer = RecordingMssqlObserver(
        throwCallbacks: <String>{
          'onConnectionOpen',
          'onConnectionClose',
          'onPoolWait',
        },
      );
      final dispatcher = MssqlObservationDispatcher(observer, poolId: 19);

      expect(
        () => dispatcher.connectionOpen(
          const MssqlConnectionOpenEvent(
            connectionId: 20,
            poolId: 19,
            target: target,
            elapsed: Duration(milliseconds: 4),
          ),
        ),
        returnsNormally,
      );
      expect(
        () => dispatcher.connectionClose(
          const MssqlConnectionCloseEvent(
            connectionId: 20,
            poolId: 19,
            target: target,
            lifetime: Duration(seconds: 1),
            repairCount: 2,
          ),
        ),
        returnsNormally,
      );
      expect(
        () => dispatcher.poolWait(
          const MssqlPoolWaitEvent(
            operationId: 21,
            poolId: 19,
            target: target,
            elapsed: Duration(milliseconds: 7),
            outcome: MssqlPoolWaitOutcome.acquired,
            metrics: MssqlPoolMetricsSnapshot(
              created: 1,
              idle: 0,
              borrowed: 1,
              opening: 0,
              waiting: 0,
              maximumSize: 1,
            ),
          ),
        ),
        returnsNormally,
      );

      expect(observer.connectionOpens, hasLength(1));
      expect(observer.connectionCloses, hasLength(1));
      expect(observer.poolWaits, hasLength(1));
      expect(observer.observerErrors, <String>[
        'onConnectionOpen',
        'onConnectionClose',
        'onPoolWait',
      ]);
    });
  });

  test('observed database errors contain classification but no message', () {
    const source = MssqlConnectionException(
      type: MssqlErrorType.connectionLost,
      message: 'sensitive server detail',
      code: 20047,
      state: 3,
      retryable: true,
      queryName: 'orders.write',
    );

    final projected = observedError(source);

    expect(projected.canonicalType, 'MssqlConnectionException');
    expect(projected.driverType, MssqlErrorType.connectionLost);
    expect(projected.code, 20047);
    expect(projected.state, 3);
    expect(projected.retryable, isTrue);
    expect(projected.mayHaveRun, isTrue);
    expect(projected.toString(), isNot(contains('sensitive server detail')));
  });

  test('bulk names and pool snapshots expose only safe metadata', () {
    const options = MssqlBulkOptions(bulkName: 'imports.customers');
    const snapshot = MssqlPoolMetricsSnapshot(
      created: 4,
      idle: 1,
      borrowed: 2,
      opening: 1,
      waiting: 3,
      maximumSize: 8,
    );

    expect(options.bulkName, 'imports.customers');
    expect(snapshot.created, 4);
    expect(snapshot.borrowed, 2);
    expect(snapshot.maximumSize, 8);
  });

  test('bulk and transaction observations terminate only once', () {
    final observer = RecordingMssqlObserver();
    final dispatcher = MssqlObservationDispatcher(observer, poolId: 4);
    final bulk = dispatcher.startBulk(
      bulkName: 'imports.customers',
      target: target,
      inTransaction: true,
      connectionId: 11,
      transactionId: 12,
    );
    final transaction = dispatcher.startTransaction(
      transactionName: 'orders.checkout',
      target: target,
      connectionId: 11,
    );

    bulk!
      ..complete(MssqlBulkResult.empty, 0)
      ..fail(StateError('late failure'), 0);
    transaction!
      ..complete(MssqlTransactionOutcome.committed)
      ..fail(StateError('late failure'), MssqlTransactionSettlement.unknown);

    expect(observer.bulkCompletes, hasLength(1));
    expect(observer.bulkErrors, isEmpty);
    expect(observer.transactionCompletes, hasLength(1));
    expect(observer.transactionErrors, isEmpty);
  });

  test('query success and error observations terminate only once', () {
    final observer = RecordingMssqlObserver();
    final dispatcher = MssqlObservationDispatcher(observer);
    final success = dispatcher.startQuery(
      kind: MssqlQueryKind.query,
      queryName: 'idempotent.success',
      target: target,
      inTransaction: false,
      connectionId: 30,
      transactionId: null,
    );
    final failure = dispatcher.startQuery(
      kind: MssqlQueryKind.stream,
      queryName: 'idempotent.failure',
      target: target,
      inTransaction: false,
      connectionId: 30,
      transactionId: null,
    );

    success!
      ..complete(
        const MssqlExecutionResult(
          resultSets: <MssqlResultSet>[],
          affectedRows: 1,
          outputParameters: <String, Object?>{},
          messages: <MssqlServerMessage>[],
        ),
        0,
      )
      ..fail(StateError('late'), 0);
    failure!
      ..fail(const MssqlCancelledException(message: 'cancelled'), 0)
      ..complete(
        const MssqlExecutionResult(
          resultSets: <MssqlResultSet>[],
          affectedRows: 0,
          outputParameters: <String, Object?>{},
          messages: <MssqlServerMessage>[],
        ),
        0,
      );

    expect(observer.queryCompletes, hasLength(1));
    expect(observer.queryCompletes.single.queryName, 'idempotent.success');
    expect(observer.queryErrors, hasLength(1));
    expect(observer.queryErrors.single.queryName, 'idempotent.failure');
    expect(observer.queryErrors.single.error.cancelled, isTrue);
  });

  test('stream completion copies terminal metrics exactly once', () {
    final observer = RecordingMssqlObserver();
    final dispatcher = MssqlObservationDispatcher(observer);
    final stream = dispatcher.startQuery(
      kind: MssqlQueryKind.stream,
      queryName: 'reports.stream',
      target: target,
      inTransaction: false,
      connectionId: 31,
      transactionId: null,
    );

    stream!
      ..completeStream(
        MssqlExecutionComplete(
          affectedRows: 9,
          outputParameters: const <String, Object?>{},
          messages: const <MssqlServerMessage>[],
          metrics: const MssqlExecutionMetrics(
            queueWait: Duration(milliseconds: 1),
            executionElapsed: Duration(milliseconds: 3),
            rowCount: 7,
            decodedBytes: 80,
            resultSets: <MssqlResultSetMetrics>[],
          ),
        ),
        4,
      )
      ..fail(StateError('late'), 4);

    final event = observer.queryCompletes.single;
    expect(event.kind, MssqlQueryKind.stream);
    expect(event.returnedRows, 7);
    expect(event.affectedRows, 9);
    expect(event.connectionRepairCount, 4);
    expect(observer.queryErrors, isEmpty);
  });

  test('operation ids are unique and transaction identity propagates', () {
    final observer = RecordingMssqlObserver();
    final dispatcher = MssqlObservationDispatcher(observer, poolId: 41);
    final transaction = dispatcher.startTransaction(
      transactionName: 'checkout',
      target: target,
      connectionId: 42,
    );
    final query = dispatcher.startQuery(
      kind: MssqlQueryKind.procedure,
      queryName: 'checkout.reserve',
      target: target,
      inTransaction: true,
      connectionId: 42,
      transactionId: transaction!.transactionId,
    );
    final bulk = dispatcher.startBulk(
      bulkName: 'checkout.lines',
      target: target,
      inTransaction: true,
      connectionId: 42,
      transactionId: transaction.transactionId,
    );

    final ids = <int>{
      observer.transactionStarts.single.operationId,
      observer.queryStarts.single.operationId,
      observer.bulkStarts.single.operationId,
    };
    expect(ids, hasLength(3));
    expect(observer.queryStarts.single.poolId, 41);
    expect(observer.bulkStarts.single.poolId, 41);
    expect(
      observer.queryStarts.single.transactionId,
      observer.transactionStarts.single.transactionId,
    );
    expect(
      observer.bulkStarts.single.transactionId,
      observer.transactionStarts.single.transactionId,
    );

    query!.fail(StateError('stop'), 0);
    bulk!.fail(StateError('stop'), 0);
    transaction.fail(StateError('stop'), MssqlTransactionSettlement.rolledBack);
  });

  test(
    'safe error projection classifies cancellation and generic failures',
    () {
      final cancelled = observedError(
        const MssqlCancelledException(message: 'private cancellation reason'),
      );
      final generic = observedError(StateError('private state'));
      final settled = observedError(
        StateError('private transaction'),
        transactionSettlement: MssqlTransactionSettlement.rolledBack,
      );

      expect(cancelled.canonicalType, 'MssqlCancelledException');
      expect(cancelled.driverType, MssqlErrorType.cancelled);
      expect(cancelled.cancelled, isTrue);
      expect(cancelled.retryable, isFalse);
      expect(generic.canonicalType, 'StateError');
      expect(generic.driverType, isNull);
      expect(generic.code, 0);
      expect(generic.toString(), isNot(contains('private state')));
      expect(
        settled.transactionSettlement,
        MssqlTransactionSettlement.rolledBack,
      );
      expect(settled.toString(), isNot(contains('private transaction')));
    },
  );

  test('event surfaces retain safe names but not secret exception data', () {
    const secret = 'sql-or-password-SENTINEL';
    final observer = RecordingMssqlObserver();
    final dispatcher = MssqlObservationDispatcher(observer, poolId: 51);
    final observation = dispatcher.startQuery(
      kind: MssqlQueryKind.query,
      queryName: 'safe.low_cardinality_name',
      target: target,
      inTransaction: false,
      connectionId: 52,
      transactionId: null,
    );

    observation!.fail(
      const MssqlConnectionException(
        type: MssqlErrorType.connectionLost,
        message: secret,
        queryName: secret,
        diagnostics: <MssqlServerMessage>[
          MssqlServerMessage(
            number: 50000,
            severity: 16,
            state: 1,
            line: 1,
            message: secret,
          ),
        ],
      ),
      0,
    );

    final start = observer.queryStarts.single;
    final error = observer.queryErrors.single;
    expect(start.queryName, 'safe.low_cardinality_name');
    expect(error.queryName, 'safe.low_cardinality_name');
    expect(error.error.canonicalType, 'MssqlConnectionException');
    expect(error.error.toString(), isNot(contains(secret)));
    expect(start.toString(), isNot(contains(secret)));
    expect(error.toString(), isNot(contains(secret)));
  });

  test('a dispatcher without an observer uses its no-op path', () {
    final dispatcher = MssqlObservationDispatcher(null);

    expect(dispatcher.enabled, isFalse);
    expect(
      dispatcher.startQuery(
        kind: MssqlQueryKind.query,
        queryName: 'ignored',
        target: target,
        inTransaction: false,
        connectionId: 60,
        transactionId: null,
      ),
      isNull,
    );
    expect(
      dispatcher.startBulk(
        bulkName: 'ignored',
        target: target,
        inTransaction: false,
        connectionId: 60,
        transactionId: null,
      ),
      isNull,
    );
    expect(
      dispatcher.startTransaction(
        transactionName: 'ignored',
        target: target,
        connectionId: 60,
      ),
      isNull,
    );
  });
}
