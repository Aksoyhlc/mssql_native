import 'dart:convert';
import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

import 'support/observability.dart';

String? _environment(String name) => Platform.environment[name];

final String _toxiproxyUrl =
    _environment('MSSQL_NATIVE_TOXI_URL') ?? 'http://127.0.0.1:8474';

MssqlConnectionConfig _proxyConfig() => MssqlConnectionConfig(
  host:
      _environment('MSSQL_NATIVE_PROXY_HOST') ??
      _environment('MSSQL_NATIVE_HOST') ??
      '127.0.0.1',
  port: int.parse(_environment('MSSQL_NATIVE_PROXY_PORT') ?? '21433'),
  database: _environment('MSSQL_NATIVE_DB') ?? 'mssql_native_test',
  username: _environment('MSSQL_NATIVE_USER') ?? 'sa',
  password: _environment('MSSQL_NATIVE_PASSWORD') ?? 'Mssql@Native2026',
  encryption: MssqlEncryption.off,
  loginTimeout: const Duration(seconds: 15),
  defaultQueryTimeout: const Duration(seconds: 10),
);

final class _Toxiproxy {
  const _Toxiproxy(this.baseUrl, this.proxy);

  final String baseUrl;
  final String proxy;

  Future<int> _send(String method, String path, [Object? body]) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, Uri.parse('$baseUrl$path'));
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        request.headers.contentType = ContentType.json;
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
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

  Future<void> setEnabled(bool enabled) async {
    final status = await _send('POST', '/proxies/$proxy', <String, Object>{
      'enabled': enabled,
    });
    if (status >= 400) {
      throw StateError('Toxiproxy enabled=$enabled returned HTTP $status.');
    }
  }

  Future<void> reset() async {
    final status = await _send('POST', '/reset');
    if (status >= 400) {
      throw StateError('Toxiproxy reset returned HTTP $status.');
    }
    await setEnabled(true);
  }

  Future<void> dropEstablishedConnections() async {
    await setEnabled(false);
    await setEnabled(true);
  }
}

