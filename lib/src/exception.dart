import 'models/result.dart';
import 'models/types.dart';

/// Base class for driver failures.
///
/// Catch this type for all database errors, or use a subclass for failures that
/// need distinct handling. [type] carries the classification across the worker
/// isolate.
///
/// Nothing here carries SQL text or parameter values: a failure message is
/// likely to be logged, and a WHERE clause or parameter list can contain
/// secrets. [queryName] carries the caller's label instead.
class MssqlException implements Exception {
  const MssqlException({
    required this.type,
    required this.message,
    this.code = 0,
    this.state = 0,
    this.retryable = false,
    this.operationId,
    this.queryName,
    this.diagnostics = const <MssqlServerMessage>[],
  });

  /// Builds the exception subclass that matches [type].
  ///
  /// One place decides, so a failure classified in the worker reaches the
  /// caller as the type its category deserves regardless of the layers it
  /// passed through.
  ///
  /// [MssqlErrorType.unknownCommitOutcome] is not remapped: it has a single
  /// source that constructs [MssqlUnknownCommitOutcomeException] directly with
  /// its own explanation.
  factory MssqlException.classify({
    required MssqlErrorType type,
    required String message,
    int code = 0,
    int state = 0,
    bool retryable = false,
    int? operationId,
    String? queryName,
    List<MssqlServerMessage> diagnostics = const <MssqlServerMessage>[],
  }) => switch (type) {
    MssqlErrorType.connection ||
    MssqlErrorType.connectionLost => MssqlConnectionException(
      type: type,
      message: message,
      code: code,
      state: state,
      retryable: retryable,
      operationId: operationId,
      queryName: queryName,
      diagnostics: diagnostics,
    ),
    MssqlErrorType.tls => MssqlTlsException(message),
    MssqlErrorType.authentication => MssqlAuthenticationException(
      message: message,
      code: code,
      state: state,
      operationId: operationId,
      queryName: queryName,
      diagnostics: diagnostics,
    ),
    MssqlErrorType.queryTimeout => MssqlQueryTimeoutException(
      message: message,
      code: code,
      state: state,
      operationId: operationId,
      queryName: queryName,
      diagnostics: diagnostics,
    ),
    MssqlErrorType.cancelled => MssqlCancelledException(
      message: message,
      operationId: operationId,
      queryName: queryName,
    ),
    MssqlErrorType.poolTimeout => MssqlPoolTimeoutException(message: message),
    MssqlErrorType.constraint => MssqlConstraintException(
      message: message,
      code: code,
      state: state,
      operationId: operationId,
      queryName: queryName,
      diagnostics: diagnostics,
    ),
    MssqlErrorType.conversion => MssqlConversionException(
      message: message,
      code: code,
      state: state,
      operationId: operationId,
      queryName: queryName,
      diagnostics: diagnostics,
    ),
    _ => MssqlException(
      type: type,
      message: message,
      code: code,
      state: state,
      retryable: retryable,
      operationId: operationId,
      queryName: queryName,
      diagnostics: diagnostics,
    ),
  };

  final MssqlErrorType type;

  /// SQL Server's message number, or FreeTDS's own error code when the
  /// failure never reached the server. Zero when there is neither.
  final int code;

  /// SQL Server's error state, the second number in `RAISERROR`, which
  /// distinguishes occurrences of the same message number.
  ///
  /// Zero when the failure did not come from the server. Filled from the
  /// server message whose number matches [code] when not given explicitly.
  final int state;

  final String message;
  final bool retryable;
  final int? operationId;

  /// The caller's label for the statement that failed, from
  /// `MssqlQueryOptions.queryName`. Null for an unlabelled statement.
  final String? queryName;

  final List<MssqlServerMessage> diagnostics;

  /// This failure as the subclass its category deserves, labelled with
  /// [queryName] and with [state] filled in from [diagnostics].
  ///
  /// Called where a failure leaves the driver. Split from the worker's
  /// classification because the worker knows what went wrong while the
  /// connection knows the caller's label and holds the server messages.
  ///
  /// An existing subclass is returned untouched: it can carry more than its
  /// category (a row and column, a stated contract) that rebuilding from
  /// [type] would discard.
  MssqlException classified({String? queryName}) {
    if (runtimeType != MssqlException) return this;
    return MssqlException.classify(
      type: type,
      message: message,
      code: code,
      state: state == 0 ? _stateFromDiagnostics(code, diagnostics) : state,
      retryable: retryable,
      operationId: operationId,
      queryName: queryName ?? this.queryName,
      diagnostics: diagnostics,
    );
  }

  static int _stateFromDiagnostics(
    int code,
    List<MssqlServerMessage> diagnostics,
  ) {
    for (final message in diagnostics.reversed) {
      if (message.number == code) return message.state;
    }
    return 0;
  }

  @override
  String toString() {
    final out = StringBuffer('$runtimeType($type');
    if (code != 0) out.write(', code=$code');
    if (state != 0) out.write(', state=$state');
    final name = queryName;
    if (name != null) out.write(', query=$name');
    return (out..write('): $message')).toString();
  }
}

/// The server could not be reached, or stopped being reachable.
///
/// Carries both [MssqlErrorType.connection] (never established) and
/// [MssqlErrorType.connectionLost] (lost mid-statement). The distinction
/// affects what the statement did, so [type] keeps it; the remedy is the same,
/// so the class does not split.
class MssqlConnectionException extends MssqlException {
  const MssqlConnectionException({
    required super.type,
    required super.message,
    super.code,
    super.state,
    super.retryable = true,
    super.operationId,
    super.queryName,
    super.diagnostics,
  });

