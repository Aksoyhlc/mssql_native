import 'dart:typed_data';

import '../models/decimal.dart';
import '../models/types.dart';

/// Decodes SQL Server's exact numeric types from their bytes, so the common
/// cases never reach `dbconvert`.
///
/// Routing every value through FreeTDS text rendering and parsing costs
/// roughly 70% more than decoding in place, and these types make up most
/// result-set cells for prices and amounts.
///
/// Wire layouts, from the vendored FreeTDS:
///
///   MONEY       `TDS_OLD_MONEY` - a signed 32-bit high half then an unsigned
///               32-bit low half, both little-endian, scaled by 10 000.
///   SMALLMONEY  one little-endian signed 32-bit value, scaled by 10 000.
///   DECIMAL /   `TDS_NUMERIC` - precision, scale, then `array`, whose first
///   NUMERIC     byte is 1 for negative and whose remaining
///               `tds_numeric_bytes_per_prec[precision] - 1` bytes are the
///               magnitude, big-endian (`src/tds/numeric.c`).
///
/// Values that cannot be decoded exactly return [fallBackToConvert] and go
/// through `dbconvert` as before: magnitudes past 64 bits and scales past what
/// a double can divide without rounding twice.

/// Returned when the value has to go through `dbconvert` after all.
const Object fallBackToConvert = _FallBack();

class _FallBack {
  const _FallBack();
  @override
  String toString() => 'fallBackToConvert';
}

/// `tds_numeric_bytes_per_prec` from `src/tds/numeric.c`, including the sign
/// byte. Index is the precision.
const List<int> _bytesPerPrecision = <int>[
  1, //
  2, 2, 3, 3, 4, 4, 4, 5, 5,
  6, 6, 6, 7, 7, 8, 8, 9, 9, 9,
  10, 10, 11, 11, 11, 12, 12, 13, 13, 14,
  14, 14, 15, 15, 16, 16, 16, 17, 17,
];

const List<int> _pow10 = <int>[
  1,
  10,
  100,
  1000,
  10000,
  100000,
  1000000,
  10000000,
  100000000,
  1000000000,
  10000000000,
  100000000000,
  1000000000000,
  10000000000000,
  100000000000000,
  1000000000000000,
];

/// Beyond this a double cannot hold the magnitude exactly, so dividing would
/// round twice.
const int _exactDoubleLimit = 1 << 53;

/// Renders [magnitude] scaled by [scale] as invariant decimal text, the same
/// shape `dbconvert` produces: a leading minus when negative, no thousands
/// separators, and exactly [scale] digits after the point.
String _text(int magnitude, int scale, bool negative) {
  final digits = magnitude.toString();
  final String body;
  if (scale == 0) {
    body = digits;
  } else if (digits.length > scale) {
    final split = digits.length - scale;
    body = '${digits.substring(0, split)}.${digits.substring(split)}';
  } else {
    body = '0.${digits.padLeft(scale, '0')}';
  }
  return negative && magnitude != 0 ? '-$body' : body;
}

Object _finish(int magnitude, int scale, bool negative, MssqlDecimalMode mode) {
  switch (mode) {
    case MssqlDecimalMode.text:
      return _text(magnitude, scale, negative);
    case MssqlDecimalMode.exact:
      // The magnitude fits an int here, so build the BigInt directly.
      final coefficient = BigInt.from(negative ? -magnitude : magnitude);
      return MssqlDecimal(coefficient, scale);
    case MssqlDecimalMode.doublePrecision:
      final signed = negative ? -magnitude : magnitude;
      if (scale == 0) return signed.toDouble();
      // Both operands are exact, so the division rounds once.
      return signed / _pow10[scale];
  }
}

/// MONEY and SMALLMONEY. [bytes] is 8 or 4 long; anything else falls back.
Object? decodeMoney(Uint8List bytes, {required MssqlDecimalMode mode}) {
  final data = ByteData.sublistView(bytes);
  final int value;
  if (bytes.length == 8) {
    // High half first, then the low half - not one little-endian int64.
    final high = data.getInt32(0, Endian.little);
    final low = data.getUint32(4, Endian.little);
    value = (high << 32) | low;
  } else if (bytes.length == 4) {
    value = data.getInt32(0, Endian.little);
  } else {
    return fallBackToConvert;
  }
  final negative = value < 0;
  final magnitude = negative ? -value : value;
  // Negating the minimum int64 overflows back to itself and stays negative,
  // so that one value takes the slow path.
  if (magnitude < 0) return fallBackToConvert;
  if (mode == MssqlDecimalMode.doublePrecision &&
      magnitude >= _exactDoubleLimit) {
    return fallBackToConvert;
  }
  return _finish(magnitude, 4, negative, mode);
}

/// DECIMAL and NUMERIC, from the `TDS_NUMERIC` struct.
Object? decodeNumeric(Uint8List bytes, {required MssqlDecimalMode mode}) {
  if (bytes.length < 3) return fallBackToConvert;
  final precision = bytes[0];
  final scale = bytes[1];
  if (precision < 1 ||
      precision >= _bytesPerPrecision.length ||
      scale > precision ||
      scale >= _pow10.length) {
    return fallBackToConvert;
  }
  final total = _bytesPerPrecision[precision];
  if (total < 2 || bytes.length < 2 + total) return fallBackToConvert;

  // bytes[2] is the sign; the magnitude follows, most significant first.
  final magnitudeBytes = total - 1;
  if (magnitudeBytes > 8) return fallBackToConvert;
  final negative = bytes[2] == 1;
  var magnitude = 0;
  for (var i = 0; i < magnitudeBytes; i++) {
    magnitude = (magnitude << 8) | bytes[3 + i];
  }
  // Eight magnitude bytes can set the sign bit of a signed Dart int.
  if (magnitude < 0) return fallBackToConvert;
  if (mode == MssqlDecimalMode.doublePrecision &&
      magnitude >= _exactDoubleLimit) {
    return fallBackToConvert;
  }
  return _finish(magnitude, scale, negative, mode);
}
