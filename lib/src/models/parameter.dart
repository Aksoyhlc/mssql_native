import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'decimal.dart';
import 'types.dart';

/// A SQL date or time value, kept separate from [DateTime].
///
/// [DateTime] resolves to microseconds and is either UTC or local, so it cannot
/// carry a `datetime2(7)` tick, an arbitrary `datetimeoffset` offset, or a time
/// with no date. The driver accepts and returns this type for those cases;
/// `mssql_orm` converts it where the schema says the conversion is lossless.
@immutable
class MssqlDateTimeValue {
  const MssqlDateTimeValue({
    required this.year,
    required this.month,
    required this.day,
    this.hour = 0,
    this.minute = 0,
    this.second = 0,
    this.nanosecond = 0,
    this.timezoneOffsetMinutes = 0,
  });

  /// A `time` value: an offset from midnight, with 100 ns resolution.
  ///
  /// The date part is a placeholder SQL Server ignores for `time`. [Duration]
  /// resolves to microseconds, so this is exact for `time(0)` through
  /// `time(6)`; `time(7)` needs [MssqlDateTimeValue] itself to keep its last
  /// digit.
  factory MssqlDateTimeValue.fromDuration(Duration value) {
    if (value.isNegative || value.inDays > 0) {
      throw ArgumentError.value(
        value,
        'value',
        'a SQL time is an offset within one day: 00:00:00 to 23:59:59.9999999',
      );
    }
    return MssqlDateTimeValue(
      year: 1900,
      month: 1,
      day: 1,
      hour: value.inHours,
      minute: value.inMinutes.remainder(60),
      second: value.inSeconds.remainder(60),
      nanosecond: value.inMicroseconds.remainder(1000000) * 1000,
    );
  }

  factory MssqlDateTimeValue.fromDateTime(DateTime value) => MssqlDateTimeValue(
    year: value.year,
    month: value.month,
    day: value.day,
    hour: value.hour,
    minute: value.minute,
    second: value.second,
    nanosecond: value.millisecond * 1000000 + value.microsecond * 1000,
    timezoneOffsetMinutes: value.timeZoneOffset.inMinutes,
  );

  final int year;
  final int month;
  final int day;
  final int hour;
  final int minute;
  final int second;
  final int nanosecond;
  final int timezoneOffsetMinutes;

  /// Throws when a component falls outside its range for [type].
  void validate(MssqlType type) {
    if (year < 1 ||
        year > 9999 ||
        month < 1 ||
        month > 12 ||
        day < 1 ||
        day > 31) {
      throw ArgumentError('Invalid SQL date value');
    }
    if (hour < 0 ||
        hour > 23 ||
        minute < 0 ||
        minute > 59 ||
        second < 0 ||
        second > 59) {
      throw ArgumentError('Invalid SQL time value');
    }
    if (nanosecond < 0 || nanosecond > 999999999) {
      throw ArgumentError('nanosecond must be between 0 and 999999999');
    }
    if (type == MssqlType.dateTimeOffset &&
        (timezoneOffsetMinutes < -14 * 60 || timezoneOffsetMinutes > 14 * 60)) {
      throw ArgumentError(
        'datetimeoffset timezone must be between -14:00 and +14:00',
      );
    }
    final normalized = DateTime.utc(year, month, day, hour, minute, second);
    if (normalized.year != year ||
        normalized.month != month ||
        normalized.day != day ||
        normalized.hour != hour ||
        normalized.minute != minute ||
        normalized.second != second) {
      throw ArgumentError('Invalid SQL date/time components');
    }
  }
}

/// A SQL value whose native type cannot or should not be inferred from Dart.
///
/// Parameter names live in the surrounding map, so this object never repeats
/// them. Most callers need this only for nulls and exact decimal values.
@immutable
class MssqlValue {
  const MssqlValue._({
    required this.type,
    required this.value,
    this.size = 0,
    this.precision = 0,
    this.scale = 0,
  });

