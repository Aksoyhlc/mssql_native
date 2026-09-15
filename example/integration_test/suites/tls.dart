import 'package:flutter_test/flutter_test.dart';
import 'package:mssql_native/mssql_native.dart';

import '../support/android_context.dart';

/// Encryption, checked against what the server says rather than what was asked
/// for. `sys.dm_exec_connections.encrypt_option` is the only honest answer: a
/// FreeTDS built without a TLS backend connects happily and never encrypts.
///
/// Certificate verification is a separate claim and is not covered here - it
/// needs a server certificate whose authority the device holds, which the
/// emulator job does not provision yet.
void registerTlsTests() {
  group('TLS on the device', () {
    testWidgets('the default is an unencrypted session', (_) async {
      // FreeTDS's own default, and what this driver has always done. Stated as
      // a test so that changing it is a deliberate act.
      final conn = await MssqlConnection.open(androidConfig());
      addTearDown(conn.close);
      expect(await encryptOption(conn), 'FALSE');
    });

    testWidgets('request leaves the session unencrypted against an ordinary '
        'server', (_) async {
      // Not a bug: FreeTDS maps `request` to TDS7_ENCRYPT_OFF, which tells the
      // server "I support encryption and am not asking for it". A server
      // without Force Encryption takes that at its word. Someone choosing
      // `request` because it sounds like "encrypt if possible" would otherwise
      // never find out.
      final conn = await MssqlConnection.open(
        androidConfig(encryption: MssqlEncryption.request),
      );
      addTearDown(conn.close);
      expect(
        await encryptOption(conn),
        'FALSE',
        reason: 'the test server does not force encryption',
      );
      expect(
        (await conn.querySingle('SELECT 1 AS ok'))['ok'],
        1,
        reason: 'it must still be a working connection',
      );
    });

    testWidgets('require encrypts, as the server sees it', (_) async {
      final conn = await MssqlConnection.open(
        androidConfig(encryption: MssqlEncryption.require),
      );
      addTearDown(conn.close);
      expect(await encryptOption(conn), 'TRUE');
    });

    testWidgets('an encrypted connection is fully usable', (_) async {
      // Encryption must not disturb anything else: parameters, Turkish text
      // through iconv, decimals and a result set all still work over the
      // statically linked OpenSSL this build carries.
      final conn = await MssqlConnection.open(
        androidConfig(encryption: MssqlEncryption.require),
      );
      addTearDown(conn.close);
      final row = await conn.querySingle(
        'SELECT @t AS turkish, @d AS amount, COUNT(*) AS n FROM dbo.products',
        parameters: [
          MssqlParameter.nvarchar('t', 'İstanbul Şişli', size: 40),
          MssqlParameter.decimal('d', '12345.6789', precision: 18, scale: 4),
        ],
      );
      expect(row['turkish'], 'İstanbul Şişli');
      expect(row['amount'], closeTo(12345.6789, 1e-9));
      expect(row['n'], greaterThan(0));
    });

    testWidgets(
      'an encrypted connection reads the single-byte Turkish column',
      (_) async {
        // Two bundled libraries at once - OpenSSL under the socket and libiconv
        // over the column - which is the combination unique to this platform.
        final conn = await MssqlConnection.open(
          androidConfig(encryption: MssqlEncryption.require),
        );
        addTearDown(conn.close);
        final row = await conn.querySingle(
          'SELECT label, label_n FROM dbo.charset_probe',
        );
        expect(row['label'], row['label_n']);
        expect(row['label'] as String, isNot(contains('Ý')));
      },
    );

    testWidgets('an encrypted connection still bulk-copies', (_) async {
      // BCP runs over the same socket, so it is encrypted too - and it is the
      // path most likely to break under a changed transport.
      final conn = await MssqlConnection.open(
        androidConfig(encryption: MssqlEncryption.require),
      );
      addTearDown(conn.close);
      await dropTable(conn, 'dbo.and_tls_bulk');
      await conn.execute(
        'CREATE TABLE dbo.and_tls_bulk (id INT NOT NULL, label NVARCHAR(40) NULL)',
      );
      addTearDown(() => dropTable(conn, 'dbo.and_tls_bulk'));

      final result = await conn.bulkInsert(
        tableName: 'dbo.and_tls_bulk',
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
              MssqlParameter.nvarchar('label', 'satır $i ÇĞİ', size: 40),
            ],
        ],
      );
      expect(result.insertedRows, 500);
      final check = await conn.querySingle(
        'SELECT COUNT(*) AS n FROM dbo.and_tls_bulk',
      );
      expect(check['n'], 500);
      expect(await encryptOption(conn), 'TRUE');
    });

    testWidgets('a pool of encrypted connections still runs in parallel', (
      _,
    ) async {
      final pool = MssqlConnectionPool(
        androidConfig(encryption: MssqlEncryption.require),
        poolConfig: const MssqlPoolConfig(maximumSize: 4),
      );
      addTearDown(pool.close);
      await pool.warmUp();

      final encrypted = await Future.wait(<Future<String>>[
        for (var i = 0; i < 4; i++)
          pool.withConnection((c) async {
            await c.execute('SELECT COUNT(*) FROM dbo.products');
            return encryptOption(c);
          }),
      ]);

      // Four separate TLS sessions, all encrypted and all usable. Whether they
      // overlapped in time is the pool suite's question and is measured there
      // on the server's clock; the device's is not a stopwatch.
      expect(encrypted, hasLength(4));
      expect(encrypted, everyElement('TRUE'));
      expect(
        pool.createdCount,
        greaterThan(1),
        reason: 'more than one encrypted session was actually opened',
      );
    });
  });
}
