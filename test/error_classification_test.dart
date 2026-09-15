import 'package:mssql_native/src/models/types.dart';
import 'package:mssql_native/src/native/dblib_callbacks.dart';
import 'package:test/test.dart';

void main() {
  group('FreeTDS error codes', () {
    test('read, write and dead-process failures are a lost connection', () {
      for (final code in <int>[20004, 20006, 20047]) {
        expect(
          classifyDbError(code, 9, 'whatever'),
          MssqlErrorType.connectionLost,
          reason: 'dberr $code',
        );
      }
    });

    test('connect, socket and host failures are a connection error', () {
      for (final code in <int>[20002, 20009, 20017]) {
        expect(
          classifyDbError(code, 9, 'whatever'),
          MssqlErrorType.connection,
          reason: 'dberr $code',
        );
      }
    });

    test('a bad password is an authentication error, not a connection one', () {
      expect(
        classifyDbError(20014, 9, 'Incorrect password'),
        MssqlErrorType.authentication,
      );
    });

    test('no-response and buffer-length failures are timeouts', () {
      for (final code in <int>[20003, 20011]) {
        expect(
          classifyDbError(code, 9, 'whatever'),
          MssqlErrorType.queryTimeout,
          reason: 'dberr $code',
        );
      }
    });

    test('an unrecognised code says timeout when the text does', () {
      expect(
        classifyDbError(29999, 5, 'the operation timeout expired'),
        MssqlErrorType.queryTimeout,
      );
    });

    test('severity 20 and above is a lost connection', () {
      expect(
        classifyDbError(29999, 20, 'something bad'),
        MssqlErrorType.connectionLost,
      );
      expect(
        classifyDbError(29999, 24, 'something worse'),
        MssqlErrorType.connectionLost,
      );
    });

    test('anything else is internal rather than guessed at', () {
      expect(
        classifyDbError(29999, 5, 'a novel complaint'),
        MssqlErrorType.internal,
      );
    });
  });

  group('SQL Server message numbers', () {
    test('1205 is a deadlock', () {
      expect(classifyServerMessage(1205, 13), MssqlErrorType.deadlock);
    });

    test('18456 is a login failure', () {
      expect(classifyServerMessage(18456, 14), MssqlErrorType.authentication);
    });

    test('constraint violations are their own category', () {
      for (final msgno in <int>[547, 2601, 2627]) {
        expect(
          classifyServerMessage(msgno, 16),
          MssqlErrorType.constraint,
          reason: 'msgno $msgno',
        );
      }
    });

    test('severity 20 and above outranks the message number', () {
      expect(classifyServerMessage(8134, 20), MssqlErrorType.connectionLost);
    });

    test('an ordinary server error is a query error', () {
      expect(classifyServerMessage(207, 16), MssqlErrorType.querySyntax);
      expect(classifyServerMessage(8134, 16), MssqlErrorType.querySyntax);
    });

    test('the two code spaces do not bleed into each other', () {
      expect(classifyDbError(20004, 9, ''), MssqlErrorType.connectionLost);
      expect(classifyServerMessage(20004, 16), MssqlErrorType.querySyntax);
    });
  });

  group('message assembly', () {
    test('FreeTDS text is used when there is any', () {
      expect(
        buildErrorMessage(20003, 0, 'Adaptive Server connection timed out', ''),
        'Adaptive Server connection timed out',
      );
    });

    test('an empty description falls back to naming the code', () {
      expect(
        buildErrorMessage(20017, 0, '', ''),
        'FreeTDS DB-Library error 20017',
      );
    });

    test('an OS error is appended with its number and text', () {
      expect(
        buildErrorMessage(
          20006,
          32,
          'Write to the server failed',
          'Broken pipe',
        ),
        'Write to the server failed (OS 32: Broken pipe)',
      );
    });

    test('an OS number with no text still appears', () {
      expect(
        buildErrorMessage(20006, 104, 'Write to the server failed', ''),
        'Write to the server failed (OS 104)',
      );
    });

    test('OS 0 with no text adds nothing', () {
      expect(
        buildErrorMessage(20018, 0, 'General SQL Server error', ''),
        'General SQL Server error',
      );
    });

    test('an OS text with number 0 is still reported', () {
      expect(
        buildErrorMessage(
          20018,
          0,
          'General SQL Server error',
          'Unknown error',
        ),
        'General SQL Server error (OS 0: Unknown error)',
      );
    });
  });

  group('the error state a worker hands back', () {
    test('starts empty', () {
      final state = NativeErrorState();
      expect(state.hasError, isFalse);
      expect(state.code, 0);
      expect(state.messages, isEmpty);
      expect(state.retryable, isFalse);
      expect(state.serverClassified, isFalse);
    });

    test('a message alone counts as an error', () {
      final state = NativeErrorState()..message = 'Invalid column name.';
      expect(state.hasError, isTrue);
    });

    test('a code alone counts as an error', () {
      final state = NativeErrorState()..code = 20004;
      expect(state.hasError, isTrue);
    });

    test('reset clears everything, including the classification flag', () {
      final state = NativeErrorState()
        ..code = 1205
        ..type = MssqlErrorType.deadlock
        ..message = 'Transaction was deadlocked'
        ..retryable = true
        ..serverClassified = true;
      state.reset();
      expect(state.hasError, isFalse);
      expect(state.type, MssqlErrorType.internal);
      expect(state.retryable, isFalse);
      expect(state.serverClassified, isFalse);
      expect(state.messages, isEmpty);
    });
  });
}

