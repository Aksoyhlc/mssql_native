import 'dart:async';
import 'dart:typed_data';

import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

import 'support/live_server.dart';

class _Failure {
  const _Failure(this.name, this.sql, this.type, {this.code});

  final String name;
  final String sql;
  final MssqlErrorType type;
  final int? code;
}

const _failures = <_Failure>[
  _Failure(
    'syntax',
    'SELECT * FROM dbo.no_such_table_at_all',
    MssqlErrorType.querySyntax,
  ),
  _Failure(
    'divide by zero',
    'SELECT 1 / 0',
    MssqlErrorType.querySyntax,
    code: 8134,
  ),
  _Failure(
    'overflow',
    'SELECT CAST(2147483648 AS INT)',
    MssqlErrorType.querySyntax,
    code: 8115,
  ),
  _Failure(
    'conversion',
    "SELECT CAST(N'abc' AS INT)",
    MssqlErrorType.querySyntax,
    code: 245,
  ),
  _Failure(
    'raised',
    "RAISERROR (N'hata-%d', 16, 1, 7);",
    MssqlErrorType.querySyntax,
    code: 50000,
  ),
  _Failure(
    'column',
    'SELECT no_such_column FROM (SELECT 1 AS a) t',
    MssqlErrorType.querySyntax,
    code: 207,
  ),
];

