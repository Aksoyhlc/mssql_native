import 'dart:typed_data';

import 'models/decimal.dart';
import 'models/parameter.dart';
import 'models/types.dart';

/// Turns one column's SQL type into Dart values and back.
///
/// A codec is built once from the column's metadata and used everywhere the
/// column appears — reading, comparing, inserting, updating, and as a relation
/// key — so [encode], [decode] and [keyValue] agree by construction.
///
/// Binding by inferred type instead is unsafe: SQL Server's type precedence
/// puts `float` above `decimal` and `nvarchar` above `varchar`, so an inferred
/// parameter converts the column rather than itself, changing the comparison's
/// meaning and making the column's index unusable.
abstract interface class MssqlTypeCodec<T> {
  /// The Dart value as a parameter of this column's own SQL type.
  MssqlValue encode(T value);

  /// A value the driver produced for this column, as [T].
  T decode(Object value);

  /// The value reduced to something usable as a map key.
  ///
  /// Grouping children by foreign key puts values in a `Map`, where Dart's
  /// equality differs from SQL's: bytes compare by identity and GUID text
  /// differs by case and braces. This normalises both so a parent's key and a
  /// child's key match when the database says they do.
  ///
  /// It does not imitate SQL collation: string keys are correlated on the
  /// server rather than by lowercasing in Dart.
  Object keyValue(T value);
}

/// What a column is, as far as binding and decoding are concerned.
///
/// Carried as one object so that a codec, a generated column and a schema
/// snapshot all describe a column the same way.
final class MssqlColumnType {
  const MssqlColumnType({
    required this.type,
    this.size = 0,
    this.precision = 0,
    this.scale = 0,
    this.nullable = true,
    this.columnName,
  });

  final MssqlType type;

  /// Declared length: characters for `char`/`varchar`/`nchar`/`nvarchar`,
  /// bytes for `binary`/`varbinary`. Zero means `max`.
  final int size;

  final int precision;
  final int scale;
  final bool nullable;

  /// Named in errors, so a range or format complaint says which column.
  final String? columnName;

  String get _where => columnName == null ? '' : ' for column $columnName';
}

/// Builds codecs from column metadata.
abstract final class MssqlTypeCodecs {
  /// A codec for [column], reading and writing `Object?`.
  ///
  /// The generated layer wraps this in a typed one; the untyped form is what
  /// the runtime needs when it holds a row as a map.
  static MssqlTypeCodec<Object?> forColumn(
    MssqlColumnType column, {
    MssqlDecimalMode decimalMode = MssqlDecimalMode.exact,
  }) => _ColumnCodec(column, decimalMode);
}

class _ColumnCodec implements MssqlTypeCodec<Object?> {
  const _ColumnCodec(this.column, this.decimalMode);

  final MssqlColumnType column;
  final MssqlDecimalMode decimalMode;

  @override
  MssqlValue encode(Object? value) {
    if (value == null) {
      if (!column.nullable) {
        throw ArgumentError.value(
          value,
          'value',
          'null is not allowed${column._where}: the column is NOT NULL',
        );
      }
      // A typed null: `WHERE x = @p` with an untyped null is not a question
      // SQL Server can answer.
      return _typedNull();
    }
    return switch (column.type) {
      MssqlType.bit => MssqlValue.bit(_as<bool>(value)),
      MssqlType.tinyInt => MssqlValue.tinyInt(_int(value, 0, 255)),
      MssqlType.smallInt => MssqlValue.smallInt(_int(value, -32768, 32767)),
      MssqlType.int32 => MssqlValue.int32(_int(value, -2147483648, 2147483647)),
      MssqlType.int64 => MssqlValue.int64(_as<int>(value)),
      MssqlType.real => MssqlValue.real(_double(value)),
      MssqlType.float64 => MssqlValue.float64(_double(value)),
      MssqlType.decimal => MssqlValue.decimal(
        _decimal(value),
        precision: _precision,
        scale: column.scale,
      ),
      MssqlType.numeric => MssqlValue.numeric(
        _decimal(value),
        precision: _precision,
        scale: column.scale,
      ),
      MssqlType.money => MssqlValue.money(_decimal(value)),
      MssqlType.smallMoney => MssqlValue.smallMoney(_decimal(value)),
      MssqlType.char => MssqlValue.char(
        _text(value, unicode: false),
        size: _byteSize(value),
      ),
      MssqlType.varchar => MssqlValue.varchar(
        _text(value, unicode: false),
        size: _byteSize(value),
      ),
      MssqlType.nchar => MssqlValue.nchar(
        _text(value, unicode: true),
        size: _unicodeSize(value),
      ),
      MssqlType.nvarchar => MssqlValue.nvarchar(
        _text(value, unicode: true),
        size: _unicodeSize(value),
      ),
      MssqlType.text => MssqlValue.text(_text(value, unicode: false)),
      MssqlType.ntext => MssqlValue.ntext(_text(value, unicode: true)),
      MssqlType.xml => MssqlValue.xml(_text(value, unicode: true)),
      MssqlType.binary => MssqlValue.binary(
        _bytes(value),
        size: _bytesSize(value),
      ),
      MssqlType.varbinary => MssqlValue.varbinary(
        _bytes(value),
        size: _bytesSize(value),
      ),
      MssqlType.image => MssqlValue.image(_bytes(value)),
      MssqlType.uniqueIdentifier => MssqlValue.uniqueIdentifier(_guid(value)),
      MssqlType.date => MssqlValue.date(_temporal(value)),
      MssqlType.time => MssqlValue.time(_temporal(value), scale: _timeScale),
      MssqlType.smallDateTime => MssqlValue.smallDateTime(_temporal(value)),
      MssqlType.dateTime => MssqlValue.dateTime(_temporal(value)),
      MssqlType.dateTime2 => MssqlValue.dateTime2(
        _temporal(value),
        scale: _timeScale,
      ),
      MssqlType.dateTimeOffset => MssqlValue.dateTimeOffset(
        _temporal(value),
        scale: _timeScale,
      ),
    };
  }

