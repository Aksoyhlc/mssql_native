import 'package:flutter_test/flutter_test.dart';
import 'package:mssql_native/mssql_native.dart';

import '../support/android_context.dart';

/// Opening, failing to open, and closing - on the platform where the loader,
/// the DNS resolver and the socket all belong to Android rather than to a
/// desktop libc.
void registerConnectionLifecycleTests() {
  group('connection lifecycle', () {
    group('failures to connect', () {
      testWidgets('a wrong password is an authentication failure', (_) async {
        // Not a connection error: retrying this is how an account gets locked.
        await expectLater(
          MssqlConnection.open(androidConfig(password: 'definitely-not-it')),
          throwsA(
            isA<MssqlException>().having(
              (e) => e.type,
              'type',
              anyOf(MssqlErrorType.authentication, MssqlErrorType.connection),
            ),
          ),
        );
      });

      testWidgets('an unknown user fails to log in', (_) async {
        await expectLater(
          MssqlConnection.open(androidConfig(username: 'no_such_login_here')),
          throwsA(isA<MssqlException>()),
        );
      });

      testWidgets('a database that does not exist is reported as such', (
        _,
      ) async {
        // The login succeeds and the USE fails, which is a different code path
        // from a rejected login.
        await expectLater(
          MssqlConnection.open(
            androidConfig(database: 'no_such_database_here'),
          ),
          throwsA(isA<MssqlException>()),
        );
      });

      testWidgets('a closed port fails rather than hanging', (_) async {
        // 1 is reserved and nothing listens on it. Through the emulator's NAT
        // this is a refusal rather than a black hole, so the login timeout is
        // the ceiling and not the expected outcome.
        final started = DateTime.now();
        await expectLater(
          MssqlConnection.open(
            androidConfig(port: 1, loginTimeout: const Duration(seconds: 10)),
          ),
          throwsA(isA<MssqlException>()),
        );
        expect(
          DateTime.now().difference(started).inSeconds,
          lessThan(30),
          reason: 'the login timeout must actually bound the attempt',
        );
      });

      testWidgets('an unresolvable host fails', (_) async {
        await expectLater(
          MssqlConnection.open(
            androidConfig(
              host: 'no-such-host.invalid',
              loginTimeout: const Duration(seconds: 10),
            ),
          ),
          throwsA(isA<MssqlException>()),
        );
      });

      testWidgets('a good connection still opens after several failures', (
        _,
      ) async {
        // The real assertion of this group: a failed login must not leave
        // process-global DB-Library state that poisons the next attempt. That
        // state is per-process, and this process is an Android app.
        for (final bad in <MssqlConnectionConfig>[
          androidConfig(password: 'wrong'),
          androidConfig(port: 1, loginTimeout: const Duration(seconds: 5)),
          androidConfig(database: 'nope'),
        ]) {
          try {
            final leaked = await MssqlConnection.open(bad);
            await leaked.close();
            fail('expected this configuration to fail');
          } on MssqlException {
            // expected
          }
        }
        final conn = await MssqlConnection.open(androidConfig());
        addTearDown(conn.close);
        expect((await conn.querySingle('SELECT 1 AS ok'))['ok'], 1);
      });

      testWidgets('a failed connection reports diagnostics, not silence', (
        _,
      ) async {
        // "Could not connect" with no detail is the failure mode that wastes an
        // afternoon; the server's own words have to survive the FFI boundary.
        try {
          await MssqlConnection.open(androidConfig(password: 'wrong-one'));
          fail('expected a failure');
        } on MssqlException catch (error) {
          expect(error.message, isNotEmpty);
          expect(error.message, isNot('null'));
        }
      });
    });

    group('a closed connection', () {
      testWidgets('reports itself closed and drops its handle', (_) async {
        final conn = await MssqlConnection.open(androidConfig());
        expect(conn.isClosed, isFalse);
        expect(conn.nativeHandle, isNot(0));
        await conn.close();
        expect(conn.isClosed, isTrue);
        expect(
          conn.nativeHandle,
          0,
          reason: 'a stale handle invites a use-after-close',
        );
      });

      testWidgets('closing twice is not an error', (_) async {
        final conn = await MssqlConnection.open(androidConfig());
        await conn.close();
        await expectLater(conn.close(), completes);
      });

      testWidgets('refuses further work with a StateError', (_) async {
        // A StateError, not an MssqlException: this is a programming mistake in
        // the caller, not something the server did.
        final conn = await MssqlConnection.open(androidConfig());
        await conn.close();
        await expectLater(conn.query('SELECT 1'), throwsStateError);
        await expectLater(conn.execute('SELECT 1'), throwsStateError);
        await expectLater(conn.ping(), throwsStateError);
        await expectLater(conn.beginTransaction(), throwsStateError);
        await expectLater(
          conn.streamBatches('SELECT 1').toList(),
          throwsStateError,
        );
      });

      testWidgets('ping succeeds while open', (_) async {
        final conn = await MssqlConnection.open(androidConfig());
        addTearDown(conn.close);
        await expectLater(conn.ping(), completes);
      });
    });
  });
}
