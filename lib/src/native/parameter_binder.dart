// Turning [MssqlParameterBinding]s into what `sp_executesql` needs.
//
// A parameterised query is sent as an RPC: `sp_executesql @stmt, @params, ...`
// where `@params` is a SQL declaration string like
// `@id int, @name nvarchar(50) OUTPUT`. The string is generated here as a pure
// function.
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../models/parameter.dart';
import '../models/types.dart';
import 'dblib.dart';

MssqlParameterBinding _asBinding(Object parameter) => switch (parameter) {
  final MssqlParameterBinding binding => binding,
  final MssqlParameter explicit => MssqlParameterBinding.fromParameter(
    explicit,
  ),
  _ => throw ArgumentError.value(
    parameter,
    'parameter',
    'Expected MssqlParameter or MssqlParameterBinding.',
  ),
};

/// The parameter's name, with a leading `@` added when the caller omitted it.
///
/// `MssqlParameterBinding` accepts both `id` and `@id`; SQL Server needs the `@`.
String parameterName(Object parameter, {bool withAt = true}) {
  final p = _asBinding(parameter);
  final name = p.name;
  if (!withAt) return name.startsWith('@') ? name.substring(1) : name;
  return name.startsWith('@') ? name : '@$name';
}

/// The SQL type for one parameter, as `sp_executesql`'s `@params` expects it.
///
/// `varchar`, `nvarchar` and `varbinary` fall back to `(max)` when no size was
/// given, which is what lets a caller pass a long string without declaring its
/// length.
String sqlTypeOf(Object parameter) {
  final p = _asBinding(parameter);
  return switch (p.type) {
    MssqlType.bit => 'bit',
    MssqlType.tinyInt => 'tinyint',
    MssqlType.smallInt => 'smallint',
    MssqlType.int32 => 'int',
    MssqlType.int64 => 'bigint',
    MssqlType.real => 'real',
    MssqlType.float64 => 'float',
    MssqlType.decimal => 'decimal(${p.precision},${p.scale})',
    MssqlType.numeric => 'numeric(${p.precision},${p.scale})',
    MssqlType.money => 'money',
    MssqlType.smallMoney => 'smallmoney',
    MssqlType.char => 'char(${p.size})',
    MssqlType.varchar => p.size <= 0 ? 'varchar(max)' : 'varchar(${p.size})',
    MssqlType.nchar => 'nchar(${p.size})',
    MssqlType.nvarchar => p.size <= 0 ? 'nvarchar(max)' : 'nvarchar(${p.size})',
    MssqlType.text => 'text',
    MssqlType.ntext => 'ntext',
    MssqlType.binary => 'binary(${p.size})',
    MssqlType.varbinary =>
      p.size <= 0 ? 'varbinary(max)' : 'varbinary(${p.size})',
    MssqlType.image => 'image',
    MssqlType.date => 'date',
    MssqlType.time => 'time(${p.scale})',
    MssqlType.smallDateTime => 'smalldatetime',
    MssqlType.dateTime => 'datetime',
    MssqlType.dateTime2 => 'datetime2(${p.scale})',
    MssqlType.dateTimeOffset => 'datetimeoffset(${p.scale})',
    MssqlType.uniqueIdentifier => 'uniqueidentifier',
    MssqlType.xml => 'xml',
  };
}

/// One parameter's entry in `sp_executesql`'s `@params` string.
String sqlDeclaration(Object parameter) {
  final p = _asBinding(parameter);
  final type = sqlTypeOf(p);
  final suffix = p.direction == MssqlParameterBindingDirection.input
      ? ''
      : ' OUTPUT';
  return '${parameterName(p)} $type$suffix';
}

/// The whole `@params` argument for `sp_executesql`.
String sqlDeclarations(Iterable<Object> parameters) =>
    parameters.map(sqlDeclaration).join(', ');

/// How one parameter must be handed to `dbrpcparam`.
///
/// Kept separate from the FFI call so the intricate part - which native type,
/// which length, which promotion - is a pure function and can be tested.
@immutable
class EncodedParameter {
  const EncodedParameter({
    required this.name,
    required this.status,
    required this.nativeType,
    required this.maxLength,
    required this.dataLength,
    required this.bytes,
  });

  final String name;

  /// 0 for input, `DBRPCRETURN` for output. sybdb.h:577.
  final int status;
  final int nativeType;
  final int maxLength;
  final int dataLength;

  /// `null` for a SQL NULL. An *empty* list is not the same thing: it is a
  /// zero-length value, such as `''` or a zero-byte blob, and it must still be
  /// bound with a real pointer or the server sees NULL.
  final Uint8List? bytes;
}

/// `DBRPCRETURN` — sybdb.h:577. Marks an output parameter.
const int dbRpcReturn = 1;