  @override
  Object? decode(Object value) => value;

  @override
  Object keyValue(Object? value) {
    if (value == null) {
      throw ArgumentError.value(
        value,
        'value',
        'null is not a key${column._where}',
      );
    }
    return switch (column.type) {
      // Bytes compare by identity in Dart; a hex string compares by value.
      MssqlType.binary ||
      MssqlType.varbinary ||
      MssqlType.image => _hex(_bytes(value)!),
      // A GUID differs by case and braces without differing as a value.
      MssqlType.uniqueIdentifier => _guid(value)!,
      MssqlType.decimal ||
      MssqlType.numeric ||
      MssqlType.money ||
      MssqlType.smallMoney =>
        value is MssqlDecimal
            // Scale is not identity: 1.50 and 1.5 are one key.
            ? value.toString().contains('.')
                  ? _trimZeros(value.toString())
                  : value.toString()
            : value,
      _ => value,
    };
  }

  MssqlValue _typedNull() => switch (column.type) {
    MssqlType.bit => const MssqlValue.bit(null),
    MssqlType.tinyInt => const MssqlValue.tinyInt(null),
    MssqlType.smallInt => const MssqlValue.smallInt(null),
    MssqlType.int32 => const MssqlValue.int32(null),
    MssqlType.int64 => const MssqlValue.int64(null),
    MssqlType.real => const MssqlValue.real(null),
    MssqlType.float64 => const MssqlValue.float64(null),
    MssqlType.decimal => MssqlValue.decimal(
      null,
      precision: _precision,
      scale: column.scale,
    ),
    MssqlType.numeric => MssqlValue.numeric(
      null,
      precision: _precision,
      scale: column.scale,
    ),
    MssqlType.money => MssqlValue.money(null),
    MssqlType.smallMoney => MssqlValue.smallMoney(null),
    MssqlType.char => MssqlValue.char(null, size: _declaredSize),
    MssqlType.varchar => MssqlValue.varchar(null, size: column.size),
    MssqlType.nchar => MssqlValue.nchar(null, size: _declaredSize),
    MssqlType.nvarchar => MssqlValue.nvarchar(null, size: column.size),
    MssqlType.text => const MssqlValue.text(null),
    MssqlType.ntext => const MssqlValue.ntext(null),
    MssqlType.xml => const MssqlValue.xml(null),
    MssqlType.binary => MssqlValue.binary(null, size: _declaredSize),
    MssqlType.varbinary => MssqlValue.varbinary(null, size: column.size),
    MssqlType.image => const MssqlValue.image(null),
    MssqlType.uniqueIdentifier => const MssqlValue.uniqueIdentifier(null),
    MssqlType.date => MssqlValue.date(null),
    MssqlType.time => MssqlValue.time(null, scale: _timeScale),
    MssqlType.smallDateTime => MssqlValue.smallDateTime(null),
    MssqlType.dateTime => MssqlValue.dateTime(null),
    MssqlType.dateTime2 => MssqlValue.dateTime2(null, scale: _timeScale),
    MssqlType.dateTimeOffset => MssqlValue.dateTimeOffset(
      null,
      scale: _timeScale,
    ),
  };

