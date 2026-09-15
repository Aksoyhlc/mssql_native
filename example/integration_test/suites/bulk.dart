import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mssql_native/mssql_native.dart';

import '../support/android_context.dart';

/// Bulk copy. The BCP path hand-encodes UTF-16LE and streams it, so it is a
/// different risk from the RPC path - and the one most likely to be memory
/// bound on a device.
void registerBulkTests() {
  group('bulk copy', () {
    late MssqlConnection conn;

    setUpAll(() async {
      conn = await sharedConnection();
      await dropTable(conn, 'dbo.and_bulk');
      await conn.execute('''
CREATE TABLE dbo.and_bulk (
  id    INT           NOT NULL,
  label NVARCHAR(60)  NULL,
  narrow VARCHAR(60)  COLLATE Turkish_CI_AS NULL,
  amount DECIMAL(18,4) NULL
);
''');
    });

    tearDownAll(() async => dropTable(conn, 'dbo.and_bulk'));

    setUp(() async => conn.execute('DELETE FROM dbo.and_bulk'));

    testWidgets('a small load reports what it inserted', (_) async {
      final result = await conn.bulkInsert(
        tableName: 'dbo.and_bulk',
        columns: const <MssqlBulkColumn>[
          MssqlBulkColumn(ordinal: 1, name: 'id', type: MssqlType.int32),
          MssqlBulkColumn(
            ordinal: 2,
            name: 'label',
            type: MssqlType.nvarchar,
            size: 60,
          ),
        ],
        rows: <List<MssqlParameter>>[
          for (var i = 0; i < 200; i++)
            <MssqlParameter>[
              MssqlParameter.int32('id', i),
              MssqlParameter.nvarchar('label', 'satır $i ÇĞİ', size: 60),
            ],
        ],
      );
      expect(result.insertedRows, 200);
      expect(result.totalRows, 200);
      final check = await conn.querySingle(
        'SELECT COUNT(*) AS n FROM dbo.and_bulk WHERE label LIKE @p',
        parameters: [MssqlParameter.nvarchar('p', '%ÇĞİ', size: 60)],
      );
      expect(check['n'], 200, reason: 'every row kept its Turkish suffix');
    });

    testWidgets('5000 rows stream in batches', (_) async {
      // Above the default batch size, so bcp_batch actually runs more than
      // once and the device holds a real stream rather than one buffer.
      final result = await conn.bulkInsert(
        tableName: 'dbo.and_bulk',
        columns: const <MssqlBulkColumn>[
          MssqlBulkColumn(ordinal: 1, name: 'id', type: MssqlType.int32),
          MssqlBulkColumn(
            ordinal: 2,
            name: 'label',
            type: MssqlType.nvarchar,
            size: 60,
          ),
        ],
        rows: <List<MssqlParameter>>[
          for (var i = 0; i < 5000; i++)
            <MssqlParameter>[
              MssqlParameter.int32('id', i),
              MssqlParameter.nvarchar('label', 'row-$i', size: 60),
            ],
        ],
        // batched, not the default atomic: bcp_batch only runs in batched
        // mode, so atomic commits once however many rows it carries and
        // committedBatches is 1 by construction.
        options: const MssqlBulkOptions(
          mode: MssqlBulkMode.batched,
          batchSize: 1000,
        ),
      );
      expect(result.insertedRows, 5000);
      expect(result.committedBatches, greaterThan(1));
      final check = await conn.querySingle(
        'SELECT COUNT(*) AS n FROM dbo.and_bulk',
      );
      expect(check['n'], 5000);
    });

    testWidgets('onProgress reports monotonically up to the total', (_) async {
      final seen = <int>[];
      final result = await conn.bulkInsert(
        tableName: 'dbo.and_bulk',
        columns: const <MssqlBulkColumn>[
          MssqlBulkColumn(ordinal: 1, name: 'id', type: MssqlType.int32),
        ],
        rows: <List<MssqlParameter>>[
          for (var i = 0; i < 2500; i++)
            <MssqlParameter>[MssqlParameter.int32('id', i)],
        ],
        options: const MssqlBulkOptions(batchSize: 500),
        onProgress: seen.add,
      );
      expect(result.insertedRows, 2500);
      expect(seen, isNotEmpty);
      var prev = 0;
      for (final sent in seen) {
        expect(sent, greaterThanOrEqualTo(prev));
        prev = sent;
      }
      expect(seen.last, lessThanOrEqualTo(2500));
    });

    testWidgets('NULLs are loaded as NULLs, not as empty values', (_) async {
      await conn.bulkInsert(
        tableName: 'dbo.and_bulk',
        columns: const <MssqlBulkColumn>[
          MssqlBulkColumn(ordinal: 1, name: 'id', type: MssqlType.int32),
          MssqlBulkColumn(
            ordinal: 2,
            name: 'label',
            type: MssqlType.nvarchar,
            size: 60,
          ),
          MssqlBulkColumn(
            ordinal: 4,
            name: 'amount',
            type: MssqlType.decimal,
            precision: 18,
            scale: 4,
          ),
        ],
        rows: <List<MssqlParameter>>[
          <MssqlParameter>[
            MssqlParameter.int32('id', 1),
            MssqlParameter.nvarchar('label', null, size: 60),
            MssqlParameter.decimal('amount', null, precision: 18, scale: 4),
          ],
          <MssqlParameter>[
            MssqlParameter.int32('id', 2),
            MssqlParameter.nvarchar('label', 'present', size: 60),
            MssqlParameter.decimal('amount', '1.2500', precision: 18, scale: 4),
          ],
        ],
      );
      final rows = await conn.queryRows(
        'SELECT id, label, amount FROM dbo.and_bulk ORDER BY id',
      );
      expect(rows, hasLength(2));
      expect(rows[0]['label'], isNull);
      expect(rows[0]['amount'], isNull);
      expect(rows[1]['label'], 'present');
      expect(rows[1]['amount'], closeTo(1.25, 1e-9));
    });

    testWidgets('emoji and surrogate pairs survive the hand-rolled UTF-16LE', (
      _,
    ) async {
      // The RPC path hands the encoding to the server; here the driver does it
      // itself, so a surrogate pair is a genuinely different risk.
      const text = 'Emoji 😀🧿 karışık İstek ğ';
      await conn.bulkInsert(
        tableName: 'dbo.and_bulk',
        columns: const <MssqlBulkColumn>[
          MssqlBulkColumn(ordinal: 1, name: 'id', type: MssqlType.int32),
          MssqlBulkColumn(
            ordinal: 2,
            name: 'label',
            type: MssqlType.nvarchar,
            size: 60,
          ),
        ],
        rows: <List<MssqlParameter>>[
          <MssqlParameter>[
            MssqlParameter.int32('id', 1),
            MssqlParameter.nvarchar('label', text, size: 60),
          ],
        ],
      );
      final row = await conn.querySingle('SELECT label FROM dbo.and_bulk');
      expect(row['label'], text);
    });

    testWidgets('a single-byte column gets the same bytes T-SQL would write', (
      _,
    ) async {
      // The comparison is against the server's own encoding of the same
      // string, because that is the only definition of "right" that does not
      // assume this driver is correct. The text is chosen to live in the
      // database's code page: what bulk copy can carry is bounded by that,
      // not by the column's collation - see the test below.
      const text = 'ÖZEL ÜRÜN';

      await conn.execute(
        'INSERT INTO dbo.and_bulk (id, narrow) VALUES (1, @v)',
        parameters: [MssqlParameter.nvarchar('v', text, size: 60)],
      );
      final viaTsql = await conn.querySingle(
        'SELECT CAST(narrow AS VARBINARY(60)) AS raw, narrow FROM dbo.and_bulk',
      );
      final expectedBytes = viaTsql['raw'] as Uint8List;
      expect(
        viaTsql['narrow'],
        text,
        reason: 'the T-SQL round-trip is the control',
      );

      await conn.execute('DELETE FROM dbo.and_bulk');
      await conn.bulkInsert(
        tableName: 'dbo.and_bulk',
        columns: const <MssqlBulkColumn>[
          MssqlBulkColumn(ordinal: 1, name: 'id', type: MssqlType.int32),
          MssqlBulkColumn(
            ordinal: 3,
            name: 'narrow',
            type: MssqlType.varchar,
            size: 60,
          ),
        ],
        rows: <List<MssqlParameter>>[
          <MssqlParameter>[
            MssqlParameter.int32('id', 1),
            MssqlParameter.varchar('narrow', text, size: 60),
          ],
        ],
      );
      final viaBcp = await conn.querySingle(
        'SELECT CAST(narrow AS VARBINARY(60)) AS raw, narrow FROM dbo.and_bulk',
      );

      String hex(Uint8List b) =>
          b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');
      expect(
        hex(viaBcp['raw'] as Uint8List),
        hex(expectedBytes),
        reason: 'BCP must store the bytes SQL Server writes for this string',
      );
      expect(viaBcp['narrow'], text);
    });

    testWidgets('what bulk copy can carry is bounded by the database, not the '
        'column', (_) async {
      // A characterisation of FreeTDS, not of this driver. Its bulk column
      // metadata declares the *connection's* collation for every character
      // column, whatever collation the column has, and SQL Server converts
      // from there. So a CP1254 column in a CP1252 database cannot take
      // Turkish through bulk copy at all: 0xDE and 0xDD leave as Ş and İ, are
      // read as Þ and Ý, and arrive as '?' and 'Y'.
      //
      // The driver refuses rather than producing that. On a Turkish database
      // there is nothing to refuse and the text goes through.
      const text = 'ŞİŞLİ ığ';
      final dbCodePage =
          (await conn.querySingle(
                "SELECT CAST(COLLATIONPROPERTY(CAST(DATABASEPROPERTYEX(DB_NAME(),"
                "'Collation') AS NVARCHAR(128)), 'CodePage') AS INT) AS cp",
              ))['cp']
              as int;

      Future<void> load() => conn.bulkInsert(
        tableName: 'dbo.and_bulk',
        columns: const <MssqlBulkColumn>[
          MssqlBulkColumn(ordinal: 1, name: 'id', type: MssqlType.int32),
          MssqlBulkColumn(
            ordinal: 3,
            name: 'narrow',
            type: MssqlType.varchar,
            size: 60,
          ),
        ],
        rows: <List<MssqlParameter>>[
          <MssqlParameter>[
            MssqlParameter.int32('id', 1),
            MssqlParameter.varchar('narrow', text, size: 60),
          ],
        ],
      );

      if (dbCodePage == 1254) {
        await load();
        final row = await conn.querySingle('SELECT narrow FROM dbo.and_bulk');
        expect(row['narrow'], text);
        return;
      }

      await expectLater(
        load(),
        throwsA(
          isA<MssqlException>()
              .having((e) => e.type, 'type', MssqlErrorType.conversion)
              .having((e) => e.message, 'message', contains('narrow')),
        ),
        reason: 'database code page $dbCodePage cannot carry Turkish',
      );
      final after = await conn.querySingle(
        'SELECT COUNT(*) AS n FROM dbo.and_bulk',
      );
      expect(after['n'], 0, reason: 'nothing may have been written');
    });

    testWidgets('text no supported code page can hold is refused', (_) async {
      // Cyrillic is in neither CP1252 nor CP1254, so this is refused whatever
      // the database collation is.
      await expectLater(
        conn.bulkInsert(
          tableName: 'dbo.and_bulk',
          columns: const <MssqlBulkColumn>[
            MssqlBulkColumn(ordinal: 1, name: 'id', type: MssqlType.int32),
            MssqlBulkColumn(
              ordinal: 3,
              name: 'narrow',
              type: MssqlType.varchar,
              size: 60,
            ),
          ],
          rows: <List<MssqlParameter>>[
            <MssqlParameter>[
              MssqlParameter.int32('id', 1),
              MssqlParameter.varchar('narrow', 'Москва', size: 60),
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
        'SELECT COUNT(*) AS n FROM dbo.and_bulk',
      );
      expect(after['n'], 0, reason: 'nothing may have been written');
    });
  });
}
