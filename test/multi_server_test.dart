
import 'dart:async';
import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

String? _e(String k) => Platform.environment[k];

MssqlConnectionConfig _cfg((String, int) server, String db) =>
    MssqlConnectionConfig(
      host: server.$1,
      port: server.$2,
      database: db,
      username: _e('MSSQL_NATIVE_USER') ?? 'sa',
      password: _e('MSSQL_NATIVE_PASSWORD') ?? 'Mssql@Native2026',
      encryption: MssqlEncryption.off,
    );

int get _port1 => int.parse(_e('MSSQL_NATIVE_PORT') ?? '1433');
int get _port2 => int.parse(_e('MSSQL_NATIVE_PORT2') ?? '1434');
String get _host1 => _e('MSSQL_NATIVE_HOST') ?? '127.0.0.1';
String get _host2 => _e('MSSQL_NATIVE_HOST2') ?? _host1;
(String, int) get _server1 => (_host1, _port1);
(String, int) get _server2 => (_host2, _port2);

Future<void> _initDb((String, int) server, String db, List<String> ddl) async {
  final master = await MssqlConnection.open(_cfg(server, 'master'));
  try {
    await master.execute(
      "IF DB_ID('$db') IS NOT NULL ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE",
    );
    await master.execute("IF DB_ID('$db') IS NOT NULL DROP DATABASE [$db]");
    await master.execute('CREATE DATABASE [$db]');
  } finally {
    await master.close();
  }
  final conn = await MssqlConnection.open(_cfg(server, db));
  try {
    for (final stmt in ddl) {
      await conn.execute(stmt);
    }
  } finally {
    await conn.close();
  }
}

