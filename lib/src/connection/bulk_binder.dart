import '../exception.dart';
import '../models/bulk.dart';
import '../models/parameter.dart';
import '../models/types.dart';

/// Whether a type carries text in the database's single-byte code page.
bool isSingleByteText(MssqlType type) =>
    type == MssqlType.char ||
    type == MssqlType.varchar ||
    type == MssqlType.text;

void validateBulkKeys(
  Map<String, Object?> row,
  List<String> selected,
  int rowIndex,
) {
  if (row.length == selected.length && selected.every(row.containsKey)) {
    return;
  }
  final selectedSet = selected.toSet();
  final missing = selected.where((name) => !row.containsKey(name)).toList();
  final extra = row.keys.where((name) => !selectedSet.contains(name)).toList();
  final column = missing.isNotEmpty
      ? missing.first
      : (extra.isNotEmpty ? extra.first : '<row>');
  throw MssqlBulkRowException(
    rowIndex: rowIndex,
    columnName: column,
    detail: missing.isNotEmpty
        ? 'the selected column is missing.'
        : 'the row contains a column outside the selected set.',
  );
}

MssqlValue bulkValue(Object? raw, MssqlBulkColumn column, int rowIndex) {
  try {
    final value = raw is MssqlParameter
        ? (raw..validate()).toValue()
        : raw is MssqlValue
        ? raw.validated()
        : coerceMssqlValue(
            raw,
            type: column.type,
            size: column.size,
            precision: column.precision,
            scale: column.scale,
          );
    if (value.type != column.type) {
      throw StateError('explicit value type does not match destination');
    }
    if (value.value == null && !column.nullable) {
      throw StateError('NULL is not allowed');
    }
    return value;
  } catch (_) {
    throw MssqlBulkRowException(
      rowIndex: rowIndex,
      columnName: column.name,
      detail:
          'expected ${column.type}; received ${raw is MssqlParameter
              ? raw.type
              : raw is MssqlValue
              ? raw.type
              : raw?.runtimeType ?? 'NULL'}.',
    );
  }
}

void validateRawBulkColumns(List<MssqlBulkColumn> columns) {
  if (columns.isEmpty) {
    throw ArgumentError('At least one bulk column is required.');
  }
  final ordinals = <int>{};
  final names = <String>{};
  for (final column in columns) {
    column.validate();
    if (!ordinals.add(column.ordinal)) {
      throw ArgumentError('Bulk column ordinals must be unique.');
    }
    if (!names.add(column.name)) {
      throw ArgumentError('Bulk column names must be unique.');
    }
  }
}