  const MssqlValue.bit(bool? value) : this._(type: MssqlType.bit, value: value);
  const MssqlValue.tinyInt(int? value)
    : this._(type: MssqlType.tinyInt, value: value);
  const MssqlValue.smallInt(int? value)
    : this._(type: MssqlType.smallInt, value: value);
  const MssqlValue.int32(int? value)
    : this._(type: MssqlType.int32, value: value);
  const MssqlValue.int64(int? value)
    : this._(type: MssqlType.int64, value: value);
  const MssqlValue.real(num? value)
    : this._(type: MssqlType.real, value: value);
  const MssqlValue.float64(num? value)
    : this._(type: MssqlType.float64, value: value);

  factory MssqlValue.decimal(
    Object? value, {
    required int precision,
    required int scale,
  }) => MssqlValue._(
    type: MssqlType.decimal,
    value: _normalizeDecimal(value, scale),
    precision: precision,
    scale: scale,
  );

  factory MssqlValue.numeric(
    Object? value, {
    required int precision,
    required int scale,
  }) => MssqlValue._(
    type: MssqlType.numeric,
    value: _normalizeDecimal(value, scale),
    precision: precision,
    scale: scale,
  );

  factory MssqlValue.money(Object? value) =>
      MssqlValue._(type: MssqlType.money, value: _normalizeDecimal(value, 4));
  factory MssqlValue.smallMoney(Object? value) => MssqlValue._(
    type: MssqlType.smallMoney,
    value: _normalizeDecimal(value, 4),
  );

  const MssqlValue.char(String? value, {required int size})
    : this._(type: MssqlType.char, value: value, size: size);
  const MssqlValue.varchar(String? value, {int size = 0})
    : this._(type: MssqlType.varchar, value: value, size: size);
  const MssqlValue.nchar(String? value, {required int size})
    : this._(type: MssqlType.nchar, value: value, size: size);
  const MssqlValue.nvarchar(String? value, {int size = 0})
    : this._(type: MssqlType.nvarchar, value: value, size: size);
  const MssqlValue.text(String? value)
    : this._(type: MssqlType.text, value: value);
  const MssqlValue.ntext(String? value)
    : this._(type: MssqlType.ntext, value: value);
  const MssqlValue.binary(Uint8List? value, {required int size})
    : this._(type: MssqlType.binary, value: value, size: size);
  const MssqlValue.varbinary(Uint8List? value, {int size = 0})
    : this._(type: MssqlType.varbinary, value: value, size: size);
  const MssqlValue.image(Uint8List? value)
    : this._(type: MssqlType.image, value: value);

  factory MssqlValue.date(Object? value) =>
      MssqlValue._(type: MssqlType.date, value: _normalizeDateTime(value));
  factory MssqlValue.time(Object? value, {int scale = 7}) => MssqlValue._(
    type: MssqlType.time,
    value: _normalizeDateTime(value),
    scale: scale,
  );
  factory MssqlValue.smallDateTime(Object? value) => MssqlValue._(
    type: MssqlType.smallDateTime,
    value: _normalizeDateTime(value),
  );
  factory MssqlValue.dateTime(Object? value) =>
      MssqlValue._(type: MssqlType.dateTime, value: _normalizeDateTime(value));
  factory MssqlValue.dateTime2(Object? value, {int scale = 7}) => MssqlValue._(
    type: MssqlType.dateTime2,
    value: _normalizeDateTime(value),
    scale: scale,
  );
  factory MssqlValue.dateTimeOffset(Object? value, {int scale = 7}) =>
      MssqlValue._(
        type: MssqlType.dateTimeOffset,
        value: _normalizeDateTime(value),
        scale: scale,
      );

  const MssqlValue.uniqueIdentifier(String? value)
    : this._(type: MssqlType.uniqueIdentifier, value: value, size: 36);
  const MssqlValue.xml(String? value)
    : this._(type: MssqlType.xml, value: value);

  const MssqlValue.raw({
    required MssqlType type,
    required Object? value,
    int size = 0,
    int precision = 0,
    int scale = 0,
  }) : this._(
         type: type,
         value: value,
         size: size,
         precision: precision,
         scale: scale,
       );

