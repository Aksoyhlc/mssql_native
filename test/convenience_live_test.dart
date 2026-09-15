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

  group('convenience API against SQL Server', () {
    late MssqlConnection connection;
    late String tableName;
    late String procedureName;

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
        ),
      );
      final suffix = '${DateTime.now().microsecondsSinceEpoch}_$pid';
      tableName = 'dbo.mssql_native_convenience_$suffix';
      procedureName = 'dbo.usp_mssql_native_convenience_$suffix';
      await connection.execute('''
CREATE TABLE $tableName (
  id INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
  label NVARCHAR(96) NOT NULL,
  amount DECIMAL(18,4) NULL,
  note NVARCHAR(30) NULL DEFAULT N'generated',
  created_at DATETIME2(7) NOT NULL DEFAULT SYSUTCDATETIME(),
  label_length AS LEN(label),
  version ROWVERSION
);
''');
      await connection.execute('''
CREATE PROCEDURE $procedureName
  @input INT,
  @output NVARCHAR(50) OUTPUT
AS
BEGIN
  SET NOCOUNT ON;
  SET @output = CONCAT(N'value-', @input);
  SELECT @input AS input_value;
  RETURN 17;
END
''');
    });

    tearDownAll(() async {
      try {
        await connection.execute('DROP PROCEDURE $procedureName;');
        await connection.execute('DROP TABLE $tableName;');
      } finally {
        await connection.close();
        await MssqlRuntime.instance.shutdown();
      }
    });

    setUp(() async => connection.execute('DELETE FROM $tableName'));

    test('map and explicit parameters produce the same RPC values', () async {
      const sql = '''
SELECT
  @enabled AS enabled,
  @count AS count_value,
  @name AS name_value,
  @nullable AS nullable_value
''';
      final simple = await connection.querySingle(
        sql,
        parameters: <String, Object?>{
          'enabled': true,
          'count': 2147483648,
          'name': 'İstanbul Şişli',
          'nullable': const MssqlValue.nvarchar(null, size: 20),
        },
      );
      final explicit = await connection.querySingle(
        sql,
        parameters: <MssqlParameter>[
          MssqlParameter.bit('enabled', true),
          MssqlParameter.int64('count', 2147483648),
          MssqlParameter.nvarchar('name', 'İstanbul Şişli', size: 20),
          MssqlParameter.nvarchar('nullable', null, size: 20),
        ],
      );

      expect(simple, explicit);
      expect(simple, <String, Object?>{
        'enabled': true,
        'count_value': 2147483648,
        'name_value': 'İstanbul Şişli',
        'nullable_value': null,
      });
    });

    test('map rows remain default and typed rows are opt-in', () async {
      final map = await connection.querySingle(
        'SELECT 7 AS id, N\'İstek\' AS label',
      );
      final typed = await connection.queryTypedSingle(
        'SELECT 7 AS id, N\'İstek\' AS label',
      );

      expect(map, <String, Object?>{'id': 7, 'label': 'İstek'});
      expect(typed.require<int>('id'), 7);
      expect(typed.require<String>('label'), 'İstek');
      expect(typed.at(0), 7);
    });

    test('typed rows keep duplicate labels available by index', () async {
      final row = await connection.queryTypedSingle(
        'SELECT 1 AS duplicate, 2 AS duplicate',
      );

      expect(row.at(0), 1);
      expect(row.at(1), 2);
      expect(() => row['duplicate'], throwsA(isA<MssqlRowAccessException>()));
    });

    test('a column answers to its name in any ASCII casing', () async {
      final row = await connection.queryTypedSingle(
        "SELECT 7 AS OrderId, N'İstek' AS ISIM, N'not' AS İSİM",
      );

      expect(row['OrderId'], 7);
      expect(row['orderid'], 7, reason: 'ASCII letters fold');
      expect(row.require<String>('isim'), 'İstek');
      expect(row.require<String>('İSİM'), 'not');
      expect(row.require<String>('ISIM'), 'İstek');
    });

    test('scalar and single-row helpers enforce their result shape', () async {
      expect(
        await connection.queryScalar<int>('SELECT COUNT(*) FROM sys.objects'),
        greaterThan(0),
      );
      await expectLater(
        connection.querySingle('SELECT 1 AS n WHERE 1 = 0'),
        throwsA(isA<MssqlNoRowsException>()),
      );
      await expectLater(
        connection.querySingle('SELECT n FROM (VALUES (1),(2)) AS v(n)'),
        throwsA(isA<MssqlMultipleRowsException>()),
      );
    });

    test(
      'metadata bulk omits generated columns and converts Dart values',
      () async {
        final result = await connection.bulkInsert(
          tableName: tableName,
          rows: <Map<String, Object?>>[
            <String, Object?>{'label': 'bir', 'amount': 1.25},
            <String, Object?>{
              'label': 'iki',
              'amount': MssqlValue.decimal(
                '99999999999999.9999',
                precision: 18,
                scale: 4,
              ),
            },
            <String, Object?>{
              'label': 'üç',
              'amount': MssqlValue.decimal(null, precision: 18, scale: 4),
            },
          ],
        );

        expect(result.insertedRows, 3);
        final rows = await connection.queryRows(
          'SELECT id, label, amount, label_length, DATALENGTH(version) AS version_bytes '
          'FROM $tableName ORDER BY id',
        );
        expect(rows.map((row) => row['label']), <String>['bir', 'iki', 'üç']);
        expect(rows[0]['amount'], MssqlDecimal.parse('1.25'));
        expect(rows[1]['amount'], MssqlDecimal.parse('99999999999999.9999'));
        expect(rows[2]['amount'], isNull);
        expect(rows[2]['label_length'], 2);
        expect(rows.every((row) => row['version_bytes'] == 8), isTrue);
        expect(
          await connection.queryScalar<String>(
            'SELECT note FROM $tableName WHERE label = N\'bir\'',
          ),
          'generated',
        );
      },
    );

    test('keepNulls explicitly preserves null over a column default', () async {
      await connection.bulkInsert(
        tableName: tableName,
        rows: <Map<String, Object?>>[
          <String, Object?>{
            'label': 'null-note',
            'note': MssqlValue.nvarchar(null, size: 30),
            'created_at': DateTime.utc(2026, 9, 5),
          },
        ],
        options: const MssqlBulkOptions(keepNulls: true),
      );

      expect(
        await connection.queryScalar<Object?>(
          'SELECT note FROM $tableName WHERE label = N\'null-note\'',
        ),
        isNull,
      );
    });

    test(
      'detailed bulkInsert remains operational beside metadata bulk',
      () async {
        final result = await connection.bulkInsert(
          tableName: tableName,
          columns: const <MssqlBulkColumn>[
            MssqlBulkColumn(
              ordinal: 2,
              name: 'label',
              type: MssqlType.nvarchar,
              size: 96,
              nullable: false,
            ),
            MssqlBulkColumn(
              ordinal: 3,
              name: 'amount',
              type: MssqlType.decimal,
              precision: 18,
              scale: 4,
            ),
          ],
          rows: <List<MssqlParameter>>[
            <MssqlParameter>[
              MssqlParameter.nvarchar('label', 'explicit', size: 96),
              MssqlParameter.decimal(
                'amount',
                '12.3400',
                precision: 18,
                scale: 4,
              ),
            ],
          ],
        );

        expect(result.insertedRows, 1);
        final row = await connection.querySingle(
          'SELECT label, amount FROM $tableName',
        );
        expect(row['label'], 'explicit');
        expect(row['amount'], MssqlDecimal.parse('12.34'));
      },
    );

    test('procedure metadata supplies output type and size', () async {
      final result = await connection.callProcedure(
        procedureName,
        parameters: <String, Object?>{'input': 9},
        outputParameters: const <String>{'output'},
      );

      expect(result.outputParameters['output'], 'value-9');
      expect(result.resultSets.single.rows.single['input_value'], 9);
      expect(result.returnStatus, 17);
    });

    test(
      'multi-result stream preserves boundaries and final metrics',
      () async {
        final events = await connection
            .stream('SELECT 1 AS first_value; SELECT 2 AS second_value;')
            .toList();
        final starts = events.whereType<MssqlResultSetStart>().toList();
        final batches = events.whereType<MssqlRowBatch>().toList();
        final ends = events.whereType<MssqlResultSetEnd>().toList();
        final complete = events.whereType<MssqlExecutionComplete>().single;

        expect(starts.map((event) => event.index), <int>[0, 1]);
        expect(batches[0].rows.single.require<int>('first_value'), 1);
        expect(batches[1].rows.single.require<int>('second_value'), 2);
        expect(ends, hasLength(2));
        expect(complete.metrics.rowCount, 2);
        expect(complete.metrics.resultSets, hasLength(2));
        expect(complete.metrics.executionElapsed, isNot(Duration.zero));
      },
    );

    test(
      'cancellation interrupts a query and leaves connection reusable',
      () async {
        final token = MssqlCancellationToken();
        final pending = connection.queryRows(
          "WAITFOR DELAY '00:00:10'; SELECT 1 AS value;",
          cancellationToken: token,
        );
        Timer(const Duration(milliseconds: 250), () => token.cancel('test'));

        await expectLater(
          pending,
          throwsA(
            isA<MssqlException>().having(
              (error) => error.type,
              'type',
              MssqlErrorType.cancelled,
            ),
          ),
        );
        expect((await connection.querySingle('SELECT 8 AS value'))['value'], 8);
      },
    );

    test('database and server metadata reflect the active session', () async {
      final expectedDatabase = _env('MSSQL_NATIVE_DB') ?? 'mssql_native_test';
      expect(connection.databaseName, expectedDatabase);
      expect(await connection.useDatabase(expectedDatabase), expectedDatabase);
      expect(connection.negotiatedTdsVersion, isNotEmpty);

      final info = await connection.serverInfo();
      expect(info.productVersion, isNotEmpty);
      expect(info.edition, isNotEmpty);
      expect(info.serverName, isNotEmpty);
      expect(info.engineEdition, greaterThan(0));
    });
  }, skip: skipReason);
}