  int get _precision => column.precision < 1 ? 18 : column.precision;

  /// Fixed-length types need a positive declared size; `max` is not one.
  int get _declaredSize => column.size < 1 ? 1 : column.size;

  /// `datetime2`, `time` and `datetimeoffset` carry up to 100 ns, bounded by
  /// the column's scale. Defaulting to 7 rather than 0 avoids silently
  /// truncating to whole seconds when metadata is missing.
  int get _timeScale => column.scale < 0 || column.scale > 7 ? 7 : column.scale;

  V _as<V>(Object value) {
    if (value is V) return value as V;
    throw ArgumentError.value(
      value,
      'value',
      'expected $V${column._where}, got ${value.runtimeType}',
    );
  }

  int _int(Object value, int lower, int upper) {
    final number = _as<int>(value);
    if (number < lower || number > upper) {
      throw RangeError.range(
        number,
        lower,
        upper,
        'value',
        'out of range'
            '${column._where}',
      );
    }
    return number;
  }

  double _double(Object value) {
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is MssqlDecimal) return value.toDouble();
    throw ArgumentError.value(
      value,
      'value',
      'expected a number${column._where}, got ${value.runtimeType}',
    );
  }

  Object _decimal(Object value) {
    if (value is MssqlDecimal || value is String || value is num) return value;
    throw ArgumentError.value(
      value,
      'value',
      'expected MssqlDecimal, String or num${column._where}, '
          'got ${value.runtimeType}',
    );
  }

  String? _text(Object value, {required bool unicode}) {
    final text = _as<String>(value);
    if (column.size > 0) {
      final length = mssqlTextLength(text, unicode: unicode);
      if (length > column.size) {
        throw ArgumentError.value(
          text,
          'value',
          'is $length ${mssqlTextLengthUnit(unicode: unicode)}, more than the '
              'declared ${column.size}${column._where}',
        );
      }
    }
    return text;
  }

  /// The declared size to send, so a column always produces the same parameter
  /// shape and the server reuses one plan.
  ///
  /// Zero on the column means `max`, not "infer from this value": inferring
  /// would send `nvarchar(3)` for `'abc'` and a different plan for `'abcd'`.
  int _unicodeSize(Object value) {
    if (column.size > 0) return column.size;
    return 0;
  }

  int _byteSize(Object value) {
    if (column.size > 0) return column.size;
    return 0;
  }

  int _bytesSize(Object value) {
    if (column.size > 0) return column.size;
    return 0;
  }

  Uint8List? _bytes(Object value) {
    if (value is Uint8List) {
      if (column.size > 0 && value.length > column.size) {
        throw ArgumentError.value(
          value,
          'value',
          'is ${value.length} bytes, more than the declared '
              '${column.size}${column._where}',
        );
      }
      return value;
    }
    if (value is List<int>) return _bytes(Uint8List.fromList(value));
    throw ArgumentError.value(
      value,
      'value',
      'expected bytes${column._where}, got ${value.runtimeType}',
    );
  }

  /// Temporal values are handed to the driver's own normalisation, which
  /// accepts [DateTime], [Duration] and [MssqlDateTimeValue] and keeps a
  /// `datetime2(7)`'s 100 ns and a `datetimeoffset`'s offset intact.
  Object _temporal(Object value) {
    if (value is DateTime || value is Duration) return value;
    if (value is MssqlDateTimeValue) return value;
    throw ArgumentError.value(
      value,
      'value',
      'expected DateTime, Duration or MssqlDateTimeValue${column._where}, '
          'got ${value.runtimeType}',
    );
  }

  String? _guid(Object value) {
    final text = _as<String>(value);
    final trimmed = text.startsWith('{') && text.endsWith('}')
        ? text.substring(1, text.length - 1)
        : text;
    if (!_guidSyntax.hasMatch(trimmed)) {
      throw ArgumentError.value(
        text,
        'value',
        'is not a uniqueidentifier${column._where}; expected '
            '00000000-0000-0000-0000-000000000000',
      );
    }
    return trimmed.toUpperCase();
  }

  static final RegExp _guidSyntax = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{12}$',
  );

  static String _hex(Uint8List bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static String _trimZeros(String text) {
    var end = text.length;
    while (end > 0 && text[end - 1] == '0') {
      end--;
    }
    if (end > 0 && text[end - 1] == '.') end--;
    return text.substring(0, end);
  }
}
