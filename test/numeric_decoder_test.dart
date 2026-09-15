import 'dart:typed_data';

import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_native/src/native/numeric_decoder.dart';
import 'package:test/test.dart';

Uint8List money(int scaled) {
  final bytes = Uint8List(8);
  final data = ByteData.sublistView(bytes);
  data.setInt32(0, scaled >> 32, Endian.little);
  data.setUint32(4, scaled & 0xFFFFFFFF, Endian.little);
  return bytes;
}

Uint8List smallMoney(int scaled) {
  final bytes = Uint8List(4);
  ByteData.sublistView(bytes).setInt32(0, scaled, Endian.little);
  return bytes;
}

Uint8List numeric({
  required int precision,
  required int scale,
  required int magnitude,
  bool negative = false,
}) {
  const widths = <int>[
    1,
    2,
    2,
    3,
    3,
    4,
    4,
    4,
    5,
    5,
    6,
    6,
    6,
    7,
    7,
    8,
    8,
    9,
    9,
    9,
    10,
    10,
    11,
    11,
    11,
    12,
    12,
    13,
    13,
    14,
    14,
    14,
    15,
    15,
    16,
    16,
    16,
    17,
    17,
  ];
  final total = widths[precision];
  final bytes = Uint8List(2 + total);
  bytes[0] = precision;
  bytes[1] = scale;
  bytes[2] = negative ? 1 : 0;
  var rest = magnitude;
  for (var i = total - 1; i >= 1; i--) {
    bytes[2 + i] = rest & 0xFF;
    rest >>= 8;
  }
  return bytes;
}

void main() {
  group('money', () {
    test('a positive amount keeps its four decimal places', () {
      expect(
        decodeMoney(money(199900), mode: MssqlDecimalMode.text),
        '19.9900',
      );
      expect(
        decodeMoney(money(199900), mode: MssqlDecimalMode.doublePrecision),
        19.99,
      );
    });

    test('a negative amount gets exactly one minus sign', () {
      expect(
        decodeMoney(money(-199900), mode: MssqlDecimalMode.text),
        '-19.9900',
      );
      expect(
        decodeMoney(money(-199900), mode: MssqlDecimalMode.doublePrecision),
        -19.99,
      );
    });

    test('zero is not signed', () {
      expect(decodeMoney(money(0), mode: MssqlDecimalMode.text), '0.0000');
      expect(
        decodeMoney(money(0), mode: MssqlDecimalMode.doublePrecision),
        0.0,
      );
    });

    test('a value smaller than its scale keeps the leading zero', () {
      expect(decodeMoney(money(1), mode: MssqlDecimalMode.text), '0.0001');
      expect(decodeMoney(money(-25), mode: MssqlDecimalMode.text), '-0.0025');
    });

    test('the upper bound round-trips exactly as text', () {
      expect(
        decodeMoney(money(9223372036854775807), mode: MssqlDecimalMode.text),
        '922337203685477.5807',
      );
    });

    test('the lower bound falls back rather than double-signing', () {
      expect(
        decodeMoney(money(-9223372036854775808), mode: MssqlDecimalMode.text),
        same(fallBackToConvert),
      );
    });

    test(
      'a magnitude past a double falls back only when a double is asked for',
      () {
        final huge = money(9223372036854775807);
        expect(
          decodeMoney(huge, mode: MssqlDecimalMode.doublePrecision),
          same(fallBackToConvert),
        );
        expect(decodeMoney(huge, mode: MssqlDecimalMode.text), isA<String>());
      },
    );

    test('smallmoney is four bytes', () {
      expect(
        decodeMoney(smallMoney(199900), mode: MssqlDecimalMode.text),
        '19.9900',
      );
      expect(
        decodeMoney(smallMoney(-1), mode: MssqlDecimalMode.text),
        '-0.0001',
      );
    });

    test('an unexpected width falls back', () {
      expect(
        decodeMoney(Uint8List(6), mode: MssqlDecimalMode.text),
        same(fallBackToConvert),
      );
    });
  });

  group('decimal and numeric', () {
    test('scale zero has no point at all', () {
      expect(
        decodeNumeric(
          numeric(precision: 9, scale: 0, magnitude: 12345),
          mode: MssqlDecimalMode.text,
        ),
        '12345',
      );
    });

    test('the fraction is padded to the scale', () {
      expect(
        decodeNumeric(
          numeric(precision: 18, scale: 4, magnitude: 123400),
          mode: MssqlDecimalMode.text,
        ),
        '12.3400',
      );
      expect(
        decodeNumeric(
          numeric(precision: 18, scale: 4, magnitude: 5),
          mode: MssqlDecimalMode.text,
        ),
        '0.0005',
      );
    });

    test('the sign byte is honoured', () {
      expect(
        decodeNumeric(
          numeric(precision: 18, scale: 2, magnitude: 12345, negative: true),
          mode: MssqlDecimalMode.text,
        ),
        '-123.45',
      );
      expect(
        decodeNumeric(
          numeric(precision: 18, scale: 2, magnitude: 12345, negative: true),
          mode: MssqlDecimalMode.doublePrecision,
        ),
        -123.45,
      );
    });

    test('a negative zero is still zero', () {
      expect(
        decodeNumeric(
          numeric(precision: 9, scale: 2, magnitude: 0, negative: true),
          mode: MssqlDecimalMode.text,
        ),
        '0.00',
      );
    });

    test('as a double it divides rather than parses', () {
      expect(
        decodeNumeric(
          numeric(precision: 18, scale: 4, magnitude: 123456789),
          mode: MssqlDecimalMode.doublePrecision,
        ),
        12345.6789,
      );
    });

    test('a magnitude wider than eight bytes falls back', () {
      expect(
        decodeNumeric(
          numeric(precision: 38, scale: 10, magnitude: 1),
          mode: MssqlDecimalMode.text,
        ),
        same(fallBackToConvert),
      );
    });

    test('a nonsensical header falls back instead of guessing', () {
      expect(
        decodeNumeric(Uint8List(2), mode: MssqlDecimalMode.text),
        same(fallBackToConvert),
      );
      expect(
        decodeNumeric(
          numeric(precision: 5, scale: 4, magnitude: 1)..[1] = 9,
          mode: MssqlDecimalMode.text,
        ),
        same(fallBackToConvert),
      );
    });
  });
}

