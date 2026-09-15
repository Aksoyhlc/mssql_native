import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

String? _e(String k) => Platform.environment[k];

const List<(String, String)> _payloads = <(String, String)>[
  ('single quote', "O'Brien"),
  ('doubled quote', "it''s"),
  ('quote then or', "' OR '1'='1"),
  ('quote then or, unbalanced', "x' OR 1=1 --"),
  ('line comment', 'legit -- rest ignored'),
  ('block comment', 'legit /* rest ignored */ tail'),
  ('stacked statement', "x'; DROP TABLE dbo.inj_target; --"),
  ('stacked without quote', '; DROP TABLE dbo.inj_target;'),
  ('batch separator', 'x\nGO\nDROP TABLE dbo.inj_target'),
  ('bracket identifier', 'x] FROM sys.objects; --'),
  ('semicolon and comment', 'a;b--c'),
  ('percent and underscore', '100% _wild_'),
  ('bracket wildcard', '[a-z]'),
  ('backslash', r'C:\temp\new'),
  ('null-ish text', 'NULL'),
  ('numeric injection', '1 OR 1=1'),
  ('union select', "x' UNION SELECT name, 1 FROM sys.objects --"),
  ('xp_cmdshell', "'; EXEC xp_cmdshell 'dir'; --"),
  ('nested quotes', """he said "she said 'no'" """),
  ('turkish with quote', "Şişli'de Çöğüş"),
  ('full-width quote', 'x\uFF07 OR 1=1'),
  ('unicode line separator', 'a\u2028DROP TABLE dbo.inj_target'),
  ('tab and newline', 'a\tb\r\nc'),
  ('char function', "x' + CHAR(39) + '"),
  ('hex literal', '0x44524F50'),
];

