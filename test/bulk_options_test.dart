import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

String? _env(String name) => Platform.environment[name];

void main() {
  final live = _env('MSSQL_NATIVE_LIVE') == '1';
  final skipReason = live
      ? null
      : 'Set MSSQL_NATIVE_LIVE=1 with a reachable SQL Server to run.';

  group('bulk copy options', () {
    late MssqlConnection connection;
    late String table;
    late String audit;
    late String trigger;

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
      table = 'dbo.mssql_native_bulkopts_$suffix';
      audit = 'dbo.mssql_native_bulkaudit_$suffix';
      trigger = 'dbo.tr_mssql_native_bulkopts_$suffix';
      await connection.execute('''
CREATE TABLE $table (
  id   INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
  qty  INT NOT NULL CHECK (qty >= 0),
  note NVARCHAR(30) NULL DEFAULT N'generated'
);
''');
      await connection.execute('''
CREATE TABLE $audit (
  id  INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
  qty INT NOT NULL
);
''');
      await connection.execute('''
CREATE TRIGGER $trigger ON $table AFTER INSERT AS
BEGIN
  SET NOCOUNT ON;
  INSERT INTO $audit (qty) SELECT qty FROM inserted;
END
''');
    });

    tearDownAll(() async {
      try {
        await connection.execute('DROP TABLE $table;');
        await connection.execute('DROP TABLE $audit;');
      } finally {
        await connection.close();
        await MssqlRuntime.instance.shutdown();
      }
    });

    setUp(() async {
      await connection.execute('TRUNCATE TABLE $table');
      await connection.execute('TRUNCATE TABLE $audit');
    });

    Future<MssqlBulkResult> load(
      List<Map<String, Object?>> rows,
      MssqlBulkOptions options,
    ) => connection.bulkInsert(tableName: table, rows: rows, options: options);

    Future<int> count(String from) async =>
        await connection.queryScalar<int>('SELECT COUNT(*) FROM $from');

    test('bulk copy ignores CHECK constraints unless asked', () async {
      await load(<Map<String, Object?>>[
        <String, Object?>{'qty': -5},
      ], const MssqlBulkOptions());
      expect(await count(table), 1);
      expect(
        await connection.queryScalar<int>('SELECT qty FROM $table'),
        -5,
        reason: 'a row the table forbids was loaded, unchecked',
      );
    });

    test('checkConstraints alone rejects the row the table forbids', () async {
      await expectLater(
        load(<Map<String, Object?>>[
          <String, Object?>{'qty': -5},
        ], const MssqlBulkOptions(checkConstraints: true)),
        throwsA(isA<MssqlException>()),
      );
      expect(await count(table), 0);
    });

    test(
      'checkConstraints still applies when it is not the first hint',
      () async {
        await expectLater(
          load(<Map<String, Object?>>[
            <String, Object?>{
              'qty': -5,
              'note': MssqlValue.nvarchar(null, size: 30),
            },
          ], const MssqlBulkOptions(keepNulls: true, checkConstraints: true)),
          throwsA(isA<MssqlException>()),
          reason: 'CHECK_CONSTRAINTS was dropped from the hint list',
        );
        expect(await count(table), 0);
      },
    );

    test('a valid row still loads with several hints combined', () async {
      final result = await load(<Map<String, Object?>>[
        <String, Object?>{
          'qty': 7,
          'note': MssqlValue.nvarchar(null, size: 30),
        },
      ], const MssqlBulkOptions(keepNulls: true, checkConstraints: true));
      expect(result.insertedRows, 1);
      expect(
        await connection.queryScalar<Object?>('SELECT note FROM $table'),
        isNull,
        reason: 'KEEP_NULLS survived too',
      );
    });

    test('triggers do not fire by default', () async {
      await load(<Map<String, Object?>>[
        <String, Object?>{'qty': 3},
      ], const MssqlBulkOptions());
      expect(await count(table), 1);
      expect(await count(audit), 0);
    });

    test('fireTriggers still applies when it is not the first hint', () async {
      await load(<Map<String, Object?>>[
        <String, Object?>{
          'qty': 3,
          'note': MssqlValue.nvarchar(null, size: 30),
        },
      ], const MssqlBulkOptions(keepNulls: true, fireTriggers: true));
      expect(await count(table), 1);
      expect(
        await count(audit),
        1,
        reason: 'FIRE_TRIGGERS was dropped from the hint list',
      );
      expect(await connection.queryScalar<int>('SELECT qty FROM $audit'), 3);
    });

    test('the identity column is assigned by the server by default', () async {
      await load(<Map<String, Object?>>[
        <String, Object?>{'qty': 1},
        <String, Object?>{'qty': 2},
      ], const MssqlBulkOptions());
      final ids = await connection.queryRows(
        'SELECT id FROM $table ORDER BY id',
      );
      expect(ids.map((r) => r['id']), <int>[1, 2]);
    });

    test('keepIdentity loads the identity values it is given', () async {
      await load(<Map<String, Object?>>[
        <String, Object?>{'id': 4242, 'qty': 1},
        <String, Object?>{'id': 4243, 'qty': 2},
      ], const MssqlBulkOptions(keepIdentity: true));
      final ids = await connection.queryRows(
        'SELECT id FROM $table ORDER BY id',
      );
      expect(ids.map((r) => r['id']), <int>[
        4242,
        4243,
      ], reason: 'the server must not have renumbered these');
    });
  }, skip: skipReason);
}

