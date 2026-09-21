import 'package:meta/meta.dart';

import '../session_state.dart';
import 'types.dart';

/// How the server ranks this session when it picks a deadlock victim.
enum MssqlDeadlockPriority {
  low,
  normal,
  high;

  String get sqlKeyword => switch (this) {
    MssqlDeadlockPriority.low => 'LOW',
    MssqlDeadlockPriority.normal => 'NORMAL',
    MssqlDeadlockPriority.high => 'HIGH',
  };
}

/// The SET options every connection is logged in with.
///
/// A session missing any of the first six cannot write to a table carrying a
/// filtered index, an indexed view or an index on a computed column: the
/// server refuses the statement with error 1934.
@immutable
class MssqlSessionOptions {
  const MssqlSessionOptions({
    this.quotedIdentifier = true,
    this.ansiNulls = true,
    this.ansiPadding = true,
    this.ansiWarnings = true,
    this.concatNullYieldsNull = true,
    this.arithAbort = true,
    this.numericRoundAbort = false,
    this.xactAbort = true,
    this.textSize = maximumTextSize,
    this.lockTimeout,
    this.deadlockPriority,
    this.isolation = MssqlIsolationLevel.baseline,
    this.initSql = const <String>[],
  });

  /// The defaults.
  static const MssqlSessionOptions ansi = MssqlSessionOptions();

  /// The behaviour before 0.2.0, for SQL that uses `"..."` for string
  /// literals. Filtered indexes and indexed views are unusable under it.
  static const MssqlSessionOptions legacy = MssqlSessionOptions(
    quotedIdentifier: false,
    ansiPadding: false,
    concatNullYieldsNull: false,
  );

  /// The largest `TEXTSIZE` the server accepts, and the driver's default.
  static const int maximumTextSize = 2147483647;

  /// Whether `"..."` delimits an identifier (on) or a string literal (off).
  final bool quotedIdentifier;

  /// Whether `= NULL` is never true.
  final bool ansiNulls;

  /// Whether trailing spaces are preserved in `char` and `binary` columns.
  final bool ansiPadding;

  /// Whether a divide by zero or an aggregate over NULL warns.
  final bool ansiWarnings;

  /// Whether concatenating NULL to a string yields NULL.
  final bool concatNullYieldsNull;

  /// Whether a divide by zero or overflow ends the statement.
  final bool arithAbort;

  /// Whether losing precision is an error rather than a rounded result. A
  /// filtered index requires it off.
  final bool numericRoundAbort;

  /// Whether a run-time error rolls the whole transaction back.
  ///
  /// Off makes a session outlive an error the caller was told was fatal.
  final bool xactAbort;

  /// The byte ceiling on `text`, `ntext`, `image` and `(max)` reads.
  final int textSize;

  /// How long a statement waits for a lock, or null for the server's default
  /// of waiting indefinitely. [Duration.zero] fails immediately instead.
  final Duration? lockTimeout;

  /// How readily the server picks this session as a deadlock victim, or null
  /// for the server's default.
  final MssqlDeadlockPriority? deadlockPriority;

  /// The isolation level every session starts and returns to. This does not
  /// opt out of a database's READ_COMMITTED_SNAPSHOT setting.
  final MssqlIsolationLevel isolation;

  /// Statements run on every connection once login has finished, for a
  /// setting this class does not name. They run after the options above and
  /// can override them; a failure fails the login.
  ///
  /// Leaving a transaction open and `SET NOCOUNT ON` are refused: the first
  /// hands the next borrower a locked session, the second breaks bulk copy and
  /// affected-row reporting. Not a connection-string key, because a connection
  /// string is no place for arbitrary SQL.
  final List<String> initSql;

