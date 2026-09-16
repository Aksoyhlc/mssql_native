import 'dart:async';
import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

import 'support/live_server.dart';
import 'support/observability.dart';

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Condition was not reached before the deadline.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

MssqlPoolConfig _singleConnectionPool({
  Duration acquireTimeout = const Duration(seconds: 2),
}) => MssqlPoolConfig(
  maximumSize: 1,
  acquireTimeout: acquireTimeout,
  validationGracePeriod: const Duration(minutes: 1),
);

void main() {
  group('live observability', () {
    setUpAll(initializeLive);
    tearDownAll(() => MssqlRuntime.instance.shutdown());

    test('connection open and close describe one logical lifetime', () async {
      final observer = RecordingMssqlObserver();
      final connection = await MssqlConnection.open(
        liveConfig(),
        observer: observer,
      );

      expect(observer.connectionOpens, hasLength(1));
      final opened = observer.connectionOpens.single;
      expect(opened.connectionId, connection.connectionId);
      expect(opened.poolId, isNull);
      expect(opened.target.host, liveConfig().host);
      expect(opened.target.port, liveConfig().port);
      expect(opened.target.database, liveConfig().database);
      expect(opened.elapsed, isNot(lessThan(Duration.zero)));

      await connection.close();
      await connection.close();

      expect(observer.connectionCloses, hasLength(1));
      final closed = observer.connectionCloses.single;
      expect(closed.connectionId, opened.connectionId);
      expect(closed.repairCount, 0);
      expect(closed.lifetime, isNot(lessThan(Duration.zero)));
    }, skip: liveSkip);

    test('connection callback failures do not block open or close', () async {
      final observer = RecordingMssqlObserver(
        throwCallbacks: <String>{'onConnectionOpen', 'onConnectionClose'},
      );

      final connection = await MssqlConnection.open(
        liveConfig(),
        observer: observer,
      );
      expect(await connection.queryScalar<int>('SELECT CAST(1 AS int)'), 1);
      await connection.close();

      expect(observer.connectionOpens, hasLength(1));
      expect(observer.connectionCloses, hasLength(1));
      expect(observer.observerErrors, <String>[
        'onConnectionOpen',
        'onConnectionClose',
      ]);
    }, skip: liveSkip);

    test('named query reports exact metrics and a single terminal', () async {
      final observer = RecordingMssqlObserver();
      final connection = await MssqlConnection.open(
        liveConfig(),
        observer: observer,
      );
      addTearDown(connection.close);
      observer.clearOperations();

      final result = await connection.query(
        'SELECT CAST(1 AS int) AS n UNION ALL SELECT CAST(2 AS int)',
        options: const MssqlQueryOptions(queryName: 'numbers.two'),
      );

      expect(result.resultSets.single.rows, hasLength(2));
      expect(observer.queryStarts, hasLength(1));
      expect(observer.queryCompletes, hasLength(1));
      expect(observer.queryErrors, isEmpty);
      final start = observer.queryStarts.single;
      final complete = observer.queryCompletes.single;
      expect(complete.operationId, start.operationId);
      expect(start.kind, MssqlQueryKind.query);
      expect(start.queryName, 'numbers.two');
      expect(complete.queryName, 'numbers.two');
      expect(complete.returnedRows, 2);
      expect(complete.metrics.rowCount, 2);
      expect(complete.metrics.resultSets.single.rowCount, 2);
      expect(complete.attemptCount, 1);
      expect(complete.connectionRepaired, isFalse);
      expect(complete.connectionRepairCount, 0);
      expect(complete.connectionId, connection.connectionId);
    }, skip: liveSkip);

    test('query terminal helpers do not create nested observations', () async {
      final observer = RecordingMssqlObserver();
      final connection = await MssqlConnection.open(
        liveConfig(),
        observer: observer,
      );
      addTearDown(connection.close);
      observer.clearOperations();

      expect(
        await connection.queryScalar<int>(
          'SELECT CAST(42 AS int)',
          options: const MssqlQueryOptions(queryName: 'answer.scalar'),
        ),
        42,
      );

      expect(observer.queryStarts, hasLength(1));
      expect(observer.queryCompletes, hasLength(1));
      expect(observer.queryCompletes.single.returnedRows, 1);
    }, skip: liveSkip);

    test('query callback failures do not change database results', () async {
      final startObserver = RecordingMssqlObserver(
        throwCallbacks: <String>{'onQueryStart'},
      );
      final startConnection = await MssqlConnection.open(
        liveConfig(),
        observer: startObserver,
      );
      addTearDown(startConnection.close);

      expect(
        await startConnection.queryScalar<int>('SELECT CAST(5 AS int)'),
        5,
      );
      expect(startObserver.queryStarts, hasLength(1));
      expect(startObserver.queryCompletes, isEmpty);
      expect(startObserver.queryErrors, isEmpty);
      expect(startObserver.observerErrors, <String>['onQueryStart']);

      final terminalObserver = RecordingMssqlObserver(
        throwCallbacks: <String>{'onQueryComplete'},
      );
      final terminalConnection = await MssqlConnection.open(
        liveConfig(),
        observer: terminalObserver,
      );
      addTearDown(terminalConnection.close);

      expect(
        await terminalConnection.queryScalar<int>('SELECT CAST(6 AS int)'),
        6,
      );
      expect(terminalObserver.queryCompletes, hasLength(1));
      expect(terminalObserver.observerErrors, <String>['onQueryComplete']);
    }, skip: liveSkip);

    test('procedure metadata lookup is not a separate observation', () async {
      final observer = RecordingMssqlObserver();
      final connection = await MssqlConnection.open(
        liveConfig(),
        observer: observer,
      );
      addTearDown(connection.close);
      observer.clearOperations();

      final result = await connection.callProcedure(
        'dbo.usp_customer_dashboard',
        parameters: const <String, Object?>{
          'customer_id': 1,
          'order_count': null,
        },
        outputParameters: const <String>{'order_count'},
        options: const MssqlQueryOptions(queryName: 'customers.dashboard'),
      );

      expect(result.returnStatus, 0);
      expect(observer.queryStarts, hasLength(1));
      expect(observer.queryCompletes, hasLength(1));
      expect(observer.queryStarts.single.kind, MssqlQueryKind.procedure);
      expect(observer.queryStarts.single.queryName, 'customers.dashboard');
    }, skip: liveSkip);

    test('stream starts on listen and completes once', () async {
      final observer = RecordingMssqlObserver();
      final connection = await MssqlConnection.open(
        liveConfig(),
        observer: observer,
      );
      addTearDown(connection.close);
      observer.clearOperations();

      final stream = connection.stream(
        'SELECT id FROM dbo.customers ORDER BY id',
        options: const MssqlQueryOptions(queryName: 'customers.stream'),
        batchRows: 2,
      );
      expect(observer.queryStarts, isEmpty);

      final events = await stream.toList();

      expect(events.whereType<MssqlRowBatch>(), isNotEmpty);
      expect(observer.queryStarts, hasLength(1));
      expect(observer.queryCompletes, hasLength(1));
      expect(observer.queryErrors, isEmpty);
      expect(observer.queryStarts.single.kind, MssqlQueryKind.stream);
      expect(observer.queryCompletes.single.returnedRows, 5);
    }, skip: liveSkip);

    test('stream SQL failure emits one safe error terminal', () async {
      final observer = RecordingMssqlObserver();
      final connection = await MssqlConnection.open(
        liveConfig(),
        observer: observer,
      );
      addTearDown(connection.close);
      observer.clearOperations();

      await expectLater(
        connection
            .stream(
              'SELECT * FROM dbo.observability_table_that_does_not_exist',
              options: const MssqlQueryOptions(queryName: 'stream.failure'),
            )
            .toList(),
        throwsA(isA<MssqlException>()),
      );

      expect(observer.queryStarts, hasLength(1));
      expect(observer.queryCompletes, isEmpty);
      expect(observer.queryErrors, hasLength(1));
      expect(observer.queryErrors.single.kind, MssqlQueryKind.stream);
      expect(observer.queryErrors.single.queryName, 'stream.failure');
      expect(
        observer.queryErrors.single.error.canonicalType,
        isNot(contains('observability_table_that_does_not_exist')),
      );
    }, skip: liveSkip);

    test('early stream cancellation emits one cancelled terminal', () async {
      final observer = RecordingMssqlObserver();
      final connection = await MssqlConnection.open(
        liveConfig(),
        observer: observer,
      );
      addTearDown(connection.close);
      observer.clearOperations();
      final firstBatch = Completer<void>();
      late StreamSubscription<MssqlStreamEvent> subscription;

      subscription = connection
          .stream(
            'SELECT TOP (5000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n '
            'FROM sys.all_objects a CROSS JOIN sys.all_objects b',
            options: const MssqlQueryOptions(queryName: 'stream.cancel'),
            batchRows: 1,
          )
          .listen((event) {
            if (event is MssqlRowBatch && !firstBatch.isCompleted) {
              firstBatch.complete();
            }
          });
      await firstBatch.future.timeout(const Duration(seconds: 5));
      await subscription.cancel();

      expect(observer.queryStarts, hasLength(1));
      expect(observer.queryCompletes, isEmpty);
      expect(observer.queryErrors, hasLength(1));
      expect(observer.queryErrors.single.error.cancelled, isTrue);
    }, skip: liveSkip);

    test('pooled query delegates one observation to one connection', () async {
      final observer = RecordingMssqlObserver();
      final pool = MssqlConnectionPool(
        liveConfig(),
        poolConfig: _singleConnectionPool(),
        observer: observer,
      );
      addTearDown(pool.close);

      final value = await pool.session.queryScalar<int>(
        'SELECT CAST(7 AS int)',
        options: const MssqlQueryOptions(queryName: 'pool.scalar'),
      );

      expect(value, 7);
      expect(observer.queryStarts, hasLength(1));
      expect(observer.queryCompletes, hasLength(1));
      expect(observer.queryErrors, isEmpty);
      expect(observer.queryStarts.single.poolId, pool.poolId);
      expect(observer.queryStarts.single.connectionId, isNull);
      expect(observer.queryCompletes.single.poolId, pool.poolId);
      expect(observer.queryCompletes.single.connectionId, isNotNull);
      expect(observer.connectionOpens.single.poolId, pool.poolId);
    }, skip: liveSkip);

    test('pooled procedure and stream each produce one observation', () async {
      final observer = RecordingMssqlObserver();
      final pool = MssqlConnectionPool(
        liveConfig(),
        poolConfig: _singleConnectionPool(),
        observer: observer,
      );
      addTearDown(pool.close);

      final procedure = await pool.session.callProcedure(
        'dbo.usp_customer_dashboard',
        parameters: const <String, Object?>{
          'customer_id': 1,
          'order_count': null,
        },
        outputParameters: const <String>{'order_count'},
        options: const MssqlQueryOptions(queryName: 'pool.dashboard'),
      );
      final streamEvents = await pool.session
          .stream(
            'SELECT id FROM dbo.customers ORDER BY id',
            options: const MssqlQueryOptions(queryName: 'pool.stream'),
            batchRows: 2,
          )
          .toList();

      expect(procedure.returnStatus, 0);
      expect(streamEvents.whereType<MssqlRowBatch>(), isNotEmpty);
      expect(observer.queryStarts, hasLength(2));
      expect(observer.queryCompletes, hasLength(2));
      expect(observer.queryErrors, isEmpty);
      expect(observer.queryStarts.map((event) => event.kind), <MssqlQueryKind>[
        MssqlQueryKind.procedure,
        MssqlQueryKind.stream,
      ]);
      expect(
        observer.queryCompletes.every((event) => event.poolId == pool.poolId),
        isTrue,
      );
      expect(
        observer.queryCompletes.every((event) => event.connectionId != null),
        isTrue,
      );
    }, skip: liveSkip);

    test('pooled bulk produces one pool-scoped observation', () async {
      final admin = await MssqlConnection.open(liveConfig());
      addTearDown(admin.close);
      final suffix = '${DateTime.now().microsecondsSinceEpoch}_$pid';
      final table = 'dbo.observability_pool_bulk_$suffix';
      await admin.execute('CREATE TABLE $table (id int NOT NULL);');
      addTearDown(() => admin.execute('DROP TABLE IF EXISTS $table;'));
      final observer = RecordingMssqlObserver();
      final pool = MssqlConnectionPool(
        liveConfig(),
        poolConfig: _singleConnectionPool(),
        observer: observer,
      );
      addTearDown(pool.close);

      final result = await pool.session.bulkInsert(
        tableName: table,
        rows: const <Map<String, Object?>>[
          <String, Object?>{'id': 1},
          <String, Object?>{'id': 2},
        ],
        options: const MssqlBulkOptions(bulkName: 'pool.bulk'),
      );

      expect(result.insertedRows, 2);
      expect(observer.bulkStarts, hasLength(1));
      expect(observer.bulkCompletes, hasLength(1));
      expect(observer.bulkErrors, isEmpty);
      expect(observer.bulkStarts.single.poolId, pool.poolId);
      expect(observer.bulkStarts.single.connectionId, isNull);
      expect(observer.bulkCompletes.single.poolId, pool.poolId);
      expect(observer.bulkCompletes.single.connectionId, isNotNull);
    }, skip: liveSkip);

    test('pool wait reports acquired with a final snapshot', () async {
      final observer = RecordingMssqlObserver();
      final pool = MssqlConnectionPool(
        liveConfig(),
        poolConfig: _singleConnectionPool(),
        observer: observer,
      );
      addTearDown(pool.close);
      final held = await pool.acquire();
      final waiting = pool.acquire();
      await _waitUntil(() => pool.waitingCount == 1);

      await pool.release(held);
      final acquired = await waiting;

      expect(observer.poolWaits, hasLength(1));
      final event = observer.poolWaits.single;
      expect(event.outcome, MssqlPoolWaitOutcome.acquired);
      expect(event.poolId, pool.poolId);
      expect(event.metrics.created, 1);
      expect(event.metrics.borrowed, 1);
      expect(event.metrics.waiting, 0);
      expect(event.metrics.maximumSize, 1);
      await pool.release(acquired);
    }, skip: liveSkip);

    test('pool wait reports timeout', () async {
      final observer = RecordingMssqlObserver();
      final pool = MssqlConnectionPool(
        liveConfig(),
        poolConfig: _singleConnectionPool(
          acquireTimeout: const Duration(milliseconds: 120),
        ),
        observer: observer,
      );
      addTearDown(pool.close);
      final held = await pool.acquire();

      await expectLater(
        pool.acquire(),
        throwsA(isA<MssqlPoolTimeoutException>()),
      );

      expect(observer.poolWaits, hasLength(1));
      expect(observer.poolWaits.single.outcome, MssqlPoolWaitOutcome.timedOut);
      expect(observer.poolWaits.single.metrics.waiting, 0);
      await pool.release(held);
    }, skip: liveSkip);

    test('pool wait reports cancellation', () async {
      final observer = RecordingMssqlObserver();
      final pool = MssqlConnectionPool(
        liveConfig(),
        poolConfig: _singleConnectionPool(),
        observer: observer,
      );
      addTearDown(pool.close);
      final held = await pool.acquire();
      final token = MssqlCancellationToken();
      final waiting = pool.acquire(cancellationToken: token);
      await _waitUntil(() => pool.waitingCount == 1);

      token.cancel('test cancellation');
      await expectLater(waiting, throwsA(isA<MssqlCancelledException>()));

      expect(observer.poolWaits, hasLength(1));
      expect(observer.poolWaits.single.outcome, MssqlPoolWaitOutcome.cancelled);
      await pool.release(held);
    }, skip: liveSkip);

    test('pool wait reports pool closure', () async {
      final observer = RecordingMssqlObserver();
      final pool = MssqlConnectionPool(
        liveConfig(),
        poolConfig: _singleConnectionPool(),
        observer: observer,
      );
      final held = await pool.acquire();
      final waiting = pool.acquire();
      await _waitUntil(() => pool.waitingCount == 1);
      final closedWaiter = expectLater(waiting, throwsA(isA<StateError>()));

      await pool.close();
      await closedWaiter;

      expect(observer.poolWaits, hasLength(1));
      expect(
        observer.poolWaits.single.outcome,
        MssqlPoolWaitOutcome.poolClosed,
      );
      await pool.release(held);
    }, skip: liveSkip);

    test('bulk success reports exact safe copy metrics', () async {
      final observer = RecordingMssqlObserver();
      final connection = await MssqlConnection.open(
        liveConfig(),
        observer: observer,
      );
      addTearDown(connection.close);
      final suffix = '${DateTime.now().microsecondsSinceEpoch}_$pid';
      final table = 'dbo.observability_bulk_$suffix';
      await connection.execute('CREATE TABLE $table (id int NOT NULL);');
      addTearDown(() => connection.execute('DROP TABLE IF EXISTS $table;'));
      observer.clearOperations();

      final result = await connection.bulkInsert(
        tableName: table,
        rows: const <Map<String, Object?>>[
          <String, Object?>{'id': 1},
          <String, Object?>{'id': 2},
          <String, Object?>{'id': 3},
        ],
        options: const MssqlBulkOptions(
          bulkName: 'imports.observability',
          batchSize: 2,
        ),
      );

      expect(result.insertedRows, 3);
      expect(observer.bulkStarts, hasLength(1));
      expect(observer.bulkCompletes, hasLength(1));
      expect(observer.bulkErrors, isEmpty);
      final event = observer.bulkCompletes.single;
      expect(event.bulkName, 'imports.observability');
      expect(event.totalRows, result.totalRows);
      expect(event.insertedRows, result.insertedRows);
      expect(event.committedBatches, result.committedBatches);
      expect(event.failedRowIndex, result.failedRowIndex);
      expect(event.toString(), isNot(contains(table)));
    }, skip: liveSkip);

    test(
      'bulk failure exposes classification without destination data',
      () async {
        final observer = RecordingMssqlObserver();
        final connection = await MssqlConnection.open(
          liveConfig(),
          observer: observer,
        );
        addTearDown(connection.close);
        final suffix = '${DateTime.now().microsecondsSinceEpoch}_$pid';
        final table = 'dbo.observability_secret_$suffix';
        await connection.execute('CREATE TABLE $table (id int NOT NULL);');
        addTearDown(() => connection.execute('DROP TABLE IF EXISTS $table;'));
        observer.clearOperations();

        await expectLater(
          connection.bulkInsert(
            tableName: table,
            rows: const <Map<String, Object?>>[
              <String, Object?>{'wrong_column': 1},
            ],
            options: const MssqlBulkOptions(bulkName: 'imports.invalid'),
          ),
          throwsA(anything),
        );

        expect(observer.bulkStarts, hasLength(1));
        expect(observer.bulkCompletes, isEmpty);
        expect(observer.bulkErrors, hasLength(1));
        expect(observer.bulkErrors.single.bulkName, 'imports.invalid');
        expect(observer.bulkErrors.single.toString(), isNot(contains(table)));
        expect(
          observer.bulkErrors.single.error.toString(),
          isNot(contains('wrong_column')),
        );
      },
      skip: liveSkip,
    );

    test(
      'transaction query and bulk share their parent transaction id',
      () async {
        final observer = RecordingMssqlObserver();
        final connection = await MssqlConnection.open(
          liveConfig(),
          observer: observer,
        );
        addTearDown(connection.close);
        final suffix = '${DateTime.now().microsecondsSinceEpoch}_$pid';
        final table = 'dbo.observability_tx_bulk_$suffix';
        await connection.execute('CREATE TABLE $table (id int NOT NULL);');
        addTearDown(() => connection.execute('DROP TABLE IF EXISTS $table;'));
        observer.clearOperations();

        final transaction = await connection.beginTransaction(
          transactionName: 'checkout.manual',
        );
        await transaction.queryScalar<int>(
          'SELECT CAST(9 AS int)',
          options: const MssqlQueryOptions(queryName: 'checkout.read'),
        );
        await transaction.bulkInsert(
          tableName: table,
          rows: const <Map<String, Object?>>[
            <String, Object?>{'id': 9},
          ],
          options: const MssqlBulkOptions(bulkName: 'checkout.lines'),
        );
        await transaction.rollback();
        await transaction.close();

        final transactionId = observer.transactionStarts.single.transactionId;
        expect(observer.queryStarts.single.transactionId, transactionId);
        expect(observer.queryStarts.single.inTransaction, isTrue);
        expect(observer.bulkStarts.single.transactionId, transactionId);
        expect(observer.bulkStarts.single.inTransaction, isTrue);
        expect(observer.transactionCompletes, hasLength(1));
        expect(
          observer.transactionCompletes.single.outcome,
          MssqlTransactionOutcome.rolledBack,
        );
        expect(observer.transactionErrors, isEmpty);
      },
      skip: liveSkip,
    );

    test(
      'transaction procedure and stream share one parent identity',
      () async {
        final observer = RecordingMssqlObserver();
        final connection = await MssqlConnection.open(
          liveConfig(),
          observer: observer,
        );
        addTearDown(connection.close);
        observer.clearOperations();

        final transaction = await connection.beginTransaction(
          transactionName: 'transaction.session.surface',
        );
        final procedure = await transaction.callProcedure(
          'dbo.usp_customer_dashboard',
          parameters: const <String, Object?>{
            'customer_id': 1,
            'order_count': null,
          },
          outputParameters: const <String>{'order_count'},
          options: const MssqlQueryOptions(queryName: 'transaction.procedure'),
        );
        final streamEvents = await transaction
            .stream(
              'SELECT id FROM dbo.customers ORDER BY id',
              options: const MssqlQueryOptions(queryName: 'transaction.stream'),
            )
            .toList();
        await transaction.rollback();
        await transaction.close();

        expect(procedure.returnStatus, 0);
        expect(streamEvents.whereType<MssqlRowBatch>(), isNotEmpty);
        expect(observer.queryStarts, hasLength(2));
        expect(observer.queryCompletes, hasLength(2));
        final transactionId = observer.transactionStarts.single.transactionId;
        expect(
          observer.queryStarts.every(
            (event) => event.transactionId == transactionId,
          ),
          isTrue,
        );
        expect(
          observer.queryStarts.every((event) => event.inTransaction),
          isTrue,
        );
        expect(
          observer.queryStarts.map((event) => event.kind),
          <MssqlQueryKind>[MssqlQueryKind.procedure, MssqlQueryKind.stream],
        );
      },
      skip: liveSkip,
    );

    test('manual commit reports one committed terminal', () async {
      final observer = RecordingMssqlObserver();
      final connection = await MssqlConnection.open(
        liveConfig(),
        observer: observer,
      );
      addTearDown(connection.close);
      observer.clearOperations();

      final transaction = await connection.beginTransaction(
        transactionName: 'transaction.commit',
      );
      await transaction.commit();
      await transaction.close();

      expect(observer.transactionCompletes, hasLength(1));
      expect(
        observer.transactionCompletes.single.outcome,
        MssqlTransactionOutcome.committed,
      );
      expect(observer.transactionErrors, isEmpty);
    }, skip: liveSkip);

    test('implicit close reports one rolled-back terminal', () async {
      final observer = RecordingMssqlObserver();
      final connection = await MssqlConnection.open(
        liveConfig(),
        observer: observer,
      );
      addTearDown(connection.close);
      observer.clearOperations();

      final transaction = await connection.beginTransaction(
        transactionName: 'transaction.close',
      );
      await transaction.close();
      await transaction.close();

      expect(observer.transactionCompletes, hasLength(1));
      expect(
        observer.transactionCompletes.single.outcome,
        MssqlTransactionOutcome.rolledBack,
      );
      expect(observer.transactionErrors, isEmpty);
    }, skip: liveSkip);

    test('callback failure reports rolled-back settlement once', () async {
      final observer = RecordingMssqlObserver();
      final connection = await MssqlConnection.open(
        liveConfig(),
        observer: observer,
      );
      addTearDown(connection.close);
      observer.clearOperations();
      final failure = StateError('application callback failed');

      await expectLater(
        connection.transaction<void>((transaction) async {
          await transaction.queryScalar<int>('SELECT CAST(1 AS int)');
          throw failure;
        }, transactionName: 'transaction.callback'),
        throwsA(same(failure)),
      );

      expect(observer.transactionCompletes, isEmpty);
      expect(observer.transactionErrors, hasLength(1));
      final event = observer.transactionErrors.single;
      expect(event.settlement, MssqlTransactionSettlement.rolledBack);
      expect(
        event.error.transactionSettlement,
        MssqlTransactionSettlement.rolledBack,
      );
      expect(event.error.canonicalType, 'StateError');
      expect(
        event.error.toString(),
        isNot(contains('application callback failed')),
      );
    }, skip: liveSkip);
  });
}
