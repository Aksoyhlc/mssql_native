import 'dart:async';

import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

import 'support/live_server.dart';

void main() {
  group('streaming backpressure and limits', () {
    late MssqlConnection connection;
    late String table;

    setUpAll(() async {
      await initializeLive();
      connection = await MssqlConnection.open(
        liveConfig(queryTimeout: const Duration(seconds: 60)),
      );
      table = 'dbo.mssql_native_backpressure';
      await connection.execute('''
DROP TABLE IF EXISTS $table;
CREATE TABLE $table (id INT NOT NULL PRIMARY KEY, label NVARCHAR(40) NOT NULL);
INSERT INTO $table (id, label)
SELECT TOP (2000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)),
       CONCAT(N'satır-', ROW_NUMBER() OVER (ORDER BY (SELECT NULL)))
FROM sys.all_objects a CROSS JOIN sys.all_objects b;
''');
    });

    tearDownAll(() async {
      try {
        await connection.execute('DROP TABLE IF EXISTS $table;');
      } finally {
        await connection.close();
        await MssqlRuntime.instance.shutdown();
      }
    });

    tearDown(() async {
      expect(await connection.queryScalar<int>('SELECT 1'), 1);
    });

    test('a paused subscriber stops the worker fetching', () async {
      final rows = <int>[];
      final done = Completer<void>();
      late StreamSubscription<MssqlRow> subscription;
      subscription = connection
          .streamRows('SELECT id FROM $table ORDER BY id', batchRows: 25)
          .listen((row) {
            rows.add(row['id'] as int);
            if (rows.length == 25) subscription.pause();
          }, onDone: done.complete);
      addTearDown(subscription.cancel);

      await Future<void>.delayed(const Duration(milliseconds: 400));
      final whilePaused = rows.length;
      expect(
        whilePaused,
        lessThan(200),
        reason: 'a paused subscriber must not keep the worker producing',
      );

      subscription.resume();
      await done.future;

      expect(rows.length, 2000, reason: 'nothing was lost across the pause');
      expect(rows.toSet().length, 2000, reason: 'and nothing arrived twice');
      for (var i = 0; i < rows.length; i++) {
        expect(rows[i], i + 1, reason: 'row $i is out of order');
      }
    });

    test('cancelling during a long pause frees the connection', () async {
      final token = MssqlCancellationToken();
      final rows = <int>[];
      late StreamSubscription<MssqlRow> subscription;
      final failed = Completer<Object>();
      subscription = connection
          .streamRows(
            'SELECT id FROM $table ORDER BY id',
            batchRows: 25,
            cancellationToken: token,
          )
          .listen(
            (row) {
              rows.add(row['id'] as int);
              if (rows.length == 25) subscription.pause();
            },
            onError: failed.complete,
            onDone: () {
              if (!failed.isCompleted) failed.complete('done without an error');
            },
          );

      await Future<void>.delayed(const Duration(milliseconds: 250));
      token.cancel('caller went away');
      subscription.resume();

      final outcome = await failed.future;
      expect(outcome, isA<MssqlException>());
      expect((outcome as MssqlException).type, MssqlErrorType.cancelled);
      await subscription.cancel();
    });

    test(
      'an abandoned stream at a result-set seam leaves no residue',
      () async {
        for (var attempt = 0; attempt < 5; attempt++) {
          final events = <MssqlStreamEvent>[];
          final stream = connection.stream(
            'SELECT TOP (3) id FROM $table ORDER BY id; '
            'SELECT TOP (5) id FROM $table ORDER BY id DESC;',
            batchRows: 2,
          );
          await for (final event in stream) {
            events.add(event);
            if (event is MssqlResultSetEnd) break;
          }
          expect(
            events.last,
            isA<MssqlResultSetEnd>(),
            reason: 'attempt $attempt',
          );
          expect(
            await connection.queryScalar<int>('SELECT $attempt'),
            attempt,
            reason: 'attempt $attempt left the connection unusable',
          );
        }
      },
    );

    test('empty result sets are reported, not skipped', () async {
      final events = <MssqlStreamEvent>[];
      await for (final event in connection.stream('''
SELECT TOP (0) id FROM $table;
SELECT TOP (2) id FROM $table ORDER BY id;
SELECT TOP (0) id FROM $table;
''')) {
        events.add(event);
      }
      final starts = events.whereType<MssqlResultSetStart>().toList();
      final ends = events.whereType<MssqlResultSetEnd>().toList();
      expect(starts.length, 3, reason: 'an empty set still has a start');
      expect(ends.length, 3);
      expect(starts.map((e) => e.index), <int>[0, 1, 2]);
      final rows = events.whereType<MssqlRowBatch>().expand((b) => b.rows);
      expect(rows.length, 2, reason: 'only the middle set has rows');
    });

    test('maximumRows truncates a stream instead of failing it', () async {
      final rows = <MssqlRow>[];
      await for (final event in connection.stream(
        'SELECT id FROM $table ORDER BY id',
        batchRows: 7,
        maximumRows: 20,
      )) {
        if (event is MssqlRowBatch) rows.addAll(event.rows);
      }
      expect(rows.length, 20);
      expect(rows.first['id'], 1);
      expect(rows.last['id'], 20);
    });

    test('maximumBytes stops a runaway stream and says so', () async {
      await expectLater(
        connection
            .stream(
              'SELECT id, label FROM $table ORDER BY id',
              batchRows: 50,
              maximumBytes: 512,
            )
            .toList(),
        throwsA(
          isA<MssqlException>()
              .having((e) => e.type, 'type', MssqlErrorType.protocol)
              .having((e) => e.message, 'message', contains('byte limit')),
        ),
      );
    });

    test('an error raised after rows still reaches the subscriber', () async {
      final rows = <MssqlRow>[];
      Object? failure;
      try {
        await for (final event in connection.stream('''
SELECT TOP (4) id FROM $table ORDER BY id;
RAISERROR (N'akış ortasında', 16, 1);
''', batchRows: 2)) {
          if (event is MssqlRowBatch) rows.addAll(event.rows);
        }
      } on MssqlException catch (error) {
        failure = error;
      }
      expect(rows.length, 4, reason: 'the rows before the error are delivered');
      expect(failure, isA<MssqlException>());
      expect((failure! as MssqlException).message, contains('akış ortasında'));
    });

    test('a failed stream does not cancel whatever runs next', () async {
      for (var attempt = 0; attempt < 5; attempt++) {
        await expectLater(
          connection
              .stream(
                "SELECT TOP (3) id FROM $table; RAISERROR (N'orta', 16, 1);",
                batchRows: 2,
              )
              .toList(),
          throwsA(
            isA<MssqlException>().having(
              (e) => e.message,
              'message',
              contains('orta'),
            ),
          ),
        );
        expect(
          await connection.queryScalar<int>('SELECT $attempt'),
          attempt,
          reason: 'attempt $attempt',
        );
        final next = await connection
            .streamRows('SELECT TOP (4) id FROM $table ORDER BY id')
            .toList();
        expect(next.length, 4, reason: 'attempt $attempt');
      }
    });

    test('batchRows of one still delivers every row exactly once', () async {
      final ids = <int>[];
      await for (final row in connection.streamRows(
        'SELECT TOP (120) id FROM $table ORDER BY id',
        batchRows: 1,
      )) {
        ids.add(row['id'] as int);
      }
      expect(ids.length, 120);
      expect(ids.toSet().length, 120);
      expect(ids.first, 1);
      expect(ids.last, 120);
    });

    test('a stream that outlives its pause reports honest metrics', () async {
      MssqlExecutionComplete? complete;
      var rows = 0;
      await for (final event in connection.stream(
        'SELECT id FROM $table ORDER BY id',
        batchRows: 64,
        maximumRows: 500,
      )) {
        if (event is MssqlRowBatch) rows += event.rows.length;
        if (event is MssqlExecutionComplete) complete = event;
      }
      expect(rows, 500);
      expect(complete, isNotNull);
      final metrics = complete!.metrics;
      expect(metrics.rowCount, 500);
      expect(metrics.resultSets.single.rowCount, 500);
      expect(metrics.timeToFirstRow, isNotNull);
      expect(metrics.decodedBytes, greaterThan(0));
    });
  }, skip: liveSkip);
}

