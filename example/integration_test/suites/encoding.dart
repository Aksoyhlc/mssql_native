import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mssql_native/mssql_native.dart';

import '../support/android_context.dart';

/// Each entry is (description, text). The samples are the desktop suite's, and
/// they are the reason this platform needed a bundled libiconv at all.
const List<(String, String)> _samples = <(String, String)>[
  ('ascii', 'plain ascii text'),
  ('turkish dotted and dotless i', 'İstanbul ışık İIıi'),
  ('turkish full alphabet', 'ÇçĞğİıÖöŞşÜü'),
  ('german sharp s', 'Grüße aus Köln, Straße'),
  ('greek', 'αβγδε ΑΒΓ'),
  ('cyrillic', 'Москва здрав'),
  ('arabic rtl', 'مرحبا بالعالم'),
  ('cjk han', '你好世界'),
  ('korean hangul', '안녕하세요'),
  ('emoji with surrogates', 'box 🧿 cart 🛒'),
  ('zero width joiner', '👩‍💻'),
  ('mixed scripts one line', 'İstanbul 世界 مرحبا 🧿'),
  ('currency signs', '₺100 €50 £40 ¥5000'),
  ('newlines and tabs', 'line1\nline2\r\nline3\tend'),
];

/// Text, which is the whole reason this platform was built.
///
/// Bionic's iconv cannot convert CP1254, so a build using it returns the
/// Turkish letters as Ý/Þ/Ð. Everything in the single-byte group passes only
/// because libiconv is bundled and statically linked.
void registerEncodingTests() {
  group('text encoding', () {
    late MssqlConnection conn;

    setUpAll(() async {
      conn = await sharedConnection();
      await conn.execute('''
IF OBJECT_ID('dbo.and_enc','U') IS NOT NULL DROP TABLE dbo.and_enc;
CREATE TABLE dbo.and_enc (
  id     INT IDENTITY(1,1) PRIMARY KEY,
  wide   NVARCHAR(400) NULL,
  narrow VARCHAR(400)  COLLATE Turkish_CI_AS NULL,
  fixed  NCHAR(20)     NULL,
  huge   NVARCHAR(MAX) NULL
);
''');
    });

    tearDownAll(() async => dropTable(conn, 'dbo.and_enc'));

    group('RPC parameter round-trip (NVARCHAR)', () {
      for (final (label, text) in _samples) {
        testWidgets(label, (_) async {
          final row = await conn.querySingle(
            'SELECT @v AS echoed',
            parameters: [MssqlParameter.nvarchar('v', text, size: 400)],
          );
          expect(row['echoed'], text);
        });
      }
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
        testWidgets('"$text" survives VARCHAR(CP1254)', (_) async {
          // Both values are written through *nvarchar* parameters. That is not
          // a workaround, it is the only correct way: a varchar parameter is
          // bound in the database's collation rather than the column's, so
          // under a Latin1 database SQL Server flattens İ to I before the
          // CP1254 column is ever reached. The test below pins that boundary.
          //
          // Reading `narrow` back is what exercises iconv, and iconv is what
          // bionic does not have.
          final inserted = await conn.query(
            'INSERT INTO dbo.and_enc (narrow, wide) OUTPUT INSERTED.id '
            'VALUES (@v, @v2)',
            parameters: [
              MssqlParameter.nvarchar('v', text, size: 400),
              MssqlParameter.nvarchar('v2', text, size: 400),
            ],
          );
          final id = inserted.resultSets.single.rows.single['id'] as int;
          final row = await conn.querySingle(
            'SELECT narrow, wide FROM dbo.and_enc WHERE id = @id',
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

      testWidgets('the seeded charset probe still reads correctly', (_) async {
        final row = await conn.querySingle(
          'SELECT label, label_n FROM dbo.charset_probe',
        );
        expect(
          row['label'],
          row['label_n'],
          reason: 'the single-byte column must match its Unicode mirror',
        );
        expect(row['label'] as String, contains('ÇÖĞÜŞİ'));
        expect(
          row['label'] as String,
          isNot(contains('Ý')),
          reason: 'Ý is what a missing iconv produces for İ',
        );
      });

      testWidgets('a WHERE on the single-byte column matches Turkish text', (
        _,
      ) async {
        // Reading it back correctly is one thing; finding it again means the
        // outbound conversion matches the inbound one.
        await conn.execute(
          'INSERT INTO dbo.and_enc (narrow) VALUES (@v)',
          parameters: [
            MssqlParameter.nvarchar('v', 'ÖZEL ÜRÜN ŞİŞLİ', size: 400),
          ],
        );
        final rows = await conn.queryRows(
          'SELECT narrow FROM dbo.and_enc WHERE narrow = @v',
          parameters: [
            MssqlParameter.nvarchar('v', 'ÖZEL ÜRÜN ŞİŞLİ', size: 400),
          ],
        );
        expect(rows, isNotEmpty);
      });

      testWidgets(
        'a varchar parameter is bound in the database collation, not the '
        'column one',
        (_) async {
          // A characterisation test for a SQL Server rule that costs people days.
          // sp_executesql declares @v as varchar(n), which SQL Server interprets
          // in the *database's* default collation. On a Latin1 database the
          // Turkish-specific letters are not representable there, so they are
          // flattened before the CP1254 column is reached. The driver cannot
          // prevent it and must not pretend to: use an nvarchar parameter.
          final collation =
              (await conn.querySingle(
                    "SELECT CAST(DATABASEPROPERTYEX(DB_NAME(),'Collation') AS "
                    'NVARCHAR(128)) AS c',
                  ))['c']
                  as String;
          if (collation.startsWith('Turkish')) {
            markTestSkipped('nothing to flatten on a Turkish database');
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
        },
      );
    });

    group('lengths and edges', () {
      testWidgets('the server counts characters, not bytes', (_) async {
        // 'İstanbul' is 8 characters and 9 UTF-8 bytes. If LEN came back as 9
        // the driver would be reporting its own encoding, not the column's.
        final row = await conn.querySingle(
          'SELECT LEN(@v) AS chars, DATALENGTH(@v) AS bytes',
          parameters: [MssqlParameter.nvarchar('v', 'İstanbul', size: 40)],
        );
        expect(row['chars'], 8);
        expect(row['bytes'], 16, reason: 'UCS-2 on the wire, two per char');
      });

      testWidgets('an empty string is not null', (_) async {
        // SQL Server distinguishes them and so must the driver: '' is a value.
        // dbrpcparam cannot express the difference, so the driver restores it
        // inside the statement - see emptyValuePrelude.
        final row = await conn.querySingle(
          '''
SELECT CASE WHEN @v IS NULL THEN 1 ELSE 0 END AS is_null, LEN(@v) AS chars
''',
          parameters: [MssqlParameter.nvarchar('v', '', size: 40)],
        );
        expect(row['is_null'], 0);
        expect(row['chars'], 0);
      });

      testWidgets('an empty string is stored as a value and found by =', (
        _,
      ) async {
        // The failure this guards: if '' became NULL the row would be
        // invisible to `WHERE wide = ''` and visible to `WHERE wide IS NULL`.
        await conn.execute('DELETE FROM dbo.and_enc');
        await conn.execute(
          'INSERT INTO dbo.and_enc (wide) VALUES (@v)',
          parameters: [MssqlParameter.nvarchar('v', '', size: 40)],
        );
        final byEquality = await conn.querySingle(
          'SELECT COUNT(*) AS n FROM dbo.and_enc WHERE wide = @v',
          parameters: [MssqlParameter.nvarchar('v', '', size: 40)],
        );
        expect(byEquality['n'], 1);
        final byNull = await conn.querySingle(
          'SELECT COUNT(*) AS n FROM dbo.and_enc WHERE wide IS NULL',
        );
        expect(byNull['n'], 0);
      });

      testWidgets('an empty blob is not null either', (_) async {
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

      testWidgets('a null parameter is still null when another is empty', (
        _,
      ) async {
        // The prelude must touch only the parameters it was built for.
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

      testWidgets('NCHAR keeps its padding and the driver does not invent it', (
        _,
      ) async {
        // dbconvert right-trims, so a fixed-width column read through the
        // conversion path could lose padding the caller stored deliberately.
        await conn.execute('DELETE FROM dbo.and_enc');
        await conn.execute(
          'INSERT INTO dbo.and_enc (fixed) VALUES (@v)',
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
          'DATALENGTH(fixed) AS bytes FROM dbo.and_enc',
        );
        expect(row['trimmed_len'], 5, reason: 'LEN ignores trailing spaces');
        expect(row['bytes'], 40, reason: 'NCHAR(20) is always 20 characters');
        expect((row['fixed'] as String).trimRight(), 'İstek');
      });

      testWidgets('a 10 000-character string round-trips at full length', (
        _,
      ) async {
        final text = 'İş' * 5000;
        expect(text.length, 10000);
        await conn.execute('DELETE FROM dbo.and_enc');
        await conn.execute(
          'INSERT INTO dbo.and_enc (huge) VALUES (@v)',
          parameters: [
            MssqlParameter.raw(
              name: 'v',
              type: MssqlType.nvarchar,
              value: text,
            ),
          ],
        );
        final row = await conn.querySingle('SELECT huge FROM dbo.and_enc');
        expect((row['huge'] as String).length, 10000);
        expect(row['huge'], text);
      });

      testWidgets('leading and trailing whitespace is preserved in NVARCHAR', (
        _,
      ) async {
        const text = '  padded  ';
        final row = await conn.querySingle(
          'SELECT @v AS echoed',
          parameters: [MssqlParameter.nvarchar('v', text, size: 40)],
        );
        expect(row['echoed'], text);
      });
    });
  });
}
