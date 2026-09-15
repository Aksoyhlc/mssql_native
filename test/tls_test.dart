import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

String? _e(String k) => Platform.environment[k];

void main() {
  final live = _e('MSSQL_NATIVE_LIVE') == '1';
  final skipReason = live
      ? null
      : 'Set MSSQL_NATIVE_LIVE=1 with a reachable SQL Server to run.';

  MssqlConnectionConfig config(MssqlEncryption encryption) =>
      MssqlConnectionConfig(
        host: _e('MSSQL_NATIVE_HOST') ?? '127.0.0.1',
        port: int.parse(_e('MSSQL_NATIVE_PORT') ?? '1433'),
        database: _e('MSSQL_NATIVE_DB') ?? 'mssql_native_test',
        username: _e('MSSQL_NATIVE_USER') ?? 'sa',
        password: _e('MSSQL_NATIVE_PASSWORD') ?? 'Mssql@Native2026',
        encryption: encryption,
      );

  Future<String> encryptOption(MssqlConnection conn) async {
    final row = await conn.querySingle(
      'SELECT CAST(encrypt_option AS NVARCHAR(10)) AS e '
      'FROM sys.dm_exec_connections WHERE session_id = @@SPID',
    );
    return (row['e'] as String).toUpperCase();
  }

  group('TLS', () {
    setUpAll(() async {
      await MssqlRuntime.instance.initialize(
        bridgePath: _e('MSSQL_NATIVE_BRIDGE'),
        sybdbPath: _e('MSSQL_NATIVE_SYBDB'),
      );
    });

    tearDownAll(() async {
      await MssqlRuntime.instance.shutdown();
    });

    Future<void> trustAnyCertificate() async {
      await MssqlRuntime.instance.shutdown();
      await MssqlRuntime.instance.initialize(
        bridgePath: _e('MSSQL_NATIVE_BRIDGE'),
        sybdbPath: _e('MSSQL_NATIVE_SYBDB'),
        tls: MssqlTlsTrust.insecureNoVerification(),
      );
    }

    test('this build reports whether it can encrypt at all', () async {
      expect(MssqlRuntime.instance.supportsTls, isA<bool>());
    });

    test('the default is an unencrypted session', () async {
      final conn = await MssqlConnection.open(config(MssqlEncryption.off));
      addTearDown(conn.close);
      expect(await encryptOption(conn), 'FALSE');
    });

    test(
      'request leaves the session unencrypted against an ordinary server',
      () async {
        if (!MssqlRuntime.instance.supportsTls) {
          markTestSkipped('this build of FreeTDS has no TLS backend');
          return;
        }
        final conn = await MssqlConnection.open(
          config(MssqlEncryption.request),
        );
        addTearDown(conn.close);
        expect(
          await encryptOption(conn),
          'FALSE',
          reason: 'the CI server does not force encryption',
        );
        expect((await conn.querySingle('SELECT 1 AS ok'))['ok'], 1);
      },
    );

    test('require encrypts, and the connection is fully usable', () async {
      if (!MssqlRuntime.instance.supportsTls) {
        markTestSkipped('this build of FreeTDS has no TLS backend');
        return;
      }
      await trustAnyCertificate();
      final conn = await MssqlConnection.open(config(MssqlEncryption.require));
      addTearDown(conn.close);
      expect(await encryptOption(conn), 'TRUE');

      final row = await conn.querySingle(
        'SELECT @t AS turkish, @d AS amount, COUNT(*) AS n FROM dbo.products',
        parameters: [
          MssqlParameter.nvarchar('t', 'İstanbul Şişli', size: 40),
          MssqlParameter.decimal('d', '12345.6789', precision: 18, scale: 4),
        ],
      );
      expect(row['turkish'], 'İstanbul Şişli');
      expect(row['amount'], MssqlDecimal.parse('12345.6789'));
      expect(row['n'], greaterThan(0));
    });

    test('an encrypted connection still bulk-copies', () async {
      if (!MssqlRuntime.instance.supportsTls) {
        markTestSkipped('this build of FreeTDS has no TLS backend');
        return;
      }
      await trustAnyCertificate();
      final conn = await MssqlConnection.open(config(MssqlEncryption.require));
      addTearDown(conn.close);
      await conn.execute('''
IF OBJECT_ID('dbo.tls_bulk','U') IS NOT NULL DROP TABLE dbo.tls_bulk;
CREATE TABLE dbo.tls_bulk (id INT NOT NULL, label NVARCHAR(40) NULL);
''');
      addTearDown(
        () => conn.execute(
          "IF OBJECT_ID('dbo.tls_bulk','U') IS NOT NULL DROP TABLE dbo.tls_bulk;",
        ),
      );

      final result = await conn.bulkInsert(
        tableName: 'dbo.tls_bulk',
        columns: const <MssqlBulkColumn>[
          MssqlBulkColumn(ordinal: 1, name: 'id', type: MssqlType.int32),
          MssqlBulkColumn(
            ordinal: 2,
            name: 'label',
            type: MssqlType.nvarchar,
            size: 40,
          ),
        ],
        rows: <List<MssqlParameter>>[
          for (var i = 0; i < 500; i++)
            <MssqlParameter>[
              MssqlParameter.int32('id', i),
              MssqlParameter.nvarchar('label', 'satır $i', size: 40),
            ],
        ],
      );
      expect(result.insertedRows, 500);
      final check = await conn.querySingle(
        'SELECT COUNT(*) AS n, MAX(label) AS last FROM dbo.tls_bulk',
      );
      expect(check['n'], 500);
      expect(await encryptOption(conn), 'TRUE');
    });

    test('a pool of encrypted connections still runs in parallel', () async {
      if (!MssqlRuntime.instance.supportsTls) {
        markTestSkipped('this build of FreeTDS has no TLS backend');
        return;
      }
      await trustAnyCertificate();
      final pool = MssqlConnectionPool(
        config(MssqlEncryption.require),
        poolConfig: const MssqlPoolConfig(maximumSize: 4),
      );
      addTearDown(pool.close);
      await pool.warmUp();

      final started = DateTime.now();
      final encrypted = await Future.wait(<Future<String>>[
        for (var i = 0; i < 4; i++)
          pool.withConnection((c) async {
            await c.execute("WAITFOR DELAY '00:00:01'; SELECT 1");
            return encryptOption(c);
          }),
      ]);
      final elapsed = DateTime.now().difference(started);

      expect(encrypted, everyElement('TRUE'));
      expect(
        elapsed.inMilliseconds,
        lessThan(2500),
        reason: 'TLS must not have serialised the pool',
      );
    });
  }, skip: skipReason);

  final caFile = _e('MSSQL_NATIVE_CA_FILE');
  final wrongCaFile = _e('MSSQL_NATIVE_WRONG_CA_FILE');
  final trustSkip = (!live || caFile == null || wrongCaFile == null)
      ? 'Set MSSQL_NATIVE_CA_FILE and MSSQL_NATIVE_WRONG_CA_FILE to a matching '
            'and a non-matching authority for the test server.'
      : null;

  group('certificate verification', () {
    Future<MssqlConnection> connectTrusting(MssqlTlsTrust trust) async {
      await MssqlRuntime.instance.shutdown();
      await MssqlRuntime.instance.initialize(
        bridgePath: _e('MSSQL_NATIVE_BRIDGE'),
        sybdbPath: _e('MSSQL_NATIVE_SYBDB'),
        tls: trust,
      );
      return MssqlConnection.open(config(MssqlEncryption.require));
    }

    tearDown(() async {
      await MssqlRuntime.instance.shutdown();
    });

    test(
      'the matching authority is accepted and the session is encrypted',
      () async {
        final conn = await connectTrusting(
          MssqlTlsTrust(certificateAuthorityFile: caFile!),
        );
        addTearDown(conn.close);
        expect(await encryptOption(conn), 'TRUE');
        expect((await conn.querySingle('SELECT 1 AS ok'))['ok'], 1);
      },
    );

    test('a non-matching authority is refused', () async {
      await expectLater(
        connectTrusting(MssqlTlsTrust(certificateAuthorityFile: wrongCaFile!)),
        throwsA(isA<MssqlException>()),
      );
    });

    test(
      'a certificate authority file that does not exist is refused early',
      () async {
        await MssqlRuntime.instance.shutdown();
        await expectLater(
          MssqlRuntime.instance.initialize(
            bridgePath: _e('MSSQL_NATIVE_BRIDGE'),
            sybdbPath: _e('MSSQL_NATIVE_SYBDB'),
            tls: const MssqlTlsTrust(
              certificateAuthorityFile: '/nonexistent/ca.pem',
            ),
          ),
          throwsA(
            isA<MssqlException>().having(
              (e) => e.type,
              'type',
              MssqlErrorType.configuration,
            ),
          ),
        );
      },
    );

    test('a hostname that does not match the certificate is refused', () async {
      await expectLater(
        connectTrusting(
          MssqlTlsTrust(
            certificateAuthorityFile: caFile!,
            expectedHostname: 'not-the-server.invalid',
          ),
        ),
        throwsA(isA<MssqlException>()),
      );
    });

    test(
      'hostname checking can be turned off for a name that will not match',
      () async {
        final conn = await connectTrusting(
          MssqlTlsTrust(
            certificateAuthorityFile: caFile!,
            validateHostname: false,
          ),
        );
        addTearDown(conn.close);
        expect(await encryptOption(conn), 'TRUE');
      },
    );

    test(
      'a trusted connection still bulk-copies and reads Turkish text',
      () async {
        final conn = await connectTrusting(
          MssqlTlsTrust(certificateAuthorityFile: caFile!),
        );
        addTearDown(conn.close);
        final row = await conn.querySingle(
          'SELECT label, label_n FROM dbo.charset_probe',
        );
        expect(row['label'], row['label_n']);
        expect(row['label'] as String, contains('ÇÖĞÜŞİ'));
      },
    );
  }, skip: trustSkip);
}

