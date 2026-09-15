import 'dart:io';
import 'dart:typed_data';

import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

String? _e(String k) => Platform.environment[k];

const List<(String, String)> _samples = <(String, String)>[
  ('ascii', 'plain ascii text'),
  ('turkish dotted and dotless i', 'İstanbul ışık İIıi'),
  ('turkish full alphabet', 'ÇçĞğİıÖöŞşÜü'),
  ('german sharp s', 'Grüße aus Köln, Straße'),
  ('french accents', 'Où êtes-vous? À côté, naïve œuf'),
  ('greek', 'αβγδε ΑΒΓ'),
  ('cyrillic', 'Москва здрав'),
  ('arabic rtl', 'مرحبا بالعالم'),
  ('hebrew rtl', 'שלום עולם'),
  ('cjk han', '你好世界'),
  ('japanese kana', 'こんにちはカタカナ'),
  ('korean hangul', '안녕하세요'),
  ('thai', 'สวัสดี'),
  ('combining diacritics', 'éàô vs éàô'),
  ('emoji with surrogates', 'box 🧿 cart 🛒'),
  ('emoji with modifier', '👍🏽'),
  ('zero width joiner', '👩‍💻'),
  ('mixed scripts one line', 'İstanbul 世界 مرحبا 🧿'),
  ('quotes and dashes', '“quoted” – dash — em …'),
  ('currency signs', '₺100 €50 £40 ¥5000'),
  ('newlines and tabs', 'line1\nline2\r\nline3\tend'),
  ('single space', ' '),
  ('only punctuation', '!@#\$%^&*()[]{}|;:,.<>?/~`'),
];

