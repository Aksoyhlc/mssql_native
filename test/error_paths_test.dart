import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

import 'support/live_server.dart';

void main() {
  group('error paths', () {
    late MssqlConnection connection;

    setUpAll(initializeLive);
    tearDownAll(() => MssqlRuntime.instance.shutdown());
    setUp(() async {
      connection = await MssqlConnection.open(liveConfig());
    });
    tearDown(() => connection.close());

    Future<void> expectStillUsable() async {
      expect(await connection.queryScalar<int>('SELECT 1'), 1);
      expect(await connection.queryScalar<int>('SELECT @@TRANCOUNT'), 0);
    }

    group('messages that are not failures', () {
      test('PRINT output is reported without failing the call', () async {
        final result = await connection.query(
          "PRINT N'ilk satır'; SELECT 1 AS ok; PRINT N'son satır';",
        );
        expect(result.resultSets.single.rows.single['ok'], 1);
        expect(
          result.messages.map((m) => m.message).join('|'),
          allOf(contains('ilk satır'), contains('son satır')),
        );
        expect(result.messages.every((m) => m.severity <= 10), isTrue);
      });

      test('a severity 10 RAISERROR is informational, not an error', () async {
        final result = await connection.query(
          "RAISERROR (N'sadece bilgi', 10, 1); SELECT 2 AS ok;",
        );
        expect(result.resultSets.single.rows.single['ok'], 2);
        expect(
          result.messages.any((m) => m.message.contains('sadece bilgi')),
          isTrue,
        );
      });
    });

    group('errors raised mid-batch', () {
      test('an error after a result set still fails the call', () async {
        await expectLater(
          connection.query(
            "SELECT 1 AS ok; RAISERROR (N'ikinci adım', 16, 1);",
          ),
          throwsA(
            isA<MssqlException>().having(
              (e) => e.message,
              'message',
              contains('ikinci adım'),
            ),
          ),
        );
        await expectStillUsable();
      });

      test('a RAISERROR does not stop the statements after it', () async {
        await connection.execute('CREATE TABLE #after_error (id INT);');
        await expectLater(
          connection.query('''
INSERT INTO #after_error VALUES (1);
RAISERROR (N'dur', 16, 1);
INSERT INTO #after_error VALUES (2);
'''),
          throwsA(isA<MssqlException>()),
        );
        final ids = await connection.queryRows(
          'SELECT id FROM #after_error ORDER BY id',
        );
        expect(ids.map((row) => row['id']), <int>[1, 2]);
        await expectStillUsable();
      });

      test('a run-time error does stop the statements after it', () async {
        await connection.execute('CREATE TABLE #after_runtime (id INT);');
        await expectLater(
          connection.query('''
INSERT INTO #after_runtime VALUES (1);
INSERT INTO #after_runtime VALUES (1 / 0);
INSERT INTO #after_runtime VALUES (3);
'''),
          throwsA(isA<MssqlException>().having((e) => e.code, 'code', 8134)),
        );
        final ids = await connection.queryRows(
          'SELECT id FROM #after_runtime ORDER BY id',
        );
        expect(ids.map((row) => row['id']), <int>[1]);
        await expectStillUsable();
      });

      test(
        'the first error is the one reported, and it carries diagnostics',
        () async {
          try {
            await connection.query('''
RAISERROR (N'birinci hata', 16, 1);
RAISERROR (N'ikinci hata', 16, 1);
''');
            fail('the batch had to fail');
          } on MssqlException catch (error) {
            expect(error.message, contains('birinci hata'));
            expect(
              error.diagnostics,
              isNotEmpty,
              reason: 'the server message must survive on the exception',
            );
            expect(error.diagnostics.first.number, 50000);
          }
          await expectStillUsable();
        },
      );

      test(
        'a batch that fails while starting leaves the session clean',
        () async {
          await expectLater(
            connection.query(
              "RAISERROR (N'bir', 16, 1); RAISERROR (N'iki', 16, 1);",
            ),
            throwsA(isA<MssqlException>()),
          );
          expect(await connection.queryScalar<int>('SELECT 7'), 7);
          expect(await connection.queryScalar<int>('SELECT 8'), 8);
        },
      );

      test('an error carries its number, severity, state and line', () async {
        try {
          await connection.query(
            "\nSELECT 1;\nRAISERROR (N'satır üç', 16, 7);",
          );
          fail('the batch had to fail');
        } on MssqlException catch (error) {
          expect(
            error.code,
            50000,
            reason: 'ad-hoc RAISERROR is message 50000',
          );
          final raised = error.diagnostics
              .where((m) => m.message.contains('satır üç'))
              .toList();
          expect(raised, isNotEmpty);
          expect(raised.single.severity, 16);
          expect(raised.single.state, 7);
          expect(raised.single.line, 3);
        }
      });

      test('a THROW is classified like the error it names', () async {
        await expectLater(
          connection.query("THROW 51000, N'fırlatıldı', 1;"),
          throwsA(
            isA<MssqlException>()
                .having((e) => e.code, 'code', 51000)
                .having((e) => e.message, 'message', contains('fırlatıldı')),
          ),
        );
        await expectStillUsable();
      });

      test('a long error message survives intact', () async {
        final long = 'ş' * 1200;
        try {
          await connection.query("RAISERROR (N'$long', 16, 1);");
          fail('the batch had to fail');
        } on MssqlException catch (error) {
          final text = <String>[
            error.message,
            for (final message in error.diagnostics) message.message,
          ].join();
          expect(
            text,
            contains('ş' * 1000),
            reason: 'the message must not be cut short or re-encoded',
          );
        }
      });
    });

    group('arithmetic and conversion failures', () {
      test('divide by zero is a query error the session survives', () async {
        await expectLater(
          connection.queryScalar<int>('SELECT 1 / 0'),
          throwsA(
            isA<MssqlException>()
                .having((e) => e.code, 'code', 8134)
                .having((e) => e.type, 'type', MssqlErrorType.querySyntax),
          ),
        );
        await expectStillUsable();
      });

      test('arithmetic overflow is reported, not silently wrapped', () async {
        await expectLater(
          connection.queryScalar<int>('SELECT CAST(2147483648 AS INT)'),
          throwsA(
            isA<MssqlException>()
                .having((e) => e.code, 'code', 8115)
                .having((e) => e.type, 'type', MssqlErrorType.querySyntax),
          ),
        );
        await expectStillUsable();
      });

      test('a failed conversion names the value', () async {
        await expectLater(
          connection.queryScalar<int>("SELECT CAST(N'abc' AS INT)"),
          throwsA(
            isA<MssqlException>().having(
              (e) => e.message,
              'message',
              contains('abc'),
            ),
          ),
        );
        await expectStillUsable();
      });

      test(
        'a string that does not fit is an error, not a truncation',
        () async {
          await connection.execute('CREATE TABLE #narrow (v NVARCHAR(3));');
          await expectLater(
            connection.execute("INSERT INTO #narrow VALUES (N'çok uzun');"),
            throwsA(isA<MssqlException>()),
          );
          expect(
            await connection.queryScalar<int>('SELECT COUNT(*) FROM #narrow'),
            0,
          );
        },
      );
    });

    group('doomed and nested transactions', () {
      test(
        'XACT_ABORT rolls the transaction back before the caller sees it',
        () async {
          await connection.execute(
            'CREATE TABLE #doomed (id INT PRIMARY KEY);',
          );
          final tx = await connection.beginTransaction();
          await tx.execute('INSERT INTO #doomed VALUES (1);');
          await expectLater(
            tx.execute('INSERT INTO #doomed VALUES (1);'),
            throwsA(
              isA<MssqlException>().having(
                (e) => e.type,
                'type',
                MssqlErrorType.constraint,
              ),
            ),
          );
          expect(await tx.queryScalar<int>('SELECT @@TRANCOUNT'), 0);
          expect(await tx.queryScalar<int>('SELECT XACT_STATE()'), 0);
          await expectLater(tx.commit(), throwsA(isA<MssqlException>()));
          await tx.close();
          expect(connection.isClosed, isFalse);
          await expectStillUsable();
          expect(
            await connection.queryScalar<int>('SELECT COUNT(*) FROM #doomed'),
            0,
            reason: 'the whole transaction was rolled back',
          );
        },
      );

      test(
        'a nested BEGIN raises the count and one ROLLBACK undoes all',
        () async {
          await connection.execute('CREATE TABLE #nested (id INT);');
          final tx = await connection.beginTransaction();
          await tx.execute('INSERT INTO #nested VALUES (1);');
          await tx.execute(
            'BEGIN TRANSACTION; INSERT INTO #nested VALUES (2);',
          );
          expect(await tx.queryScalar<int>('SELECT @@TRANCOUNT'), 2);
          await tx.rollback();
          await tx.close();
          expect(
            await connection.queryScalar<int>('SELECT COUNT(*) FROM #nested'),
            0,
          );
          await expectStillUsable();
        },
      );

      test('a savepoint rolls back its own work and keeps the rest', () async {
        await connection.execute('CREATE TABLE #savepoint (id INT);');
        final tx = await connection.beginTransaction();
        await tx.execute('INSERT INTO #savepoint VALUES (1);');
        await tx.execute('SAVE TRANSACTION keep_going;');
        await tx.execute('INSERT INTO #savepoint VALUES (2);');
        await tx.execute('ROLLBACK TRANSACTION keep_going;');
        await tx.commit();
        await tx.close();
        final ids = await connection.queryRows('SELECT id FROM #savepoint');
        expect(ids.map((row) => row['id']), <int>[1]);
        await expectStillUsable();
      });

      test('a timeout outside a transaction is survivable', () async {
        await expectLater(
          connection.execute(
            "WAITFOR DELAY '00:00:05';",
            timeout: const Duration(milliseconds: 400),
          ),
          throwsA(
            isA<MssqlException>().having(
              (e) => e.type,
              'type',
              MssqlErrorType.queryTimeout,
            ),
          ),
        );
        await expectStillUsable();
      });

      test('a timeout inside a transaction costs the connection', () async {
        final tx = await connection.beginTransaction();
        await tx.execute('CREATE TABLE #timeout_tx (id INT);');
        await tx.execute('INSERT INTO #timeout_tx VALUES (1);');
        await expectLater(
          tx.execute(
            "WAITFOR DELAY '00:00:05';",
            timeout: const Duration(milliseconds: 400),
          ),
          throwsA(
            isA<MssqlException>().having(
              (e) => e.type,
              'type',
              MssqlErrorType.queryTimeout,
            ),
          ),
        );
        await expectLater(
          tx.rollback(),
          throwsA(
            isA<MssqlException>().having(
              (e) => e.type,
              'type',
              MssqlErrorType.connectionLost,
            ),
          ),
        );
        expect(
          connection.isClosed,
          isTrue,
          reason: 'a session that cannot roll back must not be reused',
        );
        await tx.close();
      });

      test(
        'a pool replaces a connection lost to a transaction timeout',
        () async {
          final pool = MssqlConnectionPool(
            liveConfig(),
            poolConfig: const MssqlPoolConfig(maximumSize: 1),
          );
          addTearDown(pool.close);
          MssqlConnection? lost;
          await expectLater(
            pool.transaction<void>((tx) async {
              lost = tx.connection;
              await tx.execute(
                "WAITFOR DELAY '00:00:05';",
                timeout: const Duration(milliseconds: 400),
              );
            }),
            throwsA(isA<MssqlException>()),
          );
          expect(lost!.isClosed, isTrue);
          await pool.withConnection((next) async {
            expect(identical(next, lost), isFalse);
            expect(await next.queryScalar<int>('SELECT 1'), 1);
          });
        },
      );
    });
  }, skip: liveSkip);
}

