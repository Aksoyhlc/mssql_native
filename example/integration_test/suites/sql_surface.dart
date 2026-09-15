import 'package:flutter_test/flutter_test.dart';
import 'package:mssql_native/mssql_native.dart';

import '../support/android_context.dart';

/// Result-set shapes, query shapes and the limits the driver enforces itself.
void registerSqlSurfaceTests() {
  group('SQL surface', () {
    late MssqlConnection conn;

    setUpAll(() async {
      conn = await sharedConnection();
      await conn.execute('''
IF OBJECT_ID('dbo.and_scratch','U') IS NOT NULL DROP TABLE dbo.and_scratch;
CREATE TABLE dbo.and_scratch (
  id     INT           NOT NULL PRIMARY KEY,
  tag    NVARCHAR(40)  NULL,
  amount DECIMAL(18,4) NOT NULL DEFAULT (0)
);
''');
    });

    tearDownAll(() async => dropTable(conn, 'dbo.and_scratch'));

    group('result-set shapes', () {
      testWidgets('a query matching nothing yields one empty result set', (
        _,
      ) async {
        // Not zero result sets: the metadata arrived, there were simply no
        // rows. A caller reading resultSets.first must not get a range error.
        final result = await conn.query(
          'SELECT sku FROM dbo.products WHERE sku = @s',
          parameters: [MssqlParameter.varchar('s', 'NOPE', size: 24)],
        );
        expect(result.resultSets, hasLength(1));
        expect(result.resultSets.single.rows, isEmpty);
        expect(result.resultSets.single.columns.single.name, 'sku');
      });

      testWidgets(
        'a batch of three selects yields three result sets in order',
        (_) async {
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

      testWidgets('an INSERT reports affected rows and no result set', (
        _,
      ) async {
        await conn.execute('DELETE FROM dbo.and_scratch');
        final result = await conn.query(
          'INSERT INTO dbo.and_scratch (id, tag) VALUES (1, @t), (2, @t)',
          parameters: [MssqlParameter.nvarchar('t', 'seed', size: 40)],
        );
        expect(result.affectedRows, 2);
        expect(result.resultSets, isEmpty);
      });

      testWidgets('an UPDATE matching nothing reports zero affected', (
        _,
      ) async {
        // Zero must be zero, not null and not the previous statement's count.
        final affected = await conn.execute(
          'UPDATE dbo.and_scratch SET tag = @t WHERE id = @id',
          parameters: [
            MssqlParameter.nvarchar('t', 'x', size: 40),
            MssqlParameter.int32('id', -999),
          ],
        );
        expect(affected, 0);
      });

      testWidgets('a DELETE reports what it removed', (_) async {
        await conn.execute(
          'INSERT INTO dbo.and_scratch (id) VALUES (90),(91),(92)',
        );
        final affected = await conn.execute(
          'DELETE FROM dbo.and_scratch WHERE id >= @from',
          parameters: [MssqlParameter.int32('from', 90)],
        );
        expect(affected, 3);
      });

      testWidgets(
        'a mixed batch sums its row counts and keeps its result set',
        (_) async {
          // The count includes the SELECT's two rows, because NOCOUNT is off
          // deliberately - bcp_done depends on those DONE tokens - and
          // DB-Library reports a row count for a SELECT just as it does for an
          // UPDATE. So this is 2 inserted + 2 selected + 1 updated + 2 deleted.
          await conn.execute('DELETE FROM dbo.and_scratch');
          final result = await conn.query('''
INSERT INTO dbo.and_scratch (id, tag) VALUES (300, N'a'), (301, N'b');
SELECT tag FROM dbo.and_scratch WHERE id IN (300, 301) ORDER BY id;
UPDATE dbo.and_scratch SET tag = N'c' WHERE id = 300;
DELETE FROM dbo.and_scratch WHERE id IN (300, 301);
''');
          expect(result.resultSets, hasLength(1));
          expect(result.resultSets.single.rows.map((r) => r['tag']), <String>[
            'a',
            'b',
          ]);
          expect(result.affectedRows, 2 + 2 + 1 + 2);
        },
      );

      testWidgets('an unnamed column still gets a key', (_) async {
        // dbcolname returns an empty string for an unaliased expression, so
        // both columns of `SELECT 1, 2` reported the same empty name and one
        // value was lost from the row map.
        final result = await conn.query('SELECT 1, 2');
        final columns = result.resultSets.single.columns;
        expect(columns, hasLength(2));
        expect(
          columns[0].name,
          isNot(columns[1].name),
          reason: 'two unnamed columns would collide in the row map',
        );
        expect(result.resultSets.single.rows.single.values.toList(), <int>[
          1,
          2,
        ]);
      });

      testWidgets('duplicate column names do not silently drop a column', (
        _,
      ) async {
        // `SELECT a AS x, b AS x` is legal SQL and must not lose b.
        final result = await conn.query(
          'SELECT 1 AS dup, 2 AS dup, 3 AS other',
        );
        expect(result.resultSets.single.columns, hasLength(3));
        final row = result.resultSets.single.rows.single;
        expect(row.keys, hasLength(3));
        expect(row.values.toList(), <int>[1, 2, 3]);
        expect(row['dup'], 1, reason: 'the first keeps the reported name');
      });
    });

    group('query shapes', () {
      testWidgets('a recursive CTE returns every generated level', (_) async {
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

      testWidgets('a join, an aggregate and a window function agree', (
        _,
      ) async {
        final result = await conn.query('''
SELECT c.name, SUM(o.total) AS spend, COUNT(DISTINCT o.id) AS orders,
       RANK() OVER (ORDER BY SUM(o.total) DESC) AS rnk
FROM dbo.customers c
JOIN dbo.orders o ON o.customer_id = c.id
GROUP BY c.name
ORDER BY rnk
''');
        final rows = result.resultSets.single.rows;
        expect(rows, isNotEmpty);
        expect(rows.first['rnk'], 1);
        var prev = 0;
        for (final row in rows) {
          final rank = row['rnk'] as int;
          expect(rank, greaterThanOrEqualTo(prev));
          prev = rank;
        }
      });

      testWidgets('CROSS APPLY returns the top line of each order', (_) async {
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

      testWidgets('LIKE with a parameterised prefix matches', (_) async {
        final rows = await conn.queryRows(
          'SELECT sku FROM dbo.products WHERE sku LIKE @p ORDER BY sku',
          parameters: [MssqlParameter.varchar('p', 'DSK-%', size: 24)],
        );
        expect(rows, hasLength(2));
        for (final row in rows) {
          expect(row['sku'] as String, startsWith('DSK-'));
        }
      });

      testWidgets('MERGE reports all of insert, update and delete', (_) async {
        await conn.execute('DELETE FROM dbo.and_scratch');
        await conn.execute(
          "INSERT INTO dbo.and_scratch (id, tag) VALUES (1, N'old'), (2, N'stays')",
        );
        final affected = await conn.execute('''
MERGE dbo.and_scratch AS target
USING (VALUES (1, N'new'), (3, N'fresh')) AS source(id, tag)
   ON target.id = source.id
WHEN MATCHED THEN UPDATE SET tag = source.tag
WHEN NOT MATCHED BY TARGET THEN INSERT (id, tag) VALUES (source.id, source.tag)
WHEN NOT MATCHED BY SOURCE THEN DELETE;
''');
        expect(affected, 3, reason: '1 updated, 1 inserted, 1 deleted');
        final rows = await conn.queryRows(
          'SELECT id, tag FROM dbo.and_scratch ORDER BY id',
        );
        expect(rows.map((r) => r['id']), <int>[1, 3]);
        expect(rows.first['tag'], 'new');
      });
    });

    group('single-value shapes', () {
      testWidgets('FOR JSON PATH comes back as one long string, intact', (
        _,
      ) async {
        // A nested JSON payload arrives as a single NVARCHAR(MAX) value, often
        // split across several rows by SQL Server. Getting it wrong truncates
        // silently, which is why the brackets and the length are both asserted.
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

      testWidgets('a 200k-character string survives being reassembled', (
        _,
      ) async {
        // Long values are the case where TEXTSIZE and the row-splitting logic
        // both matter - and where a device's heap is tighter than a runner's.
        final rows = await conn.queryRows(
          "SELECT REPLICATE(CAST(N'x' AS NVARCHAR(MAX)), 200000) AS big",
        );
        final text = rows.map((r) => r['big'] as String).join();
        expect(text.length, 200000);
        expect(text.replaceAll('x', ''), isEmpty);
      });

      testWidgets('querySingle refuses to guess when there are two rows', (
        _,
      ) async {
        await expectLater(
          conn.querySingle('SELECT sku FROM dbo.products'),
          throwsA(isA<MssqlMultipleRowsException>()),
        );
      });

      testWidgets('querySingle throws when there are none', (_) async {
        await expectLater(
          conn.querySingle("SELECT sku FROM dbo.products WHERE sku = 'NOPE'"),
          throwsA(isA<MssqlNoRowsException>()),
        );
      });

      testWidgets('querySingleOrNull returns null instead of throwing', (
        _,
      ) async {
        final row = await conn.querySingleOrNull(
          "SELECT sku FROM dbo.products WHERE sku = 'NOPE'",
        );
        expect(row, isNull);
      });

      testWidgets('every column of an all-null row is null, not missing', (
        _,
      ) async {
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
      testWidgets('maximumRows truncates rather than failing', (_) async {
        // querySingle depends on this: it asks for two rows to detect
        // duplicates and expects to be handed what exists.
        final rows = await conn.queryRows(
          'SELECT sku FROM dbo.products ORDER BY sku',
          maximumRows: 3,
        );
        expect(rows, hasLength(3));
      });

      testWidgets('the connection is reusable after a truncated read', (
        _,
      ) async {
        // dbcanquery has to discard the rows nobody read, or the next
        // statement finds the socket mid-result-set.
        await conn.queryRows('SELECT sku FROM dbo.products', maximumRows: 1);
        expect((await conn.querySingle('SELECT 7 AS ok'))['ok'], 7);
      });

      testWidgets('maximumBytes is an error, not a truncation', (_) async {
        // The distinction is deliberate: a byte ceiling means "this response is
        // too big to hold", which a caller must be told about.
        await expectLater(
          conn.query(
            "SELECT REPLICATE(CAST(N'x' AS NVARCHAR(MAX)), 100000) AS big",
            maximumBytes: 1024,
          ),
          throwsA(isA<MssqlException>()),
        );
        expect((await conn.querySingle('SELECT 8 AS ok'))['ok'], 8);
      });

      testWidgets(
        'batchRows outside 1..1000 is refused before the server sees it',
        (_) async {
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

      testWidgets('an empty statement is refused', (_) async {
        await expectLater(conn.query('   '), throwsArgumentError);
      });

      testWidgets('a non-positive timeout is refused', (_) async {
        await expectLater(
          conn.query('SELECT 1', timeout: Duration.zero),
          throwsArgumentError,
        );
      });

      testWidgets('streaming in small batches yields every row exactly once', (
        _,
      ) async {
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
      });

      testWidgets('streamBatches refuses a multi-result statement', (_) async {
        // It yields batches of one result set; a second one would arrive with
        // different columns and silently corrupt the caller's rows.
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
  });
}
