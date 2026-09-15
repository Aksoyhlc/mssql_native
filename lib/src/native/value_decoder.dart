// Turning DB-Library's raw column bytes into Dart values.
//
// Free of `dart:ffi` so decoding stays a pure function of (type, bytes) and
// can be unit tested without a database. Conversions that need a live
// `DBPROCESS` are left to the worker via [needsConversion].
import 'dart:convert';
import 'dart:typed_data';

import '../models/types.dart';
import 'dblib.dart';

/// Returned by [decodeFixed] for types that must go through `dbconvert`.
///
/// The worker checks this identity because only it holds the `DBPROCESS`
/// `dbconvert` requires.
const Object needsConversion = _NeedsConversion();

class _NeedsConversion {
  const _NeedsConversion();
  @override
  String toString() => 'needsConversion';
}

/// Returned by [decodeFixed] for date and time types, which need
/// `dbanydatecrack` and a live `DBPROCESS`.
///
/// Distinct from [needsConversion] because the result is a structured
/// [MssqlDateTimeValue], not text: callers read a `datetimeoffset` offset in
/// minutes rather than parse it back out of a string.
const Object needsDateCrack = _NeedsDateCrack();

class _NeedsDateCrack {
  const _NeedsDateCrack();
  @override
  String toString() => 'needsDateCrack';
}

/// Whether [type] is a date or time type, to be read with `dbanydatecrack`.
bool requiresDateCrack(int type) => switch (type) {
  Syb.datetime || Syb.datetime4 || Syb.datetimn => true,
  Syb.date || Syb.time => true,
  Syb.msdate || Syb.mstime || Syb.msdatetime2 || Syb.msdatetimeoffset => true,
  Syb.bigdatetime || Syb.bigtime => true,
  _ => false,
};

/// Whether [type] must go through `dbconvert` instead of decoding from bytes.
///
/// This is a deny-list: only the types explicitly decodable below are decoded;
/// everything else is converted to text. An unrecognised type then arrives as
/// text rather than being misread as UTF-8.
///
/// Decimal and money need it because a double loses precision: `DECIMAL(18,4)`
/// carries eighteen significant digits and `99999999999999.9999` would round.
///
/// Date and time need it because each type has its own packed layout, and
/// hand-decoding produces plausible wrong values rather than errors.
///
/// Identifiers and unknown types need it because `dbconvert` knows their
/// canonical text form while this file does not.
bool requiresTextConversion(int type) => switch (type) {
  // Decodable from their bytes; everything else is not.
  Syb.intn || Syb.int1 || Syb.int2 || Syb.int4 || Syb.int8 => false,
  Syb.fltn || Syb.real || Syb.flt8 => false,
  Syb.bit || Syb.bitn => false,
  Syb.binary || Syb.varbinary || Syb.image => false,
  Syb.charType ||
  Syb.varchar ||
  Syb.text ||
  Syb.nchar ||
  Syb.nvarchar ||
  Syb.ntext => false,
  _ => true,
};

/// Decodes a column value from the bytes `dbdata` returned.
///
/// Returns `null` for an empty value, [needsConversion] for the types
/// [requiresTextConversion] covers, and otherwise an `int`, `double`, `bool`,
/// `String` or `Uint8List`.
Object? decodeFixed({required int type, required Uint8List bytes}) {
  if (bytes.isEmpty) return null;
  if (requiresDateCrack(type)) return needsDateCrack;
  if (requiresTextConversion(type)) return needsConversion;

  final data = ByteData.sublistView(bytes);
  switch (type) {
    // The nullable variants carry their width in the length, not the type: a
    // nullable INT arrives as SYBINTN with dbdatlen saying 1, 2, 4 or 8.
    case Syb.intn:
      return switch (bytes.length) {
        1 => bytes[0],
        2 => data.getInt16(0, Endian.little),
        4 => data.getInt32(0, Endian.little),
        8 => data.getInt64(0, Endian.little),
        _ => Uint8List.fromList(bytes),
      };
    case Syb.fltn:
      return switch (bytes.length) {
        4 => data.getFloat32(0, Endian.little),
        8 => data.getFloat64(0, Endian.little),
        _ => Uint8List.fromList(bytes),
      };

    case Syb.int1:
      return bytes[0];
    case Syb.int2:
      return data.getInt16(0, Endian.little);
    case Syb.int4:
      return data.getInt32(0, Endian.little);
    case Syb.int8:
      return data.getInt64(0, Endian.little);

    case Syb.real:
      return data.getFloat32(0, Endian.little);
    case Syb.flt8:
      return data.getFloat64(0, Endian.little);

    case Syb.bit:
    case Syb.bitn:
      return bytes[0] != 0;

    case Syb.binary:
    case Syb.varbinary:
    case Syb.image:
      return Uint8List.fromList(bytes);

    default:
      // char, varchar, text, nchar, nvarchar, ntext; requiresTextConversion
      // has sent everything else to dbconvert. FreeTDS has already converted
      // the server's code page to the connection clientCharset (UTF-8 by
      // default) through iconv.
      return utf8.decode(bytes, allowMalformed: true);
  }
}

/// Whether [type] is one of the exact numeric families.
///
/// These are the only converted types that can become a `double`;
/// `uniqueidentifier` and unrecognised types are text.
bool isExactNumeric(int type) => switch (type) {
  Syb.decimal || Syb.numeric => true,
  Syb.money || Syb.money4 || Syb.moneyn => true,
  _ => false,
};

/// Maps a DB-Library native type onto the driver's logical [MssqlType].
///
/// Unrecognised types map to [MssqlType.varchar]: FreeTDS has already returned
/// text by then.
MssqlType logicalTypeFor(int nativeType) => switch (nativeType) {
  Syb.bit || Syb.bitn => MssqlType.bit,
  Syb.int1 => MssqlType.tinyInt,
  Syb.int2 => MssqlType.smallInt,
  Syb.int4 => MssqlType.int32,
  Syb.int8 || Syb.intn => MssqlType.int64,
  Syb.real => MssqlType.real,
  Syb.flt8 || Syb.fltn => MssqlType.float64,
  Syb.decimal => MssqlType.decimal,
  Syb.numeric => MssqlType.numeric,
  Syb.money || Syb.moneyn => MssqlType.money,
  Syb.money4 => MssqlType.smallMoney,
  Syb.charType => MssqlType.char,
  Syb.varchar => MssqlType.varchar,
  Syb.nchar => MssqlType.nchar,
  Syb.nvarchar => MssqlType.nvarchar,
  Syb.text => MssqlType.text,
  Syb.ntext => MssqlType.ntext,
  Syb.binary => MssqlType.binary,
  Syb.varbinary => MssqlType.varbinary,
  Syb.image => MssqlType.image,
  Syb.date || Syb.msdate => MssqlType.date,
  Syb.time || Syb.mstime || Syb.bigtime => MssqlType.time,
  Syb.datetime4 => MssqlType.smallDateTime,
  Syb.datetime || Syb.datetimn => MssqlType.dateTime,
  Syb.msdatetime2 || Syb.bigdatetime => MssqlType.dateTime2,
  Syb.msdatetimeoffset => MssqlType.dateTimeOffset,
  Syb.unique => MssqlType.uniqueIdentifier,
  Syb.msxml => MssqlType.xml,
  _ => MssqlType.varchar,
};
