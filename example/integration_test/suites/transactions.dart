import 'package:flutter_test/flutter_test.dart';
import 'package:mssql_native/mssql_native.dart';

import '../support/android_context.dart';

/// Transactions and the lease that stops a query from interleaving with one.
void registerTransactionTests() {
  group('transactions', () {
    testWidgets('a commit persists', (_) async {
      final conn = await sharedConnection();
      final before = await conn.querySingle(
        'SELECT COUNT(*) AS n FROM dbo.inventory_log',
      );
      await conn.transaction((tx) async {
        await tx.query(
          'INSERT INTO dbo.inventory_log (product_id, delta, reason) '
          'VALUES (1000, @d, @r)',
          parameters: [
            MssqlParameter.int32('d', -3),
            MssqlParameter.nvarchar('r', 'android-commit', size: 40),
          ],
        );
      });
      final after = await conn.querySingle(
        'SELECT COUNT(*) AS n FROM dbo.inventory_log',
      );
      expect(after['n'], (before['n'] as int) + 1);
    });

    testWidgets('a rollback leaves no trace', (_) async {
      final conn = await sharedConnection();
      final before = await conn.querySingle(
        'SELECT COUNT(*) AS n FROM dbo.orders WHERE customer_id = 5',
      );
      final tx = await conn.beginTransaction();
      await tx.query(
        'INSERT INTO dbo.orders (customer_id, status, notes) VALUES (@c, 1, @n)',
        parameters: [
          MssqlParameter.int32('c', 5),
          MssqlParameter.nvarchar('n', 'rollback-me', size: 50),
        ],
      );
      await tx.rollback();
      await tx.close();
      final after = await conn.querySingle(
        'SELECT COUNT(*) AS n FROM dbo.orders WHERE customer_id = 5',
      );
      expect(after['n'], before['n']);
    });

    testWidgets('the connection refuses direct queries while leased', (
      _,
    ) async {
      // Interleaving a query with an open transaction on the same session is
      // almost always a bug, and a silent one.
      final conn = await MssqlConnection.open(androidConfig());
      addTearDown(conn.close);
      final tx = await conn.beginTransaction();
      await expectLater(conn.query('SELECT 1'), throwsStateError);
      await tx.rollback();
      await tx.close();
      expect(
        (await conn.querySingle('SELECT 1 AS ok'))['ok'],
        1,
        reason: 'the lease must be released again',
      );
    });

    testWidgets('closing a connection mid-transaction is refused', (_) async {
      final conn = await MssqlConnection.open(androidConfig());
      final tx = await conn.beginTransaction();
      await expectLater(conn.close(), throwsStateError);
      await tx.rollback();
      await tx.close();
      await conn.close();
    });

    testWidgets('a committed transaction cannot be used again', (_) async {
      final conn = await MssqlConnection.open(androidConfig());
      addTearDown(conn.close);
      final tx = await conn.beginTransaction();
      await tx.commit();
      // These throw synchronously, before returning a future, so they are
      // matched as callables rather than as futures.
      expect(() => tx.commit(), throwsStateError);
      expect(() => tx.query('SELECT 1'), throwsStateError);
      await tx.close();
    });

    testWidgets('rolling back after a commit is a no-op, not an error', (
      _,
    ) async {
      // close() calls rollback for safety, so this has to be harmless or every
      // committed transaction would throw on the way out.
      final conn = await MssqlConnection.open(androidConfig());
      addTearDown(conn.close);
      final tx = await conn.beginTransaction();
      await tx.commit();
      await expectLater(tx.rollback(), completes);
      await tx.close();
    });

    testWidgets('close releases the lease even after a failed statement', (
      _,
    ) async {
      // The deadlock case: the transaction is already dead server-side, and if
      // close() gave up the connection would be unusable forever.
      final conn = await MssqlConnection.open(androidConfig());
      addTearDown(conn.close);
      final tx = await conn.beginTransaction();
      try {
        await tx.query('SELECT * FROM dbo.no_such_table_at_all');
      } on MssqlException {
        // expected
      }
      await tx.close();
      expect(
        (await conn.querySingle('SELECT 1 AS ok'))['ok'],
        1,
        reason: 'the lease must have been released',
      );
    });

    testWidgets('every isolation level is accepted and still works', (_) async {
      // One connection for all four rather than the desktop suite's four: on
      // an emulator the logins cost more than the coverage they add, and the
      // level is set in the BEGIN batch, so a fresh session proves nothing
      // extra.
      final conn = await MssqlConnection.open(androidConfig());
      addTearDown(conn.close);
      for (final level in <MssqlIsolationLevel>[
        MssqlIsolationLevel.readUncommitted,
        MssqlIsolationLevel.readCommitted,
        MssqlIsolationLevel.repeatableRead,
        MssqlIsolationLevel.serializable,
      ]) {
        final tx = await conn.beginTransaction(isolationLevel: level);
        final result = await tx.query('SELECT 1 AS ok');
        expect(result.resultSets.single.rows.single['ok'], 1, reason: '$level');
        await tx.rollback();
        await tx.close();
      }
    });

    testWidgets('an error inside a transaction rolls the whole thing back', (
      _,
    ) async {
      final conn = await sharedConnection();
      await dropTable(conn, 'dbo.and_tx');
      await conn.execute(
        'CREATE TABLE dbo.and_tx (id INT PRIMARY KEY, tag NVARCHAR(20) NULL)',
      );
      addTearDown(() => dropTable(conn, 'dbo.and_tx'));
      try {
        await conn.transaction((tx) async {
          await tx.query("INSERT INTO dbo.and_tx (id, tag) VALUES (1, N'ok')");
          // Violates the primary key -> aborts the transaction.
          await tx.query("INSERT INTO dbo.and_tx (id, tag) VALUES (1, N'dup')");
        });
        fail('expected the transaction to throw');
      } on MssqlException {
        // expected
      }
      final after = await conn.querySingle(
        'SELECT COUNT(*) AS n FROM dbo.and_tx',
      );
      expect(after['n'], 0, reason: 'both inserts must be rolled back');
    });
  });
}
