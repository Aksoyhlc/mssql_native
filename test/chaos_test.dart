
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

String? _e(String k) => Platform.environment[k];

final String _toxiUrl = _e('MSSQL_NATIVE_TOXI_URL') ?? 'http://127.0.0.1:8474';

int get _proxyPort => int.parse(_e('MSSQL_NATIVE_PROXY_PORT') ?? '21433');
int get _directPort => int.parse(_e('MSSQL_NATIVE_PORT') ?? '1433');

MssqlConnectionConfig _proxyCfg({Duration? timeout}) => MssqlConnectionConfig(
  host: _e('MSSQL_NATIVE_PROXY_HOST') ?? _e('MSSQL_NATIVE_HOST') ?? '127.0.0.1',
  port: _proxyPort,
  database: _e('MSSQL_NATIVE_DB') ?? 'mssql_native_test',
  username: _e('MSSQL_NATIVE_USER') ?? 'sa',
  password: _e('MSSQL_NATIVE_PASSWORD') ?? 'Mssql@Native2026',
  encryption: MssqlEncryption.off,
  loginTimeout: const Duration(seconds: 15),
  defaultQueryTimeout: timeout ?? const Duration(seconds: 30),
);

MssqlConnectionConfig _directCfg() => MssqlConnectionConfig(
  host: _e('MSSQL_NATIVE_HOST') ?? '127.0.0.1',
  port: _directPort,
  database: _e('MSSQL_NATIVE_DB') ?? 'mssql_native_test',
  username: _e('MSSQL_NATIVE_USER') ?? 'sa',
  password: _e('MSSQL_NATIVE_PASSWORD') ?? 'Mssql@Native2026',
  encryption: MssqlEncryption.off,
);

class Toxiproxy {
  const Toxiproxy(this.baseUrl, this.proxy);
  final String baseUrl;
  final String proxy;

  Future<int> _send(String method, String path, [Object? body]) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(method, Uri.parse('$baseUrl$path'));
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        req.headers.contentType = ContentType.json;
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final resp = await req.close();
      await resp.drain<void>();
      return resp.statusCode;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> reachable() async {
    try {
      return await _send('GET', '/proxies/$proxy') < 400;
    } catch (_) {
      return false;
    }
  }

  Future<void> addToxic(
    String name,
    String type,
    String stream,
    Map<String, Object> attributes, {
    double toxicity = 1.0,
  }) async {
    await removeToxic(name);
    final code = await _send('POST', '/proxies/$proxy/toxics', {
      'name': name,
      'type': type,
      'stream': stream,
      'toxicity': toxicity,
      'attributes': attributes,
    });
    if (code >= 400) throw StateError('toxiproxy add $name -> $code');
  }

  Future<void> removeToxic(String name) async {
    try {
      await _send('DELETE', '/proxies/$proxy/toxics/$name');
    } catch (_) {
      /* not present */
    }
  }

  Future<void> setEnabled(bool enabled) async {
    await _send('POST', '/proxies/$proxy', {'enabled': enabled});
  }

  Future<void> reset() async {
    await _send('POST', '/reset');
    await setEnabled(true);
  }
}

const int kRows = 2000;