void main() {
  final live = _e('MSSQL_NATIVE_LIVE') == '1';
  final skip = live
      ? null
      : 'Set MSSQL_NATIVE_LIVE=1 with a reachable SQL Server to run.';
  var secondUp = false;

  group('multi-server (multisql)', () {
    setUpAll(() async {
      await MssqlRuntime.instance.initialize(
        bridgePath: _e('MSSQL_NATIVE_BRIDGE'),
        sybdbPath: _e('MSSQL_NATIVE_SYBDB'),
      );
      try {
        final probe = await MssqlConnection.open(
          _cfg(_server2, 'master'),
        ).timeout(const Duration(seconds: 8));
        await probe.close();
        secondUp = true;
      } catch (_) {
        return;
      }
      await _initDb(_server1, 'hq_db', [
        'CREATE TABLE dbo.catalog (sku VARCHAR(20) PRIMARY KEY, name NVARCHAR(60) NOT NULL)',
        "INSERT INTO dbo.catalog VALUES ('ITM-01', N'Kırmızı Defter'), ('ITM-02', N'Şeffaf Dosya'), ('ITM-03', N'Modern Kalem')",
      ]);
      await _initDb(_server1, 'pricing_db', [
        'CREATE TABLE dbo.price (sku VARCHAR(20) PRIMARY KEY, amount DECIMAL(18,2) NOT NULL)',
        "INSERT INTO dbo.price VALUES ('ITM-01', 4200.00), ('ITM-02', 1975.50), ('ITM-03', 2780.00)",
      ]);
      await _initDb(_server2, 'branch_db', [
        'CREATE TABLE dbo.sales (id INT IDENTITY PRIMARY KEY, sku VARCHAR(20) NOT NULL, qty INT NOT NULL)',
        "INSERT INTO dbo.sales (sku, qty) VALUES ('ITM-01', 3), ('ITM-02', 5), ('ITM-01', 2)",
      ]);
    });

    tearDownAll(() async {
      if (secondUp) {
        for (final entry in [
          (_server1, 'hq_db'),
          (_server1, 'pricing_db'),
          (_server2, 'branch_db'),
        ]) {
          try {
            final m = await MssqlConnection.open(_cfg(entry.$1, 'master'));
            await m.execute(
              "IF DB_ID('${entry.$2}') IS NOT NULL ALTER DATABASE [${entry.$2}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE",
            );
            await m.execute(
              "IF DB_ID('${entry.$2}') IS NOT NULL DROP DATABASE [${entry.$2}]",
            );
            await m.close();
          } catch (_) {}
        }
      }
      await MssqlRuntime.instance.shutdown();
    });

    test('two servers are independent instances with their own data', () async {
      if (!secondUp) {
        markTestSkipped('Second SQL Server not reachable');
        return;
      }
      final hq = await MssqlConnection.open(_cfg(_server1, 'hq_db'));
      final branch = await MssqlConnection.open(_cfg(_server2, 'branch_db'));
      try {
        final catalog = await hq.querySingle(
          'SELECT COUNT(*) AS n FROM dbo.catalog',
        );
        final sales = await branch.querySingle(
          'SELECT COUNT(*) AS n FROM dbo.sales',
        );
        expect(catalog['n'], 3);
        expect(sales['n'], 3);
        await expectLater(
          branch.querySingle('SELECT COUNT(*) FROM dbo.catalog'),
          throwsA(isA<MssqlException>()),
        );
      } finally {
        await hq.close();
        await branch.close();
      }
    });

    test('concurrent queries fan out across both servers', () async {
      if (!secondUp) {
        markTestSkipped('Second SQL Server not reachable');
        return;
      }
      final hq = await MssqlConnection.open(_cfg(_server1, 'hq_db'));
      final branch = await MssqlConnection.open(_cfg(_server2, 'branch_db'));
      try {
        final results = await Future.wait([
          for (var i = 0; i < 20; i++)
            (i.isEven ? hq : branch).querySingle(
              'SELECT @@SPID AS spid, DB_NAME() AS db',
            ),
        ]);
        expect(results.length, 20);
        expect(results.where((r) => r['db'] == 'hq_db').length, 10);
        expect(results.where((r) => r['db'] == 'branch_db').length, 10);
      } finally {
        await hq.close();
        await branch.close();
      }
    });

    test('independent pools per server under concurrent load', () async {
      if (!secondUp) {
        markTestSkipped('Second SQL Server not reachable');
        return;
      }
      final poolHq = MssqlConnectionPool(
        _cfg(_server1, 'hq_db'),
        poolConfig: const MssqlPoolConfig(maximumSize: 4),
      );
      final poolBranch = MssqlConnectionPool(
        _cfg(_server2, 'branch_db'),
        poolConfig: const MssqlPoolConfig(maximumSize: 4),
      );
      try {
        final futures = <Future<Map<String, Object?>>>[];
        for (var i = 0; i < 30; i++) {
          futures.add(
            poolHq.withConnection(
              (c) => c.querySingle('SELECT COUNT(*) AS n FROM dbo.catalog'),
            ),
          );
          futures.add(
            poolBranch.withConnection(
              (c) => c.querySingle('SELECT SUM(qty) AS q FROM dbo.sales'),
            ),
          );
        }
        final rows = await Future.wait(futures);
        expect(rows.length, 60);
        expect(poolHq.createdCount, greaterThan(1));
        expect(poolBranch.createdCount, greaterThan(1));
      } finally {
        await poolHq.close();
        await poolBranch.close();
      }
    });

    test('cross-database join on a single server', () async {
      if (!secondUp) {
        markTestSkipped('Second SQL Server not reachable');
        return;
      }
      final hq = await MssqlConnection.open(_cfg(_server1, 'hq_db'));
      try {
        final result = await hq.query(
          'SELECT c.sku, c.name, p.amount '
          'FROM hq_db.dbo.catalog c '
          'JOIN pricing_db.dbo.price p ON p.sku = c.sku '
          'ORDER BY c.sku',
        );
        final rows = result.resultSets.single.rows;
        expect(rows.length, 3);
        expect(rows.first['sku'], 'ITM-01');
        expect(rows.first['name'], 'Kırmızı Defter');
        expect(rows.first['amount'], MssqlDecimal.parse('4200.00'));
      } finally {
        await hq.close();
      }
    });

    test(
      'a failure on one server leaves the other connection healthy',
      () async {
        if (!secondUp) {
          markTestSkipped('Second SQL Server not reachable');
          return;
        }
        final hq = await MssqlConnection.open(_cfg(_server1, 'hq_db'));
        final branch = await MssqlConnection.open(_cfg(_server2, 'branch_db'));
        try {
          await expectLater(
            branch.query('SELECT * FROM dbo.nonexistent_branch_table'),
            throwsA(isA<MssqlException>()),
          );
          expect((await hq.querySingle('SELECT 1 AS v'))['v'], 1);
          expect((await branch.querySingle('SELECT 2 AS v'))['v'], 2);
        } finally {
          await hq.close();
          await branch.close();
        }
      },
    );
  }, skip: skip);
}

