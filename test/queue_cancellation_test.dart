import 'dart:async';

import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

import 'support/live_server.dart';

const _slow = "WAITFOR DELAY '00:00:01'; SELECT 1 AS ok;";

void main() {
  group('the operation queue', () {
    late MssqlConnection connection;

    setUpAll(initializeLive);
    tearDownAll(() => MssqlRuntime.instance.shutdown());

    setUp(() async {
      connection = await MssqlConnection.open(
        liveConfig(queryTimeout: const Duration(seconds: 30)),
      );
      await connection.execute('CREATE TABLE #queue_probe (tag NVARCHAR(40));');
    });
    tearDown(() => connection.close());

    Future<int> probeCount() =>
        connection.queryScalar<int>('SELECT COUNT(*) FROM #queue_probe');

    test(
      'cancelling a queued call leaves the running one and the next alone',
      () async {
        final token = MssqlCancellationToken();
        final running = connection.queryScalar<int>(_slow);
        final cancelled = connection.execute(
          "INSERT INTO #queue_probe VALUES (N'cancelled');",
          cancellationToken: token,
        );
        final next = connection.queryScalar<int>('SELECT 7 AS ok');
        final rejected = expectLater(
          cancelled,
          throwsA(
            isA<MssqlException>().having(
              (e) => e.type,
              'type',
              MssqlErrorType.cancelled,
            ),
          ),
        );

        token.cancel('not needed after all');

        expect(await running, 1);
        await rejected;
        expect(await next, 7);
      },
    );

    test(
      'a queued call cancelled before its turn never reaches the server',
      () async {
        final token = MssqlCancellationToken();
        final running = connection.queryScalar<int>(_slow);
        final cancelled = connection.execute(
          "INSERT INTO #queue_probe VALUES (N'never-ran');",
          cancellationToken: token,
        );
        final rejected = expectLater(cancelled, throwsA(isA<MssqlException>()));
        token.cancel();
        await rejected;
        await running;

        expect(
          await probeCount(),
          0,
          reason: 'the cancelled INSERT must never have been sent',
        );
      },
    );

    test('one token cancels every call it owns, and only those', () async {
      final token = MssqlCancellationToken();
      final running = connection.queryScalar<int>(_slow);
      final mine = <Future<int>>[
        for (var i = 0; i < 4; i++)
          connection.execute(
            "INSERT INTO #queue_probe VALUES (N'shared-$i');",
            cancellationToken: token,
          ),
      ];
      final theirs = connection.queryScalar<int>('SELECT 9 AS ok');
      final rejected = <Future<void>>[
        for (final call in mine)
          expectLater(
            call,
            throwsA(
              isA<MssqlException>().having(
                (e) => e.type,
                'type',
                MssqlErrorType.cancelled,
              ),
            ),
          ),
      ];

      token.cancel();

      expect(await running, 1);
      await Future.wait(rejected);
      expect(await theirs, 9);
      expect(await probeCount(), 0);
    });

    test('cancelling the running call still lets the queue drain', () async {
      final token = MssqlCancellationToken();
      final running = connection.queryScalar<int>(
        _slow,
        cancellationToken: token,
      );
      final queued = <Future<int>>[
        for (var i = 0; i < 3; i++)
          connection.queryScalar<int>('SELECT $i AS ok'),
      ];
      final rejected = expectLater(running, throwsA(isA<MssqlException>()));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      token.cancel();

      await rejected;
      for (var i = 0; i < queued.length; i++) {
        expect(await queued[i], i, reason: 'queued call $i must still run');
      }
      expect(await connection.queryScalar<int>('SELECT 1'), 1);
    });

    test('cancelling at the handover moment never wedges the gate', () async {
      final succeeded = <String>{};
      for (var attempt = 0; attempt < 12; attempt++) {
        final tag = 'race-$attempt';
        final token = MssqlCancellationToken();
        final running = connection.queryScalar<int>(
          "WAITFOR DELAY '00:00:00.150'; SELECT 1 AS ok;",
        );
        final racing = connection.execute(
          "INSERT INTO #queue_probe VALUES (N'$tag');",
          cancellationToken: token,
        );
        final settled = racing.then<bool>(
          (_) => true,
          onError: (Object error) {
            expect(error, isA<MssqlException>());
            expect(
              (error as MssqlException).type,
              MssqlErrorType.cancelled,
              reason: 'attempt $attempt',
            );
            return false;
          },
        );
        Timer(Duration(milliseconds: 140 + attempt * 2), token.cancel);

        expect(await running, 1);
        if (await settled) succeeded.add(tag);
        expect(
          await connection.queryScalar<int>('SELECT 5'),
          5,
          reason: 'attempt $attempt left the gate locked',
        );
      }

      final rows = await connection.queryRows('SELECT tag FROM #queue_probe');
      final written = rows.map((row) => row['tag'] as String).toSet();
      expect(
        written,
        containsAll(succeeded),
        reason: 'a call that returned normally must have written its row',
      );
      expect(rows.length, written.length, reason: 'no row was written twice');
    });

    test('a cancelled write inside a transaction can still be undone', () async {
      var undone = 0;
      for (var attempt = 0; attempt < 6; attempt++) {
        final token = MssqlCancellationToken();
        final tx = await connection.beginTransaction();
        final racing = tx.execute(
          "WAITFOR DELAY '00:00:00.120'; INSERT INTO #queue_probe VALUES (N'tx-$attempt');",
          cancellationToken: token,
        );
        final settled = racing.then<void>((_) {}, onError: (Object _) {});
        Timer(const Duration(milliseconds: 60), token.cancel);
        await settled;
        await tx.rollback();
        await tx.close();
        if (await probeCount() == 0) undone++;
      }
      expect(undone, 6, reason: 'rollback must erase the write every time');
      expect(await connection.queryScalar<int>('SELECT 1'), 1);
    });

    test(
      'a token that already served a call is spent, not contagious',
      () async {
        final token = MssqlCancellationToken();
        expect(
          await connection.queryScalar<int>(
            'SELECT 3',
            cancellationToken: token,
          ),
          3,
        );
        token.cancel('after the fact');

        await expectLater(
          connection.queryScalar<int>('SELECT 4', cancellationToken: token),
          throwsA(
            isA<MssqlException>().having(
              (e) => e.type,
              'type',
              MssqlErrorType.cancelled,
            ),
          ),
        );
        expect(await connection.queryScalar<int>('SELECT 4'), 4);
      },
    );

    test('a call that waited reports the wait in its metrics', () async {
      final running = connection.query(_slow);
      final queued = connection.query('SELECT 1 AS ok');
      await running;
      final result = await queued;
      expect(
        result.metrics.queueWait,
        greaterThan(const Duration(milliseconds: 200)),
      );
      expect(
        result.metrics.executionElapsed,
        lessThan(result.metrics.queueWait),
      );
    });

    test(
      'close waits for the call in flight instead of cutting it off',
      () async {
        final running = connection.queryScalar<int>(_slow);
        final closing = connection.close();
        expect(await running, 1, reason: 'the in-flight call must finish');
        await closing;
        expect(connection.isClosed, isTrue);
      },
    );

    test(
      'a queued call on a connection that closes first fails cleanly',
      () async {
        final running = connection.queryScalar<int>(_slow);
        final closing = connection.close();
        final afterClose = connection.queryScalar<int>('SELECT 1');
        expect(await running, 1);
        await closing;
        await expectLater(afterClose, throwsA(isA<StateError>()));
      },
    );
  }, skip: liveSkip);
}