  final MssqlType type;
  final Object? value;
  final int size;
  final int precision;
  final int scale;

  MssqlValue validated() {
    _validateMssqlValue(this);
    return this;
  }
}

/// Rows destined for a table-valued parameter.
///
/// TDS carries table-valued parameters as their own wire type, which FreeTDS
/// does not implement at any layer, so the driver builds the table on the
/// server instead: the rows are bulk-loaded into a temporary staging table on
/// the same session, copied into a variable of the procedure's own table type,
/// and the procedure is called with that. The caller sees an ordinary
/// parameter.
///
/// Each row is keyed by the table type's column names, in any order.
@immutable
class MssqlTableRows {
  const MssqlTableRows(this.rows);

  final Iterable<Map<String, Object?>> rows;
}

/// An explicitly named SQL parameter for callers that want full control.
///
/// The shorter map API accepts [MssqlValue] because the map key already holds
/// the name. This class keeps the original advanced API, including input,
/// output and input/output directions.
@immutable
class MssqlParameter {
  const MssqlParameter._({
    required this.name,
    required this.type,
    required this.value,
    this.direction = MssqlParameterDirection.input,
    this.size = 0,
    this.precision = 0,
    this.scale = 0,
  });

  const MssqlParameter.bit(
    String name,
    bool? value, {
    MssqlParameterDirection direction = MssqlParameterDirection.input,
  }) : this._(
         name: name,
         type: MssqlType.bit,
         value: value,
         direction: direction,
       );

  const MssqlParameter.int32(
    String name,
    int? value, {
    MssqlParameterDirection direction = MssqlParameterDirection.input,
  }) : this._(
         name: name,
         type: MssqlType.int32,
         value: value,
         direction: direction,
       );

  const MssqlParameter.int64(
    String name,
    int? value, {
    MssqlParameterDirection direction = MssqlParameterDirection.input,
  }) : this._(
         name: name,
         type: MssqlType.int64,
         value: value,
         direction: direction,
       );

  const MssqlParameter.float64(
    String name,
    double? value, {
    MssqlParameterDirection direction = MssqlParameterDirection.input,
  }) : this._(
         name: name,
         type: MssqlType.float64,
         value: value,
         direction: direction,
       );

  factory MssqlParameter.decimal(
    String name,
    Object? value, {
    required int precision,
    required int scale,
    MssqlParameterDirection direction = MssqlParameterDirection.input,
  }) => MssqlParameter._(
    name: name,
    type: MssqlType.decimal,
    value: _normalizeDecimal(value, scale),
    precision: precision,
    scale: scale,
    direction: direction,
  );

  const MssqlParameter.varchar(
    String name,
    String? value, {
    required int size,
    MssqlParameterDirection direction = MssqlParameterDirection.input,
  }) : this._(
         name: name,
         type: MssqlType.varchar,
         value: value,
         size: size,
         direction: direction,
       );

  const MssqlParameter.nvarchar(
    String name,
    String? value, {
    required int size,
    MssqlParameterDirection direction = MssqlParameterDirection.input,
  }) : this._(
         name: name,
         type: MssqlType.nvarchar,
         value: value,
         size: size,
         direction: direction,
       );

  const MssqlParameter.varbinary(
    String name,
    Uint8List? value, {
    required int size,
    MssqlParameterDirection direction = MssqlParameterDirection.input,
  }) : this._(
         name: name,
         type: MssqlType.varbinary,
         value: value,
         size: size,
         direction: direction,
       );

  const MssqlParameter.dateTime2(
    String name,
    MssqlDateTimeValue? value, {
    int scale = 7,
    MssqlParameterDirection direction = MssqlParameterDirection.input,
  }) : this._(
         name: name,
         type: MssqlType.dateTime2,
         value: value,
         scale: scale,
         direction: direction,
       );

  const MssqlParameter.guid(
    String name,
    String? value, {
    MssqlParameterDirection direction = MssqlParameterDirection.input,
  }) : this._(
         name: name,
         type: MssqlType.uniqueIdentifier,
         value: value,
         size: 36,
         direction: direction,
       );

