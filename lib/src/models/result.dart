import 'package:meta/meta.dart';

import 'types.dart';

/// Metadata for one column of a result set.
@immutable
class MssqlColumn {
  const MssqlColumn({
    required this.index,
    required this.name,
    required this.type,
    required this.nullable,
    required this.maxLength,
    required this.precision,
    required this.scale,
    required this.nativeType,
    this.reportedName,
  });

  final int index;
  final String name;
  final MssqlType type;
  final bool nullable;
  final int maxLength;
  final int precision;
  final int scale;
  final int nativeType;

  /// The label SQL Server reported before map-safe disambiguation.
  ///
  /// [name] remains unique so map rows cannot lose a value. Typed rows use
  /// this label for name lookup and retain positional access for duplicates.
  final String? reportedName;
}

/// Thrown when a row lookup by name fails: no such column, an ambiguous name,
/// a type mismatch, or a required value that is NULL.
class MssqlRowAccessException implements Exception {
  const MssqlRowAccessException(this.message);

  final String message;

  @override
  String toString() => 'MssqlRowAccessException: $message';
}

/// One shared name lookup for every row in a result set.
@internal
class MssqlRowSchema {
  MssqlRowSchema(List<MssqlColumn> columns)
    : this._build(List<MssqlColumn>.unmodifiable(columns));

  MssqlRowSchema._build(List<MssqlColumn> columns)
    : this._withIndexes(columns, _buildIndexes(columns));

  MssqlRowSchema._withIndexes(this.columns, this._indexes)
    : _foldedIndexes = _buildFolded(columns);

  final List<MssqlColumn> columns;
  final Map<String, int> _indexes;
  final Map<String, int> _foldedIndexes;

  static Map<String, int> _buildIndexes(List<MssqlColumn> columns) {
    final indexes = <String, int>{};
    for (var index = 0; index < columns.length; index++) {
      final name = columns[index].reportedName ?? columns[index].name;
      indexes[name] = indexes.containsKey(name) ? -1 : index;
    }
    return indexes;
  }

  /// Lower-cases the ASCII letters and nothing else.
  ///
  /// Not `toLowerCase()`, which is Unicode's: it merges `I` and `İ` into `i`
  /// and leaves `ı` alone, which is wrong for Turkish. The server's collation
  /// is not known per column, so only the range every collation agrees on is
  /// folded. `ISIM` answers to `isim`; `İSİM` and `ısım` answer to themselves.
  static String foldAscii(String name) {
    final units = name.codeUnits;
    List<int>? folded;
    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      if (unit >= 0x41 && unit <= 0x5A) {
        folded ??= List<int>.of(units);
        folded[i] = unit + 0x20;
      }
    }
    return folded == null ? name : String.fromCharCodes(folded);
  }

  static Map<String, int> _buildFolded(List<MssqlColumn> columns) {
    final folded = <String, int>{};
    for (var index = 0; index < columns.length; index++) {
      final key = foldAscii(columns[index].reportedName ?? columns[index].name);
      folded[key] = folded.containsKey(key) ? -1 : index;
    }
    return folded;
  }

  int indexOf(String name) {
    // The name as written wins: columns differing only in case both stay
    // reachable, and only a name matching none falls through to the folded
    // lookup.
    final exact = _indexes[name];
    if (exact != null && exact >= 0) return exact;
    if (exact == null) {
      final folded = _foldedIndexes[foldAscii(name)];
      if (folded != null && folded >= 0) return folded;
      if (folded == null) {
        throw MssqlRowAccessException(
          'The result set has no column named "$name".',
        );
      }
    }
    throw MssqlRowAccessException(
      'The result set contains more than one column named "$name"; '
      'use row.at(index).',
    );
  }

  bool contains(String name) =>
      _indexes.containsKey(name) || _foldedIndexes.containsKey(foldAscii(name));
  bool isAmbiguous(String name) =>
      _indexes[name] == -1 ||
      (!_indexes.containsKey(name) && _foldedIndexes[foldAscii(name)] == -1);
}

@immutable
final class MssqlRow {
  @internal
  MssqlRow.fromValues(this._schema, List<Object?> values) : _values = values {
    if (values.length != _schema.columns.length) {
      throw ArgumentError(
        'Row has ${values.length} values for ${_schema.columns.length} columns.',
      );
    }
  }

  final MssqlRowSchema _schema;
  final List<Object?> _values;

