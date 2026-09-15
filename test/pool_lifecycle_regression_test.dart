import 'dart:async';
import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

String? _env(String name) => Platform.environment[name];

void main() {
  final live = _env('MSSQL_NATIVE_LIVE') == '1';
  final skipReason = live
      ? null
      : 'Set MSSQL_NATIVE_LIVE=1 with a reachable SQL Server to run.';

  MssqlConnectionConfig config({String? password}) => MssqlConnectionConfig(
    host: _env('MSSQL_NATIVE_HOST') ?? '127.0.0.1',
    port: int.parse(_env('MSSQL_NATIVE_PORT') ?? '1433'),
    database: _env('MSSQL_NATIVE_DB') ?? 'mssql_native_test',
    username: _env('MSSQL_NATIVE_USER') ?? 'sa',
    password: password ?? _env('MSSQL_NATIVE_PASSWORD') ?? 'Mssql@Native2026',
    encryption: MssqlEncryption.off,
    loginTimeout: const Duration(seconds: 3),
  );

  group('pool lifecycle regressions', () {
    setUpAll(() async {
      await MssqlRuntime.instance.initialize(
        bridgePath: _env('MSSQL_NATIVE_BRIDGE'),
        sybdbPath: _env('MSSQL_NATIVE_SYBDB'),
      );
    });

    tearDownAll(MssqlRuntime.instance.shutdown);

    test('concurrent warm ups reserve capacity before opening', () async {
      final pool = MssqlConnectionPool(
        config(),
        poolConfig: const MssqlPoolConfig(minimumSize: 2, maximumSize: 2),
      );
      addTearDown(pool.close);

      await Future.wait(<Future<void>>[pool.warmUp(), pool.warmUp()]);

      expect(pool.createdCount, 2);
      expect(pool.idleCount, 2);
    });

    test('warm up cannot add connections after close starts', () async {
      final pool = MssqlConnectionPool(
        config(),
        poolConfig: const MssqlPoolConfig(minimumSize: 2, maximumSize: 2),
      );

      final warming = pool.warmUp();
      final closing = pool.close();
      await warming.catchError((_) {});
      await closing;

      expect(pool.createdCount, 0);
      expect(pool.idleCount, 0);
      await expectLater(pool.acquire(), throwsStateError);
    });

    test('an in-flight acquire cannot succeed after close starts', () async {
      final pool = MssqlConnectionPool(config());

      final acquiring = pool.acquire();
      final rejected = expectLater(acquiring, throwsStateError);
      await pool.close();

      await rejected;
      expect(pool.createdCount, 0);
      expect(pool.idleCount, 0);
    });

    test(
      'duplicate and foreign releases are rejected without corruption',
      () async {
        final firstPool = MssqlConnectionPool(
          config(),
          poolConfig: const MssqlPoolConfig(
            maximumSize: 1,
            acquireTimeout: Duration(milliseconds: 300),
          ),
        );
        final secondPool = MssqlConnectionPool(config());
        addTearDown(firstPool.close);
        addTearDown(secondPool.close);

        final connection = await firstPool.acquire();
        await expectLater(secondPool.release(connection), throwsStateError);
        expect(secondPool.createdCount, 0);
        expect(secondPool.idleCount, 0);

        await firstPool.release(connection);
        await expectLater(firstPool.release(connection), throwsStateError);

        final borrowedAgain = await firstPool.acquire();
        await expectLater(
          firstPool.acquire(),
          throwsA(
            isA<MssqlException>().having(
              (error) => error.type,
              'type',
              MssqlErrorType.poolTimeout,
            ),
          ),
        );
        await firstPool.release(borrowedAgain);
        expect(firstPool.createdCount, 1);
        expect(firstPool.idleCount, 1);
      },
    );

    test(
      'returning a borrowed connection after close keeps counters at zero',
      () async {
        final pool = MssqlConnectionPool(config());
        final connection = await pool.acquire();

        await pool.close();
        pool.release(connection);
        for (var i = 0; i < 100 && !connection.isClosed; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        expect(pool.createdCount, 0);
        expect(pool.idleCount, 0);
        expect(connection.isClosed, isTrue);
      },
    );

    test(
      'a closed returned connection advances pending acquires in FIFO order',
      () async {
        final pool = MssqlConnectionPool(
          config(),
          poolConfig: const MssqlPoolConfig(
            maximumSize: 1,
            acquireTimeout: Duration(seconds: 8),
          ),
        );
        addTearDown(pool.close);
        final held = await pool.acquire();
        final order = <int>[];
        final first = pool.acquire().then((connection) {
          order.add(1);
          return connection;
        });
        final second = pool.acquire().then((connection) {
          order.add(2);
          return connection;
        });

        await held.close();
        pool.release(held);
        final firstConnection = await first;
        expect(order, <int>[1]);
        pool.release(firstConnection);
        final secondConnection = await second;
        expect(order, <int>[1, 2]);
        pool.release(secondConnection);
      },
    );

    test('a failed open advances the next pending acquire', () async {
      final pool = MssqlConnectionPool(
        config(password: 'definitely-not-the-password'),
        poolConfig: const MssqlPoolConfig(
          maximumSize: 1,
          acquireTimeout: Duration(seconds: 8),
        ),
      );
      addTearDown(pool.close);

      final first = pool.acquire();
      final second = pool.acquire();
      await expectLater(first, throwsA(isA<MssqlException>()));
      await expectLater(
        second,
        throwsA(
          isA<MssqlException>().having(
            (error) => error.type,
            'type',
            isNot(MssqlErrorType.poolTimeout),
          ),
        ),
      );
      expect(pool.waitingCount, 0);
      expect(pool.createdCount, 0);
    });

    test('concurrent close calls await the same shutdown', () async {
      final pool = MssqlConnectionPool(config());
      final connection = await pool.acquire();
      final query = connection.execute("WAITFOR DELAY '00:00:01'; SELECT 1");
      final released = pool.release(connection);

      final firstClose = pool.close();
      var secondCompleted = false;
      final secondClose = pool.close().whenComplete(() {
        secondCompleted = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(secondCompleted, isFalse);
      await query;
      await released;
      await Future.wait(<Future<void>>[firstClose, secondClose]);
      expect(pool.createdCount, 0);
    });
  }, skip: skipReason);

  group('the acquire budget and its cancellation cover the whole wait', () {
    setUpAll(() async {
      await MssqlRuntime.instance.initialize(
        bridgePath: _env('MSSQL_NATIVE_BRIDGE'),
        sybdbPath: _env('MSSQL_NATIVE_SYBDB'),
      );
    });
    tearDownAll(() => MssqlRuntime.instance.shutdown());

    test(
      'a cancelled command stops queueing instead of waiting out the timeout',
      () async {
        final pool = MssqlConnectionPool(
          config(),
          poolConfig: const MssqlPoolConfig(
            maximumSize: 1,
            acquireTimeout: Duration(seconds: 30),
          ),
        );
        addTearDown(pool.close);

        final held = await pool.acquire();
        final token = MssqlCancellationToken();
        final watch = Stopwatch()..start();
        final queued = pool.session.query('SELECT 1', cancellationToken: token);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        token.cancel('no longer wanted');
        await expectLater(queued, throwsA(isA<MssqlException>()));
        watch.stop();
        expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
        await pool.release(held);
      },
    );

    test('the token on the options is honoured the same way', () async {
      final pool = MssqlConnectionPool(
        config(),
        poolConfig: const MssqlPoolConfig(
          maximumSize: 1,
          acquireTimeout: Duration(seconds: 30),
        ),
      );
      addTearDown(pool.close);

      final held = await pool.acquire();
      final token = MssqlCancellationToken();
      final watch = Stopwatch()..start();
      final queued = pool.session.query(
        'SELECT 1',
        options: MssqlQueryOptions(cancellationToken: token),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      token.cancel();
      await expectLater(queued, throwsA(isA<MssqlException>()));
      watch.stop();
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      await pool.release(held);
    });

    test('callProcedure and ping queue under the token too', () async {
      final pool = MssqlConnectionPool(
        config(),
        poolConfig: const MssqlPoolConfig(
          maximumSize: 1,
          acquireTimeout: Duration(seconds: 30),
        ),
      );
      addTearDown(pool.close);

      final held = await pool.acquire();
      final token = MssqlCancellationToken();
      final watch = Stopwatch()..start();
      final pinged = pool.session.ping(cancellationToken: token);
      final called = pool.session.callProcedure(
        'dbo.usp_customer_dashboard',
        parameters: <String, Object?>{'customer_id': 1, 'order_count': null},
        outputParameters: <String>{'order_count'},
        cancellationToken: token,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      token.cancel();
      await expectLater(pinged, throwsA(isA<MssqlException>()));
      await expectLater(called, throwsA(isA<MssqlException>()));
      watch.stop();
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      await pool.release(held);
    });
  }, skip: skipReason);
}