/// The string FreeTDS expects for an encryption level.
///
/// These four spellings are what `tds_config_encryption` accepts
/// (FreeTDS src/tds/config.c:474); anything else falls back to "require"
/// silently.
String encryptionSetting(MssqlEncryption level) => switch (level) {
  MssqlEncryption.off => 'off',
  MssqlEncryption.request => 'request',
  MssqlEncryption.require => 'require',
  MssqlEncryption.strict => 'strict',
};

/// Whether [p] carries a zero-length value rather than a null one.
///
/// `''` and `NULL` differ in SQL Server, but `dbrpcparam` documents
/// `datalen == 0` as one way to specify a NULL and discards the pointer
/// (FreeTDS src/dblib/rpc.c:240-246), so a zero-length value must be reinstated
/// inside the statement — see [emptyValuePrelude].
bool isEmptyValue(Object parameter) {
  final p = _asBinding(parameter);
  final value = p.value;
  if (value is String) return value.isEmpty;
  if (value is Uint8List) return value.isEmpty;
  return false;
}

/// `SET` statements that restore the zero-length values `dbrpcparam` turned
/// into nulls, to be prepended to `sp_executesql`'s `@stmt`.
///
/// An `sp_executesql` parameter is a local variable of the batch, so assigning
/// to one is ordinary T-SQL; defaults in `@params` are not documented to work.
///
/// Returns an empty string when no parameter needs it, leaving most statements
/// and their plan-cache entries untouched.
String emptyValuePrelude(Iterable<Object> parameters) {
  final out = StringBuffer();
  for (final parameter in parameters) {
    final p = _asBinding(parameter);
    if (!isEmptyValue(p)) continue;
    final literal = p.value is Uint8List ? '0x' : "N''";
    out.write('SET ${parameterName(p)} = $literal; ');
  }
  return out.toString();
}

/// The text form of a parameter's value.
///
/// Date and time values are formatted rather than packed: SQL Server parses
/// these literals unambiguously, while hand-built binary layouts produce
/// plausible wrong dates. Ported from `parameter_text` in core.cpp.
String parameterText(Object parameter) {
  final p = _asBinding(parameter);
  final value = p.value;
  if (value == null) return '';
  if (value is MssqlDateTimeValue) {
    final d = value;
    String p2(int n) => n.toString().padLeft(2, '0');
    final date =
        '${d.year.toString().padLeft(4, '0')}-${p2(d.month)}-${p2(d.day)}';
    final scale = switch (p.type) {
      MssqlType.time ||
      MssqlType.dateTime2 ||
      MssqlType.dateTimeOffset => p.scale,
      MssqlType.dateTime => 3,
      _ => 0,
    };
    final digits = d.nanosecond.toString().padLeft(9, '0');
    final fraction = scale == 0 ? '' : '.${digits.substring(0, scale)}';
    final time = '${p2(d.hour)}:${p2(d.minute)}:${p2(d.second)}$fraction';
    switch (p.type) {
      case MssqlType.date:
        return date;
      case MssqlType.time:
        return time;
      case MssqlType.dateTimeOffset:
        final offset = d.timezoneOffsetMinutes;
        final sign = offset < 0 ? '-' : '+';
        final abs = offset.abs();
        return '${date}T$time$sign${p2(abs ~/ 60)}:${p2(abs % 60)}';
      default:
        return '${date}T$time';
    }
  }
  if (value is Uint8List) return '';
  return value.toString();
}

/// The text form accepted by FreeTDS's BCP source-field converter.
///
/// RPC accepts ISO's `T` separator, while FreeTDS BCP parses Microsoft date
/// families with a space between the date and time components.
String bulkParameterText(Object parameter) {
  final p = _asBinding(parameter);
  final text = parameterText(p);
  if (p.value is MssqlDateTimeValue && text.length > 10 && text[10] == 'T') {
    return '${text.substring(0, 10)} ${text.substring(11)}';
  }
  return text;
}

/// The native type `dbrpcparam` should be told, before any size-driven
/// promotion. Ported from `native_type_for_parameter` in core.cpp.
int _baseNativeType(MssqlType type) => switch (type) {
  MssqlType.bit => Syb.bit,
  MssqlType.tinyInt => Syb.int1,
  MssqlType.smallInt => Syb.int2,
  MssqlType.int32 => Syb.int4,
  MssqlType.int64 => Syb.int8,
  MssqlType.real => Syb.real,
  MssqlType.float64 => Syb.flt8,
  MssqlType.binary => Syb.binary,
  MssqlType.varbinary || MssqlType.image => Syb.varbinary,
  _ => Syb.nvarchar,
};

