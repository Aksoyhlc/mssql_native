import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

import 'support/live_server.dart';

void main() {
  group('transaction failure ownership', () {
    late MssqlConnection connection;
    setUpAll(initializeLive);
    tearDownAll(() => MssqlRuntime.instance.shutdown());
    setUp(() async {
      connection = await MssqlConnection.open(liveConfig());
    });
    tearDown(() => connection.close());

    test('callback error survives a failed cleanup rollback', () async {
      final original = StateError('original callback failure');
      await expectLater(
        connection.transaction<void>((tx) async {
          await tx.execute('ROLLBACK TRANSACTION;');
          throw original;
        }),
        throwsA(same(original)),
      );
    });

    test('original stack survives a failed cleanup rollback', () async {
      final original = StateError('original');
      final stack = StackTrace.fromString('original-transaction-stack');
      try {
        await connection.transaction<void>((tx) async {
          await tx.execute('ROLLBACK TRANSACTION;');
          Error.throwWithStackTrace(original, stack);
        });
        fail('Expected the callback failure');
      } catch (error, actualStack) {
        expect(error, same(original));
        expect(actualStack.toString(), contains('original-transaction-stack'));
      }
    });

    test(
      'a rejected rollback still surfaces, on a session proven clean',
      () async {
        final tx = await connection.beginTransaction();
        await tx.execute('ROLLBACK TRANSACTION;');
        await expectLater(tx.rollback(), throwsA(isA<MssqlException>()));
        expect(connection.isClosed, isFalse);
        await tx.close();
        expect(await connection.queryScalar<int>('SELECT @@TRANCOUNT'), 0);
        expect(await connection.queryScalar<int>('SELECT 1'), 1);
      },
    );

    test(
      'implicit close releases the lease when the session is clean',
      () async {
        final tx = await connection.beginTransaction();
        await tx.execute('ROLLBACK TRANSACTION;');
        await tx.close();
        expect(connection.isClosed, isFalse);
        expect(await connection.queryScalar<int>('SELECT 1'), 1);
      },
    );

    test('a session that cannot be inspected is discarded', () async {
      final spid = await connection.queryScalar<int>('SELECT @@SPID');
      final tx = await connection.beginTransaction();
      final killer = await MssqlConnection.open(liveConfig());
      addTearDown(killer.close);
      await killer.execute('KILL $spid;');
      await tx.close();
      expect(connection.isClosed, isTrue);
    });

    test('callback result is returned after successful commit', () async {
      expect(
        await connection.transaction((tx) => tx.queryScalar<int>('SELECT 42')),
        42,
      );
      expect(await connection.queryScalar<int>('SELECT @@TRANCOUNT'), 0);
    });

    test('callback failure rolls back its writes', () async {
      await connection.execute('CREATE TABLE #tx_regression (id int);');
      final original = StateError('rollback this');
      await expectLater(
        connection.transaction<void>((tx) async {
          await tx.execute('INSERT INTO #tx_regression VALUES (1);');
          throw original;
        }),
        throwsA(same(original)),
      );
      expect(
        await connection.queryScalar<int>(
          'SELECT COUNT(*) FROM #tx_regression',
        ),
        0,
      );
      expect(await connection.queryScalar<int>('SELECT @@TRANCOUNT'), 0);
    });

    test('close without commit rolls back and releases the lease', () async {
      final tx = await connection.beginTransaction();
      await tx.close();
      expect(await connection.queryScalar<int>('SELECT @@TRANCOUNT'), 0);
      await tx.close();
    });

    test('manual rollback is idempotent', () async {
      final tx = await connection.beginTransaction();
      await tx.rollback();
      await tx.rollback();
      await tx.close();
      expect(await connection.queryScalar<int>('SELECT @@TRANCOUNT'), 0);
    });

    test(
      'a pooled transaction preserves the callback failure and the pool',
      () async {
        final pool = MssqlConnectionPool(
          liveConfig(),
          poolConfig: const MssqlPoolConfig(maximumSize: 1),
        );
        addTearDown(pool.close);
        final original = StateError('pooled-original');
        await expectLater(
          pool.transaction<void>((tx) async {
            await tx.execute('ROLLBACK TRANSACTION;');
            throw original;
          }),
          throwsA(same(original)),
        );
        await pool.withConnection((next) async {
          expect(next.isClosed, isFalse);
          expect(await next.queryScalar<int>('SELECT @@TRANCOUNT'), 0);
        });
      },
    );

    test(
      'a pooled transaction on a killed session hands back a fresh one',
      () async {
        final pool = MssqlConnectionPool(
          liveConfig(),
          poolConfig: const MssqlPoolConfig(maximumSize: 1),
        );
        addTearDown(pool.close);
        final killer = await MssqlConnection.open(liveConfig());
        addTearDown(killer.close);
        MssqlConnection? borrowed;
        final original = StateError('killed-original');
        await expectLater(
          pool.transaction<void>((tx) async {
            borrowed = tx.connection;
            final spid = await tx.queryScalar<int>('SELECT @@SPID');
            await killer.execute('KILL $spid;');
            throw original;
          }),
          throwsA(same(original)),
        );
        expect(borrowed!.isClosed, isTrue);
        await pool.withConnection((next) async {
          expect(identical(next, borrowed), isFalse);
          expect(await next.queryScalar<int>('SELECT @@TRANCOUNT'), 0);
        });
      },
    );
  }, skip: liveSkip);

  group('the whole session surface works through the transaction handle', () {
    late MssqlConnection connection;
    setUpAll(initializeLive);
    tearDownAll(() => MssqlRuntime.instance.shutdown());
    setUp(() async {
      connection = await MssqlConnection.open(liveConfig());
    });
    tearDown(() => connection.close());

    test('ping', () async {
      await connection.transaction<void>((tx) async {
        await tx.ping();
        expect(await tx.queryScalar<int>('SELECT @@TRANCOUNT'), greaterThan(0));
      });
    });

    test(
      'callProcedure, with its output parameter and return status',
      () async {
        await connection.transaction<void>((tx) async {
          final result = await tx.callProcedure(
            'dbo.usp_customer_dashboard',
            parameters: <String, Object?>{
              'customer_id': 1,
              'order_count': null,
            },
            outputParameters: <String>{'order_count'},
          );
          expect(result.resultSets, isNotEmpty);
          expect(result.outputParameters['order_count'], isA<int>());
          expect(
            await tx.queryScalar<int>('SELECT @@TRANCOUNT'),
            greaterThan(0),
          );
        });
      },
    );

    test('stream', () async {
      await connection.transaction<void>((tx) async {
        var rows = 0;
        await for (final event in tx.stream('SELECT id FROM dbo.customers')) {
          if (event is MssqlRowBatch) rows += event.rows.length;
        }
        expect(rows, greaterThan(0));
      });
    });

    test('streamRows, which the session mixin builds on stream', () async {
      await connection.transaction<void>((tx) async {
        final ids = await tx
            .streamRows('SELECT id FROM dbo.customers ORDER BY id')
            .toList();
        expect(ids, isNotEmpty);
      });
    });

    test('bulkInsert', () async {
      await connection.execute(
        'DROP TABLE IF EXISTS dbo.tx_bulk_probe; '
        'CREATE TABLE dbo.tx_bulk_probe (id int NOT NULL, name nvarchar(40) NULL);',
      );
      addTearDown(
        () => connection.execute('DROP TABLE IF EXISTS dbo.tx_bulk_probe;'),
      );
      await connection.transaction<void>((tx) async {
        final result = await tx.bulkInsert(
          tableName: 'dbo.tx_bulk_probe',
          rows: <Map<String, Object?>>[
            <String, Object?>{'id': 1, 'name': 'bir'},
            <String, Object?>{'id': 2, 'name': 'iki'},
          ],
        );
        expect(result.insertedRows, 2);
      });
      expect(
        await connection.queryScalar<int>(
          'SELECT COUNT(*) FROM dbo.tx_bulk_probe',
        ),
        2,
      );
    });

    test('a rolled-back transaction undoes what the procedure wrote', () async {
      await connection.execute('CREATE TABLE #tx_proc (id int);');
      final original = StateError('roll this back');
      await expectLater(
        connection.transaction<void>((tx) async {
          await tx.execute('INSERT INTO #tx_proc VALUES (1);');
          await tx.ping();
          await tx.callProcedure(
            'dbo.usp_customer_dashboard',
            parameters: <String, Object?>{
              'customer_id': 1,
              'order_count': null,
            },
            outputParameters: <String>{'order_count'},
          );
          throw original;
        }),
        throwsA(same(original)),
      );
      expect(
        await connection.queryScalar<int>('SELECT COUNT(*) FROM #tx_proc'),
        0,
      );
    });

    test(
      'the connection itself is still refused while the lease is held',
      () async {
        final tx = await connection.beginTransaction();
        addTearDown(tx.close);
        await expectLater(connection.ping(), throwsA(isA<StateError>()));
        await expectLater(
          connection.callProcedure('dbo.usp_customer_dashboard'),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          connection.stream('SELECT 1').toList(),
          throwsA(isA<StateError>()),
        );
      },
    );
  }, skip: liveSkip);
}

