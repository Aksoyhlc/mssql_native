
import 'dart:async';
import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

String? _e(String k) => Platform.environment[k];

MssqlConnectionConfig _config() => MssqlConnectionConfig(
  host: _e('MSSQL_NATIVE_HOST') ?? '127.0.0.1',
  port: int.parse(_e('MSSQL_NATIVE_PORT') ?? '1433'),
  database: _e('MSSQL_NATIVE_DB') ?? 'mssql_native_test',
  username: _e('MSSQL_NATIVE_USER') ?? 'sa',
  password: _e('MSSQL_NATIVE_PASSWORD') ?? 'Mssql@Native2026',
  encryption: MssqlEncryption.off,
  defaultQueryTimeout: const Duration(seconds: 30),
);

void main() {
  final live = _e('MSSQL_NATIVE_LIVE') == '1';
  final skip = live
      ? null
      : 'Set MSSQL_NATIVE_LIVE=1 with a reachable SQL Server to run.';

  group('errors & resilience', () {
    late MssqlConnection conn;

    setUpAll(() async {
      await MssqlRuntime.instance.initialize(
        bridgePath: _e('MSSQL_NATIVE_BRIDGE'),
        sybdbPath: _e('MSSQL_NATIVE_SYBDB'),
      );
      conn = await MssqlConnection.open(_config());
      await conn.execute(
        "IF OBJECT_ID('dbo.err_child') IS NOT NULL DROP TABLE dbo.err_child",
      );
      await conn.execute(
        "IF OBJECT_ID('dbo.err_parent') IS NOT NULL DROP TABLE dbo.err_parent",
      );
      await conn.execute(
        "IF OBJECT_ID('dbo.lock_test') IS NOT NULL DROP TABLE dbo.lock_test",
      );
      await conn.execute('CREATE TABLE dbo.err_parent (id INT PRIMARY KEY)');
      await conn.execute(
        'CREATE TABLE dbo.err_child ('
        ' id INT PRIMARY KEY,'
        ' parent_id INT NOT NULL REFERENCES dbo.err_parent(id),'
        ' code VARCHAR(20) NOT NULL UNIQUE)',
      );
      await conn.execute('INSERT INTO dbo.err_parent (id) VALUES (1)');
      await conn.execute(
        'CREATE TABLE dbo.lock_test (id INT PRIMARY KEY, val INT NOT NULL)',
      );
      await conn.execute(
        'INSERT INTO dbo.lock_test (id, val) VALUES (1, 10), (2, 20)',
      );
    });

    tearDownAll(() async {
      await conn.execute(
        "IF OBJECT_ID('dbo.err_child') IS NOT NULL DROP TABLE dbo.err_child",
      );
      await conn.execute(
        "IF OBJECT_ID('dbo.err_parent') IS NOT NULL DROP TABLE dbo.err_parent",
      );
      await conn.execute(
        "IF OBJECT_ID('dbo.lock_test') IS NOT NULL DROP TABLE dbo.lock_test",
      );
      await conn.close();
      await MssqlRuntime.instance.shutdown();
    });

    test('unique constraint violation maps to constraint error', () async {
      await conn.execute(
        'INSERT INTO dbo.err_child (id, parent_id, code) VALUES (1, 1, @c)',
        parameters: [MssqlParameter.varchar('c', 'DUP', size: 20)],
      );
      try {
        await conn.execute(
          'INSERT INTO dbo.err_child (id, parent_id, code) VALUES (2, 1, @c)',
          parameters: [MssqlParameter.varchar('c', 'DUP', size: 20)],
        );
        fail('expected a unique-constraint failure');
      } on MssqlException catch (e) {
        expect(e.type, MssqlErrorType.constraint);
        expect(e.code, anyOf(2601, 2627));
        expect(e.retryable, isFalse);
      }
    });

    test('foreign-key violation maps to constraint error', () async {
      try {
        await conn.execute(
          'INSERT INTO dbo.err_child (id, parent_id, code) VALUES (3, 999, @c)',
          parameters: [MssqlParameter.varchar('c', 'FK', size: 20)],
        );
        fail('expected a foreign-key failure');
      } on MssqlException catch (e) {
        expect(e.type, MssqlErrorType.constraint);
        expect(e.code, 547);
      }
    });

    test(
      'syntax error surfaces as a query error, connection stays usable',
      () async {
        try {
          await conn.query('SELECT * FROM dbo.this_table_does_not_exist_xyz');
          fail('expected a syntax/name error');
        } on MssqlException catch (e) {
          expect(e.type, isNot(MssqlErrorType.internal));
          expect(e.message.toLowerCase(), contains('object name'));
        }
        final row = await conn.querySingle('SELECT 1 AS ok');
        expect(row['ok'], 1);
      },
    );

    test(
      'query timeout raises queryTimeout and leaves the connection usable',
      () async {
        try {
          await conn.query(
            "WAITFOR DELAY '00:00:05'",
            timeout: const Duration(seconds: 1),
            retry: MssqlRetryPolicy.never,
          );
          fail('expected a timeout');
        } on MssqlException catch (e) {
          expect(e.type, MssqlErrorType.queryTimeout);
        }
        final row = await conn.querySingle('SELECT 7 AS ok');
        expect(row['ok'], 7);
      },
    );

    test('error inside a transaction rolls the whole thing back', () async {
      final before = await conn.querySingle(
        'SELECT COUNT(*) AS n FROM dbo.err_child',
      );
      try {
        await conn.transaction((tx) async {
          await tx.query(
            'INSERT INTO dbo.err_child (id, parent_id, code) VALUES (10, 1, @c)',
            parameters: [MssqlParameter.varchar('c', 'TX-OK', size: 20)],
          );
          await tx.query(
            'INSERT INTO dbo.err_child (id, parent_id, code) VALUES (11, 999, @c)',
            parameters: [MssqlParameter.varchar('c', 'TX-BAD', size: 20)],
          );
        });
        fail('expected the transaction to throw');
      } on MssqlException {
      }
      final after = await conn.querySingle(
        'SELECT COUNT(*) AS n FROM dbo.err_child',
      );
      expect(
        after['n'],
        before['n'],
        reason: 'both inserts must be rolled back',
      );
    });

    test(
      'deadlock produces a retryable deadlock error for exactly one victim',
      () async {
        final a = await MssqlConnection.open(_config());
        final b = await MssqlConnection.open(_config());
        MssqlTransaction? txA;
        MssqlTransaction? txB;
        try {
          txA = await a.beginTransaction();
          txB = await b.beginTransaction();
          await txA.query(
            'UPDATE dbo.lock_test SET val = val + 1 WHERE id = 1',
          );
          await txB.query(
            'UPDATE dbo.lock_test SET val = val + 1 WHERE id = 2',
          );
          final fA = txA.query(
            'UPDATE dbo.lock_test SET val = val + 1 WHERE id = 2',
          );
          final fB = txB.query(
            'UPDATE dbo.lock_test SET val = val + 1 WHERE id = 1',
          );
          final outcomes = await Future.wait(<Future<Object?>>[
            fA.then<Object?>((_) => null).catchError((Object e) => e),
            fB.then<Object?>((_) => null).catchError((Object e) => e),
          ]);
          final deadlocks = outcomes.whereType<MssqlException>().toList();
          expect(
            deadlocks.length,
            1,
            reason: 'exactly one transaction is the deadlock victim',
          );
          expect(deadlocks.single.type, MssqlErrorType.deadlock);
          expect(deadlocks.single.retryable, isTrue);
        } finally {
          if (txA != null) await txA.close();
          if (txB != null) await txB.close();
          await a.close();
          await b.close();
        }
      },
    );

    test('an opt-in idempotent read reconnects and repeats itself', () async {
      final victim = await MssqlConnection.open(_config());
      final killer = await MssqlConnection.open(_config());
      try {
        final spid =
            (await victim.querySingle('SELECT @@SPID AS spid'))['spid'] as int;
        await killer.execute('KILL $spid');
        final row = await victim.querySingle(
          'SELECT 123 AS v',
          options: const MssqlQueryOptions(
            retry: MssqlRetryPolicy.idempotentRead,
          ),
        );
        expect(row['v'], 123);
      } finally {
        await victim.close();
        await killer.close();
      }
    });

    test('a killed session surfaces, and leaves a usable connection', () async {
      final victim = await MssqlConnection.open(_config());
      final killer = await MssqlConnection.open(_config());
      try {
        await victim.execute('SET CONTEXT_INFO 0x0102030405');
        final marked = await victim.querySingle('SELECT CONTEXT_INFO() AS ci');
        expect(marked['ci'], isNotNull);
        final spid =
            (await victim.querySingle('SELECT @@SPID AS spid'))['spid'] as int;

        await killer.execute('KILL $spid');

        await expectLater(
          victim.querySingle('SELECT 123 AS v'),
          throwsA(isA<MssqlException>()),
        );

        final row = await victim.querySingle('SELECT 123 AS v');
        expect(row['v'], 123);

        final after = await victim.querySingle('SELECT CONTEXT_INFO() AS ci');
        expect(
          after['ci'],
          isNull,
          reason: 'a genuinely new session was established',
        );
      } finally {
        await victim.close();
        await killer.close();
      }
    });
  }, skip: skip);
}