void main() {
  final live = _e('MSSQL_NATIVE_LIVE') == '1';
  final skip = live
      ? null
      : 'Set MSSQL_NATIVE_LIVE=1 with a reachable SQL Server to run.';
  final tox = Toxiproxy(_toxiUrl, 'mssql');
  var proxyUp = false;

  group('network chaos', () {
    setUpAll(() async {
      await MssqlRuntime.instance.initialize(
        bridgePath: _e('MSSQL_NATIVE_BRIDGE'),
        sybdbPath: _e('MSSQL_NATIVE_SYBDB'),
      );
      proxyUp = await tox.reachable();
      if (!proxyUp) return;
      await tox.reset();
      final seed = await MssqlConnection.open(_directCfg());
      try {
        await seed.execute(
          "IF OBJECT_ID('dbo.chaos') IS NOT NULL DROP TABLE dbo.chaos",
        );
        await seed.execute(
          'CREATE TABLE dbo.chaos ('
          ' id INT IDENTITY(1,1) PRIMARY KEY, grp INT NOT NULL, payload NVARCHAR(80) NOT NULL)',
        );
        await seed.bulkInsert(
          tableName: 'dbo.chaos',
          columns: const [
            MssqlBulkColumn(ordinal: 2, name: 'grp', type: MssqlType.int32),
            MssqlBulkColumn(
              ordinal: 3,
              name: 'payload',
              type: MssqlType.nvarchar,
              size: 80,
            ),
          ],
          rows: List.generate(
            kRows,
            (i) => [
              MssqlParameter.int32('grp', i % 20),
              MssqlParameter.nvarchar('payload', 'satır-$i-İstekğüş', size: 80),
            ],
          ),
        );
      } finally {
        await seed.close();
      }
    });

    tearDownAll(() async {
      if (proxyUp) {
        await tox.reset();
        try {
          final seed = await MssqlConnection.open(_directCfg());
          await seed.execute(
            "IF OBJECT_ID('dbo.chaos') IS NOT NULL DROP TABLE dbo.chaos",
          );
          await seed.close();
        } catch (_) {}
      }
      await MssqlRuntime.instance.shutdown();
    });

    setUp(() async {
      if (proxyUp) await tox.reset();
    });

    test('baseline query works through the proxy', () async {
      if (!proxyUp) {
        markTestSkipped('Toxiproxy not reachable');
        return;
      }
      final c = await MssqlConnection.open(_proxyCfg());
      try {
        final row = await c.querySingle('SELECT COUNT(*) AS n FROM dbo.chaos');
        expect(row['n'], kRows);
      } finally {
        await c.close();
      }
    });

    test('session-level ops time out on a silent black hole (no hang)', () async {
      if (!proxyUp) {
        markTestSkipped('Toxiproxy not reachable');
        return;
      }
      final c = await MssqlConnection.open(
        _proxyCfg(timeout: const Duration(seconds: 3)),
      );
      try {
        await tox.addToxic('bh', 'timeout', 'downstream', {'timeout': 0});
        final sw = Stopwatch()..start();
        await expectLater(c.ping(), throwsA(isA<MssqlException>()));
        sw.stop();
        expect(
          sw.elapsed,
          lessThan(const Duration(seconds: 20)),
          reason: 'ping must fail on its deadline, not block forever',
        );
      } finally {
        await tox.removeToxic('bh');
        await c.close();
      }
    });

    test('high latency is tolerated (queries just get slower)', () async {
      if (!proxyUp) {
        markTestSkipped('Toxiproxy not reachable');
        return;
      }
      final c = await MssqlConnection.open(_proxyCfg());
      try {
        await tox.addToxic('lat', 'latency', 'downstream', {
          'latency': 250,
          'jitter': 50,
        });
        final sw = Stopwatch()..start();
        final row = await c.querySingle(
          'SELECT COUNT(*) AS n FROM dbo.chaos WHERE grp = @g',
          parameters: [MssqlParameter.int32('g', 3)],
        );
        sw.stop();
        expect(row['n'], kRows ~/ 20);
        expect(
          sw.elapsedMilliseconds,
          greaterThan(200),
          reason: 'latency actually applied',
        );
      } finally {
        await c.close();
      }
    });

    test(
      'severe latency times out, then recovers when the link clears',
      () async {
        if (!proxyUp) {
          markTestSkipped('Toxiproxy not reachable');
          return;
        }
        final c = await MssqlConnection.open(_proxyCfg());
        try {
          await tox.addToxic('lat', 'latency', 'downstream', {
            'latency': 4000,
            'jitter': 0,
          });
          await expectLater(
            c.query(
              'SELECT COUNT(*) FROM dbo.chaos',
              timeout: const Duration(milliseconds: 800),
              retry: MssqlRetryPolicy.never,
            ),
            throwsA(
              isA<MssqlException>().having(
                (e) => e.type,
                'type',
                MssqlErrorType.queryTimeout,
              ),
            ),
          );
          await tox.removeToxic('lat');
          final row = await c.querySingle(
            'SELECT COUNT(*) AS n FROM dbo.chaos',
          );
          expect(row['n'], kRows);
        } finally {
          await c.close();
        }
      },
    );

    test('bandwidth-throttled large result still streams correctly', () async {
      if (!proxyUp) {
        markTestSkipped('Toxiproxy not reachable');
        return;
      }
      final c = await MssqlConnection.open(
        _proxyCfg(timeout: const Duration(seconds: 60)),
      );
      try {
        await tox.addToxic('bw', 'bandwidth', 'downstream', {
          'rate': 64,
        });
        var seen = 0;
        await for (final batch in c.streamBatches(
          'SELECT id, payload FROM dbo.chaos ORDER BY id',
          batchRows: 200,
        )) {
          seen += batch.length;
        }
        expect(seen, kRows);
      } finally {
        await c.close();
      }
    });

    test('fragmented packets (slicer) do not corrupt decoded rows', () async {
      if (!proxyUp) {
        markTestSkipped('Toxiproxy not reachable');
        return;
      }
      final c = await MssqlConnection.open(
        _proxyCfg(timeout: const Duration(seconds: 60)),
      );
      try {
        await tox.addToxic('slice', 'slicer', 'downstream', {
          'average_size': 48,
          'size_variation': 16,
          'delay': 200,
        });
        final ids = <int>{};
        await for (final batch in c.streamBatches(
          'SELECT id FROM dbo.chaos ORDER BY id',
          batchRows: 128,
        )) {
          for (final r in batch) {
            ids.add(r['id'] as int);
          }
        }
        expect(
          ids.length,
          kRows,
          reason: 'every row decoded exactly once despite fragmentation',
        );
      } finally {
        await c.close();
      }
    });

    test(
      'kop-bağlan-kop-bağlan: repeated hard drops keep reconnecting',
      () async {
        if (!proxyUp) {
          markTestSkipped('Toxiproxy not reachable');
          return;
        }
        final c = await MssqlConnection.open(_proxyCfg());
        try {
          for (var i = 1; i <= 8; i++) {
            await tox.setEnabled(false);
            await tox.setEnabled(true);
            final row = await c.querySingle(
              'SELECT $i AS v, COUNT(*) AS n FROM dbo.chaos',
              options: const MssqlQueryOptions(
                retry: MssqlRetryPolicy.idempotentRead,
              ),
            );
            expect(row['v'], i);
            expect(row['n'], kRows);
          }
        } finally {
          await c.close();
        }
      },
    );

    test('pool recovers after mass connection resets', () async {
      if (!proxyUp) {
        markTestSkipped('Toxiproxy not reachable');
        return;
      }
      final pool = MssqlConnectionPool(
        _proxyCfg(),
        poolConfig: const MssqlPoolConfig(
          maximumSize: 6,
          acquireTimeout: Duration(seconds: 20),
        ),
      );
      try {
        await Future.wait(
          List.generate(
            12,
            (_) => pool.withConnection(
              (c) => c.querySingle('SELECT COUNT(*) AS n FROM dbo.chaos'),
            ),
          ),
        );

        await tox.addToxic('rst', 'reset_peer', 'downstream', {'timeout': 0});
        final during = await Future.wait(
          List.generate(
            12,
            (i) => pool
                .withConnection((c) => c.querySingle('SELECT 1 AS v'))
                .then((_) => true)
                .catchError((Object _) => false),
          ),
        );
        await tox.removeToxic('rst');
        final after = await Future.wait(
          List.generate(
            24,
            (_) => pool
                .withConnection(
                  (c) => c.querySingle('SELECT COUNT(*) AS n FROM dbo.chaos'),
                )
                .then((r) => r['n']),
          ),
        );
        expect(
          after.every((n) => n == kRows),
          isTrue,
          reason: 'pool fully recovered',
        );
        expect(during.length, 12);
      } finally {
        await pool.close();
      }
    });

    test('sustained chaos: random faults never corrupt results', () async {
      if (!proxyUp) {
        markTestSkipped('Toxiproxy not reachable');
        return;
      }
      final pool = MssqlConnectionPool(
        _proxyCfg(timeout: const Duration(seconds: 20)),
        poolConfig: const MssqlPoolConfig(
          maximumSize: 5,
          acquireTimeout: Duration(seconds: 20),
        ),
      );
      final rng = Random(42);
      var ok = 0;
      try {
        for (var round = 0; round < 12; round++) {
          switch (round % 4) {
            case 0:
              await tox.addToxic('c', 'latency', 'downstream', {
                'latency': 150 + rng.nextInt(300),
                'jitter': 50,
              });
              break;
            case 1:
              await tox.addToxic('c', 'slicer', 'downstream', {
                'average_size': 64,
                'size_variation': 32,
                'delay': 100,
              });
              break;
            case 2:
              await tox.addToxic('c', 'bandwidth', 'downstream', {'rate': 128});
              break;
            case 3:
              await tox.setEnabled(false);
              await tox.setEnabled(true);
              break;
          }
          for (var q = 0; q < 4; q++) {
            final g = rng.nextInt(20);
            Map<String, Object?>? row;
            for (var attempt = 0; attempt < 4 && row == null; attempt++) {
              try {
                row = await pool.withConnection(
                  (c) => c.querySingle(
                    'SELECT COUNT(*) AS n FROM dbo.chaos WHERE grp = @g',
                    parameters: [MssqlParameter.int32('g', g)],
                  ),
                );
              } on MssqlException catch (e) {
                if (!e.retryable &&
                    e.type != MssqlErrorType.connectionLost &&
                    e.type != MssqlErrorType.connection) {
                  rethrow;
                }
                await Future<void>.delayed(const Duration(milliseconds: 100));
              }
            }
            if (row != null) {
              expect(
                row['n'],
                kRows ~/ 20,
                reason: 'result never corrupted under chaos',
              );
              ok++;
            }
          }
          await tox.reset();
        }
      } finally {
        await tox.reset();
        await pool.close();
      }
      expect(
        ok,
        greaterThan(0),
        reason: 'at least some queries completed across the chaos run',
      );
    });
  }, skip: skip);
}

