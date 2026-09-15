import 'package:flutter_test/flutter_test.dart';
import 'package:mssql_native/mssql_native.dart';

import '../support/android_context.dart';

/// Errors and recovery. The interesting half on a device is that a failure
/// must leave the connection - and the process-global DB-Library state behind
/// it - usable, because an app does not get to restart itself.
void registerErrorTests() {
  group('errors and resilience', () {
    late MssqlConnection conn;

    setUpAll(() async {
      conn = await sharedConnection();
      await dropTable(conn, 'dbo.and_child');
      await dropTable(conn, 'dbo.and_parent');
      await dropTable(conn, 'dbo.and_lock');
      await conn.execute('CREATE TABLE dbo.and_parent (id INT PRIMARY KEY)');
      await conn.execute(
        'CREATE TABLE dbo.and_child ('
        ' id INT PRIMARY KEY,'
        ' parent_id INT NOT NULL REFERENCES dbo.and_parent(id),'
        ' code VARCHAR(20) NOT NULL UNIQUE)',
      );
      await conn.execute('INSERT INTO dbo.and_parent (id) VALUES (1)');
      await conn.execute(
        'CREATE TABLE dbo.and_lock (id INT PRIMARY KEY, val INT NOT NULL)',
      );
      await conn.execute(
        'INSERT INTO dbo.and_lock (id, val) VALUES (1, 10), (2, 20)',
      );
    });

    tearDownAll(() async {
      await dropTable(conn, 'dbo.and_child');
      await dropTable(conn, 'dbo.and_parent');
      await dropTable(conn, 'dbo.and_lock');
    });

    testWidgets('a unique constraint violation maps to a constraint error', (
      _,
    ) async {
      await conn.execute(
        'INSERT INTO dbo.and_child (id, parent_id, code) VALUES (1, 1, @c)',
        parameters: [MssqlParameter.varchar('c', 'DUP', size: 20)],
      );
      try {
        await conn.execute(
          'INSERT INTO dbo.and_child (id, parent_id, code) VALUES (2, 1, @c)',
          parameters: [MssqlParameter.varchar('c', 'DUP', size: 20)],
        );
        fail('expected a unique-constraint failure');
      } on MssqlException catch (e) {
        expect(e.type, MssqlErrorType.constraint);
        expect(e.code, anyOf(2601, 2627));
        expect(e.retryable, isFalse);
      }
    });

    testWidgets('a foreign-key violation maps to a constraint error', (
      _,
    ) async {
      try {
        await conn.execute(
          'INSERT INTO dbo.and_child (id, parent_id, code) VALUES (3, 999, @c)',
          parameters: [MssqlParameter.varchar('c', 'FK', size: 20)],
        );
        fail('expected a foreign-key failure');
      } on MssqlException catch (e) {
        expect(e.type, MssqlErrorType.constraint);
        expect(e.code, 547);
      }
    });

    testWidgets('a name error surfaces as a query error and the connection '
        'stays usable', (_) async {
      try {
        await conn.query('SELECT * FROM dbo.this_table_does_not_exist_xyz');
        fail('expected a name error');
      } on MssqlException catch (e) {
        expect(e.type, isNot(MssqlErrorType.internal));
        expect(e.message.toLowerCase(), contains('object name'));
      }
      expect((await conn.querySingle('SELECT 1 AS ok'))['ok'], 1);
    });

    testWidgets('the server number and text survive the FFI boundary', (
      _,
    ) async {
      // The error handlers that collect these are the one piece of C in the
      // driver, and they own DB-Library's process-global callbacks. If they
      // were not wired up in the APK, this is where the silence would show.
      try {
        await conn.query('SELECT * FROM dbo.still_not_a_table');
        fail('expected a name error');
      } on MssqlException catch (e) {
        expect(e.code, 208, reason: 'SQL Server: invalid object name');
        expect(e.message, isNotEmpty);
        expect(e.message, isNot('null'));
      }
    });

    testWidgets('a query timeout raises queryTimeout and leaves the connection '
        'usable', (_) async {
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
      expect((await conn.querySingle('SELECT 7 AS ok'))['ok'], 7);
    });

    testWidgets(
      'a deadlock produces a retryable error for exactly one victim',
      (_) async {
        final a = await MssqlConnection.open(androidConfig());
        final b = await MssqlConnection.open(androidConfig());
        MssqlTransaction? txA;
        MssqlTransaction? txB;
        try {
          txA = await a.beginTransaction();
          txB = await b.beginTransaction();
          // A locks row 1, B locks row 2.
          await txA.query('UPDATE dbo.and_lock SET val = val + 1 WHERE id = 1');
          await txB.query('UPDATE dbo.and_lock SET val = val + 1 WHERE id = 2');
          // Now cross: each waits on the other's row -> deadlock.
          final fA = txA.query(
            'UPDATE dbo.and_lock SET val = val + 1 WHERE id = 2',
          );
          final fB = txB.query(
            'UPDATE dbo.and_lock SET val = val + 1 WHERE id = 1',
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

    testWidgets(
      'an idempotent query auto-reconnects after the session is killed',
      (_) async {
        // The one that matters most on a phone: the network drops and comes back
        // constantly, and a driver that needed the app restarted would be
        // useless there.
        final victim = await MssqlConnection.open(androidConfig());
        final killer = await MssqlConnection.open(androidConfig());
        try {
          // CONTEXT_INFO is session-scoped and reliably empty on a fresh session,
          // so it proves a reconnect even if the SPID is reused.
          await victim.execute('SET CONTEXT_INFO 0x0102030405');
          expect(
            (await victim.querySingle('SELECT CONTEXT_INFO() AS ci'))['ci'],
            isNotNull,
          );
          final spid =
              (await victim.querySingle('SELECT @@SPID AS spid'))['spid']
                  as int;

          await killer.execute('KILL $spid');

          expect(
            (await victim.querySingle(
              'SELECT 123 AS v',
              options: const MssqlQueryOptions(
                retry: MssqlRetryPolicy.idempotentRead,
              ),
            ))['v'],
            123,
          );
          expect(
            (await victim.querySingle('SELECT CONTEXT_INFO() AS ci'))['ci'],
            isNull,
            reason: 'a genuinely new session was established',
          );
        } finally {
          await victim.close();
          await killer.close();
        }
      },
    );
  });
}