  const MssqlParameter.raw({
    required this.name,
    required this.type,
    required this.value,
    this.direction = MssqlParameterDirection.input,
    this.size = 0,
    this.precision = 0,
    this.scale = 0,
  });

  final String name;
  final MssqlType type;
  final MssqlParameterDirection direction;
  final Object? value;
  final int size;
  final int precision;
  final int scale;

  MssqlValue toValue() => MssqlValue.raw(
    type: type,
    value: value,
    size: size,
    precision: precision,
    scale: scale,
  );

  void validate() {
    normalizeParameterName(name);
    final value = this.value;
    if (size < 0) throw RangeError.value(size, 'size');
    if (precision < 0 || precision > 38) {
      throw RangeError.range(precision, 0, 38, 'precision');
    }
    if (scale < 0 ||
        (scale > 7 && type != MssqlType.decimal && type != MssqlType.numeric)) {
      throw RangeError.value(scale, 'scale');
    }
    if (type == MssqlType.decimal || type == MssqlType.numeric) {
      if (precision < 1) {
        throw ArgumentError('decimal/numeric requires precision 1..38');
      }
      if (scale > precision) {
        throw RangeError.range(scale, 0, precision, 'scale');
      }
    }
    if ((type == MssqlType.char ||
            type == MssqlType.nchar ||
            type == MssqlType.binary) &&
        size < 1) {
      throw ArgumentError('$type requires a positive fixed size');
    }
    if (direction != MssqlParameterDirection.input &&
        _outputNeedsSize(type) &&
        size < 1) {
      throw ArgumentError('Output $type parameters require an explicit size');
    }
    switch (type) {
      case MssqlType.bit:
        if (value != null && value is! bool) {
          throw ArgumentError('bit expects bool');
        }
        break;
      case MssqlType.tinyInt:
        if (value != null && (value is! int || value < 0 || value > 255)) {
          throw ArgumentError('tinyInt expects an integer from 0 to 255');
        }
        break;
      case MssqlType.smallInt:
        if (value != null &&
            (value is! int || value < -32768 || value > 32767)) {
          throw ArgumentError('smallInt expects a signed 16-bit integer');
        }
        break;
      case MssqlType.int32:
        if (value != null &&
            (value is! int || value < -2147483648 || value > 2147483647)) {
          throw ArgumentError('int32 expects a signed 32-bit integer');
        }
        break;
      case MssqlType.int64:
        if (value != null && value is! int) {
          throw ArgumentError('int64 expects int');
        }
        break;
      case MssqlType.real:
      case MssqlType.float64:
        if (value != null && value is! num) {
          throw ArgumentError('$type expects num');
        }
        break;
      case MssqlType.binary:
      case MssqlType.varbinary:
      case MssqlType.image:
        if (value != null && value is! Uint8List) {
          throw ArgumentError('$type expects Uint8List');
        }
        if (value is Uint8List && size > 0 && value.length > size) {
          throw ArgumentError('$type value exceeds the configured size');
        }
        break;
      case MssqlType.date:
      case MssqlType.time:
      case MssqlType.smallDateTime:
      case MssqlType.dateTime:
      case MssqlType.dateTime2:
      case MssqlType.dateTimeOffset:
        if (value != null && value is! MssqlDateTimeValue) {
          throw ArgumentError('$type expects MssqlDateTimeValue');
        }
        if (value is MssqlDateTimeValue) value.validate(type);
        break;
      case MssqlType.uniqueIdentifier:
        if (value != null &&
            (value is! String ||
                !RegExp(
                  r'^[{]?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}[}]?$',
                ).hasMatch(value))) {
          throw ArgumentError(
            'uniqueIdentifier expects a canonical GUID string',
          );
        }
        break;
      default:
        if (value != null && value is! String) {
          throw ArgumentError('$type expects String');
        }
        if (value is String && size > 0 && value.runes.length > size) {
          throw ArgumentError('$type value exceeds the configured size');
        }
        break;
    }
  }
}