  int get length => _values.length;
  Iterable<String> get columnNames =>
      _schema.columns.map((column) => column.reportedName ?? column.name);

  Object? operator [](String columnName) => at(_schema.indexOf(columnName));

  Object? at(int index) {
    RangeError.checkValidIndex(index, _values, 'index');
    return _values[index];
  }

  /// The column metadata at [index].
  ///
  /// Generated mappers read by ordinal after checking the name at that
  /// position, which avoids rebuilding the schema's lookup for every field.
  MssqlColumn columnAt(int index) {
    RangeError.checkValidIndex(index, _schema.columns, 'index');
    return _schema.columns[index];
  }

  /// The reported column name at [index].
  String nameAt(int index) {
    final column = columnAt(index);
    return column.reportedName ?? column.name;
  }

  /// Refuses a row whose leading columns are not [expected] in that order.
  ///
  /// Extra trailing columns are allowed: a `withCount` projection appends
  /// aggregates after the table's own columns. Fewer columns, or a name
  /// that does not match at an ordinal, is a different shape and cannot
  /// use a generated `fromRow`.
  void assertOrdinalNames(List<String> expected) {
    if (length < expected.length) {
      throw MssqlRowAccessException(
        'Row has $length column(s); generated mapper expected at least '
        '${expected.length}.',
      );
    }
    for (var index = 0; index < expected.length; index++) {
      final actual = nameAt(index);
      final wanted = expected[index];
      if (actual == wanted) continue;
      if (MssqlRowSchema.foldAscii(actual) ==
          MssqlRowSchema.foldAscii(wanted)) {
        continue;
      }
      throw MssqlRowAccessException(
        'Column $index was expected to be "$wanted" but the result '
        'reported "$actual". The generated mapper reads by ordinal; a '
        'SELECT that reorders or aliases columns cannot use fromRow.',
      );
    }
  }

  T? get<T>(String columnName) {
    final value = this[columnName];
    if (value == null) return null;
    if (value is T) return value as T;
    throw MssqlRowAccessException(
      'Column "$columnName" contains ${value.runtimeType}, not $T.',
    );
  }

  T require<T>(String columnName) {
    final value = get<T>(columnName);
    if (value == null) {
      throw MssqlRowAccessException('Column "$columnName" is NULL.');
    }
    return value;
  }

  bool containsColumn(String columnName) => _schema.contains(columnName);

  Map<String, Object?> toMap() {
    final result = <String, Object?>{};
    for (var index = 0; index < _schema.columns.length; index++) {
      final name = _schema.columns[index].name;
      result[name] = _values[index];
    }
    return result;
  }

  @override
  String toString() => 'MssqlRow($_values)';
}

@immutable
class MssqlResultSetMetrics {
  const MssqlResultSetMetrics({
    required this.index,
    required this.rowCount,
    required this.decodedBytes,
    required this.elapsed,
  });

  final int index;
  final int rowCount;
  final int decodedBytes;
  final Duration elapsed;

  static const empty = MssqlResultSetMetrics(
    index: 0,
    rowCount: 0,
    decodedBytes: 0,
    elapsed: Duration.zero,
  );
}

@immutable
class MssqlExecutionMetrics {
  const MssqlExecutionMetrics({
    required this.queueWait,
    required this.executionElapsed,
    required this.rowCount,
    required this.decodedBytes,
    required this.resultSets,
    this.timeToFirstRow,
  });

  static const empty = MssqlExecutionMetrics(
    queueWait: Duration.zero,
    executionElapsed: Duration.zero,
    rowCount: 0,
    decodedBytes: 0,
    resultSets: <MssqlResultSetMetrics>[],
  );

  final Duration queueWait;
  final Duration executionElapsed;
  final Duration? timeToFirstRow;
  final int rowCount;
  final int decodedBytes;
  final List<MssqlResultSetMetrics> resultSets;
}

/// A buffered result set with column metadata and map and typed row views.
@immutable
class MssqlResultSet {
  const MssqlResultSet({
    required this.columns,
    required this.rows,
    this.metrics = MssqlResultSetMetrics.empty,
  }) : typedRows = const <MssqlRow>[];

  const MssqlResultSet._({
    required this.columns,
    required this.rows,
    required this.typedRows,
    required this.metrics,
  });