  /// Whether the failure arrived after the statement was sent.
  ///
  /// A statement still in flight may have completed on the server, so a caller
  /// who needs exactly-once application must check rather than repeat.
  bool get mayHaveRun => type == MssqlErrorType.connectionLost;
}

/// The server refused the credentials.
///
/// Its own type because retrying cannot help and it must not be treated as
/// transient.
class MssqlAuthenticationException extends MssqlException {
  const MssqlAuthenticationException({
    required super.message,
    super.code,
    super.state,
    super.operationId,
    super.queryName,
    super.diagnostics,
  }) : super(type: MssqlErrorType.authentication);
}

/// The session could not be encrypted, or could not be trusted.
///
/// Separate from a plain connection failure: retrying or waiting does not help,
/// and the fix is a configuration change.
///
/// Reported as [MssqlErrorType.tls], so a caller can tell a trust-store problem
/// from a malformed connection string. Never retryable: the driver fails closed
/// rather than retrying without encryption.
///
/// [MssqlTlsException.configuration] covers TLS settings that are wrong before
/// any transport exists.
class MssqlTlsException extends MssqlException {
  const MssqlTlsException(String message)
    : super(type: MssqlErrorType.tls, message: message);

  /// A TLS setting that is wrong before any transport exists: an unresolved CA
  /// path, an empty trust store, a conflicting second `initialize`, a build
  /// with no TLS backend.
  ///
  /// Typed [MssqlErrorType.configuration] rather than [MssqlErrorType.tls]
  /// because the fix is in the program or deployment, not a certificate. These
  /// are raised at `initialize` rather than folded into the first connection
  /// failure.
  const MssqlTlsException.configuration(String message)
    : super(type: MssqlErrorType.configuration, message: message);
}

/// The server was given its time and did not answer in it.
///
/// Kept apart from [MssqlCancelledException]: a timeout says the work may still
/// be running on the server, while a cancellation means the caller stopped
/// waiting.
class MssqlQueryTimeoutException extends MssqlException {
  const MssqlQueryTimeoutException({
    required super.message,
    super.code,
    super.state,
    super.operationId,
    super.queryName,
    super.diagnostics,
  }) : super(type: MssqlErrorType.queryTimeout, retryable: true);
}

/// The caller cancelled the operation. Never retryable.
class MssqlCancelledException extends MssqlException {
  const MssqlCancelledException({
    required super.message,
    super.operationId,
    super.queryName,
  }) : super(type: MssqlErrorType.cancelled);
}

/// No pooled connection became available within the acquire budget.
///
/// Distinct from [MssqlQueryTimeoutException]: the server was never asked
/// anything, and the remedy is pool sizing or connection hold time, not a
/// faster query.
class MssqlPoolTimeoutException extends MssqlException {
  const MssqlPoolTimeoutException({required super.message})
    : super(type: MssqlErrorType.poolTimeout, retryable: true);
}

/// The server rejected the write because it would break a constraint.
///
/// A unique index, foreign key or check. Often not a fault but an answer (the
/// row already exists, the parent is gone). [code] is 2601, 2627 or 547.
class MssqlConstraintException extends MssqlException {
  const MssqlConstraintException({
    required super.message,
    super.code,
    super.state,
    super.operationId,
    super.queryName,
    super.diagnostics,
  }) : super(type: MssqlErrorType.constraint);

  /// Whether the write collided with a unique index or primary key.
  ///
  /// 2601 is a unique index and 2627 a key constraint; both mean the row
  /// already exists. 547 (foreign key or check) usually does not.
  bool get isDuplicateKey => code == 2601 || code == 2627;
}

/// A value could not be carried between Dart and SQL Server.
///
/// Raised in both directions: a value that does not fit its column, and a
/// column that does not fit the Dart type it was read into. The message names
/// the column or parameter but never quotes the value.
class MssqlConversionException extends MssqlException {
  const MssqlConversionException({
    required super.message,
    super.code,
    super.state,
    super.operationId,
    super.queryName,
    super.diagnostics,
  }) : super(type: MssqlErrorType.conversion);
}

/// Raised by a single-row terminal when the query matched nothing.
class MssqlNoRowsException extends MssqlException {
  const MssqlNoRowsException()
    : super(
        type: MssqlErrorType.protocol,
        message: 'The query returned no rows.',
      );
}

/// Raised by a single-row terminal when the query matched more than one row.
class MssqlMultipleRowsException extends MssqlException {
  const MssqlMultipleRowsException()
    : super(
        type: MssqlErrorType.protocol,
        message: 'The query returned more than one row.',
      );
}

/// Raised when a COMMIT was sent and no answer came back.
///
/// Not a connection error and not retryable: repeating the work is the wrong
/// response to "it may already be done".
class MssqlUnknownCommitOutcomeException extends MssqlException {
  const MssqlUnknownCommitOutcomeException(String detail)
    : super(
        type: MssqlErrorType.unknownCommitOutcome,
        message:
            'The connection was lost while committing, so the transaction may '
            'or may not have committed. Do not repeat the work; read the '
            'database to find out what it holds. Cause: $detail',
      );
}

/// A bulk-copy row the server rejected, naming the row and column.
class MssqlBulkRowException extends MssqlConversionException {
  MssqlBulkRowException({
    required this.rowIndex,
    required this.columnName,
    required String detail,
  }) : super(message: 'Bulk row $rowIndex, column "$columnName": $detail');

  final int rowIndex;
  final String columnName;
}