bool _outputNeedsSize(MssqlType type) =>
    type == MssqlType.varchar ||
    type == MssqlType.nvarchar ||
    type == MssqlType.varbinary ||
    type == MssqlType.char ||
    type == MssqlType.nchar ||
    type == MssqlType.binary;

enum MssqlParameterBindingDirection { input, output, inputOutput }

/// The worker-facing form produced from a public parameter map.
@internal
@immutable
class MssqlParameterBinding {
  const MssqlParameterBinding({
    required this.name,
    required this.type,
    required this.direction,
    required this.value,
    required this.size,
    required this.precision,
    required this.scale,
  });

  factory MssqlParameterBinding.fromValue(
    String name,
    MssqlValue value, {
    MssqlParameterBindingDirection direction =
        MssqlParameterBindingDirection.input,
  }) {
    final normalized = normalizeParameterName(name);
    value.validated();
    return MssqlParameterBinding(
      name: normalized,
      type: value.type,
      direction: direction,
      value: value.value,
      size: value.size,
      precision: value.precision,
      scale: value.scale,
    );
  }

  factory MssqlParameterBinding.fromParameter(MssqlParameter parameter) {
    parameter.validate();
    final value = parameter.toValue();
    return MssqlParameterBinding(
      name: normalizeParameterName(parameter.name),
      type: value.type,
      direction: switch (parameter.direction) {
        MssqlParameterDirection.input => MssqlParameterBindingDirection.input,
        MssqlParameterDirection.output => MssqlParameterBindingDirection.output,
        MssqlParameterDirection.inputOutput =>
          MssqlParameterBindingDirection.inputOutput,
      },
      value: value.value,
      size: value.size,
      precision: value.precision,
      scale: value.scale,
    );
  }

  final String name;
  final MssqlType type;
  final MssqlParameterBindingDirection direction;
  final Object? value;
  final int size;
  final int precision;
  final int scale;
}

List<MssqlParameterBinding> compileParameters(Object parameters) {
  if (parameters is Iterable) {
    final seen = <String>{};
    final bindings = <MssqlParameterBinding>[];
    for (final item in parameters) {
      if (item is! MssqlParameter) {
        throw ArgumentError.value(
          item,
          'parameters',
          'Explicit parameter lists may contain only MssqlParameter values.',
        );
      }
      final name = normalizeParameterName(item.name);
      if (!seen.add(name)) {
        throw ArgumentError.value(
          item.name,
          'parameters',
          'Duplicate SQL parameter after @ normalization.',
        );
      }
      bindings.add(MssqlParameterBinding.fromParameter(item));
    }
    return bindings;
  }
  if (parameters is! Map<String, Object?>) {
    throw ArgumentError.value(
      parameters,
      'parameters',
      'Expected Map<String, Object?> or Iterable<MssqlParameter>.',
    );
  }
  if (parameters.isEmpty) return const <MssqlParameterBinding>[];
  final seen = <String>{};
  final result = <MssqlParameterBinding>[];
  for (final entry in parameters.entries) {
    final name = normalizeParameterName(entry.key);
    if (!seen.add(name)) {
      throw ArgumentError.value(
        entry.key,
        'parameters',
        'Duplicate SQL parameter after @ normalization: $name',
      );
    }
    final value = entry.value is MssqlValue
        ? entry.value! as MssqlValue
        : inferMssqlValue(entry.value, parameterName: name);
    result.add(MssqlParameterBinding.fromValue(name, value));
  }
  return result;
}

String normalizeParameterName(String name) {
  final normalized = name.startsWith('@') ? name.substring(1) : name;
  if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$').hasMatch(normalized)) {
    throw ArgumentError.value(name, 'name', 'Invalid SQL parameter name');
  }
  return normalized;
}