void main() {
  final live = _environment('MSSQL_NATIVE_LIVE') == '1';
  final liveSkip = live
      ? null
      : 'Set MSSQL_NATIVE_LIVE=1 with a reachable SQL Server to run.';
  final toxiproxy = _Toxiproxy(_toxiproxyUrl, 'mssql');
  var proxyAvailable = false;

  group('observability network chaos', () {
    setUpAll(() async {
      await MssqlRuntime.instance.initialize(
        bridgePath: _environment('MSSQL_NATIVE_BRIDGE'),
        sybdbPath: _environment('MSSQL_NATIVE_SYBDB'),
      );
      proxyAvailable = await toxiproxy.reachable();
      if (proxyAvailable) await toxiproxy.reset();
    });

    setUp(() async {
      if (proxyAvailable) await toxiproxy.reset();
    });

    tearDown(() async {
      if (proxyAvailable) await toxiproxy.reset();
    });

    tearDownAll(() => MssqlRuntime.instance.shutdown());

    test('retry is folded into one repaired logical query', () async {
      if (!proxyAvailable) {
        markTestSkipped('Toxiproxy is not reachable.');
        return;
      }
      final observer = RecordingMssqlObserver();
      final connection = await MssqlConnection.open(
        _proxyConfig(),
        observer: observer,
      );
      addTearDown(connection.close);
      observer.clearOperations();

      await toxiproxy.dropEstablishedConnections();
      final value = await connection.queryScalar<int>(
        'SELECT CAST(73 AS int)',
        options: const MssqlQueryOptions(
          queryName: 'chaos.retry',
          retry: MssqlRetryPolicy.idempotentRead,
        ),
      );

      expect(value, 73);
      expect(observer.queryStarts, hasLength(1));
      expect(observer.queryCompletes, hasLength(1));
      expect(observer.queryErrors, isEmpty);
      final terminal = observer.queryCompletes.single;
      expect(terminal.queryName, 'chaos.retry');
      expect(terminal.attemptCount, 2);
      expect(terminal.connectionRepaired, isTrue);
      expect(terminal.connectionRepairCount, 1);
      expect(connection.repairCount, 1);
    }, skip: liveSkip);

    test('non-retried failure reports repair for the next use', () async {
      if (!proxyAvailable) {
        markTestSkipped('Toxiproxy is not reachable.');
        return;
      }
      final observer = RecordingMssqlObserver();
      final connection = await MssqlConnection.open(
        _proxyConfig(),
        observer: observer,
      );
      addTearDown(connection.close);
      observer.clearOperations();

      await toxiproxy.dropEstablishedConnections();
      await expectLater(
        connection.queryScalar<int>(
          'SELECT CAST(81 AS int)',
          options: const MssqlQueryOptions(
            queryName: 'chaos.no_retry',
            retry: MssqlRetryPolicy.never,
          ),
        ),
        throwsA(isA<MssqlConnectionException>()),
      );

      expect(observer.queryStarts, hasLength(1));
      expect(observer.queryCompletes, isEmpty);
      expect(observer.queryErrors, hasLength(1));
      final terminal = observer.queryErrors.single;
      expect(terminal.queryName, 'chaos.no_retry');
      expect(terminal.attemptCount, 1);
      expect(terminal.connectionRepaired, isTrue);
      expect(terminal.connectionRepairCount, 1);
      expect(connection.repairCount, 1);
      expect(await connection.queryScalar<int>('SELECT CAST(82 AS int)'), 82);
    }, skip: liveSkip);

    test('lost commit reports one unknown transaction outcome', () async {
      if (!proxyAvailable) {
        markTestSkipped('Toxiproxy is not reachable.');
        return;
      }
      final observer = RecordingMssqlObserver();
      final connection = await MssqlConnection.open(
        _proxyConfig(),
        observer: observer,
      );
      addTearDown(connection.close);
      observer.clearOperations();
      final transaction = await connection.beginTransaction(
        transactionName: 'chaos.commit',
      );

      await toxiproxy.dropEstablishedConnections();
      await expectLater(
        transaction.commit(),
        throwsA(isA<MssqlUnknownCommitOutcomeException>()),
      );
      await transaction.close();

      expect(observer.transactionStarts, hasLength(1));
      expect(observer.transactionCompletes, isEmpty);
      expect(observer.transactionErrors, hasLength(1));
      final terminal = observer.transactionErrors.single;
      expect(terminal.transactionName, 'chaos.commit');
      expect(terminal.settlement, MssqlTransactionSettlement.unknown);
      expect(terminal.error.driverType, MssqlErrorType.unknownCommitOutcome);
      expect(
        terminal.error.transactionSettlement,
        MssqlTransactionSettlement.unknown,
      );
    }, skip: liveSkip);

    test('lost rollback reports one unknown transaction outcome', () async {
      if (!proxyAvailable) {
        markTestSkipped('Toxiproxy is not reachable.');
        return;
      }
      final observer = RecordingMssqlObserver();
      final connection = await MssqlConnection.open(
        _proxyConfig(),
        observer: observer,
      );
      addTearDown(connection.close);
      observer.clearOperations();
      final transaction = await connection.beginTransaction(
        transactionName: 'chaos.rollback',
      );

      await toxiproxy.dropEstablishedConnections();
      await expectLater(transaction.rollback(), throwsA(isA<MssqlException>()));
      await transaction.close();

      expect(observer.transactionCompletes, isEmpty);
      expect(observer.transactionErrors, hasLength(1));
      expect(
        observer.transactionErrors.single.settlement,
        MssqlTransactionSettlement.unknown,
      );
      expect(
        observer.transactionErrors.single.transactionName,
        'chaos.rollback',
      );
    }, skip: liveSkip);

    test(
      'failed callback with lost rollback keeps the application error',
      () async {
        if (!proxyAvailable) {
          markTestSkipped('Toxiproxy is not reachable.');
          return;
        }
        final observer = RecordingMssqlObserver();
        final connection = await MssqlConnection.open(
          _proxyConfig(),
          observer: observer,
        );
        addTearDown(connection.close);
        observer.clearOperations();
        final applicationError = StateError('application sentinel');

        await expectLater(
          connection.transaction<void>((transaction) async {
            await toxiproxy.dropEstablishedConnections();
            throw applicationError;
          }, transactionName: 'chaos.callback'),
          throwsA(same(applicationError)),
        );

        expect(observer.transactionCompletes, isEmpty);
        expect(observer.transactionErrors, hasLength(1));
        final terminal = observer.transactionErrors.single;
        expect(terminal.settlement, MssqlTransactionSettlement.unknown);
        expect(terminal.error.canonicalType, 'StateError');
        expect(
          terminal.error.toString(),
          isNot(contains('application sentinel')),
        );
      },
      skip: liveSkip,
    );
  });
}
