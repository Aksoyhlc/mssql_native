import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

String? _e(String k) => Platform.environment[k];

void main() {
  final live = _e('MSSQL_NATIVE_LIVE') == '1';
  final skipReason = live
      ? null
      : 'Set MSSQL_NATIVE_LIVE=1 with a reachable SQL Server to run.';

  final host = _e('MSSQL_NATIVE_HOST') ?? '127.0.0.1';
  final port = int.parse(_e('MSSQL_NATIVE_PORT') ?? '1433');
  final database = _e('MSSQL_NATIVE_DB') ?? 'mssql_native_test';
  final username = _e('MSSQL_NATIVE_USER') ?? 'sa';
  final password = _e('MSSQL_NATIVE_PASSWORD') ?? 'Mssql@Native2026';

  MssqlConnectionConfig config({
    String? overrideHost,
    int? overridePort,
    String? overrideDatabase,
    String? overrideUser,
    String? overridePassword,
    Duration login = const Duration(seconds: 8),
  }) => MssqlConnectionConfig(
    host: overrideHost ?? host,
    port: overridePort ?? port,
    database: overrideDatabase ?? database,
    username: overrideUser ?? username,
    password: overridePassword ?? password,
    encryption: MssqlEncryption.off,
    loginTimeout: login,
  );

  group('connection lifecycle', () {
    setUpAll(() async {
      await MssqlRuntime.instance.initialize(
        bridgePath: _e('MSSQL_NATIVE_BRIDGE'),
        sybdbPath: _e('MSSQL_NATIVE_SYBDB'),
      );
    });

    tearDownAll(() async {
      await MssqlRuntime.instance.shutdown();
    });

    group('failures to connect', () {
      test('a wrong password is an authentication failure', () async {
        await expectLater(
          MssqlConnection.open(config(overridePassword: 'definitely-not-it')),
          throwsA(
            isA<MssqlException>().having(
              (e) => e.type,
              'type',
              anyOf(MssqlErrorType.authentication, MssqlErrorType.connection),
            ),
          ),
        );
      });

      test('an unknown user fails to log in', () async {
        await expectLater(
          MssqlConnection.open(config(overrideUser: 'no_such_login_here')),
          throwsA(isA<MssqlException>()),
        );
      });

      test('a database that does not exist is reported as such', () async {
        await expectLater(
          MssqlConnection.open(
            config(overrideDatabase: 'no_such_database_here'),
          ),
          throwsA(isA<MssqlException>()),
        );
      });

      test('a closed port fails rather than hanging', () async {
        final started = DateTime.now();
        await expectLater(
          MssqlConnection.open(
            config(overridePort: 1, login: const Duration(seconds: 5)),
          ),
          throwsA(isA<MssqlException>()),
        );
        expect(
          DateTime.now().difference(started).inSeconds,
          lessThan(20),
          reason: 'the login timeout must actually bound the attempt',
        );
      });

      test('an unresolvable host fails', () async {
        await expectLater(
          MssqlConnection.open(
            config(
              overrideHost: 'no-such-host.invalid',
              login: const Duration(seconds: 5),
            ),
          ),
          throwsA(isA<MssqlException>()),
        );
      });

      test('a good connection still opens after several failures', () async {
        for (final bad in <MssqlConnectionConfig>[
          config(overridePassword: 'wrong'),
          config(overridePort: 1, login: const Duration(seconds: 3)),
          config(overrideDatabase: 'nope'),
        ]) {
          try {
            final leaked = await MssqlConnection.open(bad);
            await leaked.close();
            fail('expected $bad to fail');
          } on MssqlException {
          }
        }
        final conn = await MssqlConnection.open(config());
        addTearDown(conn.close);
        final row = await conn.querySingle('SELECT 1 AS ok');
        expect(row['ok'], 1);
      });

      test(
        'a failed connection reports diagnostics or a message, not silence',
        () async {
          try {
            await MssqlConnection.open(config(overridePassword: 'wrong-one'));
            fail('expected a failure');
          } on MssqlException catch (error) {
            expect(error.message, isNotEmpty);
            expect(error.message, isNot('null'));
          }
        },
      );
    });

    group('a closed connection', () {
      test('reports itself closed and drops its handle', () async {
        final conn = await MssqlConnection.open(config());
        expect(conn.isClosed, isFalse);
        expect(conn.nativeHandle, isNot(0));
        await conn.close();
        expect(conn.isClosed, isTrue);
        expect(
          conn.nativeHandle,
          0,
          reason: 'a stale handle invites a use-after-close',
        );
      });

      test('closing twice is not an error', () async {
        final conn = await MssqlConnection.open(config());
        await conn.close();
        await expectLater(conn.close(), completes);
      });

      test('refuses further work with a StateError', () async {
        final conn = await MssqlConnection.open(config());
        await conn.close();
        await expectLater(conn.query('SELECT 1'), throwsStateError);
        await expectLater(conn.execute('SELECT 1'), throwsStateError);
        await expectLater(conn.ping(), throwsStateError);
        await expectLater(conn.beginTransaction(), throwsStateError);
        await expectLater(
          conn.streamBatches('SELECT 1').toList(),
          throwsStateError,
        );
      });

      test('ping succeeds while open', () async {
        final conn = await MssqlConnection.open(config());
        addTearDown(conn.close);
        await expectLater(conn.ping(), completes);
      });
    });

    group('transaction leases', () {
      test('the connection refuses direct queries while leased', () async {
        final conn = await MssqlConnection.open(config());
        addTearDown(conn.close);
        final tx = await conn.beginTransaction();
        await expectLater(conn.query('SELECT 1'), throwsStateError);
        await tx.rollback();
        await tx.close();
        final row = await conn.querySingle('SELECT 1 AS ok');
        expect(row['ok'], 1);
      });

      test('closing a connection mid-transaction is refused', () async {
        final conn = await MssqlConnection.open(config());
        final tx = await conn.beginTransaction();
        await expectLater(conn.close(), throwsStateError);
        await tx.rollback();
        await tx.close();
        await conn.close();
      });

      test('a committed transaction cannot be used again', () async {
        final conn = await MssqlConnection.open(config());
        addTearDown(conn.close);
        final tx = await conn.beginTransaction();
        await tx.commit();
        expect(() => tx.commit(), throwsStateError);
        expect(() => tx.query('SELECT 1'), throwsStateError);
        await tx.close();
      });

      test('rolling back after a commit is a no-op, not an error', () async {
        final conn = await MssqlConnection.open(config());
        addTearDown(conn.close);
        final tx = await conn.beginTransaction();
        await tx.commit();
        await expectLater(tx.rollback(), completes);
        await tx.close();
      });

      test('close releases the lease even after a failed statement', () async {
        final conn = await MssqlConnection.open(config());
        addTearDown(conn.close);
        final tx = await conn.beginTransaction();
        try {
          await tx.query('SELECT * FROM dbo.no_such_table_at_all');
        } on MssqlException {
        }
        await tx.close();
        final row = await conn.querySingle('SELECT 1 AS ok');
        expect(row['ok'], 1, reason: 'the lease must have been released');
      });

      test(
        'an isolation level is accepted and the transaction still works',
        () async {
          for (final level in <MssqlIsolationLevel>[
            MssqlIsolationLevel.readUncommitted,
            MssqlIsolationLevel.readCommitted,
            MssqlIsolationLevel.repeatableRead,
            MssqlIsolationLevel.serializable,
          ]) {
            final conn = await MssqlConnection.open(config());
            final tx = await conn.beginTransaction(isolationLevel: level);
            final result = await tx.query('SELECT 1 AS ok');
            expect(
              result.resultSets.single.rows.single['ok'],
              1,
              reason: '$level',
            );
            await tx.rollback();
            await tx.close();
            await conn.close();
          }
        },
      );
    });

    group('the pool', () {
      test('hands back a working connection and reuses it', () async {
        final pool = MssqlConnectionPool(
          config(),
          poolConfig: const MssqlPoolConfig(maximumSize: 2),
        );
        addTearDown(pool.close);
        final first = await pool.withConnection(
          (c) async => (await c.querySingle('SELECT 1 AS ok'))['ok'],
        );
        expect(first, 1);
        expect(pool.createdCount, 1);
        await pool.withConnection((c) async => c.ping());
        expect(pool.createdCount, 1);
        expect(pool.idleCount, 1);
      });

      test('creates up to its maximum and no further', () async {
        final pool = MssqlConnectionPool(
          config(),
          poolConfig: const MssqlPoolConfig(
            maximumSize: 2,
            acquireTimeout: Duration(seconds: 2),
          ),
        );
        addTearDown(pool.close);
        final a = await pool.acquire();
        final b = await pool.acquire();
        expect(pool.createdCount, 2);
        await expectLater(
          pool.acquire(),
          throwsA(
            isA<MssqlException>().having(
              (e) => e.type,
              'type',
              MssqlErrorType.poolTimeout,
            ),
          ),
        );
        pool.release(a);
        pool.release(b);
      });

      test('warmUp opens the minimum eagerly', () async {
        final pool = MssqlConnectionPool(
          config(),
          poolConfig: const MssqlPoolConfig(minimumSize: 2, maximumSize: 4),
        );
        addTearDown(pool.close);
        await pool.warmUp();
        expect(pool.createdCount, 2);
        expect(pool.idleCount, 2);
      });

      test('runs work on several connections at once', () async {
        final pool = MssqlConnectionPool(
          config(),
          poolConfig: const MssqlPoolConfig(maximumSize: 4),
        );
        addTearDown(pool.close);
        final results = await Future.wait(<Future<Object?>>[
          for (var i = 0; i < 12; i++)
            pool.withConnection(
              (c) async => (await c.querySingle(
                'SELECT @n AS n',
                parameters: [MssqlParameter.int32('n', i)],
              ))['n'],
            ),
        ]);
        expect(results, List<int>.generate(12, (i) => i));
        expect(pool.createdCount, lessThanOrEqualTo(4));
      });

      test(
        'queries on separate pooled connections do not wait for each other',
        () async {
          final pool = MssqlConnectionPool(
            config(),
            poolConfig: const MssqlPoolConfig(maximumSize: 4),
          );
          addTearDown(pool.close);
          await pool.warmUp();

          final started = DateTime.now();
          await Future.wait(<Future<void>>[
            for (var i = 0; i < 4; i++)
              pool.withConnection(
                (c) => c.execute("WAITFOR DELAY '00:00:01'; SELECT 1"),
              ),
          ]);
          final elapsed = DateTime.now().difference(started);

          expect(
            elapsed.inMilliseconds,
            lessThan(2500),
            reason:
                'four one-second queries took ${elapsed.inMilliseconds}ms, '
                'which means they were not running at the same time',
          );
          expect(
            elapsed.inMilliseconds,
            greaterThan(900),
            reason: 'the delay must actually have been executed',
          );
        },
      );

      test('queries on one connection are serialised, deliberately', () async {
        final conn = await MssqlConnection.open(config());
        addTearDown(conn.close);

        final started = DateTime.now();
        await Future.wait(<Future<void>>[
          conn.execute("WAITFOR DELAY '00:00:01'; SELECT 1"),
          conn.execute("WAITFOR DELAY '00:00:01'; SELECT 1"),
        ]);
        final elapsed = DateTime.now().difference(started);

        expect(
          elapsed.inMilliseconds,
          greaterThan(1500),
          reason:
              'two one-second statements on one connection took '
              '${elapsed.inMilliseconds}ms; overlapping them would corrupt '
              'the DBPROCESS state machine',
        );
      });

      test('a slow query on one connection does not block another', () async {
        final slow = await MssqlConnection.open(config());
        final quick = await MssqlConnection.open(config());
        addTearDown(slow.close);
        addTearDown(quick.close);

        final slowFuture = slow.execute("WAITFOR DELAY '00:00:02'; SELECT 1");
        await Future<void>.delayed(const Duration(milliseconds: 200));

        final started = DateTime.now();
        final row = await quick.querySingle('SELECT 1 AS ok');
        final elapsed = DateTime.now().difference(started);
        expect(row['ok'], 1);
        expect(
          elapsed.inMilliseconds,
          lessThan(1000),
          reason:
              'the quick query waited ${elapsed.inMilliseconds}ms behind '
              'a query on a different connection',
        );

        await slowFuture;
      });

      test('a closed pool refuses to hand out connections', () async {
        final pool = MssqlConnectionPool(config());
        await pool.close();
        await expectLater(pool.acquire(), throwsStateError);
      });

      test('releasing after close does not resurrect the connection', () async {
        final pool = MssqlConnectionPool(config());
        final conn = await pool.acquire();
        await pool.close();
        pool.release(conn);
        expect(pool.idleCount, 0);
      });
    });
  }, skip: skipReason);
}

