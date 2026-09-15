import 'dart:convert';
import 'dart:typed_data';

/// Single-byte encoders for bulk copy.
///
/// FreeTDS does not convert `bcp_bind` program variables: the bytes handed
/// over land in the column unchanged, and a column's `char_conv` applies only
/// on the data-file path (`tds_bcp_fread`), which this driver does not use.
/// Unicode columns are therefore hand-encoded as UTF-16LE, and single-byte
/// columns must be encoded here rather than sent as UTF-8.
///
/// The code page to encode for is the database's, not the column's: FreeTDS
/// declares `tds->conn->collation` for every character column in its bulk
/// metadata, whatever collation the column actually has. SQL Server converts
/// from that declared collation to the column's.

/// Bytes 0x80-0xFF of CP1252, as Unicode code points. -1 is undefined.
const List<int> _cp1252High = <int>[
  0x20AC, -1, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, -1, 0x017D, -1,
  -1, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, -1, 0x017E, 0x0178,
  0x00A0, 0x00A1, 0x00A2, 0x00A3, 0x00A4, 0x00A5, 0x00A6, 0x00A7,
  0x00A8, 0x00A9, 0x00AA, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x00AF,
  0x00B0, 0x00B1, 0x00B2, 0x00B3, 0x00B4, 0x00B5, 0x00B6, 0x00B7,
  0x00B8, 0x00B9, 0x00BA, 0x00BB, 0x00BC, 0x00BD, 0x00BE, 0x00BF,
  0x00C0, 0x00C1, 0x00C2, 0x00C3, 0x00C4, 0x00C5, 0x00C6, 0x00C7,
  0x00C8, 0x00C9, 0x00CA, 0x00CB, 0x00CC, 0x00CD, 0x00CE, 0x00CF,
  0x00D0, 0x00D1, 0x00D2, 0x00D3, 0x00D4, 0x00D5, 0x00D6, 0x00D7,
  0x00D8, 0x00D9, 0x00DA, 0x00DB, 0x00DC, 0x00DD, 0x00DE, 0x00DF,
  0x00E0, 0x00E1, 0x00E2, 0x00E3, 0x00E4, 0x00E5, 0x00E6, 0x00E7,
  0x00E8, 0x00E9, 0x00EA, 0x00EB, 0x00EC, 0x00ED, 0x00EE, 0x00EF,
  0x00F0, 0x00F1, 0x00F2, 0x00F3, 0x00F4, 0x00F5, 0x00F6, 0x00F7,
  0x00F8, 0x00F9, 0x00FA, 0x00FB, 0x00FC, 0x00FD, 0x00FE, 0x00FF,
];

/// CP1254 is CP1252 with six Turkish letters in place of the Icelandic and
/// Norse ones, and without Ž/ž.
List<int> _buildCp1254() {
  final table = List<int>.of(_cp1252High);
  table[0x8E - 0x80] = -1; // Ž
  table[0x9E - 0x80] = -1; // ž
  table[0xD0 - 0x80] = 0x011E; // Ğ, where CP1252 has Ð
  table[0xDD - 0x80] = 0x0130; // İ, where CP1252 has Ý
  table[0xDE - 0x80] = 0x015E; // Ş, where CP1252 has Þ
  table[0xF0 - 0x80] = 0x011F; // ğ
  table[0xFD - 0x80] = 0x0131; // ı, the dotless one
  table[0xFE - 0x80] = 0x015F; // ş
  return table;
}

final Map<int, List<int>> _tables = <int, List<int>>{
  1252: _cp1252High,
  1254: _buildCp1254(),
};

final Map<int, Map<int, int>> _reverse = <int, Map<int, int>>{};

Map<int, int>? _reverseFor(int codePage) {
  final cached = _reverse[codePage];
  if (cached != null) return cached;
  final table = _tables[codePage];
  if (table == null) return null;
  final map = <int, int>{};
  for (var i = 0; i < table.length; i++) {
    final rune = table[i];
    if (rune >= 0) map[rune] = 0x80 + i;
  }
  return _reverse[codePage] = map;
}

/// Whether [codePage] can be encoded beyond ASCII.
bool isSupportedCodePage(int codePage) => _tables.containsKey(codePage);

/// The code pages this driver can write to a single-byte column.
Iterable<int> get supportedCodePages => _tables.keys;

/// Thrown when text cannot be written to a single-byte column.
///
/// Carries no code of its own: the caller turns it into the driver's own
/// error type, because this file knows nothing about DB-Library.
class CodePageError implements Exception {
  CodePageError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Encodes [text] for a single-byte column in the database's [codePage].
///
/// ASCII passes through regardless of the code page; every Windows
/// single-byte page agrees with ASCII below 0x80. Non-ASCII requires a
/// supported page and a mapping for every character. Both failures throw
/// rather than approximate.
Uint8List encodeForCodePage(String text, int codePage, String columnName) {
  var ascii = true;
  for (final unit in text.codeUnits) {
    if (unit >= 0x80) {
      ascii = false;
      break;
    }
  }
  if (ascii) return Uint8List.fromList(utf8.encode(text));

  final map = _reverseFor(codePage);
  if (map == null) {
    throw CodePageError(
      'Bulk copy cannot write non-ASCII text to the single-byte column '
      '"$columnName": this database is code page '
      '${codePage == 0 ? 'unknown' : '$codePage'}, and the driver can only '
      'encode for ${supportedCodePages.join(' and ')}. Use an NVARCHAR '
      'column, or an ordinary parameterised INSERT, which lets SQL Server do '
      'the conversion.',
    );
  }

  final out = BytesBuilder(copy: false);
  for (final rune in text.runes) {
    if (rune < 0x80) {
      out.addByte(rune);
      continue;
    }
    final byte = map[rune];
    if (byte == null) {
      throw CodePageError(
        'Bulk copy cannot write U+'
        '${rune.toRadixString(16).toUpperCase().padLeft(4, '0')} to the '
        'single-byte column "$columnName": code page $codePage has no such '
        'character. Note this is the *database\'s* code page, not the '
        "column's - FreeTDS declares bulk character data in the database "
        'collation whatever the column is, so a CP1254 column in a CP1252 '
        'database cannot take Turkish text through bulk copy. Use an NVARCHAR '
        'column, or an ordinary parameterised INSERT.',
      );
    }
    out.addByte(byte);
  }
  return out.toBytes();
}
