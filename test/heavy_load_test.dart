
import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

String? _e(String k) => Platform.environment[k];

const int kRows = 50000;
const int kBatch = 5000;

MssqlConnectionConfig _config() => MssqlConnectionConfig(
  host: _e('MSSQL_NATIVE_HOST') ?? '127.0.0.1',
  port: int.parse(_e('MSSQL_NATIVE_PORT') ?? '1433'),
  database: _e('MSSQL_NATIVE_DB') ?? 'mssql_native_test',
  username: _e('MSSQL_NATIVE_USER') ?? 'sa',
  password: _e('MSSQL_NATIVE_PASSWORD') ?? 'Mssql@Native2026',
  encryption: MssqlEncryption.off,
  defaultQueryTimeout: const Duration(minutes: 5),
);

int _qtyOf(int i) => (i * 37) % 1000;

void main() {
  final live = _e('MSSQL_NATIVE_LIVE') == '1';
  final skip = live
      ? null
      : 'Set MSSQL_NATIVE_LIVE=1 with a reachable SQL Server to run.';

  group('heavy load', () {
    late MssqlConnection conn;

    setUpAll(() async {
      await MssqlRuntime.instance.initialize(
        bridgePath: _e('MSSQL_NATIVE_BRIDGE'),
        sybdbPath: _e('MSSQL_NATIVE_SYBDB'),
      );
      conn = await MssqlConnection.open(_config());
      await conn.execute(
        "IF OBJECT_ID('dbo.heavy') IS NOT NULL DROP TABLE dbo.heavy",
      );
      await conn.execute(
        'CREATE TABLE dbo.heavy ('
        ' id    INT IDENTITY(1,1) PRIMARY KEY,'
        ' grp   INT           NOT NULL,'
        ' code  VARCHAR(24)   NOT NULL,'
        ' name  NVARCHAR(60)  NOT NULL,'
        ' qty   INT           NOT NULL,'
        ' price DECIMAL(18,2) NOT NULL)',
      );
    });

    tearDownAll(() async {
      await conn.execute(
        "IF OBJECT_ID('dbo.heavy') IS NOT NULL DROP TABLE dbo.heavy",
      );
      await conn.close();
      await MssqlRuntime.instance.shutdown();
    });

    test('batched BCP loads $kRows rows and commits in batches', () async {
      var progressCalls = 0;
      final sw = Stopwatch()..start();
      final result = await conn.bulkInsert(
        tableName: 'dbo.heavy',
        options: const MssqlBulkOptions(
          mode: MssqlBulkMode.batched,
          batchSize: kBatch,
        ),
        columns: const [
          MssqlBulkColumn(ordinal: 2, name: 'grp', type: MssqlType.int32),
          MssqlBulkColumn(
            ordinal: 3,
            name: 'code',
            type: MssqlType.varchar,
            size: 24,
          ),
          MssqlBulkColumn(
            ordinal: 4,
            name: 'name',
            type: MssqlType.nvarchar,
            size: 60,
          ),
          MssqlBulkColumn(ordinal: 5, name: 'qty', type: MssqlType.int32),
          MssqlBulkColumn(
            ordinal: 6,
            name: 'price',
            type: MssqlType.decimal,
            precision: 18,
            scale: 2,
          ),
        ],
        rows: Iterable.generate(
          kRows,
          (i) => [
            MssqlParameter.int32('grp', i % 50),
            MssqlParameter.varchar(
              'code',
              'C${i.toString().padLeft(9, '0')}',
              size: 24,
            ),
            MssqlParameter.nvarchar('name', 'Satır $i · Ürün-şĞİç', size: 60),
            MssqlParameter.int32('qty', _qtyOf(i)),
            MssqlParameter.decimal(
              'price',
              ((i % 100000) / 100).toStringAsFixed(2),
              precision: 18,
              scale: 2,
            ),
          ],
        ),
        onProgress: (_) => progressCalls++,
      );
      sw.stop();
      final rate = (kRows * 1000 / sw.elapsedMilliseconds).round();
      print(
        'Batched BCP: $kRows rows in ${sw.elapsedMilliseconds}ms '
        '(~$rate rows/s), ${result.committedBatches} batches',
      );
      expect(result.insertedRows, kRows);
      expect(result.totalRows, kRows);
      expect(result.committedBatches, greaterThanOrEqualTo(kRows ~/ kBatch));
    });

    test('all $kRows rows are present and intact (checksum)', () async {
      var expectedQtySum = 0;
      for (var i = 0; i < kRows; i++) {
        expectedQtySum += _qtyOf(i);
      }
      final row = await conn.querySingle(
        'SELECT COUNT(*) AS n, SUM(CONVERT(BIGINT, qty)) AS q FROM dbo.heavy',
      );
      expect(row['n'], kRows);
      expect(int.parse(row['q'].toString()), expectedQtySum);
    });

    test('non-ASCII survived the large batched load', () async {
      final row = await conn.querySingle(
        'SELECT name FROM dbo.heavy WHERE grp = @g AND code = @c',
        parameters: [
          MssqlParameter.int32('g', 7 % 50),
          MssqlParameter.varchar(
            'c',
            'C${(7).toString().padLeft(9, '0')}',
            size: 24,
          ),
        ],
      );
      expect(row['name'], 'Satır 7 · Ürün-şĞİç');
    });

    test('streaming all $kRows rows yields each id exactly once', () async {
      var count = 0;
      var minId = 1 << 62;
      var maxId = 0;
      final sw = Stopwatch()..start();
      await for (final batch in conn.streamBatches(
        'SELECT id FROM dbo.heavy ORDER BY id',
        batchRows: 1000,
      )) {
        for (final r in batch) {
          final id = r['id'] as int;
          if (id < minId) minId = id;
          if (id > maxId) maxId = id;
          count++;
        }
      }
      sw.stop();
      print('Streamed $count rows in ${sw.elapsedMilliseconds}ms');
      expect(count, kRows);
      expect(maxId - minId + 1, kRows);
    });
  }, skip: skip);
}