  /// The batch the driver sends once login has finished.
  String renderSetBatch() {
    final statements = <String>[
      'SET QUOTED_IDENTIFIER ${_onOff(quotedIdentifier)}',
      'SET ANSI_NULLS ${_onOff(ansiNulls)}',
      'SET ANSI_PADDING ${_onOff(ansiPadding)}',
      'SET ANSI_WARNINGS ${_onOff(ansiWarnings)}',
      'SET CONCAT_NULL_YIELDS_NULL ${_onOff(concatNullYieldsNull)}',
      'SET ARITHABORT ${_onOff(arithAbort)}',
      'SET NUMERIC_ROUNDABORT ${_onOff(numericRoundAbort)}',
      'SET XACT_ABORT ${_onOff(xactAbort)}',
      'SET TEXTSIZE $textSize',
      if (lockTimeout != null)
        'SET LOCK_TIMEOUT ${lockTimeout!.inMilliseconds}',
      if (deadlockPriority != null)
        'SET DEADLOCK_PRIORITY ${deadlockPriority!.sqlKeyword}',
    ];
    // Stated even when it is the baseline: sending nothing would let whoever
    // held the connection last decide it.
    return '${statements.join('; ')}; '
        '${MssqlSessionState.isolationSql(isolation)}';
  }

  /// The batch that runs [initSql], or null when there is none.
  ///
  /// Separate from [renderSetBatch] because `QUOTED_IDENTIFIER` takes effect
  /// when a batch is parsed, not when it runs.
  String? renderInitBatch() {
    if (initSql.isEmpty) return null;
    final statements = initSql.map(
      (statement) =>
          statement.trimRight().endsWith(';') ? statement : '$statement;',
    );
    return '${statements.join('\n')}\n'
        "IF @@TRANCOUNT > 0 RAISERROR('initSql left a transaction open on the "
        "session.', 16, 1);\n"
        "IF (@@OPTIONS & 512) <> 0 RAISERROR('initSql turned NOCOUNT on, which "
        "breaks bulk copy and affected-row reporting.', 16, 1);";
  }

  /// This configuration with individual settings replaced.
  MssqlSessionOptions copyWith({
    bool? quotedIdentifier,
    bool? ansiNulls,
    bool? ansiPadding,
    bool? ansiWarnings,
    bool? concatNullYieldsNull,
    bool? arithAbort,
    bool? numericRoundAbort,
    bool? xactAbort,
    int? textSize,
    Duration? lockTimeout,
    MssqlDeadlockPriority? deadlockPriority,
    MssqlIsolationLevel? isolation,
    List<String>? initSql,
  }) => MssqlSessionOptions(
    quotedIdentifier: quotedIdentifier ?? this.quotedIdentifier,
    ansiNulls: ansiNulls ?? this.ansiNulls,
    ansiPadding: ansiPadding ?? this.ansiPadding,
    ansiWarnings: ansiWarnings ?? this.ansiWarnings,
    concatNullYieldsNull: concatNullYieldsNull ?? this.concatNullYieldsNull,
    arithAbort: arithAbort ?? this.arithAbort,
    numericRoundAbort: numericRoundAbort ?? this.numericRoundAbort,
    xactAbort: xactAbort ?? this.xactAbort,
    textSize: textSize ?? this.textSize,
    lockTimeout: lockTimeout ?? this.lockTimeout,
    deadlockPriority: deadlockPriority ?? this.deadlockPriority,
    isolation: isolation ?? this.isolation,
    initSql: initSql ?? this.initSql,
  );

  void validate() {
    if (textSize < 0 || textSize > maximumTextSize) {
      throw RangeError.range(textSize, 0, maximumTextSize, 'textSize');
    }
    final timeout = lockTimeout;
    if (timeout != null && timeout.isNegative) {
      throw ArgumentError.value(
        timeout,
        'lockTimeout',
        'A negative lock timeout is not a wait; pass null for the server '
            'default of waiting indefinitely.',
      );
    }
    for (final statement in initSql) {
      if (statement.trim().isEmpty) {
        throw ArgumentError.value(
          initSql,
          'initSql',
          'An empty statement would be sent to the server as part of the '
              'login batch.',
        );
      }
    }
  }

  static String _onOff(bool value) => value ? 'ON' : 'OFF';
}