MssqlValue inferMssqlValue(Object? value, {String? parameterName}) {
  if (value == null) {
    final suffix = parameterName == null ? '' : ' "$parameterName"';
    throw ArgumentError(
      'Cannot infer the SQL type of null parameter$suffix. '
      'Wrap it in an MssqlValue such as MssqlValue.nvarchar(null, size: 100).',
    );
  }
  if (value is MssqlValue) return value.validated();
  if (value is bool) return MssqlValue.bit(value);
  if (value is int) {
    if (value >= -2147483648 && value <= 2147483647) {
      return MssqlValue.int32(value);
    }
    if (value >= -9223372036854775808 && value <= 9223372036854775807) {
      return MssqlValue.int64(value);
    }
    throw RangeError.value(
      value,
      parameterName ?? 'value',
      'SQL bigint requires a signed 64-bit integer',
    );
  }
  if (value is MssqlDecimal) {
    // A decimal binds as DECIMAL, never as FLOAT. SQL Server's type precedence
    // puts float above decimal, so a float parameter compared against a money
    // column converts the *column*, which both changes the comparison's
    // semantics and rules out the index on it.
    final digits = value.coefficient.abs().toString().length;
    final precision = digits < value.scale ? value.scale : digits;
    if (precision > 38) {
      throw RangeError.value(
        precision,
        parameterName ?? 'value',
        'SQL decimal holds at most 38 digits; this value has',
      );
    }
    return MssqlValue.decimal(
      value,
      precision: precision < 1 ? 1 : precision,
      scale: value.scale,
    );
  }
  if (value is double) {
    if (!value.isFinite) {
      throw ArgumentError.value(
        value,
        parameterName ?? 'value',
        'SQL float does not accept NaN or infinity',
      );
    }
    return MssqlValue.float64(value);
  }
  if (value is String) {
    return MssqlValue.nvarchar(
      value,
      size: value.length > 4000 ? 0 : (value.isEmpty ? 1 : value.length),
    );
  }
  if (value is DateTime) return MssqlValue.dateTime2(value);
  if (value is Uint8List) {
    return MssqlValue.varbinary(
      value,
      size: value.length > 8000 ? 0 : (value.isEmpty ? 1 : value.length),
    );
  }
  throw ArgumentError.value(
    value.runtimeType,
    parameterName ?? 'value',
    'Unsupported Dart value type for SQL parameter',
  );
}

@internal
MssqlValue coerceMssqlValue(
  Object? value, {
  required MssqlType type,
  int size = 0,
  int precision = 0,
  int scale = 0,
}) {
  if (value is MssqlValue) return value.validated();
  final MssqlValue result;
  switch (type) {
    case MssqlType.bit:
      result = MssqlValue.bit(value as bool?);
      break;
    case MssqlType.tinyInt:
      result = MssqlValue.tinyInt(value as int?);
      break;
    case MssqlType.smallInt:
      result = MssqlValue.smallInt(value as int?);
      break;
    case MssqlType.int32:
      result = MssqlValue.int32(value as int?);
      break;
    case MssqlType.int64:
      result = MssqlValue.int64(value as int?);
      break;
    case MssqlType.real:
      result = MssqlValue.real(value as num?);
      break;
    case MssqlType.float64:
      result = MssqlValue.float64(value as num?);
      break;
    case MssqlType.decimal:
      result = MssqlValue.decimal(value, precision: precision, scale: scale);
      break;
    case MssqlType.numeric:
      result = MssqlValue.numeric(value, precision: precision, scale: scale);
      break;
    case MssqlType.money:
      result = MssqlValue.money(value);
      break;
    case MssqlType.smallMoney:
      result = MssqlValue.smallMoney(value);
      break;
    case MssqlType.char:
      result = MssqlValue.char(value as String?, size: size);
      break;
    case MssqlType.varchar:
      result = MssqlValue.varchar(value as String?, size: size);
      break;
    case MssqlType.nchar:
      result = MssqlValue.nchar(value as String?, size: size);
      break;
    case MssqlType.nvarchar:
      result = MssqlValue.nvarchar(value as String?, size: size);
      break;
    case MssqlType.text:
      result = MssqlValue.text(value as String?);
      break;
    case MssqlType.ntext:
      result = MssqlValue.ntext(value as String?);
      break;
    case MssqlType.binary:
      result = MssqlValue.binary(value as Uint8List?, size: size);
      break;
    case MssqlType.varbinary:
      result = MssqlValue.varbinary(value as Uint8List?, size: size);
      break;
    case MssqlType.image:
      result = MssqlValue.image(value as Uint8List?);
      break;
    case MssqlType.date:
      result = MssqlValue.date(value);
      break;
    case MssqlType.time:
      result = MssqlValue.time(value, scale: scale);
      break;
    case MssqlType.smallDateTime:
      result = MssqlValue.smallDateTime(value);
      break;
    case MssqlType.dateTime:
      result = MssqlValue.dateTime(value);
      break;
    case MssqlType.dateTime2:
      result = MssqlValue.dateTime2(value, scale: scale);
      break;
    case MssqlType.dateTimeOffset:
      result = MssqlValue.dateTimeOffset(value, scale: scale);
      break;
    case MssqlType.uniqueIdentifier:
      result = MssqlValue.uniqueIdentifier(value as String?);
      break;
    case MssqlType.xml:
      result = MssqlValue.xml(value as String?);
      break;
  }
  return result.validated();
}

