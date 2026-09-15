
import 'dart:async';
import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

String? _e(String k) => Platform.environment[k];

const int kRowCount = 3000;

MssqlConnectionConfig _config() => MssqlConnectionConfig(
  host: _e('MSSQL_NATIVE_HOST') ?? '127.0.0.1',
  port: int.parse(_e('MSSQL_NATIVE_PORT') ?? '1433'),
  database: _e('MSSQL_NATIVE_DB') ?? 'mssql_native_test',
  username: _e('MSSQL_NATIVE_USER') ?? 'sa',
  password: _e('MSSQL_NATIVE_PASSWORD') ?? 'Mssql@Native2026',
  encryption: MssqlEncryption.off,
  defaultQueryTimeout: const Duration(seconds: 60),
);

void main() {
  final live = _e('MSSQL_NATIVE_LIVE') == '1';
  final skip = live
      ? null
      : 'Set MSSQL_NATIVE_LIVE=1 with a reachable SQL Server to run.';

  group('stress', () {
    late MssqlConnection conn;

    setUpAll(() async {
      await MssqlRuntime.instance.initialize(
        bridgePath: _e('MSSQL_NATIVE_BRIDGE'),
        sybdbPath: _e('MSSQL_NATIVE_SYBDB'),
      );
      conn = await MssqlConnection.open(_config());

      await conn.execute(
        "IF OBJECT_ID('dbo.stress') IS NOT NULL DROP TABLE dbo.stress",
      );
      await conn.execute(
        'CREATE TABLE dbo.stress ('
        ' id       INT IDENTITY(1,1) PRIMARY KEY,'
        ' grp      INT           NOT NULL,'
        ' code     VARCHAR(20)   NOT NULL,'
        ' name     NVARCHAR(60)  NOT NULL,'
        ' price    DECIMAL(18,2) NOT NULL,'
        ' qty      INT           NOT NULL,'
        ' flag     BIT           NOT NULL,'
        ' created  DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME())',
      );

      final sw = Stopwatch()..start();
      final result = await conn.bulkInsert(
        tableName: 'dbo.stress',
        columns: const [
          MssqlBulkColumn(ordinal: 2, name: 'grp', type: MssqlType.int32),
          MssqlBulkColumn(
            ordinal: 3,
            name: 'code',
            type: MssqlType.varchar,
            size: 20,
          ),
          MssqlBulkColumn(
            ordinal: 4,
            name: 'name',
            type: MssqlType.nvarchar,
            size: 60,
          ),
          MssqlBulkColumn(
            ordinal: 5,
            name: 'price',
            type: MssqlType.decimal,
            precision: 18,
            scale: 2,
          ),
          MssqlBulkColumn(ordinal: 6, name: 'qty', type: MssqlType.int32),
          MssqlBulkColumn(ordinal: 7, name: 'flag', type: MssqlType.bit),
        ],
        rows: List.generate(kRowCount, (i) {
          final price = ((i * 7) % 100000) / 100.0;
          return [
            MssqlParameter.int32('grp', i % 25),
            MssqlParameter.varchar(
              'code',
              'SKU-${i.toString().padLeft(6, '0')}',
              size: 20,
            ),
            MssqlParameter.nvarchar('name', 'Ürün #$i — kayıt', size: 60),
            MssqlParameter.decimal(
              'price',
              price.toStringAsFixed(2),
              precision: 18,
              scale: 2,
            ),
            MssqlParameter.int32('qty', i % 500),
            MssqlParameter.bit('flag', i % 2 == 0),
          ];
        }),
      );
      sw.stop();
      print(
        'BCP loaded ${result.insertedRows} rows in ${sw.elapsedMilliseconds}ms',
      );
      expect(result.insertedRows, kRowCount);
    });

    tearDownAll(() async {
      await conn.execute(
        "IF OBJECT_ID('dbo.stress') IS NOT NULL DROP TABLE dbo.stress",
      );
      await conn.close();
      await MssqlRuntime.instance.shutdown();
    });

    test('row count is correct after bulk load', () async {
      final row = await conn.querySingle(
        'SELECT COUNT(*) AS n FROM dbo.stress',
      );
      expect(row['n'], kRowCount);
    });

    test(
      'large result set (all $kRowCount rows) materialises correctly',
      () async {
        final sw = Stopwatch()..start();
        final result = await conn.query(
          'SELECT id, grp, code, name, price, qty, flag, created '
          'FROM dbo.stress ORDER BY id',
        );
        sw.stop();
        final rows = result.resultSets.single.rows;
        print('SELECT $kRowCount rows in ${sw.elapsedMilliseconds}ms');
        expect(rows.length, kRowCount);
        expect(rows.first['code'], 'SKU-000000');
        expect(
          rows.last['code'],
          'SKU-${(kRowCount - 1).toString().padLeft(6, '0')}',
        );
        expect(rows.first['flag'], isA<bool>());
        expect(rows[1]['name'], 'Ürün #1 — kayıt');
      },
    );

    test(
      'streaming large result set in batches yields every row once',
      () async {
        var seen = 0;
        final ids = <int>{};
        await for (final batch in conn.streamBatches(
          'SELECT id FROM dbo.stress ORDER BY id',
          batchRows: 256,
        )) {
          for (final r in batch) {
            ids.add(r['id'] as int);
            seen++;
          }
        }
        expect(seen, kRowCount);
        expect(ids.length, kRowCount);
      },
    );

    test('parameterised aggregate over the large table', () async {
      final row = await conn.querySingle(
        'SELECT COUNT(*) AS n, SUM(qty) AS total_qty, AVG(price) AS avg_price '
        'FROM dbo.stress WHERE grp = @g',
        parameters: [MssqlParameter.int32('g', 3)],
      );
      expect(row['n'], kRowCount ~/ 25);
    });

    test('100 sequential queries on one connection stay correct', () async {
      for (var i = 0; i < 100; i++) {
        final g = i % 25;
        final row = await conn.querySingle(
          'SELECT COUNT(*) AS n FROM dbo.stress WHERE grp = @g',
          parameters: [MssqlParameter.int32('g', g)],
        );
        expect(row['n'], kRowCount ~/ 25);
      }
    });

    test(
      'concurrent queries on a single connection are serialised safely',
      () async {
        final futures = <Future<void>>[];
        for (var i = 0; i < 40; i++) {
          final g = i % 25;
          futures.add(
            conn
                .querySingle(
                  'SELECT COUNT(*) AS n FROM dbo.stress WHERE grp = @g',
                  parameters: [MssqlParameter.int32('g', g)],
                )
                .then((row) => expect(row['n'], kRowCount ~/ 25)),
          );
        }
        await Future.wait(futures);
      },
    );

    test('concurrent queries across a connection pool', () async {
      final pool = MssqlConnectionPool(
        _config(),
        poolConfig: const MssqlPoolConfig(
          maximumSize: 8,
          acquireTimeout: Duration(seconds: 30),
        ),
      );
      try {
        const tasks = 80;
        final sw = Stopwatch()..start();
        final results = await Future.wait(
          List.generate(tasks, (i) {
            final g = i % 25;
            return pool.withConnection(
              (c) => c.querySingle(
                'SELECT COUNT(*) AS n, MIN(id) AS lo, MAX(id) AS hi '
                'FROM dbo.stress WHERE grp = @g',
                parameters: [MssqlParameter.int32('g', g)],
              ),
            );
          }),
        );
        sw.stop();
        print(
          '$tasks concurrent pool queries in ${sw.elapsedMilliseconds}ms '
          'across ${pool.createdCount} connections',
        );
        expect(results.length, tasks);
        for (final row in results) {
          expect(row['n'], kRowCount ~/ 25);
        }
        expect(pool.createdCount, lessThanOrEqualTo(8));
        expect(pool.createdCount, greaterThan(1));
      } finally {
        await pool.close();
      }
    });

    test('concurrent independent transactions across the pool', () async {
      final pool = MssqlConnectionPool(
        _config(),
        poolConfig: const MssqlPoolConfig(maximumSize: 6),
      );
      try {
        final futures = List.generate(24, (i) {
          return pool.withConnection((c) async {
            return c.transaction((tx) async {
              final r = await tx.query(
                'SELECT COUNT(*) AS n FROM dbo.stress WHERE qty >= @q',
                parameters: [MssqlParameter.int32('q', i * 10)],
              );
              return r.resultSets.single.rows.single['n'] as int;
            });
          });
        });
        final counts = await Future.wait(futures);
        expect(counts.length, 24);
        for (var i = 1; i < counts.length; i++) {
          expect(counts[i], lessThanOrEqualTo(counts[i - 1]));
        }
      } finally {
        await pool.close();
      }
    });
  }, skip: skip);
}

