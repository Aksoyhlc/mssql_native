import 'package:flutter_test/flutter_test.dart';
import 'package:mssql_native/mssql_native.dart';

import '../support/android_context.dart';

/// The pool, and the claim underneath it: connections live on separate
/// isolates and must be usable at the same time. That claim is why the error
/// handlers are in C, and it has never been checked on Android.
void registerPoolTests() {
  group('the pool', () {
    testWidgets('hands back a working connection and reuses it', (_) async {
      final pool = MssqlConnectionPool(
        androidConfig(),
        poolConfig: const MssqlPoolConfig(maximumSize: 2),
      );
      addTearDown(pool.close);
      final first = await pool.withConnection(
        (c) async => (await c.querySingle('SELECT 1 AS ok'))['ok'],
      );
      expect(first, 1);
      expect(pool.createdCount, 1);
      await pool.withConnection((c) async => c.ping());
      expect(pool.createdCount, 1, reason: 'the second call must reuse it');
      expect(pool.idleCount, 1);
    });

    testWidgets('creates up to its maximum and no further', (_) async {
      final pool = MssqlConnectionPool(
        androidConfig(),
        poolConfig: const MssqlPoolConfig(
          maximumSize: 2,
          acquireTimeout: Duration(seconds: 3),
        ),
      );
      addTearDown(pool.close);
      final a = await pool.acquire();
      final b = await pool.acquire();
      expect(pool.createdCount, 2);
      // A third acquire has nothing to give and must time out rather than
      // opening an unbounded number of sessions.
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

    testWidgets('warmUp opens the minimum eagerly', (_) async {
      final pool = MssqlConnectionPool(
        androidConfig(),
        poolConfig: const MssqlPoolConfig(minimumSize: 2, maximumSize: 4),
      );
      addTearDown(pool.close);
      await pool.warmUp();
      expect(pool.createdCount, 2);
      expect(pool.idleCount, 2);
    });

    testWidgets('runs work on several connections at once', (_) async {
      final pool = MssqlConnectionPool(
        androidConfig(),
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

    // Concurrency is a claim about time, and on an emulator the device clock
    // is not a stopwatch: the first version of these two tests measured 622ms
    // for four parallel one-second waits and 866ms for two serialised ones -
    // both impossible, and both the guest clock running slow under load.
    //
    // So the timing is taken on the server instead. Each statement records
    // SYSUTCDATETIME() before and after its delay, and the question becomes
    // whether the intervals overlap - which is what "at the same time" means
    // and needs no client clock at all.
    const overlapSql = """
INSERT INTO dbo.and_overlap (id, started) VALUES (@id, SYSUTCDATETIME());
WAITFOR DELAY '00:00:01';
UPDATE dbo.and_overlap SET finished = SYSUTCDATETIME() WHERE id = @id;
""";

    Future<void> resetOverlap() async {
      final conn = await sharedConnection();
      await dropTable(conn, 'dbo.and_overlap');
      await conn.execute(
        'CREATE TABLE dbo.and_overlap ('
        ' id INT NOT NULL PRIMARY KEY,'
        ' started DATETIME2(3) NOT NULL,'
        ' finished DATETIME2(3) NULL)',
      );
    }

    /// The shortest recorded delay, in server milliseconds.
    Future<int> shortestDelay() async {
      final conn = await sharedConnection();
      final row = await conn.querySingle(
        'SELECT MIN(DATEDIFF(MILLISECOND, started, finished)) AS ms '
        'FROM dbo.and_overlap',
      );
      return row['ms'] as int;
    }

    testWidgets('queries on separate pooled connections run at the same time', (
      _,
    ) async {
      await resetOverlap();
      addTearDown(
        () async => dropTable(await sharedConnection(), 'dbo.and_overlap'),
      );

      final pool = MssqlConnectionPool(
        androidConfig(),
        poolConfig: const MssqlPoolConfig(maximumSize: 4),
      );
      addTearDown(pool.close);
      await pool.warmUp();

      await Future.wait(<Future<void>>[
        for (var i = 0; i < 4; i++)
          pool.withConnection(
            (c) => c.execute(
              overlapSql,
              parameters: [MssqlParameter.int32('id', i)],
            ),
          ),
      ]);

      expect(
        await shortestDelay(),
        greaterThanOrEqualTo(900),
        reason: 'the delay must actually have been executed',
      );
      final conn = await sharedConnection();
      final row = await conn.querySingle(
        'SELECT CASE WHEN MAX(started) < MIN(finished) THEN 1 ELSE 0 END '
        'AS overlapped FROM dbo.and_overlap',
      );
      expect(
        row['overlapped'],
        1,
        reason:
            'no moment existed at which all four were in flight, so they '
            'were not running at the same time',
      );
    });

    testWidgets('queries on one connection are serialised, deliberately', (
      _,
    ) async {
      // The other half of the claim. A DBPROCESS is not reentrant, so two
      // statements on the same connection must queue - that is what the
      // per-connection operation lock is for. Two intervals that overlapped
      // here would mean the state machine was driven from two places at once.
      await resetOverlap();
      addTearDown(
        () async => dropTable(await sharedConnection(), 'dbo.and_overlap'),
      );

      final conn = await MssqlConnection.open(androidConfig());
      addTearDown(conn.close);
      await Future.wait(<Future<void>>[
        for (var i = 0; i < 2; i++)
          conn.execute(overlapSql, parameters: [MssqlParameter.int32('id', i)]),
      ]);

      expect(await shortestDelay(), greaterThanOrEqualTo(900));
      final shared = await sharedConnection();
      final row = await shared.querySingle("""
SELECT COUNT(*) AS overlaps
FROM dbo.and_overlap a
JOIN dbo.and_overlap b ON a.id < b.id
WHERE a.started < b.finished AND b.started < a.finished
""");
      expect(
        row['overlaps'],
        0,
        reason: 'overlapping them would corrupt the DBPROCESS state machine',
      );
    });

    testWidgets('a closed pool refuses to hand out connections', (_) async {
      final pool = MssqlConnectionPool(androidConfig());
      await pool.close();
      await expectLater(pool.acquire(), throwsStateError);
    });

    testWidgets('releasing after close does not resurrect the connection', (
      _,
    ) async {
      // release() is the only way back into the pool, and after close() it has
      // to drop the connection rather than queue it for reuse.
      final pool = MssqlConnectionPool(androidConfig());
      final conn = await pool.acquire();
      await pool.close();
      pool.release(conn);
      expect(pool.idleCount, 0);
    });
  });
}