Object? _normalizeDateTime(Object? value) {
  if (value == null || value is MssqlDateTimeValue) return value;
  if (value is DateTime) return MssqlDateTimeValue.fromDateTime(value);
  // A `time` column reads back as a Duration for scales up to 6, so writing
  // one back has to work without the caller converting it by hand.
  if (value is Duration) return MssqlDateTimeValue.fromDuration(value);
  throw ArgumentError.value(
    value,
    'value',
    'date/time expects DateTime, Duration or MssqlDateTimeValue',
  );
}

Object? _normalizeDecimal(Object? value, int scale) {
  if (value == null || value is String) return value;
  if (value is MssqlDecimal) {
    // Exact all the way to the wire. Rescaling refuses rather than rounds:
    // a value with more decimal places than the column declares is a mistake
    // the caller should see, not one this layer should quietly resolve.
    return value.rescale(scale < 0 ? 0 : scale).toString();
  }
  if (value is! num) {
    throw ArgumentError.value(
      value,
      'value',
      'decimal expects MssqlDecimal, String or num',
    );
  }
  if (value is double && !value.isFinite) {
    throw ArgumentError.value(
      value,
      'value',
      'decimal does not accept NaN or infinity',
    );
  }
  if (value is int) {
    return scale <= 0 ? value.toString() : '$value.${_zeros(scale)}';
  }
  final renderedScale = scale < 0 ? 0 : (scale > 20 ? 20 : scale);
  var text = value.toStringAsFixed(renderedScale);
  if (scale > renderedScale) {
    text = '$text${_zeros(scale - renderedScale)}';
  }
  if (text.contains('e') || text.contains('E')) {
    throw ArgumentError.value(
      value,
      'value',
      'is too large to render as decimal text. Pass a String to keep every digit.',
    );
  }
  return text;
}

String _zeros(int count) => List<String>.filled(count, '0').join();