  factory MssqlResultSet.fromValues({
    required List<MssqlColumn> columns,
    required List<List<Object?>> values,
    required MssqlResultSetMetrics metrics,
  }) {
    final schema = MssqlRowSchema(columns);
    final typedRows = List<MssqlRow>.unmodifiable(
      values.map((row) => MssqlRow.fromValues(schema, row)),
    );
    final rows = List<Map<String, Object?>>.unmodifiable(
      typedRows.map((row) => row.toMap()),
    );
    return MssqlResultSet._(
      columns: schema.columns,
      rows: rows,
      typedRows: typedRows,
      metrics: metrics,
    );
  }

  final List<MssqlColumn> columns;

  /// Original map-shaped rows, retained for the advanced API.
  final List<Map<String, Object?>> rows;

  /// Typed row views for callers that opt into indexed and typed access.
  final List<MssqlRow> typedRows;
  final MssqlResultSetMetrics metrics;
}

/// Results, output values, messages and metrics from a statement or procedure.
@immutable
class MssqlExecutionResult {
  const MssqlExecutionResult({
    required this.resultSets,
    required this.affectedRows,
    required this.outputParameters,
    required this.messages,
    this.metrics = MssqlExecutionMetrics.empty,
    this.returnStatus,
    this.statementRowCounts = const <int>[],
  });

  final List<MssqlResultSet> resultSets;

  /// Every row count the batch reported, added together.
  ///
  /// SQL Server emits one token per statement, including statements run by a
  /// trigger. This total therefore cannot be attributed to the caller's
  /// statement alone. See [statementRowCounts] for the individual counts.
  final int affectedRows;

  /// The same counts in the order the server reported them, one per row-count
  /// token, including a trigger's.
  final List<int> statementRowCounts;

  final Map<String, Object?> outputParameters;
  final List<MssqlServerMessage> messages;
  final int? returnStatus;
  final MssqlExecutionMetrics metrics;
}

/// An event emitted while streaming rows or completing an execution.
sealed class MssqlStreamEvent {
  const MssqlStreamEvent();
}

@immutable
final class MssqlResultSetStart extends MssqlStreamEvent {
  MssqlResultSetStart({required this.index, required List<MssqlColumn> columns})
    : columns = List<MssqlColumn>.unmodifiable(columns);

  final int index;
  final List<MssqlColumn> columns;
}

@immutable
final class MssqlRowBatch extends MssqlStreamEvent {
  MssqlRowBatch({required this.resultSetIndex, required List<MssqlRow> rows})
    : rows = List<MssqlRow>.unmodifiable(rows);

  final int resultSetIndex;
  final List<MssqlRow> rows;
}

@immutable
final class MssqlResultSetEnd extends MssqlStreamEvent {
  const MssqlResultSetEnd({required this.metrics});

  final MssqlResultSetMetrics metrics;
}

@immutable
final class MssqlExecutionComplete extends MssqlStreamEvent {
  MssqlExecutionComplete({
    required this.affectedRows,
    required Map<String, Object?> outputParameters,
    required List<MssqlServerMessage> messages,
    required this.metrics,
    this.returnStatus,
    List<int> statementRowCounts = const <int>[],
  }) : outputParameters = Map<String, Object?>.unmodifiable(outputParameters),
       messages = List<MssqlServerMessage>.unmodifiable(messages),
       statementRowCounts = List<int>.unmodifiable(statementRowCounts);

  /// The batch's row counts added together; see
  /// [MssqlExecutionResult.affectedRows] for why that is not a per-statement
  /// answer.
  final int affectedRows;

  /// The counts kept apart, in the order the server reported them.
  final List<int> statementRowCounts;

  final Map<String, Object?> outputParameters;
  final List<MssqlServerMessage> messages;
  final int? returnStatus;
  final MssqlExecutionMetrics metrics;
}

@immutable
class MssqlServerInfo {
  const MssqlServerInfo({
    required this.productVersion,
    required this.productLevel,
    required this.edition,
    required this.engineEdition,
    required this.serverName,
  });

  final String productVersion;
  final String productLevel;
  final String edition;
  final int engineEdition;
  final String serverName;
}

/// A SQL Server message reported during execution.
@immutable
class MssqlServerMessage {
  const MssqlServerMessage({
    required this.number,
    required this.severity,
    required this.state,
    required this.line,
    required this.message,
    this.server,
    this.procedure,
  });

  final int number;
  final int severity;
  final int state;
  final int line;
  final String message;
  final String? server;
  final String? procedure;
}
