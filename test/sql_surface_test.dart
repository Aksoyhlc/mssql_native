import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

String? _e(String k) => Platform.environment[k];

void main() {
  final live = _e('MSSQL_NATIVE_LIVE') == '1';
  final skipReason = live
      ? null
      : 'Set MSSQL_NATIVE_LIVE=1 with a reachable SQL Server to run.';

  group('SQL surface', () {
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
IF OBJECT_ID('dbo.surf_scratch','U') IS NOT NULL DROP TABLE dbo.surf_scratch;
CREATE TABLE dbo.surf_scratch (
  id     INT           NOT NULL PRIMARY KEY,
  tag    NVARCHAR(40)  NULL,
  amount DECIMAL(18,4) NOT NULL DEFAULT (0)
);
''');
    });

    tearDownAll(() async {
      await conn.execute(
        "IF OBJECT_ID('dbo.surf_scratch','U') IS NOT NULL "
        'DROP TABLE dbo.surf_scratch;',
      );
      await conn.close();
      await MssqlRuntime.instance.shutdown();
    });

    group('result-set shapes', () {
      test('a query matching nothing yields one empty result set', () async {
        final result = await conn.query(
          'SELECT sku FROM dbo.products WHERE sku = @s',
          parameters: [MssqlParameter.varchar('s', 'NOPE', size: 24)],
        );
        expect(result.resultSets, hasLength(1));
        expect(result.resultSets.single.rows, isEmpty);
        expect(result.resultSets.single.columns, hasLength(1));
        expect(result.resultSets.single.columns.single.name, 'sku');
      });

      test(
        'a batch of three selects yields three result sets in order',
        () async {
          final result = await conn.query(
            'SELECT 1 AS a; SELECT 2 AS b, 3 AS c; SELECT 4 AS d',
          );
          expect(result.resultSets, hasLength(3));
          expect(result.resultSets[0].rows.single['a'], 1);
          expect(result.resultSets[1].columns, hasLength(2));
          expect(result.resultSets[1].rows.single['c'], 3);
          expect(result.resultSets[2].rows.single['d'], 4);
        },
      );

      test('an INSERT reports affected rows and no result set', () async {
        final result = await conn.query(
          'INSERT INTO dbo.surf_scratch (id, tag) VALUES (1, @t), (2, @t)',
          parameters: [MssqlParameter.nvarchar('t', 'seed', size: 40)],
        );
        expect(result.affectedRows, 2);
        expect(result.resultSets, isEmpty);
      });

      test('an UPDATE matching nothing reports zero affected', () async {
        final affected = await conn.execute(
          'UPDATE dbo.surf_scratch SET tag = @t WHERE id = @id',
          parameters: [
            MssqlParameter.nvarchar('t', 'x', size: 40),
            MssqlParameter.int32('id', -999),
          ],
        );
        expect(affected, 0);
      });

      test('a DELETE reports what it removed', () async {
        await conn.execute(
          'INSERT INTO dbo.surf_scratch (id) VALUES (90), (91), (92)',
        );
        final affected = await conn.execute(
          'DELETE FROM dbo.surf_scratch WHERE id >= @from',
          parameters: [MssqlParameter.int32('from', 90)],
        );
        expect(affected, 3);
      });

      test(
        'a mixed batch sums its row counts and keeps its result set',
        () async {
          final result = await conn.query('''
INSERT INTO dbo.surf_scratch (id, tag) VALUES (300, N'a'), (301, N'b');
SELECT tag FROM dbo.surf_scratch WHERE id IN (300, 301) ORDER BY id;
UPDATE dbo.surf_scratch SET tag = N'c' WHERE id = 300;
DELETE FROM dbo.surf_scratch WHERE id IN (300, 301);
''');
          expect(result.resultSets, hasLength(1));
          expect(result.resultSets.single.rows.map((r) => r['tag']), <String>[
            'a',
            'b',
          ]);
          expect(result.affectedRows, 2 + 2 + 1 + 2);
        },
      );

      test('an unnamed column still gets a key', () async {
        final result = await conn.query('SELECT 1, 2');
        final columns = result.resultSets.single.columns;
        expect(columns, hasLength(2));
        expect(
          columns[0].name,
          isNot(columns[1].name),
          reason: 'two unnamed columns would collide in the row map',
        );
        final row = result.resultSets.single.rows.single;
        expect(row.keys, hasLength(2));
        expect(row.values.toList(), <int>[1, 2]);
      });

      test('duplicate column names do not silently drop a column', () async {
        final result = await conn.query(
          'SELECT 1 AS dup, 2 AS dup, 3 AS other',
        );
        expect(result.resultSets.single.columns, hasLength(3));
        final row = result.resultSets.single.rows.single;
        expect(row.keys, hasLength(3));
        expect(row.values.toList(), <int>[1, 2, 3]);
        expect(row['dup'], 1, reason: 'the first keeps the reported name');
      });

      test(
        'a named column is not renamed just because another is unnamed',
        () async {
          final result = await conn.query('SELECT 1, 2 AS named, 3');
          final names = result.resultSets.single.columns
              .map((c) => c.name)
              .toList();
          expect(names, contains('named'));
          expect(names.toSet(), hasLength(3));
        },
      );
    });

    group('query shapes', () {
      test('a recursive CTE returns every generated level', () async {
        final rows = await conn.queryRows('''
WITH numbers AS (
  SELECT 1 AS n
  UNION ALL
  SELECT n + 1 FROM numbers WHERE n < 25
)
SELECT n FROM numbers ORDER BY n
''');
        expect(rows, hasLength(25));
        expect(rows.first['n'], 1);
        expect(rows.last['n'], 25);
      });

      test('EXISTS narrows to customers who actually ordered', () async {
        final rows = await conn.queryRows('''
SELECT c.name FROM dbo.customers c
WHERE EXISTS (SELECT 1 FROM dbo.orders o WHERE o.customer_id = c.id)
ORDER BY c.name
''');
        expect(rows, isNotEmpty);
        expect(rows.map((r) => r['name']), isNot(contains('Zeynep Kaya')));
      });

      test(
        'GROUP BY with HAVING filters the aggregate, not the rows',
        () async {
          final rows = await conn.queryRows('''
SELECT c.code, COUNT(*) AS n, SUM(p.stock_qty) AS stock
FROM dbo.products p
JOIN dbo.categories c ON c.id = p.category_id
GROUP BY c.code
HAVING COUNT(*) >= 2
ORDER BY c.code
''');
          expect(rows, isNotEmpty);
          for (final row in rows) {
            expect(row['n'], greaterThanOrEqualTo(2));
          }
        },
      );

      test('a correlated subquery in the select list is one column', () async {
        final rows = await conn.queryRows('''
SELECT c.name,
       (SELECT COUNT(*) FROM dbo.orders o WHERE o.customer_id = c.id) AS orders
FROM dbo.customers c
ORDER BY c.id
''');
        expect(rows, isNotEmpty);
        expect(rows.first.keys, containsAll(<String>['name', 'orders']));
      });

      test('CROSS APPLY returns the top line of each order', () async {
        final rows = await conn.queryRows('''
SELECT o.id, x.line_no
FROM dbo.orders o
CROSS APPLY (
  SELECT TOP 1 line_no FROM dbo.order_items i
  WHERE i.order_id = o.id ORDER BY i.unit_price DESC
) AS x
ORDER BY o.id
''');
        expect(rows, isNotEmpty);
      });

      test('LIKE with a parameterised prefix matches', () async {
        final rows = await conn.queryRows(
          'SELECT sku FROM dbo.products WHERE sku LIKE @p ORDER BY sku',
          parameters: [MssqlParameter.varchar('p', 'DSK-%', size: 24)],
        );
        expect(rows, hasLength(2));
        for (final row in rows) {
          expect(row['sku'] as String, startsWith('DSK-'));
        }
      });

      test('ORDER BY DESC really reverses the ascending order', () async {
        final asc = await conn.queryRows(
          'SELECT sku FROM dbo.products ORDER BY sku ASC',
        );
        final desc = await conn.queryRows(
          'SELECT sku FROM dbo.products ORDER BY sku DESC',
        );
        expect(
          desc.map((r) => r['sku']).toList(),
          asc.map((r) => r['sku']).toList().reversed.toList(),
        );
      });

      test('UPDATE ... FROM with a join reports the rows it touched', () async {
        await conn.execute("""
INSERT INTO dbo.surf_scratch (id, tag, amount)
VALUES (500, N'x', 0), (501, N'y', 0)
""");
        final affected = await conn.execute('''
UPDATE s SET amount = j.v
FROM dbo.surf_scratch s
JOIN (VALUES (500, 1.5), (501, 2.5)) AS j(id, v) ON j.id = s.id
''');
        expect(affected, 2);
        final rows = await conn.queryRows(
          'SELECT id, amount FROM dbo.surf_scratch '
          'WHERE id IN (500, 501) ORDER BY id',
        );
        expect(rows.map((r) => r['amount']), <MssqlDecimal>[
          MssqlDecimal.parse('1.5000'),
          MssqlDecimal.parse('2.5000'),
        ]);
        await conn.execute(
          'DELETE FROM dbo.surf_scratch WHERE id IN (500,501)',
        );
      });

      test('MERGE reports all of insert, update and delete', () async {
        await conn.execute('DELETE FROM dbo.surf_scratch');
        await conn.execute("""
INSERT INTO dbo.surf_scratch (id, tag) VALUES (1, N'old'), (2, N'stays')
""");
        final affected = await conn.execute('''
MERGE dbo.surf_scratch AS target
USING (VALUES (1, N'new'), (3, N'fresh')) AS source(id, tag)
   ON target.id = source.id
WHEN MATCHED THEN UPDATE SET tag = source.tag
WHEN NOT MATCHED BY TARGET THEN INSERT (id, tag) VALUES (source.id, source.tag)
WHEN NOT MATCHED BY SOURCE THEN DELETE;
''');
        expect(affected, 3, reason: '1 updated, 1 inserted, 1 deleted');
        final rows = await conn.queryRows(
          'SELECT id, tag FROM dbo.surf_scratch ORDER BY id',
        );
        expect(rows.map((r) => r['id']), <int>[1, 3]);
        expect(rows.first['tag'], 'new');
      });
    });

    group('single-value shapes', () {
      test('FOR JSON PATH comes back as one long string, intact', () async {
        final rows = await conn.queryRows('''
SELECT c.code, c.name,
  (SELECT p.sku, p.name, p.price
   FROM dbo.products p WHERE p.category_id = c.id
   FOR JSON PATH) AS products
FROM dbo.categories c
FOR JSON PATH
''');
        final json = rows.map((r) => r.values.single as String).join();
        expect(json, startsWith('['));
        expect(json, endsWith(']'));
        expect(json, contains('DSK-LMP-001'));
        expect(json, contains('Işıklı'), reason: 'Unicode inside JSON');
        expect(json.length, greaterThan(500));
      });

      test('a 200k-character string survives being reassembled', () async {
        final rows = await conn.queryRows(
          "SELECT REPLICATE(CAST(N'x' AS NVARCHAR(MAX)), 200000) AS big",
        );
        final text = rows.map((r) => r['big'] as String).join();
        expect(text.length, 200000);
        expect(text.replaceAll('x', ''), isEmpty);
      });

      test('querySingle refuses to guess when there are two rows', () async {
        await expectLater(
          conn.querySingle('SELECT sku FROM dbo.products'),
          throwsA(isA<MssqlMultipleRowsException>()),
        );
      });

      test('querySingle throws when there are none', () async {
        await expectLater(
          conn.querySingle("SELECT sku FROM dbo.products WHERE sku = 'NOPE'"),
          throwsA(isA<MssqlNoRowsException>()),
        );
      });

      test('querySingleOrNull returns null instead of throwing', () async {
        final row = await conn.querySingleOrNull(
          "SELECT sku FROM dbo.products WHERE sku = 'NOPE'",
        );
        expect(row, isNull);
      });

      test('querySingleOrNull still refuses two rows', () async {
        await expectLater(
          conn.querySingleOrNull('SELECT sku FROM dbo.products'),
          throwsA(isA<MssqlMultipleRowsException>()),
        );
      });

      test('every column of an all-null row is null, not missing', () async {
        final row = await conn.querySingle('''
SELECT CAST(NULL AS INT) AS i, CAST(NULL AS NVARCHAR(10)) AS s,
       CAST(NULL AS DECIMAL(18,4)) AS d, CAST(NULL AS DATETIME2(3)) AS t,
       CAST(NULL AS VARBINARY(8)) AS b, CAST(NULL AS BIT) AS f,
       CAST(NULL AS UNIQUEIDENTIFIER) AS g
''');
        expect(row.keys, hasLength(7));
        for (final entry in row.entries) {
          expect(entry.value, isNull, reason: entry.key);
        }
      });
    });

    group('limits', () {
      test('maximumRows truncates rather than failing', () async {
        final rows = await conn.queryRows(
          'SELECT sku FROM dbo.products ORDER BY sku',
          maximumRows: 3,
        );
        expect(rows, hasLength(3));
      });

      test('the connection is reusable after a truncated read', () async {
        await conn.queryRows('SELECT sku FROM dbo.products', maximumRows: 1);
        final row = await conn.querySingle('SELECT 7 AS ok');
        expect(row['ok'], 7);
      });

      test('maximumBytes is an error, not a truncation', () async {
        await expectLater(
          conn.query(
            "SELECT REPLICATE(CAST(N'x' AS NVARCHAR(MAX)), 100000) AS big",
            maximumBytes: 1024,
          ),
          throwsA(isA<MssqlException>()),
        );
        final row = await conn.querySingle('SELECT 8 AS ok');
        expect(row['ok'], 8);
      });

      test(
        'batchRows outside 1..1000 is refused before the server sees it',
        () async {
          await expectLater(
            conn.query('SELECT 1', batchRows: 0),
            throwsRangeError,
          );
          await expectLater(
            conn.query('SELECT 1', batchRows: 1001),
            throwsRangeError,
          );
        },
      );

      test('an empty statement is refused', () async {
        await expectLater(conn.query('   '), throwsArgumentError);
      });

      test('a non-positive timeout is refused', () async {
        await expectLater(
          conn.query('SELECT 1', timeout: Duration.zero),
          throwsArgumentError,
        );
      });

      test(
        'streaming in small batches yields every row exactly once',
        () async {
          final seen = <String>[];
          await for (final batch in conn.streamBatches(
            'SELECT sku FROM dbo.products ORDER BY sku',
            batchRows: 3,
          )) {
            seen.addAll(batch.map((r) => r['sku'] as String));
          }
          final all = await conn.queryRows(
            'SELECT sku FROM dbo.products ORDER BY sku',
          );
          expect(seen, all.map((r) => r['sku']).toList());
          expect(seen.toSet(), hasLength(seen.length), reason: 'no duplicates');
        },
      );

      test('streamBatches refuses a multi-result statement', () async {
        await expectLater(
          conn.streamBatches('SELECT 1 AS a; SELECT 2 AS b').toList(),
          throwsA(
            isA<MssqlException>().having(
              (e) => e.type,
              'type',
              MssqlErrorType.protocol,
            ),
          ),
        );
        expect(
          await conn.queryScalar<int>('SELECT 42'),
          42,
          reason: 'the rejected second result must be drained safely',
        );
      });
    });
  }, skip: skipReason);
}

