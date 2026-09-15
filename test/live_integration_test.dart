
import 'dart:io';
import 'dart:typed_data';

import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

String? _e(String k) => Platform.environment[k];

void main() {
  final live = _e('MSSQL_NATIVE_LIVE') == '1';
  final skipReason = live
      ? null
      : 'Set MSSQL_NATIVE_LIVE=1 (and a reachable SQL Server) to run.';

  group('live SQL Server end-to-end', () {
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
    });

    tearDownAll(() async {
      await conn.close();
      await MssqlRuntime.instance.shutdown();
    });

    test('scalar select', () async {
      final row = await conn.querySingle('SELECT 42 AS answer');
      expect(row['answer'], 42);
    });

    test('typed parameter lookup returns correct Dart types', () async {
      final row = await conn.querySingle(
        'SELECT id, name, price, cost, weight_kg, stock_qty, is_active, '
        'rowguid, thumbnail, created_at '
        'FROM dbo.products WHERE sku = @sku',
        parameters: [MssqlParameter.varchar('sku', 'DSK-LMP-001', size: 24)],
      );
      expect(row['name'], 'Işıklı Masa Lambası');
      expect(row['id'], isA<int>());
      expect(row['price'], isA<MssqlDecimal>());
      expect(row['cost'], isA<MssqlDecimal>());
      expect(row['weight_kg'], isA<double>());
      expect(row['stock_qty'], isA<int>());
      expect(row['is_active'], isA<bool>());
      expect(row['is_active'], true);
      expect(row['rowguid'], isA<String>());
      expect(row['rowguid'], matches(RegExp(r'^[0-9A-Fa-f-]{36}$')));
      expect(row['thumbnail'], isA<Uint8List>());
      expect(
        (row['thumbnail'] as Uint8List),
        equals(Uint8List.fromList([0x1A, 0x2B, 0x3C, 0x4D])),
      );
      expect(row['created_at'], isA<MssqlDateTimeValue>());
    });

    test('null values decode as null', () async {
      final row = await conn.querySingle(
        'SELECT grammage, barcode, thumbnail FROM dbo.products WHERE sku = @sku',
        parameters: [MssqlParameter.varchar('sku', 'PPR-A4C-101', size: 24)],
      );
      expect(row['grammage'], isNull);
      expect(row['thumbnail'], isNull);
    });

    test('VARCHAR with Turkish (CP1254) collation round-trips', () async {
      const expected =
          '4 KENAR OVERLOK ÜZERİ EBATLAR BEZ BAŞLIKLI OLACAKTIR. DÜZ BÜKÜM ÇÖĞÜŞİ çöğüşı';
      final row = await conn.querySingle(
        'SELECT label, label_n FROM dbo.charset_probe WHERE id = 1',
      );
      expect(row['label'], expected);
      expect(row['label_n'], expected);
    });

    test('complex join + aggregation + window function', () async {
      final result = await conn.query(
        'SELECT c.name, c.segment, '
        '       SUM(o.total) AS spend, '
        '       COUNT(DISTINCT o.id) AS orders, '
        '       RANK() OVER (ORDER BY SUM(o.total) DESC) AS rnk '
        'FROM dbo.customers c '
        'JOIN dbo.orders o ON o.customer_id = c.id '
        'GROUP BY c.name, c.segment '
        'HAVING SUM(o.total) > @floor '
        'ORDER BY rnk',
        parameters: [
          MssqlParameter.decimal('floor', '0', precision: 18, scale: 2),
        ],
      );
      final rows = result.resultSets.single.rows;
      expect(rows, isNotEmpty);
      expect(rows.first['rnk'], 1);
      var prev = 0;
      for (final r in rows) {
        final rank = r['rnk'] as int;
        expect(rank, greaterThanOrEqualTo(prev));
        prev = rank;
      }
    });

    test(
      'stored procedure: multiple result sets + output + return status',
      () async {
        final result = await conn.callProcedure(
          'dbo.usp_customer_dashboard',
          parameters: [
            MssqlParameter.int32('customer_id', 1),
            MssqlParameter.int32(
              'order_count',
              null,
              direction: MssqlParameterDirection.output,
            ),
          ],
        );
        expect(result.resultSets.length, 2, reason: 'header + order lines');
        expect(result.resultSets[0].rows.single['segment'], 'wholesale');
        expect(result.resultSets[1].rows, isNotEmpty);
        expect(result.outputParameters['order_count'], isA<int>());
        expect(result.outputParameters['order_count'], greaterThan(0));
        expect(result.returnStatus, 0);
      },
    );

    test('stored procedure not-found path returns 404 and -1 output', () async {
      final result = await conn.callProcedure(
        'dbo.usp_customer_dashboard',
        parameters: [
          MssqlParameter.int32('customer_id', 999999),
          MssqlParameter.int32(
            'order_count',
            null,
            direction: MssqlParameterDirection.output,
          ),
        ],
      );
      expect(result.returnStatus, 404);
      expect(result.outputParameters['order_count'], -1);
    });

    test('transaction rollback leaves no trace', () async {
      final before = await conn.querySingle(
        'SELECT COUNT(*) AS n FROM dbo.orders WHERE customer_id = 5',
      );
      final tx = await conn.beginTransaction();
      await tx.query(
        'INSERT INTO dbo.orders (customer_id, status, notes) '
        'VALUES (@c, 1, @n)',
        parameters: [
          MssqlParameter.int32('c', 5),
          MssqlParameter.nvarchar('n', 'rollback-me', size: 50),
        ],
      );
      await tx.rollback();
      await tx.close();
      final after = await conn.querySingle(
        'SELECT COUNT(*) AS n FROM dbo.orders WHERE customer_id = 5',
      );
      expect(after['n'], before['n']);
    });

    test('transaction commit persists', () async {
      final before = await conn.querySingle(
        'SELECT COUNT(*) AS n FROM dbo.inventory_log',
      );
      await conn.transaction((tx) async {
        await tx.query(
          'INSERT INTO dbo.inventory_log (product_id, delta, reason) '
          'VALUES (1000, @d, @r)',
          parameters: [
            MssqlParameter.int32('d', -3),
            MssqlParameter.nvarchar('r', 'commit-test', size: 40),
          ],
        );
      });
      final after = await conn.querySingle(
        'SELECT COUNT(*) AS n FROM dbo.inventory_log',
      );
      expect(after['n'], (before['n'] as int) + 1);
    });

    test('bulk insert (BCP) streams rows', () async {
      final before = await conn.querySingle(
        'SELECT COUNT(*) AS n FROM dbo.inventory_log',
      );
      final result = await conn.bulkInsert(
        tableName: 'dbo.inventory_log',
        columns: const [
          MssqlBulkColumn(
            ordinal: 2,
            name: 'product_id',
            type: MssqlType.int32,
          ),
          MssqlBulkColumn(ordinal: 3, name: 'delta', type: MssqlType.int32),
          MssqlBulkColumn(
            ordinal: 4,
            name: 'reason',
            type: MssqlType.nvarchar,
            size: 40,
          ),
        ],
        rows: List.generate(
          50,
          (i) => [
            MssqlParameter.int32('product_id', 1000 + (i % 10)),
            MssqlParameter.int32('delta', i - 25),
            MssqlParameter.nvarchar('reason', 'bulk-$i', size: 40),
          ],
        ),
      );
      expect(result.insertedRows, 50);
      final after = await conn.querySingle(
        'SELECT COUNT(*) AS n FROM dbo.inventory_log',
      );
      expect(after['n'], (before['n'] as int) + 50);
    });
  }, skip: skipReason);
}

