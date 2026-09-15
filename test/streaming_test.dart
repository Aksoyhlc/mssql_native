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

  group('streaming and cancellation', () {
    late MssqlConnection connection;
    late String table;

    setUpAll(() async {
      await MssqlRuntime.instance.initialize(
        bridgePath: _env('MSSQL_NATIVE_BRIDGE'),
        sybdbPath: _env('MSSQL_NATIVE_SYBDB'),
      );
      connection = await MssqlConnection.open(
        MssqlConnectionConfig(
          host: _env('MSSQL_NATIVE_HOST') ?? '127.0.0.1',
          port: int.parse(_env('MSSQL_NATIVE_PORT') ?? '1433'),
          database: _env('MSSQL_NATIVE_DB') ?? 'mssql_native_test',
          username: _env('MSSQL_NATIVE_USER') ?? 'sa',
          password: _env('MSSQL_NATIVE_PASSWORD') ?? 'Mssql@Native2026',
          encryption: MssqlEncryption.off,
          defaultQueryTimeout: const Duration(seconds: 60),
        ),
      );
      final suffix = '${DateTime.now().microsecondsSinceEpoch}_$pid';
      table = 'dbo.mssql_native_stream_$suffix';
      await connection.execute('''
CREATE TABLE $table (id INT NOT NULL PRIMARY KEY, label NVARCHAR(40) NOT NULL);
INSERT INTO $table (id, label)
SELECT TOP (750) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)),
       CONCAT(N'satır-', ROW_NUMBER() OVER (ORDER BY (SELECT NULL)))
FROM sys.all_objects;
''');
    });

    tearDownAll(() async {
      try {
        await connection.execute('DROP TABLE $table;');
      } finally {
        await connection.close();
        await MssqlRuntime.instance.shutdown();
      }
    });

    test(
      'one result set arrives as start, batches, end, then complete',
      () async {
        final events = await connection
            .stream('SELECT id, label FROM $table ORDER BY id', batchRows: 100)
            .toList();

        expect(events.first, isA<MssqlResultSetStart>());
        expect(events.last, isA<MssqlExecutionComplete>());
        expect(
          (events.first as MssqlResultSetStart).columns.map((c) => c.name),
          <String>['id', 'label'],
        );

        expect(events.whereType<MssqlResultSetStart>(), hasLength(1));
        expect(events.whereType<MssqlResultSetEnd>(), hasLength(1));
        final endAt = events.indexWhere((e) => e is MssqlResultSetEnd);
        for (var i = 0; i < events.length; i++) {
          if (events[i] is MssqlRowBatch) {
            expect(i, greaterThan(0), reason: 'a batch before the start');
            expect(i, lessThan(endAt), reason: 'a batch after the end');
          }
        }

        final rows = events.whereType<MssqlRowBatch>().expand((b) => b.rows);
        expect(rows, hasLength(750));
        expect(rows.first['id'], 1);
        expect(rows.last['label'], 'satır-750');
      },
    );

    test(
      'batchRows bounds each batch and nothing is lost at the seam',
      () async {
        final batches = await connection
            .stream('SELECT id FROM $table ORDER BY id', batchRows: 100)
            .where((e) => e is MssqlRowBatch)
            .cast<MssqlRowBatch>()
            .toList();

        expect(
          batches.length,
          greaterThan(1),
          reason: '750 rows at 100 a batch',
        );
        for (final batch in batches) {
          expect(batch.rows.length, lessThanOrEqualTo(100));
          expect(batch.rows, isNotEmpty, reason: 'an empty batch says nothing');
        }
        final ids = batches.expand((b) => b.rows).map((r) => r['id'] as int);
        expect(
          ids,
          List<int>.generate(750, (i) => i + 1),
          reason: 'every row exactly once, in order, across the seams',
        );
      },
    );

    test(
      'a three-statement batch reports three result sets in order',
      () async {
        final events = await connection
            .stream('SELECT 1 AS a; SELECT 2 AS b, 3 AS c; SELECT 4 AS d')
            .toList();

        final starts = events.whereType<MssqlResultSetStart>().toList();
        expect(starts, hasLength(3));
        expect(starts.map((s) => s.index), <int>[0, 1, 2]);
        expect(starts[1].columns.map((c) => c.name), <String>['b', 'c']);
        expect(events.whereType<MssqlResultSetEnd>(), hasLength(3));
        expect(
          events.whereType<MssqlExecutionComplete>(),
          hasLength(1),
          reason: 'one completion for the whole batch',
        );
      },
    );

    test('the completion metrics agree with what was streamed', () async {
      final events = await connection
          .stream('SELECT id FROM $table ORDER BY id', batchRows: 250)
          .toList();
      final streamed = events.whereType<MssqlRowBatch>().fold<int>(
        0,
        (n, b) => n + b.rows.length,
      );
      final complete = events.whereType<MssqlExecutionComplete>().single;

      expect(complete.metrics.rowCount, streamed);
      expect(complete.metrics.resultSets, hasLength(1));
      expect(complete.metrics.resultSets.single.rowCount, streamed);
      expect(complete.metrics.timeToFirstRow, isNotNull);
      expect(
        complete.metrics.timeToFirstRow!,
        lessThanOrEqualTo(complete.metrics.executionElapsed),
        reason: 'the first row cannot arrive after the last',
      );
    });

    test('streamRows yields the same rows queryRows returns', () async {
      final streamed = await connection
          .streamRows('SELECT id, label FROM $table ORDER BY id', batchRows: 64)
          .toList();
      final fetched = await connection.queryRows(
        'SELECT id, label FROM $table ORDER BY id',
      );

      expect(streamed, hasLength(fetched.length));
      for (var i = 0; i < fetched.length; i++) {
        expect(streamed[i]['id'], fetched[i]['id'], reason: 'row $i');
        expect(streamed[i]['label'], fetched[i]['label'], reason: 'row $i');
      }
    });

    test('streamRows refuses a multi-result statement', () async {
      await expectLater(
        connection.streamRows('SELECT 1 AS a; SELECT 2 AS b').toList(),
        throwsA(
          isA<MssqlException>().having(
            (e) => e.type,
            'type',
            MssqlErrorType.protocol,
          ),
        ),
      );
      expect(
        await connection.queryScalar<int>('SELECT 1'),
        1,
        reason: 'the connection survives the refusal',
      );
    });

    test('a token cancelled before the call refuses it outright', () async {
      final token = MssqlCancellationToken()..cancel('not today');
      await expectLater(
        connection.queryRows('SELECT id FROM $table', cancellationToken: token),
        throwsA(
          isA<MssqlException>().having(
            (e) => e.type,
            'type',
            MssqlErrorType.cancelled,
          ),
        ),
      );
      expect(await connection.queryScalar<int>('SELECT 1'), 1);
    });

    test(
      'cancelling a running query raises cancelled and frees the connection',
      () async {
        final token = MssqlCancellationToken();
        final pending = connection.query(
          "WAITFOR DELAY '00:00:10'; SELECT 1 AS ok",
          cancellationToken: token,
        );
        await Future<void>.delayed(const Duration(milliseconds: 400));
        token.cancel('caller changed its mind');

        await expectLater(
          pending,
          throwsA(
            isA<MssqlException>().having(
              (e) => e.type,
              'type',
              MssqlErrorType.cancelled,
            ),
          ),
        );

        expect(await connection.queryScalar<int>('SELECT 42'), 42);
      },
    );

    test(
      'cancelling mid-stream stops it and leaves the connection usable',
      () async {
        final token = MssqlCancellationToken();
        final seen = <int>[];
        await expectLater(
          () async {
            await for (final row in connection.streamRows(
              'SELECT id FROM $table ORDER BY id',
              batchRows: 50,
              cancellationToken: token,
            )) {
              seen.add(row['id'] as int);
              if (seen.length == 50) token.cancel('enough');
            }
          }(),
          throwsA(
            isA<MssqlException>().having(
              (e) => e.type,
              'type',
              MssqlErrorType.cancelled,
            ),
          ),
        );

        expect(
          seen,
          hasLength(lessThan(750)),
          reason: 'the stream stopped short of the full result',
        );
        expect(seen.first, 1);
        expect(await connection.queryScalar<int>('SELECT 7'), 7);
      },
    );

    test('abandoning a stream early leaves the connection usable', () async {
      final first = await connection
          .streamRows('SELECT id FROM $table ORDER BY id', batchRows: 25)
          .first;
      expect(first['id'], 1);
      expect(await connection.queryScalar<int>('SELECT 9'), 9);
    });

    test(
      'streamProcedure reports its result sets and its return status',
      () async {
        final events = await connection
            .streamProcedure(
              'dbo.usp_customer_dashboard',
              parameters: <String, Object?>{'customer_id': 1},
              outputParameters: const <String>{'order_count'},
            )
            .toList();

        expect(
          events.whereType<MssqlResultSetStart>(),
          hasLength(2),
          reason: 'header and order lines',
        );
        final complete = events.whereType<MssqlExecutionComplete>().single;
        expect(complete.returnStatus, 0);
        expect(complete.outputParameters['order_count'], isA<int>());
        expect(complete.outputParameters['order_count'], greaterThan(0));
      },
    );
  }, skip: skipReason);
}

