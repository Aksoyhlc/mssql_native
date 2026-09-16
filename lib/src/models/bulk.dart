import 'package:meta/meta.dart';

import 'types.dart';

@immutable
class MssqlBulkColumn {
  const MssqlBulkColumn({
    required this.ordinal,
    required this.name,
    required this.type,
    this.size = 0,
    this.precision = 0,
    this.scale = 0,
    this.nullable = true,
  });

  final int ordinal;
  final String name;
  final MssqlType type;
  final int size;
  final int precision;
  final int scale;
  final bool nullable;

  void validate() {
    if (ordinal < 1) throw RangeError.value(ordinal, 'ordinal');
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$').hasMatch(name)) {
      throw ArgumentError.value(name, 'name', 'Invalid bulk column name');
    }
    if (size < 0) throw RangeError.value(size, 'size');
    if (precision < 0 || precision > 38) {
      throw RangeError.range(precision, 0, 38, 'precision');
    }
    if (scale < 0 || scale > precision && precision != 0) {
      throw RangeError.value(scale, 'scale');
    }
    if ((type == MssqlType.decimal || type == MssqlType.numeric) &&
        precision < 1) {
      throw ArgumentError(
        'Bulk decimal/numeric columns require precision and scale',
      );
    }
  }
}

/// Hints FreeTDS sends with a BCP session.
///
/// Each flag selects a distinct server behaviour and none implies another. All
/// default to false, so an ordinary bulk copy sends no hints and gets SQL
/// Server's defaults, matching `SqlBulkCopyOptions.Default`. The ORM does not
/// change them when it chooses `bulkCopy`.
@immutable
class MssqlBulkOptions {
  const MssqlBulkOptions({
    this.mode = MssqlBulkMode.atomic,
    this.batchSize = 1000,
    this.timeout = const Duration(minutes: 2),
    this.bulkName,
    this.keepNulls = false,
    this.checkConstraints = false,
    this.fireTriggers = false,
    this.tableLock = false,
    this.keepIdentity = false,
  });

  /// Whether a mid-load failure rolls the whole copy back ([MssqlBulkMode.atomic])
  /// or keeps already-committed batches ([MssqlBulkMode.batched]).
  final MssqlBulkMode mode;
  final int batchSize;
  final Duration timeout;

  /// A safe, low-cardinality label for observability.
  ///
  /// The destination table and row values are never exposed to observers.
  final String? bulkName;

  /// When true, an omitted or null field stores NULL rather than the column
  /// default. BCP's default is the opposite: KEEP_NULLS off.
  final bool keepNulls;

  /// When true, CHECK constraints run. BCP's default skips them.
  final bool checkConstraints;

  /// When true, INSERT triggers fire. BCP's default does not fire them, so
  /// a table whose audit trail lives in a trigger is silent unless this is
  /// set.
  final bool fireTriggers;

  /// When true, the copy takes a table-level lock (`TABLOCK`): faster, and it
  /// allows minimal logging under the bulk-logged recovery model, but it
  /// blocks other sessions on that table for as long as the load runs. Off by
  /// default, matching `SqlBulkCopyOptions.Default`.
  final bool tableLock;

  /// When true, identity values in the payload are stored as given.
  final bool keepIdentity;

  void validate() {
    if (batchSize < 1) throw RangeError.value(batchSize, 'batchSize');
    if (timeout <= Duration.zero) throw ArgumentError.value(timeout, 'timeout');
  }
}

@immutable
class MssqlBulkResult {
  const MssqlBulkResult({
    required this.totalRows,
    required this.insertedRows,
    required this.committedBatches,
    required this.elapsed,
    this.failedRowIndex,
  });

  final int totalRows;
  final int insertedRows;
  final int committedBatches;
  final int? failedRowIndex;
  final Duration elapsed;

  static const empty = MssqlBulkResult(
    totalRows: 0,
    insertedRows: 0,
    committedBatches: 0,
    elapsed: Duration.zero,
  );
}