void main() {
  group('endurance', () {
    setUpAll(initializeLive);
    tearDownAll(() => MssqlRuntime.instance.shutdown());

    test('500 alternating successes and failures never drift', () async {
      final connection = await MssqlConnection.open(liveConfig());
      addTearDown(connection.close);
      final handle = connection.nativeHandle;
      final seen = <String, int>{};

      for (var i = 0; i < 250; i++) {
        expect(
          await connection.queryScalar<int>('SELECT $i'),
          i,
          reason: 'success $i',
        );
        final failure = _failures[i % _failures.length];
        try {
          await connection.query(failure.sql);
          fail('${failure.name} had to fail on iteration $i');
        } on MssqlException catch (error) {
          expect(error.type, failure.type, reason: '${failure.name} at $i');
          if (failure.code != null) {
            expect(error.code, failure.code, reason: '${failure.name} at $i');
          }
          expect(
            error.diagnostics,
            isNotEmpty,
            reason: '${failure.name} at $i must carry its server message',
          );
          seen[failure.name] = (seen[failure.name] ?? 0) + 1;
        }
      }

      expect(seen.length, _failures.length, reason: 'every mode was exercised');
      expect(
        connection.nativeHandle,
        handle,
        reason: 'no failure forced a silent reconnect',
      );
      expect(await connection.queryScalar<int>('SELECT @@TRANCOUNT'), 0);
      expect(await connection.queryScalar<int>('SELECT 1'), 1);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('session state survives a long run of failures', () async {
      final connection = await MssqlConnection.open(liveConfig());
      addTearDown(connection.close);
      await connection.execute('CREATE TABLE #endurance (id INT);');
      await connection.execute("SET DATEFIRST 3;");

      for (var i = 0; i < 120; i++) {
        await connection.execute('INSERT INTO #endurance VALUES ($i);');
        try {
          await connection.query(_failures[i % _failures.length].sql);
          fail('iteration $i had to fail');
        } on MssqlException {
        }
      }

      expect(
        await connection.queryScalar<int>('SELECT COUNT(*) FROM #endurance'),
        120,
      );
      expect(
        await connection.queryScalar<int>('SELECT @@DATEFIRST'),
        3,
        reason: 'a session setting must not be reset by failures',
      );
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('parameters round-trip unchanged across a long run', () async {
      final connection = await MssqlConnection.open(liveConfig());
      addTearDown(connection.close);

      for (var i = 0; i < 150; i++) {
        final text = 'satır-$i-şğüıöç';
        final row = await connection.querySingle(
          'SELECT @n AS n, @t AS t, @d AS d, @b AS b',
          parameters: <MssqlParameter>[
            MssqlParameter.int64('n', i * 1000003),
            MssqlParameter.nvarchar('t', text, size: 60),
            MssqlParameter.decimal(
              'd',
              '12345678901234.$i',
              precision: 28,
              scale: 4,
            ),
            MssqlParameter.varbinary(
              'b',
              Uint8List.fromList(<int>[i % 256, 0, 255]),
              size: 8,
            ),
          ],
        );
        expect(row['n'], i * 1000003, reason: 'iteration $i');
        expect(row['t'], text, reason: 'iteration $i');
        expect(
          row['d'].toString(),
          startsWith('12345678901234.'),
          reason: 'iteration $i',
        );
        expect((row['b'] as List).first, i % 256, reason: 'iteration $i');

        if (i % 5 == 0) {
          await expectLater(
            connection.querySingle(
              'SELECT @n AS n',
              parameters: <MssqlParameter>[
                MssqlParameter.nvarchar('n', 'not-a-number', size: 20),
              ],
              timeout: const Duration(seconds: 5),
            ),
            completes,
          );
        }
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('200 transactions leave nothing open and no lease behind', () async {
      final connection = await MssqlConnection.open(liveConfig());
      addTearDown(connection.close);
      await connection.execute('CREATE TABLE #tx_storm (id INT);');

      for (var i = 0; i < 200; i++) {
        switch (i % 4) {
          case 0:
            await connection.transaction(
              (tx) => tx.execute('INSERT INTO #tx_storm VALUES ($i);'),
            );
          case 1:
            final tx = await connection.beginTransaction();
            await tx.execute('INSERT INTO #tx_storm VALUES ($i);');
            await tx.rollback();
            await tx.close();
          case 2:
            await expectLater(
              connection.transaction<void>((tx) async {
                await tx.execute('INSERT INTO #tx_storm VALUES ($i);');
                throw StateError('rolled back $i');
              }),
              throwsA(isA<StateError>()),
            );
          case 3:
            final tx = await connection.beginTransaction();
            await expectLater(
              tx.query('SELECT * FROM dbo.no_such_table_at_all'),
              throwsA(isA<MssqlException>()),
            );
            await tx.close();
        }
        expect(
          await connection.queryScalar<int>('SELECT @@TRANCOUNT'),
          0,
          reason: 'iteration $i left a transaction open',
        );
      }

      expect(
        await connection.queryScalar<int>('SELECT COUNT(*) FROM #tx_storm'),
        50,
      );
    }, timeout: const Timeout(Duration(minutes: 4)));

    test(
      'opening and closing 60 connections leaves nothing registered',
      () async {
        for (var i = 0; i < 60; i++) {
          final connection = await MssqlConnection.open(liveConfig());
          expect(await connection.queryScalar<int>('SELECT $i'), i);
          if (i % 3 == 0) {
            try {
              await connection.query('SELECT 1 / 0');
              fail('iteration $i had to fail');
            } on MssqlException {
            }
          }
          await connection.close();
          expect(connection.isClosed, isTrue);
        }
        final probe = await MssqlConnection.open(liveConfig());
        expect(await probe.queryScalar<int>('SELECT 1'), 1);
        await probe.close();
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );

    test('a saturated pool survives a storm of mixed outcomes', () async {
      final pool = MssqlConnectionPool(
        liveConfig(),
        poolConfig: const MssqlPoolConfig(
          maximumSize: 4,
          acquireTimeout: Duration(seconds: 30),
        ),
      );
      addTearDown(pool.close);

      var succeeded = 0;
      var failed = 0;
      var cancelled = 0;

      Future<void> worker(int id) async {
        for (var i = 0; i < 40; i++) {
          final step = (id + i) % 5;
          try {
            await pool.withConnection((connection) async {
              switch (step) {
                case 0:
                case 1:
                  final value = await connection.queryScalar<int>(
                    'SELECT ${id * 100 + i}',
                  );
                  expect(value, id * 100 + i);
                  succeeded++;
                case 2:
                  await connection.query(_failures[i % _failures.length].sql);
                  fail('worker $id iteration $i had to fail');
                case 3:
                  await connection.transaction<void>((tx) async {
                    await tx.execute('SELECT 1;');
                    throw StateError('planned');
                  });
                case 4:
                  final token = MssqlCancellationToken();
                  final running = connection.execute(
                    "WAITFOR DELAY '00:00:01';",
                    cancellationToken: token,
                  );
                  final settled = running.then<void>(
                    (_) {},
                    onError: (Object _) {},
                  );
                  Timer(const Duration(milliseconds: 40), token.cancel);
                  await settled;
                  cancelled++;
              }
            });
          } on MssqlException {
            failed++;
          } on StateError {
            failed++;
          }
        }
      }

      await Future.wait(<Future<void>>[
        for (var id = 0; id < 6; id++) worker(id),
      ]);

      expect(succeeded, greaterThan(0));
      expect(failed, greaterThan(0));
      expect(cancelled, greaterThan(0));
      expect(pool.waitingCount, 0, reason: 'nobody is left queued');
      expect(
        pool.createdCount,
        lessThanOrEqualTo(4 + failed),
        reason: 'the pool must not open a connection per failure',
      );

      await Future.wait(<Future<void>>[
        for (var i = 0; i < 8; i++)
          pool.withConnection((connection) async {
            expect(await connection.queryScalar<int>('SELECT $i'), i);
            expect(await connection.queryScalar<int>('SELECT @@TRANCOUNT'), 0);
          }),
      ]);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test(
      'streaming and executing interleaved for 100 rounds stay correct',
      () async {
        final connection = await MssqlConnection.open(liveConfig());
        addTearDown(connection.close);
        await connection.execute('''
CREATE TABLE #interleaved (id INT NOT NULL);
INSERT INTO #interleaved (id)
SELECT TOP (200) ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
FROM sys.all_objects;
''');

        for (var round = 0; round < 100; round++) {
          final ids = <int>[];
          await for (final row in connection.streamRows(
            'SELECT id FROM #interleaved ORDER BY id',
            batchRows: 16,
          )) {
            ids.add(row['id'] as int);
            if (round % 3 == 0 && ids.length == 50) break;
          }
          expect(ids.length, round % 3 == 0 ? 50 : 200, reason: 'round $round');
          expect(ids.first, 1, reason: 'round $round');

          if (round % 4 == 0) {
            try {
              await connection.query('SELECT 1 / 0');
              fail('round $round had to fail');
            } on MssqlException {
            }
          }
          expect(
            await connection.queryScalar<int>('SELECT $round'),
            round,
            reason: 'round $round left the connection unusable',
          );
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  }, skip: liveSkip);
}

