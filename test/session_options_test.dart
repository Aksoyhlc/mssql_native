import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

String? _env(String name) => Platform.environment[name];

MssqlConnectionConfig _config() => MssqlConnectionConfig(
  host: _env('MSSQL_NATIVE_HOST') ?? '127.0.0.1',
  port: int.parse(_env('MSSQL_NATIVE_PORT') ?? '1433'),
  database: _env('MSSQL_NATIVE_DB') ?? 'mssql_native_test',
  username: _env('MSSQL_NATIVE_USER') ?? 'sa',
  password: _env('MSSQL_NATIVE_PASSWORD') ?? 'Mssql@Native2026',
  encryption: MssqlEncryption.off,
);

/// The six options SQL Server requires of a session that writes to a table
/// carrying a filtered index, an indexed view or an indexed computed column.
/// Anything missing is error 1934 at DML time, and error 1934 at CREATE INDEX
/// time as well, which is why the fixture applies them by hand.
const _requiredOptions =
    'SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON; '
    'SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; '
    'SET CONCAT_NULL_YIELDS_NULL ON; SET ARITHABORT ON;';

void main() {
  final live = _env('MSSQL_NATIVE_LIVE') == '1';
  final skipReason = live
      ? null
      : 'Set MSSQL_NATIVE_LIVE=1 with a reachable SQL Server to run.';

  group('session options', () {
    // The fixture connection sets the options itself, so the schema can be
    // built whatever the driver's login does. The subject connection is left
    // exactly as the driver opens it: that is what these tests are about.
    late MssqlConnection fixture;
    late MssqlConnection subject;
    late String table;

    setUpAll(() async {
      await MssqlRuntime.instance.initialize(
        bridgePath: _env('MSSQL_NATIVE_BRIDGE'),
        sybdbPath: _env('MSSQL_NATIVE_SYBDB'),
      );
      fixture = await MssqlConnection.open(_config());
      subject = await MssqlConnection.open(_config());
      table =
          'dbo.mssql_native_sessopts_'
          '${DateTime.now().microsecondsSinceEpoch}_$pid';
      await fixture.execute(_requiredOptions);
      await fixture.execute('''
CREATE TABLE $table (
  id         INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
  old_erp_id INT NULL
);
''');
      await fixture.execute('''
CREATE UNIQUE INDEX ux_${table.split('.').last}_old_erp_id
  ON $table (old_erp_id) WHERE old_erp_id IS NOT NULL;
''');
    });

    tearDownAll(() async {
      await fixture.execute('DROP TABLE IF EXISTS $table;');
      await fixture.close();
      await subject.close();
    });

    test('login leaves the options a filtered index needs turned on', () async {
      final rows = await subject.queryRows('''
SELECT CAST(SESSIONPROPERTY('QUOTED_IDENTIFIER') AS INT)     AS quoted_identifier,
       CAST(SESSIONPROPERTY('ANSI_NULLS') AS INT)            AS ansi_nulls,
       CAST(SESSIONPROPERTY('ANSI_PADDING') AS INT)          AS ansi_padding,
       CAST(SESSIONPROPERTY('ANSI_WARNINGS') AS INT)         AS ansi_warnings,
       CAST(SESSIONPROPERTY('CONCAT_NULL_YIELDS_NULL') AS INT) AS concat_null,
       CAST(SESSIONPROPERTY('ARITHABORT') AS INT)            AS arith_abort,
       CAST(SESSIONPROPERTY('NUMERIC_ROUNDABORT') AS INT)    AS numeric_roundabort;
''');
      expect(rows.single, <String, Object?>{
        'quoted_identifier': 1,
        'ansi_nulls': 1,
        'ansi_padding': 1,
        'ansi_warnings': 1,
        'concat_null': 1,
        'arith_abort': 1,
        'numeric_roundabort': 0,
      });
    });

    test('a freshly opened connection can write to a filtered index', () async {
      // Two NULLs, because the filter is what makes them legal under a unique
      // index: this is the shape that made the driver fail in the first place.
      await subject.execute('INSERT INTO $table (old_erp_id) VALUES (NULL);');
      await subject.execute('INSERT INTO $table (old_erp_id) VALUES (NULL);');
      await subject.execute('INSERT INTO $table (old_erp_id) VALUES (7);');
      expect(await subject.queryScalar<int>('SELECT COUNT(*) FROM $table'), 3);
    });

    test('a pooled connection can write to a filtered index', () async {
      final pool = MssqlConnectionPool(_config());
      addTearDown(pool.close);
      await pool.session.execute(
        'INSERT INTO $table (old_erp_id) VALUES (NULL);',
      );
    });

    test('initSql runs on every connection the driver opens', () async {
      final connection = await MssqlConnection.open(
        _config().copyWith(
          sessionOptions: MssqlSessionOptions.ansi.copyWith(
            initSql: <String>['SET DATEFIRST 3'],
          ),
        ),
      );
      addTearDown(connection.close);
      expect(await connection.queryScalar<int>('SELECT @@DATEFIRST'), 3);
    });

    test('initSql that leaves a transaction open fails the login', () async {
      await expectLater(
        MssqlConnection.open(
          _config().copyWith(
            sessionOptions: MssqlSessionOptions.ansi.copyWith(
              initSql: <String>['BEGIN TRANSACTION'],
            ),
          ),
        ),
        throwsA(
          isA<MssqlException>().having(
            (e) => e.message,
            'message',
            allOf(contains('initSql'), contains('transaction')),
          ),
        ),
      );
    });

    test('initSql that turns NOCOUNT on fails the login', () async {
      await expectLater(
        MssqlConnection.open(
          _config().copyWith(
            sessionOptions: MssqlSessionOptions.ansi.copyWith(
              initSql: <String>['SET NOCOUNT ON'],
            ),
          ),
        ),
        throwsA(
          isA<MssqlException>().having(
            (e) => e.message,
            'message',
            allOf(contains('initSql'), contains('NOCOUNT')),
          ),
        ),
      );
    });

    test('legacy keeps the pre-0.2.0 behaviour available', () async {
      final connection = await MssqlConnection.open(
        _config().copyWith(sessionOptions: MssqlSessionOptions.legacy),
      );
      addTearDown(connection.close);
      expect(
        await connection.queryScalar<int>(
          "SELECT CAST(SESSIONPROPERTY('QUOTED_IDENTIFIER') AS INT)",
        ),
        0,
      );
    });
  }, skip: skipReason);

  group('rendering', () {
    test('the defaults are what every other SQL Server client sets', () {
      expect(
        MssqlSessionOptions.ansi.renderSetBatch(),
        'SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON; SET ANSI_PADDING ON; '
        'SET ANSI_WARNINGS ON; SET CONCAT_NULL_YIELDS_NULL ON; '
        'SET ARITHABORT ON; SET NUMERIC_ROUNDABORT OFF; SET XACT_ABORT ON; '
        'SET TEXTSIZE 2147483647; '
        'SET TRANSACTION ISOLATION LEVEL READ COMMITTED;',
      );
    });

    test('legacy differs from ansi in exactly the three DB-Library gaps', () {
      expect(MssqlSessionOptions.legacy.quotedIdentifier, isFalse);
      expect(MssqlSessionOptions.legacy.ansiPadding, isFalse);
      expect(MssqlSessionOptions.legacy.concatNullYieldsNull, isFalse);
      expect(
        MssqlSessionOptions.legacy
            .copyWith(
              quotedIdentifier: true,
              ansiPadding: true,
              concatNullYieldsNull: true,
            )
            .renderSetBatch(),
        MssqlSessionOptions.ansi.renderSetBatch(),
      );
    });

    test('the optional settings are only sent when they are asked for', () {
      expect(
        MssqlSessionOptions.ansi.renderSetBatch(),
        isNot(anyOf(contains('LOCK_TIMEOUT'), contains('DEADLOCK_PRIORITY'))),
      );
      final batch = const MssqlSessionOptions(
        lockTimeout: Duration(seconds: 3),
        deadlockPriority: MssqlDeadlockPriority.low,
      ).renderSetBatch();
      expect(batch, contains('SET LOCK_TIMEOUT 3000'));
      expect(batch, contains('SET DEADLOCK_PRIORITY LOW'));
    });

    test('initSql is its own batch, guarded, and absent when empty', () {
      expect(MssqlSessionOptions.ansi.renderInitBatch(), isNull);
      final batch = const MssqlSessionOptions(
        initSql: <String>['SET DATEFIRST 1'],
      ).renderInitBatch()!;
      expect(batch, startsWith('SET DATEFIRST 1;'));
      expect(batch, contains('@@TRANCOUNT'));
      expect(batch, contains('@@OPTIONS & 512'));
      expect(
        MssqlSessionOptions.ansi.renderSetBatch(),
        isNot(contains('DATEFIRST')),
      );
    });

    test('a setting the server would reject is refused here first', () {
      expect(
        () => const MssqlSessionOptions(textSize: -1).validate(),
        throwsRangeError,
      );
      expect(
        () => const MssqlSessionOptions(
          lockTimeout: Duration(seconds: -1),
        ).validate(),
        throwsArgumentError,
      );
      expect(
        () => const MssqlSessionOptions(initSql: <String>['  ']).validate(),
        throwsArgumentError,
      );
      expect(MssqlSessionOptions.ansi.validate, returnsNormally);
    });
  });
}
