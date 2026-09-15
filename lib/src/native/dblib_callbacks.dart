// Classifying what FreeTDS reported.
//
// The handlers themselves are C, in native/src/handlers.c, and they only
// record. This file reads the C recorder's thread-local state and decides what
// the failure was. Dart callbacks were previously used here, but DB-Library's
// process-global handlers could invoke one from a different connection isolate
// and abort the VM with "Cannot invoke native callback from a different isolate".
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../models/result.dart';
import '../models/types.dart';
import 'handlers.dart';

/// What the handlers collected during the DB-Library call in progress.
class NativeErrorState {
  int code = 0;
  MssqlErrorType type = MssqlErrorType.internal;
  String message = '';
  bool retryable = false;

  /// Set when a server message with severity >= 11 has already classified the
  /// failure. The error handler then leaves the classification alone.
  ///
  /// This is what makes error messages useful. A bad query produces two
  /// callbacks: the message handler first, with the real text
  /// ("Invalid column name 'x'.", msgno 207), then the error handler with
  /// FreeTDS's generic dberr 20018, "General SQL Server error: Check messages
  /// from the SQL Server". Without this flag the generic one would win.
  bool serverClassified = false;

  final List<MssqlServerMessage> messages = <MssqlServerMessage>[];

  void reset() {
    code = 0;
    type = MssqlErrorType.internal;
    message = '';
    retryable = false;
    serverClassified = false;
    messages.clear();
  }

  bool get hasError => code != 0 || message.isNotEmpty;
}

/// This isolate's classified state. One connection per worker isolate, so one
/// state suffices; keying by `DBPROCESS` would add nothing.
final NativeErrorState errorState = NativeErrorState();

/// Reads a NUL-terminated C string without ever throwing.
///
/// `toDartString` rejects malformed UTF-8, which would turn a database error
/// into a `FormatException` and lose the failure the caller has to see. Server
/// text is only ever displayed, so a replacement character beats an exception.
String _str(Pointer<Utf8> p) {
  if (p == nullptr) return '';
  final bytes = p.cast<Uint8>();
  var length = 0;
  while (bytes[length] != 0) {
    length++;
  }
  if (length == 0) return '';
  return utf8.decode(bytes.asTypedList(length), allowMalformed: true);
}

/// Ported from `build_error_message` in core.cpp.
String buildErrorMessage(
  int dberr,
  int oserr,
  String dbErrStr,
  String osErrStr,
) {
  final out = StringBuffer();
  if (dbErrStr.isNotEmpty) {
    out.write(dbErrStr);
  } else {
    out.write('FreeTDS DB-Library error $dberr');
  }
  if (oserr != 0 || osErrStr.isNotEmpty) {
    out.write(' (OS $oserr');
    if (osErrStr.isNotEmpty) out.write(': $osErrStr');
    out.write(')');
  }
  return out.toString();
}

/// Ported from `classify_error` in core.cpp. The numbers are FreeTDS's own
/// error codes, not SQL Server's.
MssqlErrorType classifyDbError(int dberr, int severity, String text) {
  switch (dberr) {
    case 20004: // SYBEREAD  - read from server failed, e.g. session killed
    case 20006: // SYBEWRIT  - write to server failed
    case 20047: // SYBEDDNE  - DBPROCESS is dead or not enabled
      return MssqlErrorType.connectionLost;
    case 20002: // SYBEFCON  - server connection failed
    case 20009: // SYBECONN  - unable to connect socket
    case 20017: // SYBEUHST  - unknown host
      return MssqlErrorType.connection;
    case 20014: // SYBEPWD   - incorrect password
      return MssqlErrorType.authentication;
    case 20003: // SYBETIME  - server did not respond in time
    case 20011: // SYBEBUFL  - operation timed out / buffer
      return MssqlErrorType.queryTimeout;
  }
  if (text.contains('timeout')) return MssqlErrorType.queryTimeout;
  if (severity >= 20) return MssqlErrorType.connectionLost;
  return MssqlErrorType.internal;
}

bool _isRetryable(MssqlErrorType type) =>
    type == MssqlErrorType.connection ||
    type == MssqlErrorType.connectionLost ||
    type == MssqlErrorType.queryTimeout;

/// Ported from `dblib_message_handler`. Classifies on SQL Server's own message
/// numbers, which are more specific than anything FreeTDS reports.
MssqlErrorType classifyServerMessage(int msgno, int severity) {
  if (msgno == 1205) return MssqlErrorType.deadlock;
  if (msgno == 18456) return MssqlErrorType.authentication;
  if (msgno == 547 || msgno == 2601 || msgno == 2627) {
    return MssqlErrorType.constraint;
  }
  if (severity >= 20) return MssqlErrorType.connectionLost;
  return MssqlErrorType.querySyntax;
}

/// Pulls the C recorder's state for this thread into [errorState].
///
/// Called after a DB-Library call fails, rather than continuously, because the
/// recorder is written to during the call and read once afterwards on the same
/// thread.
///
/// The precedence here is what makes error messages useful, and it is the
/// reason this is not a straight copy. A bad query produces two callbacks: the
/// message handler first, with the real text ("Invalid column name 'x'.",
/// msgno 207), then the error handler with FreeTDS's generic dberr 20018,
/// "General SQL Server error: Check messages from the SQL Server". The server
/// message wins.
void syncErrorState(Handlers handlers) {
  errorState.reset();

  final count = handlers.messageCount();
  for (var i = 0; i < count; i++) {
    final text = _str(handlers.messageText(i));
    final server = _str(handlers.messageServer(i));
    final procedure = _str(handlers.messageProcedure(i));
    final number = handlers.messageNumber(i);
    final severity = handlers.messageSeverity(i);
    errorState.messages.add(
      MssqlServerMessage(
        number: number,
        severity: severity,
        state: handlers.messageState(i),
        line: handlers.messageLine(i),
        message: text,
        server: server.isEmpty ? null : server,
        procedure: procedure.isEmpty ? null : procedure,
      ),
    );

    // Below 11 it is informational - PRINT output, row counts - and not a
    // failure.
    if (severity >= 11) {
      errorState.code = number;
      errorState.serverClassified = true;
      errorState.type = classifyServerMessage(number, severity);
      errorState.retryable =
          errorState.type == MssqlErrorType.deadlock ||
          errorState.type == MssqlErrorType.connectionLost;
      errorState.message = text.isEmpty
          ? 'SQL Server reported an error.'
          : text;
    }
  }

  if (handlers.hasError() == 0) return;
  final dberr = handlers.errorCode();
  if (errorState.serverClassified) {
    // Keep the server's classification and text; only fill a code it did not
    // provide (a message numbered 0).
    if (errorState.code == 0) errorState.code = dberr;
    return;
  }
  errorState.code = dberr;
  errorState.message = buildErrorMessage(
    dberr,
    handlers.errorOs(),
    _str(handlers.errorText()),
    _str(handlers.errorOsText()),
  );
  errorState.type = classifyDbError(
    dberr,
    handlers.errorSeverity(),
    errorState.message,
  );
  errorState.retryable = _isRetryable(errorState.type);
}
