import 'dart:typed_data';

/// The size a decoded row is charged against a streaming byte budget.
///
/// Dart holds strings as UTF-16, so a character costs two bytes whatever the
/// column's encoding was on the wire.
int decodedRowBytes(List<Object?> row) {
  var bytes = 0;
  for (final value in row) {
    bytes += switch (value) {
      null => 0,
      final String text => text.length * 2,
      final Uint8List data => data.length,
      final bool _ => 1,
      _ => 8,
    };
  }
  return bytes;
}

/// Rejects query options the driver cannot honour, before anything is sent.
void validateQueryLimits(
  String sql, {
  required int batchRows,
  required int maximumRows,
  required int maximumBytes,
  required Duration? timeout,
}) {
  if (sql.trim().isEmpty) throw ArgumentError.value(sql, 'sql');
  if (batchRows < 1 || batchRows > 1000) {
    throw RangeError.range(batchRows, 1, 1000, 'batchRows');
  }
  if (maximumRows < 0) throw RangeError.value(maximumRows, 'maximumRows');
  if (maximumBytes < 0) throw RangeError.value(maximumBytes, 'maximumBytes');
  if (timeout != null && timeout <= Duration.zero) {
    throw ArgumentError.value(timeout, 'timeout');
  }
}