bool _isBinary(MssqlType t) =>
    t == MssqlType.binary || t == MssqlType.varbinary || t == MssqlType.image;

bool _isIntegral(MssqlType t) =>
    t == MssqlType.tinyInt ||
    t == MssqlType.smallInt ||
    t == MssqlType.int32 ||
    t == MssqlType.int64;

int _integralWidth(MssqlType t) => switch (t) {
  MssqlType.tinyInt => 1,
  MssqlType.smallInt => 2,
  MssqlType.int32 => 4,
  _ => 8,
};

/// Works out everything `dbrpcparam` needs for [p].
///
/// Size-driven promotions are required by FreeTDS: `SYBVARCHAR` widens to the
/// TDS7 type only up to 4000 bytes, so longer text goes as
/// `SYBNTEXT`/`SYBTEXT`; `SYBVARBINARY` caps at 8000 bytes, so larger binaries
/// and `image` go as `SYBIMAGE`; and `SYBNVARCHAR` (0x67) is not a valid RPC
/// wire type, so ordinary strings go as `SYBVARCHAR` and FreeTDS widens them.
EncodedParameter encodeParameter(Object parameter) {
  final p = _asBinding(parameter);
  final name = parameterName(p);
  final isOutput = p.direction != MssqlParameterBindingDirection.input;
  final status = isOutput ? dbRpcReturn : 0;
  var nativeType = _baseNativeType(p.type);
  var variableLength = false;
  Uint8List? bytes;
  var dataLength = 0;

  if (p.value == null) {
    if (_isBinary(p.type)) {
      nativeType = Syb.varbinary;
      variableLength = true;
    } else if (!_isIntegral(p.type) &&
        p.type != MssqlType.bit &&
        p.type != MssqlType.real &&
        p.type != MssqlType.float64) {
      nativeType = Syb.varchar;
      variableLength = true;
    }
  } else if (p.type == MssqlType.bit) {
    bytes = Uint8List(1)..[0] = (p.value == true) ? 1 : 0;
    nativeType = Syb.bit;
    dataLength = 1;
  } else if (_isIntegral(p.type)) {
    final width = _integralWidth(p.type);
    final data = ByteData(8)..setInt64(0, p.value as int, Endian.little);
    bytes = Uint8List.sublistView(data, 0, width);
    dataLength = width;
  } else if (p.type == MssqlType.real) {
    final data = ByteData(4)
      ..setFloat32(0, (p.value as num).toDouble(), Endian.little);
    bytes = data.buffer.asUint8List();
    dataLength = 4;
  } else if (p.type == MssqlType.float64) {
    final data = ByteData(8)
      ..setFloat64(0, (p.value as num).toDouble(), Endian.little);
    bytes = data.buffer.asUint8List();
    dataLength = 8;
  } else if (_isBinary(p.type)) {
    bytes = p.value as Uint8List;
    final large =
        p.type == MssqlType.image || p.size <= 0 || bytes.length > 8000;
    nativeType = large ? Syb.image : Syb.varbinary;
    dataLength = bytes.length;
    variableLength = true;
  } else {
    final text = Uint8List.fromList(utf8.encode(parameterText(p)));
    final unicode =
        p.type == MssqlType.nchar ||
        p.type == MssqlType.nvarchar ||
        p.type == MssqlType.ntext;
    final textBlob = p.type == MssqlType.varchar || p.type == MssqlType.text;
    final large = p.size <= 0 || text.length > 4000;
    if (unicode && large) {
      // The RPC path applies the connection's UTF-8 client charset, so hand
      // SYBNTEXT the UTF-8 bytes and let FreeTDS widen them to UCS-2.
      nativeType = Syb.ntext;
    } else if (textBlob && large) {
      nativeType = Syb.text;
    } else {
      nativeType = Syb.varchar;
    }
    bytes = text;
    dataLength = text.length;
    variableLength = true;
  }

  // FreeTDS's dbrpcparam maxlen rules, from src/dblib/rpc.c: input parameters
  // must pass -1, output parameters pass -1 for fixed types and the return
  // buffer size for variable-length ones.
  int maxLength;
  if (!isOutput || !variableLength) {
    maxLength = -1;
  } else if (_isBinary(p.type)) {
    maxLength = p.size > 0 ? p.size : (dataLength > 1 ? dataLength : 1);
  } else {
    maxLength = p.size > 0 ? p.size * 4 : (dataLength > 128 ? dataLength : 128);
  }

  return EncodedParameter(
    name: name,
    status: status,
    nativeType: nativeType,
    maxLength: maxLength,
    dataLength: dataLength,
    // An empty list stays empty, not null: `WHERE c = ''` and `WHERE c IS
    // NULL` select different rows.
    bytes: bytes,
  );
}
