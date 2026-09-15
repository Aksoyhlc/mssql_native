import 'models/types.dart';

/// Session state the driver changed and can restore.
///
/// SQL Server keeps isolation level, current database and SET options until
/// something changes them, so on a pooled connection each setting leaks to the
/// next borrower. This tracker records only changes the driver made and can
/// undo exactly; anything a caller changed through raw SQL is invisible and
/// marks the session dirty, so the pool discards it rather than handing it on.
class MssqlSessionState {
  MssqlSessionState({required this.baselineDatabase});

  /// The isolation level every session starts and returns to.
  ///
  /// Stated explicitly rather than left to the server, so it is a property of
  /// the driver's contract. This does not opt out of a database's
  /// READ_COMMITTED_SNAPSHOT setting.
  static const MssqlIsolationLevel baselineIsolation =
      MssqlIsolationLevel.readCommitted;

  /// The database the connection logged in to, or null when it was not stated.
  final String? baselineDatabase;

  MssqlIsolationLevel _isolation = baselineIsolation;
  String? _database;
  final Set<String> _setOptions = <String>{};
  String? _dirtyReason;

  /// The isolation level the session is currently at.
  MssqlIsolationLevel get isolation => _isolation;

  /// The database the session is currently on, as far as the driver knows.
  String? get database => _database ?? baselineDatabase;

  /// Why this session cannot be described any more, or null when it can.
  String? get dirtyReason => _dirtyReason;

  /// Whether the session holds state the driver cannot undo.
  bool get isDirty => _dirtyReason != null;

  /// Whether anything at all needs undoing before the session is handed on.
  bool get needsRestore =>
      isDirty ||
      _isolation != baselineIsolation ||
      (_database != null && _database != baselineDatabase) ||
      _setOptions.isNotEmpty;

  /// Records that the driver moved the session to [level].
  void recordIsolation(MssqlIsolationLevel level) {
    _isolation = level == MssqlIsolationLevel.baseline
        ? baselineIsolation
        : level;
  }

  /// Records that the driver switched the session to [name].
  void recordDatabase(String name) => _database = name;

  /// Records a SET option the driver turned on.
  ///
  /// [restore] is the statement that undoes it.
  void recordSetOption(String restore) => _setOptions.add(restore);

  /// Declares the session unusable for anyone else.
  ///
  /// Called when raw SQL changed something the driver cannot name, or when a
  /// restore attempt failed.
  void markDirty(String reason) => _dirtyReason ??= reason;

  /// The statements that return this session to its baseline.
  ///
  /// Empty when nothing changed, or when the session is dirty: an unknown
  /// change cannot be undone, so the pool discards the session instead.
  List<String> restoreStatements() {
    if (isDirty) return const <String>[];
    final statements = <String>[..._setOptions];
    final database = _database;
    if (database != null && database != baselineDatabase) {
      if (baselineDatabase == null) {
        markDirty(
          'the session changed database and the connection never stated one '
          'to go back to',
        );
        return const <String>[];
      }
      statements.add('USE [${baselineDatabase!.replaceAll(']', ']]')}];');
    }
    if (_isolation != baselineIsolation) {
      statements.add(isolationSql(baselineIsolation));
    }
    return statements;
  }

  /// Accepts that the statements from [restoreStatements] ran.
  void markRestored() {
    _isolation = baselineIsolation;
    _database = null;
    _setOptions.clear();
  }

  /// The statement that moves a session to [level].
  ///
  /// [MssqlIsolationLevel.baseline] emits a real statement: sending nothing
  /// would let one caller's choice become the next caller's default.
  static String isolationSql(MssqlIsolationLevel level) => switch (level) {
    MssqlIsolationLevel.baseline => isolationSql(baselineIsolation),
    MssqlIsolationLevel.readUncommitted =>
      'SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;',
    MssqlIsolationLevel.readCommitted =>
      'SET TRANSACTION ISOLATION LEVEL READ COMMITTED;',
    MssqlIsolationLevel.repeatableRead =>
      'SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;',
    MssqlIsolationLevel.snapshot => 'SET TRANSACTION ISOLATION LEVEL SNAPSHOT;',
    MssqlIsolationLevel.serializable =>
      'SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;',
  };
}