void main() {
  final live = _e('MSSQL_NATIVE_LIVE') == '1';
  final skipReason = live
      ? null
      : 'Set MSSQL_NATIVE_LIVE=1 with a reachable SQL Server to run.';

  group('text encoding', () {
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
IF OBJECT_ID('dbo.enc_probe','U') IS NOT NULL DROP TABLE dbo.enc_probe;
CREATE TABLE dbo.enc_probe (
  id       INT IDENTITY(1,1) PRIMARY KEY,
  wide     NVARCHAR(400) NULL,
  narrow   VARCHAR(400)  COLLATE Turkish_CI_AS NULL,
  fixed    NCHAR(20)     NULL,
  huge     NVARCHAR(MAX) NULL
);
''');
    });

    tearDownAll(() async {
      await conn.execute(
        "IF OBJECT_ID('dbo.enc_probe','U') IS NOT NULL "
        'DROP TABLE dbo.enc_probe;',
      );
      await conn.close();
      await MssqlRuntime.instance.shutdown();
    });

    group('RPC parameter round-trip (NVARCHAR)', () {
      for (final (label, text) in _samples) {
        test(label, () async {
          final row = await conn.querySingle(
            'SELECT @v AS echoed',
            parameters: [MssqlParameter.nvarchar('v', text, size: 400)],
          );
          expect(row['echoed'], text);
        });
      }
    });

    group('stored and read back (NVARCHAR)', () {
      for (final (label, text) in _samples) {
        test(label, () async {
          final inserted = await conn.query(
            'INSERT INTO dbo.enc_probe (wide) OUTPUT INSERTED.id VALUES (@v)',
            parameters: [MssqlParameter.nvarchar('v', text, size: 400)],
          );
          final id = inserted.resultSets.single.rows.single['id'] as int;
          final row = await conn.querySingle(
            'SELECT wide FROM dbo.enc_probe WHERE id = @id',
            parameters: [MssqlParameter.int32('id', id)],
          );
          expect(row['wide'], text);
        });
      }
    });

    group('bulk copy round-trip (NVARCHAR)', () {
      test('every sample survives one bulk load', () async {
        await conn.execute('DELETE FROM dbo.enc_probe');
        final result = await conn.bulkInsert(
          tableName: 'dbo.enc_probe',
          columns: const <MssqlBulkColumn>[
            MssqlBulkColumn(
              ordinal: 2,
              name: 'wide',
              type: MssqlType.nvarchar,
              size: 400,
            ),
          ],
          rows: <List<MssqlParameter>>[
            for (final (_, text) in _samples)
              <MssqlParameter>[
                MssqlParameter.nvarchar('wide', text, size: 400),
              ],
          ],
        );
        expect(result.insertedRows, _samples.length);

        final rows = await conn.queryRows(
          'SELECT wide FROM dbo.enc_probe ORDER BY id',
        );
        expect(
          rows.map((r) => r['wide']).toList(),
          _samples.map((s) => s.$2).toList(),
        );
      });
    });

    group('bulk copy into a single-byte column', () {
      test(
        'the bytes match what SQL Server writes for the same string',
        () async {
          const text = 'ÖZEL ÜRÜN';
          await conn.execute('DELETE FROM dbo.enc_probe');
          await conn.execute(
            'INSERT INTO dbo.enc_probe (narrow) VALUES (@v)',
            parameters: [MssqlParameter.nvarchar('v', text, size: 400)],
          );
          final expected =
              (await conn.querySingle(
                    'SELECT CAST(narrow AS VARBINARY(400)) AS raw '
                    'FROM dbo.enc_probe',
                  ))['raw']
                  as Uint8List;

          await conn.execute('DELETE FROM dbo.enc_probe');
          final result = await conn.bulkInsert(
            tableName: 'dbo.enc_probe',
            columns: const <MssqlBulkColumn>[
              MssqlBulkColumn(
                ordinal: 3,
                name: 'narrow',
                type: MssqlType.varchar,
                size: 400,
              ),
            ],
            rows: <List<MssqlParameter>>[
              <MssqlParameter>[
                MssqlParameter.varchar('narrow', text, size: 400),
              ],
            ],
          );
          expect(result.insertedRows, 1);
          final row = await conn.querySingle(
            'SELECT narrow, CAST(narrow AS VARBINARY(400)) AS raw '
            'FROM dbo.enc_probe',
          );
          expect(row['raw'], expected);
          expect(row['narrow'], text);
        },
      );

      test(
        'what it can carry is bounded by the database, not the column',
        () async {
          const text = 'ŞİŞLİ ığ';
          await conn.execute('DELETE FROM dbo.enc_probe');
          final dbCodePage =
              (await conn.querySingle(
                    "SELECT CAST(COLLATIONPROPERTY(CAST(DATABASEPROPERTYEX(DB_NAME(),"
                    "'Collation') AS NVARCHAR(128)), 'CodePage') AS INT) AS cp",
                  ))['cp']
                  as int;

          Future<void> load() => conn.bulkInsert(
            tableName: 'dbo.enc_probe',
            columns: const <MssqlBulkColumn>[
              MssqlBulkColumn(
                ordinal: 3,
                name: 'narrow',
                type: MssqlType.varchar,
                size: 400,
              ),
            ],
            rows: <List<MssqlParameter>>[
              <MssqlParameter>[
                MssqlParameter.varchar('narrow', text, size: 400),
              ],
            ],
          );

          if (dbCodePage == 1254) {
            await load();
            final row = await conn.querySingle(
              'SELECT narrow FROM dbo.enc_probe',
            );
            expect(row['narrow'], text);
            return;
          }
          await expectLater(
            load(),
            throwsA(
              isA<MssqlException>().having(
                (e) => e.type,
                'type',
                MssqlErrorType.conversion,
              ),
            ),
            reason: 'database code page $dbCodePage cannot carry Turkish',
          );
          final after = await conn.querySingle(
            'SELECT COUNT(*) AS n FROM dbo.enc_probe',
          );
          expect(after['n'], 0, reason: 'nothing may have been written');
        },
      );

      test(
        'text no supported code page can hold is refused, not mangled',
        () async {
          await conn.execute('DELETE FROM dbo.enc_probe');
          await expectLater(
            conn.bulkInsert(
              tableName: 'dbo.enc_probe',
              columns: const <MssqlBulkColumn>[
                MssqlBulkColumn(
                  ordinal: 3,
                  name: 'narrow',
                  type: MssqlType.varchar,
                  size: 400,
                ),
              ],
              rows: <List<MssqlParameter>>[
                <MssqlParameter>[
                  MssqlParameter.varchar('narrow', 'Москва', size: 400),
                ],
              ],
            ),
            throwsA(
              isA<MssqlException>().having(
                (e) => e.type,
                'type',
                MssqlErrorType.conversion,
              ),
            ),
          );
          final after = await conn.querySingle(
            'SELECT COUNT(*) AS n FROM dbo.enc_probe',
          );
          expect(after['n'], 0, reason: 'nothing may have been written');
        },
      );
    });

    group('single-byte Turkish collation (CP1254 through iconv)', () {
      const turkish = <String>[
        'İstanbul',
        'ÇĞİÖŞÜ',
        'çğıöşü',
        'Şişli\'de ÇÖĞÜŞ',
        '4 KENAR OVERLOK ÜZERİ DÜZ BÜKÜM',
        'ışıklı İIıi',
      ];

      for (final text in turkish) {
        test('"$text" survives VARCHAR(CP1254)', () async {
          final inserted = await conn.query(
            'INSERT INTO dbo.enc_probe (narrow, wide) '
            'OUTPUT INSERTED.id VALUES (@v, @v2)',
            parameters: [
              MssqlParameter.nvarchar('v', text, size: 400),
              MssqlParameter.nvarchar('v2', text, size: 400),
            ],
          );
          final id = inserted.resultSets.single.rows.single['id'] as int;
          final row = await conn.querySingle(
            'SELECT narrow, wide FROM dbo.enc_probe WHERE id = @id',
            parameters: [MssqlParameter.int32('id', id)],
          );
          expect(
            row['narrow'],
            text,
            reason: 'the single-byte column needs iconv',
          );
          expect(
            row['wide'],
            text,
            reason: 'the Unicode column is the control',
          );
          expect(row['narrow'], row['wide'], reason: 'both columns must agree');
        });
      }

      test('the seeded charset probe still reads correctly', () async {
        final row = await conn.querySingle(
          'SELECT label, label_n FROM dbo.charset_probe',
        );
        expect(row['label'], row['label_n']);
        expect(row['label'] as String, contains('ÇÖĞÜŞİ'));
        expect(
          row['label'] as String,
          isNot(contains('Ý')),
          reason: 'Ý is what a broken iconv produces for İ',
        );
      });

      test('a WHERE on the single-byte column matches Turkish text', () async {
        await conn.execute(
          'INSERT INTO dbo.enc_probe (narrow) VALUES (@v)',
          parameters: [
            MssqlParameter.nvarchar('v', 'ÖZEL ÜRÜN ŞİŞLİ', size: 400),
          ],
        );
        final rows = await conn.queryRows(
          'SELECT narrow FROM dbo.enc_probe WHERE narrow = @v',
          parameters: [
            MssqlParameter.nvarchar('v', 'ÖZEL ÜRÜN ŞİŞLİ', size: 400),
          ],
        );
        expect(rows, isNotEmpty);
      });

      test('a varchar parameter is bound in the database collation, not the '
          'column one', () async {
        final collation =
            (await conn.querySingle(
                  "SELECT CAST(DATABASEPROPERTYEX(DB_NAME(),'Collation') AS "
                  'NVARCHAR(128)) AS c',
                ))['c']
                as String;
        if (collation.startsWith('Turkish')) {
          return;
        }

        const text = 'İĞŞ';
        final viaVarchar = await conn.querySingle(
          'SELECT @v AS echoed',
          parameters: [MssqlParameter.varchar('v', text, size: 40)],
        );
        expect(
          viaVarchar['echoed'],
          'IGS',
          reason: 'flattened by the $collation database collation',
        );

        final viaNvarchar = await conn.querySingle(
          'SELECT @v AS echoed',
          parameters: [MssqlParameter.nvarchar('v', text, size: 40)],
        );
        expect(
          viaNvarchar['echoed'],
          text,
          reason: 'the Unicode parameter is unaffected',
        );
      });
    });

    group('lengths and edges', () {
      test('the server counts characters, not bytes', () async {
        final row = await conn.querySingle(
          'SELECT LEN(@v) AS chars, DATALENGTH(@v) AS bytes',
          parameters: [MssqlParameter.nvarchar('v', 'İstanbul', size: 40)],
        );
        expect(row['chars'], 8);
        expect(row['bytes'], 16, reason: 'UCS-2 on the wire, two per char');
      });

      test('an empty string is not null', () async {
        final row = await conn.querySingle(
          '''
SELECT CASE WHEN @v IS NULL THEN 1 ELSE 0 END AS is_null,
       LEN(@v) AS chars
''',
          parameters: [MssqlParameter.nvarchar('v', '', size: 40)],
        );
        expect(row['is_null'], 0);
        expect(row['chars'], 0);
      });

      test('an empty string is stored as a value and found by =', () async {
        await conn.execute('DELETE FROM dbo.enc_probe');
        await conn.execute(
          'INSERT INTO dbo.enc_probe (wide) VALUES (@v)',
          parameters: [MssqlParameter.nvarchar('v', '', size: 40)],
        );
        final byEquality = await conn.querySingle(
          'SELECT COUNT(*) AS n FROM dbo.enc_probe WHERE wide = @v',
          parameters: [MssqlParameter.nvarchar('v', '', size: 40)],
        );
        expect(byEquality['n'], 1);
        final byNull = await conn.querySingle(
          'SELECT COUNT(*) AS n FROM dbo.enc_probe WHERE wide IS NULL',
        );
        expect(byNull['n'], 0);
      });

      test('an empty blob is not null either', () async {
        final row = await conn.querySingle(
          '''
SELECT CASE WHEN @b IS NULL THEN 1 ELSE 0 END AS is_null,
       DATALENGTH(@b) AS bytes
''',
          parameters: [MssqlParameter.varbinary('b', Uint8List(0), size: 40)],
        );
        expect(row['is_null'], 0);
        expect(row['bytes'], 0);
      });

      test('a null parameter is still null when another is empty', () async {
        final row = await conn.querySingle(
          '''
SELECT CASE WHEN @a IS NULL THEN 1 ELSE 0 END AS a_null,
       CASE WHEN @b IS NULL THEN 1 ELSE 0 END AS b_null
''',
          parameters: [
            MssqlParameter.nvarchar('a', null, size: 40),
            MssqlParameter.nvarchar('b', '', size: 40),
          ],
        );
        expect(row['a_null'], 1);
        expect(row['b_null'], 0);
      });

      test('a null string is null, not an empty one', () async {
        final row = await conn.querySingle(
          'SELECT CASE WHEN @v IS NULL THEN 1 ELSE 0 END AS is_null',
          parameters: [MssqlParameter.nvarchar('v', null, size: 40)],
        );
        expect(row['is_null'], 1);
      });

      test(
        'NCHAR keeps its padding and the driver does not invent it',
        () async {
          await conn.execute('DELETE FROM dbo.enc_probe');
          await conn.execute(
            'INSERT INTO dbo.enc_probe (fixed) VALUES (@v)',
            parameters: [
              MssqlParameter.raw(
                name: 'v',
                type: MssqlType.nchar,
                value: 'İstek',
                size: 20,
              ),
            ],
          );
          final row = await conn.querySingle(
            'SELECT fixed, LEN(fixed) AS trimmed_len, '
            'DATALENGTH(fixed) AS bytes FROM dbo.enc_probe',
          );
          expect(row['trimmed_len'], 5, reason: 'LEN ignores trailing spaces');
          expect(row['bytes'], 40, reason: 'NCHAR(20) is always 20 characters');
          expect((row['fixed'] as String).trimRight(), 'İstek');
        },
      );

      test('a 10 000-character string round-trips at full length', () async {
        final text = 'İş' * 5000;
        expect(text.length, 10000);
        await conn.execute('DELETE FROM dbo.enc_probe');
        await conn.execute(
          'INSERT INTO dbo.enc_probe (huge) VALUES (@v)',
          parameters: [
            MssqlParameter.raw(
              name: 'v',
              type: MssqlType.nvarchar,
              value: text,
            ),
          ],
        );
        final row = await conn.querySingle('SELECT huge FROM dbo.enc_probe');
        expect((row['huge'] as String).length, 10000);
        expect(row['huge'], text);
      });

      test(
        'trailing and leading whitespace is preserved in NVARCHAR',
        () async {
          const text = '  padded  ';
          final row = await conn.querySingle(
            'SELECT @v AS echoed',
            parameters: [MssqlParameter.nvarchar('v', text, size: 40)],
          );
          expect(row['echoed'], text);
        },
      );
    });
  }, skip: skipReason);
}

