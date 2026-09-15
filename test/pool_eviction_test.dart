import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

import 'support/live_server.dart';

void main() {
  group('pool eviction and validation', () {
    setUpAll(initializeLive);
    tearDownAll(() => MssqlRuntime.instance.shutdown());

    Future<(MssqlConnection, int)> borrowAndRemember(
      MssqlConnectionPool pool,
    ) async {
      late MssqlConnection borrowed;
      late int spid;
      await pool.withConnection((connection) async {
        borrowed = connection;
        spid = await connection.queryScalar<int>('SELECT @@SPID');
      });
      return (borrowed, spid);
    }

    test(
      'an idle connection past its timeout is thrown away, not reused',
      () async {
        final pool = MssqlConnectionPool(
          liveConfig(),
          poolConfig: const MssqlPoolConfig(
            maximumSize: 2,
            idleTimeout: Duration(milliseconds: 200),
          ),
        );
        addTearDown(pool.close);

        final (first, _) = await borrowAndRemember(pool);
        expect(pool.idleCount, 1);

        await Future<void>.delayed(const Duration(milliseconds: 400));

        await pool.withConnection((next) async {
          expect(
            identical(next, first),
            isFalse,
            reason: 'the stale connection must not be handed back',
          );
          expect(await next.queryScalar<int>('SELECT 1'), 1);
        });
        expect(
          first.isClosed,
          isTrue,
          reason: 'and it must be closed, not merely dropped',
        );
      },
    );

    test('a connection still inside its timeout is reused as it is', () async {
      final pool = MssqlConnectionPool(
        liveConfig(),
        poolConfig: const MssqlPoolConfig(
          maximumSize: 2,
          idleTimeout: Duration(minutes: 5),
        ),
      );
      addTearDown(pool.close);

      final (first, _) = await borrowAndRemember(pool);
      await pool.withConnection((next) async {
        expect(identical(next, first), isTrue);
      });
      expect(first.isClosed, isFalse);
    });

    test(
      'the pool keeps its minimum even when the timeout has passed',
      () async {
        final pool = MssqlConnectionPool(
          liveConfig(),
          poolConfig: const MssqlPoolConfig(
            minimumSize: 1,
            maximumSize: 2,
            idleTimeout: Duration(milliseconds: 200),
          ),
        );
        addTearDown(pool.close);
        await pool.warmUp();

        final (first, _) = await borrowAndRemember(pool);
        await Future<void>.delayed(const Duration(milliseconds: 400));

        await pool.withConnection((next) async {
          expect(
            identical(next, first),
            isTrue,
            reason: 'the minimum is what stops the eviction here',
          );
        });
        expect(first.isClosed, isFalse);
      },
    );

    test(
      'a session killed while idle is replaced before the caller sees it',
      () async {
        final pool = MssqlConnectionPool(
          liveConfig(),
          poolConfig: const MssqlPoolConfig(maximumSize: 2),
        );
        addTearDown(pool.close);
        final killer = await MssqlConnection.open(liveConfig());
        addTearDown(killer.close);

        final (first, spid) = await borrowAndRemember(pool);
        await killer.execute('KILL $spid;');

        await pool.withConnection((next) async {
          expect(
            identical(next, first),
            isFalse,
            reason: 'the validation ping must have caught the dead session',
          );
          expect(await next.queryScalar<int>('SELECT 1'), 1);
        });
        expect(first.isClosed, isTrue);
      },
    );

    test(
      'validationGracePeriod hands a connection back without checking it',
      () async {
        final pool = MssqlConnectionPool(
          liveConfig(),
          poolConfig: const MssqlPoolConfig(
            maximumSize: 2,
            validationGracePeriod: Duration(minutes: 1),
          ),
        );
        addTearDown(pool.close);
        final killer = await MssqlConnection.open(liveConfig());
        addTearDown(killer.close);

        final (first, spid) = await borrowAndRemember(pool);
        await killer.execute('KILL $spid;');

        await pool.withConnection((next) async {
          expect(
            identical(next, first),
            isTrue,
            reason: 'inside the grace period the pool asks nothing',
          );
          await expectLater(
            next.queryScalar<int>('SELECT 1'),
            throwsA(isA<MssqlException>()),
          );
        });

        await pool.withConnection((next) async {
          expect(await next.queryScalar<int>('SELECT 1'), 1);
        });
      },
    );

    test('a grace period that has elapsed goes back to validating', () async {
      final pool = MssqlConnectionPool(
        liveConfig(),
        poolConfig: const MssqlPoolConfig(
          maximumSize: 2,
          validationGracePeriod: Duration(milliseconds: 150),
        ),
      );
      addTearDown(pool.close);
      final killer = await MssqlConnection.open(liveConfig());
      addTearDown(killer.close);

      final (first, spid) = await borrowAndRemember(pool);
      await killer.execute('KILL $spid;');
      await Future<void>.delayed(const Duration(milliseconds: 300));

      await pool.withConnection((next) async {
        expect(identical(next, first), isFalse);
        expect(await next.queryScalar<int>('SELECT 1'), 1);
      });
    });
  }, skip: liveSkip);
}