void main() {
  final live = _e('MSSQL_NATIVE_LIVE') == '1';
  final skipReason = live
      ? null
      : 'Set MSSQL_NATIVE_LIVE=1 with a reachable SQL Server to run.';

  group('parameters are data, not code', () {
    late MssqlConnection conn;

    setUpAll(() async {
      await MssqlRuntime.instance.initialize(
        bridgePath: _e('MSSQL_NATIVE_BRIDGE'),
        sybdbPath: _e('MSSQL_NATIVE_SYBDB'),
      );
      conn = await MssqlConnection.open(
        MssqlConnectionConfig(
          host: _e('MSSQL_NATIVE_HOST') ?? '127.0.0.1',
          port: int.parse(_e('MSSQL_NATIVE_PORT') ?? '1433'),
          database: _e('MSSQL_NATIVE_DB') ?? 'mssql_native_test',
          username: _e('MSSQL_NATIVE_USER') ?? 'sa',
          password: _e('MSSQL_NATIVE_PASSWORD') ?? 'Mssql@Native2026',
          encryption: MssqlEncryption.off,
        ),
      );
      await conn.execute('''
IF OBJECT_ID('dbo.inj_target','U') IS NOT NULL DROP TABLE dbo.inj_target;
CREATE TABLE dbo.inj_target (
  id      INT IDENTITY(1,1) PRIMARY KEY,
  label   NVARCHAR(400) NULL,
  label_8 VARCHAR(400)  COLLATE Turkish_CI_AS NULL
);
''');
    });

    tearDownAll(() async {
      await conn.execute(
        "IF OBJECT_ID('dbo.inj_target','U') IS NOT NULL "
        'DROP TABLE dbo.inj_target;',
      );
      await conn.close();
      await MssqlRuntime.instance.shutdown();
    });

    for (final (label, payload) in _payloads) {
      test('$label survives an RPC round-trip unchanged', () async {
        final inserted = await conn.query(
          'INSERT INTO dbo.inj_target (label) OUTPUT INSERTED.id '
          'VALUES (@v)',
          parameters: [MssqlParameter.nvarchar('v', payload, size: 400)],
        );
        final id = inserted.resultSets.single.rows.single['id'] as int;

        final row = await conn.querySingle(
          'SELECT label, LEN(label) AS chars FROM dbo.inj_target '
          'WHERE id = @id',
          parameters: [MssqlParameter.int32('id', id)],
        );
        expect(
          row['label'],
          payload,
          reason: 'stored value differs from what was sent',
        );

        final still = await conn.querySingle(
          "SELECT COUNT(*) AS n FROM dbo.inj_target WHERE id = @id",
          parameters: [MssqlParameter.int32('id', id)],
        );
        expect(still['n'], 1);
      });
    }

    test(
      'a payload in a WHERE clause matches only itself, not everything',
      () async {
        const payload = "marker-8f21' OR '1'='1";
        await conn.execute(
          'INSERT INTO dbo.inj_target (label) VALUES (@v)',
          parameters: [MssqlParameter.nvarchar('v', payload, size: 400)],
        );
        final total = await conn.querySingle(
          'SELECT COUNT(*) AS n FROM dbo.inj_target',
        );
        expect(
          total['n'] as int,
          greaterThan(1),
          reason: 'the "match everything" case has to be distinguishable',
        );

        final rows = await conn.queryRows(
          'SELECT id FROM dbo.inj_target WHERE label = @v',
          parameters: [MssqlParameter.nvarchar('v', payload, size: 400)],
        );
        expect(rows, hasLength(1));
      },
    );

    test(
      'a wildcard payload in LIKE is matched literally when escaped',
      () async {
        const literal = 'lk-4c7 100% _wild_';
        await conn.execute(
          'INSERT INTO dbo.inj_target (label) VALUES (@a), (@b)',
          parameters: [
            MssqlParameter.nvarchar('a', literal, size: 400),
            MssqlParameter.nvarchar('b', 'lk-4c7 100X YwildY', size: 400),
          ],
        );
        final rows = await conn.queryRows(
          r"SELECT label FROM dbo.inj_target "
          r"WHERE label LIKE @v ESCAPE '\'",
          parameters: [
            MssqlParameter.nvarchar('v', r'lk-4c7 100\% \_wild\_', size: 400),
          ],
        );
        expect(
          rows.map((r) => r['label']),
          <String>[literal],
          reason: 'the escaped pattern must match the literal and nothing else',
        );
      },
    );

    test(
      'a payload is not executed on the single-byte Turkish column',
      () async {
        const payload = "Çöğüş'; DROP TABLE dbo.inj_target; --";
        await conn.execute(
          'INSERT INTO dbo.inj_target (label_8) VALUES (@v)',
          parameters: [MssqlParameter.nvarchar('v', payload, size: 400)],
        );
        final row = await conn.querySingle(
          'SELECT TOP 1 label_8 FROM dbo.inj_target '
          'WHERE label_8 IS NOT NULL ORDER BY id DESC',
        );
        expect(row['label_8'], payload);
      },
    );

    test(
      'a payload survives the bulk-copy path, which has no statement at all',
      () async {
        final rows = <List<MssqlParameter>>[
          for (final (_, payload) in _payloads)
            <MssqlParameter>[
              MssqlParameter.nvarchar('label', payload, size: 400),
            ],
        ];
        final result = await conn.bulkInsert(
          tableName: 'dbo.inj_target',
          columns: const <MssqlBulkColumn>[
            MssqlBulkColumn(
              ordinal: 2,
              name: 'label',
              type: MssqlType.nvarchar,
              size: 400,
            ),
          ],
          rows: rows,
        );
        expect(result.insertedRows, _payloads.length);

        for (final (label, payload) in _payloads) {
          final row = await conn.querySingle(
            'SELECT COUNT(*) AS n FROM dbo.inj_target WHERE label = @v',
            parameters: [MssqlParameter.nvarchar('v', payload, size: 400)],
          );
          expect(row['n'], greaterThanOrEqualTo(1), reason: 'bulk: $label');
        }
      },
    );

    test('the target table is still standing after every payload', () async {
      final row = await conn.querySingle(
        "SELECT OBJECT_ID('dbo.inj_target','U') AS id",
      );
      expect(row['id'], isNotNull);
      final objects = await conn.querySingle(
        'SELECT COUNT(*) AS n FROM sys.objects '
        "WHERE name = 'inj_target' AND type = 'U'",
      );
      expect(objects['n'], 1);
    });

    test('a parameter cannot supply a table or column name', () async {
      await expectLater(
        conn.queryRows(
          'SELECT * FROM @table',
          parameters: [
            MssqlParameter.nvarchar('table', 'dbo.inj_target', size: 128),
          ],
        ),
        throwsA(
          isA<MssqlException>().having(
            (e) => e.type,
            'type',
            MssqlErrorType.querySyntax,
          ),
        ),
      );
      final row = await conn.querySingle('SELECT 1 AS ok');
      expect(row['ok'], 1);
    });
  }, skip: skipReason);
}