void _validateMssqlValue(MssqlValue sql) {
  final value = sql.value;
  if (sql.size < 0) throw RangeError.value(sql.size, 'size');
  if (sql.precision < 0 || sql.precision > 38) {
    throw RangeError.range(sql.precision, 0, 38, 'precision');
  }
  if (sql.scale < 0 ||
      (sql.scale > 7 &&
          sql.type != MssqlType.decimal &&
          sql.type != MssqlType.numeric)) {
    throw RangeError.value(sql.scale, 'scale');
  }
  if (sql.type == MssqlType.decimal || sql.type == MssqlType.numeric) {
    if (sql.precision < 1) {
      throw ArgumentError('decimal/numeric requires precision 1..38');
    }
    if (sql.scale > sql.precision) {
      throw RangeError.range(sql.scale, 0, sql.precision, 'scale');
    }
  }
  if ((sql.type == MssqlType.char ||
          sql.type == MssqlType.nchar ||
          sql.type == MssqlType.binary) &&
      sql.size < 1) {
    throw ArgumentError('${sql.type} requires a positive fixed size');
  }

  switch (sql.type) {
    case MssqlType.bit:
      if (value != null && value is! bool) {
        throw ArgumentError('bit expects bool');
      }
      break;
    case MssqlType.tinyInt:
      if (value != null && (value is! int || value < 0 || value > 255)) {
        throw ArgumentError('tinyInt expects an integer from 0 to 255');
      }
      break;
    case MssqlType.smallInt:
      if (value != null && (value is! int || value < -32768 || value > 32767)) {
        throw ArgumentError('smallInt expects a signed 16-bit integer');
      }
      break;
    case MssqlType.int32:
      if (value != null &&
          (value is! int || value < -2147483648 || value > 2147483647)) {
        throw ArgumentError('int32 expects a signed 32-bit integer');
      }
      break;
    case MssqlType.int64:
      if (value != null &&
          (value is! int ||
              value < -9223372036854775808 ||
              value > 9223372036854775807)) {
        throw ArgumentError('int64 expects a signed 64-bit integer');
      }
      break;
    case MssqlType.real:
    case MssqlType.float64:
      if (value != null && value is! num) {
        throw ArgumentError('${sql.type} expects num');
      }
      if (value is double && !value.isFinite) {
        throw ArgumentError('${sql.type} does not accept NaN or infinity');
      }
      break;
    case MssqlType.decimal:
    case MssqlType.numeric:
    case MssqlType.money:
    case MssqlType.smallMoney:
      if (value != null && value is! String && value is! num) {
        throw ArgumentError('${sql.type} expects String or num');
      }
      if (value is String &&
          (sql.type == MssqlType.decimal || sql.type == MssqlType.numeric)) {
        _validateDecimalText(value, sql.precision, sql.scale);
      }
      break;
    case MssqlType.binary:
    case MssqlType.varbinary:
    case MssqlType.image:
      if (value != null && value is! Uint8List) {
        throw ArgumentError('${sql.type} expects Uint8List');
      }
      if (value is Uint8List && sql.size > 0 && value.length > sql.size) {
        throw ArgumentError('${sql.type} value exceeds the configured size');
      }
      break;
    case MssqlType.date:
    case MssqlType.time:
    case MssqlType.smallDateTime:
    case MssqlType.dateTime:
    case MssqlType.dateTime2:
    case MssqlType.dateTimeOffset:
      if (value != null && value is! MssqlDateTimeValue) {
        throw ArgumentError(
          '${sql.type} expects DateTime or MssqlDateTimeValue',
        );
      }
      if (value is MssqlDateTimeValue) value.validate(sql.type);
      break;
    case MssqlType.uniqueIdentifier:
      if (value != null &&
          (value is! String ||
              !RegExp(
                r'^[{]?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}[}]?$',
              ).hasMatch(value))) {
        throw ArgumentError('uniqueIdentifier expects a canonical GUID string');
      }
      break;
    default:
      if (value != null && value is! String) {
        throw ArgumentError('${sql.type} expects String');
      }
      if (value is String && sql.size > 0) {
        final unicode = mssqlTypeIsUnicodeText(sql.type);
        final length = mssqlTextLength(value, unicode: unicode);
        if (length > sql.size) {
          throw ArgumentError(
            '${sql.type} value is $length '
            '${mssqlTextLengthUnit(unicode: unicode)}, more than the '
            'configured ${sql.size}',
          );
        }
      }
      break;
  }
}

void _validateDecimalText(String value, int precision, int scale) {
  final match = RegExp(r'^[+-]?(\d+)(?:\.(\d*))?$').firstMatch(value);
  if (match == null) {
    throw ArgumentError('decimal expects invariant numeric text');
  }
  final integer = match.group(1)!.replaceFirst(RegExp(r'^0+'), '');
  final fraction = match.group(2) ?? '';
  final integerDigits = integer.isEmpty ? 0 : integer.length;
  if (fraction.length > scale || integerDigits > precision - scale) {
    throw ArgumentError(
      'decimal value exceeds precision $precision and scale $scale',
    );
  }
}
