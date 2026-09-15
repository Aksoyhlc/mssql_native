import 'dart:convert';
import 'dart:typed_data';

import 'package:mssql_native/src/models/types.dart';
import 'package:mssql_native/src/native/dblib.dart';
import 'package:mssql_native/src/native/value_decoder.dart';
import 'package:test/test.dart';

Uint8List bytes(List<int> values) => Uint8List.fromList(values);

void main() {
  group('integers', () {
    test('fixed widths are little-endian and signed', () {
      expect(decodeFixed(type: Syb.int1, bytes: bytes([0x2A])), 42);
      expect(decodeFixed(type: Syb.int2, bytes: bytes([0x00, 0x01])), 256);
      expect(decodeFixed(type: Syb.int4, bytes: bytes([0x01, 0, 0, 0])), 1);
      expect(
        decodeFixed(type: Syb.int4, bytes: bytes([0xFF, 0xFF, 0xFF, 0xFF])),
        -1,
      );
      expect(
        decodeFixed(type: Syb.int8, bytes: bytes([0, 0, 0, 0, 0, 0, 0, 0x80])),
        -9223372036854775808,
      );
    });

    test('the nullable variant takes its width from the byte count', () {
      expect(decodeFixed(type: Syb.intn, bytes: bytes([0x2A])), 42);
      expect(decodeFixed(type: Syb.intn, bytes: bytes([0x00, 0x01])), 256);
      expect(decodeFixed(type: Syb.intn, bytes: bytes([0x01, 0, 0, 0])), 1);
      expect(
        decodeFixed(type: Syb.intn, bytes: bytes([0, 0, 0, 0, 0, 0, 0, 0x01])),
        72057594037927936,
      );
    });
  });

  group('floats', () {
    test('real is 32-bit and float8 is 64-bit', () {
      final f32 = ByteData(4)..setFloat32(0, 1.5, Endian.little);
      final f64 = ByteData(8)..setFloat64(0, 1.5, Endian.little);
      expect(decodeFixed(type: Syb.real, bytes: f32.buffer.asUint8List()), 1.5);
      expect(decodeFixed(type: Syb.flt8, bytes: f64.buffer.asUint8List()), 1.5);
    });

    test('the nullable variant dispatches on width', () {
      final f64 = ByteData(8)..setFloat64(0, 2.25, Endian.little);
      expect(
        decodeFixed(type: Syb.fltn, bytes: f64.buffer.asUint8List()),
        2.25,
      );
    });
  });

  group('bits and binary', () {
    test('bits become bools', () {
      expect(decodeFixed(type: Syb.bit, bytes: bytes([1])), true);
      expect(decodeFixed(type: Syb.bit, bytes: bytes([0])), false);
      expect(decodeFixed(type: Syb.bitn, bytes: bytes([1])), true);
    });

    test('binary types stay bytes', () {
      for (final type in <int>[Syb.binary, Syb.varbinary, Syb.image]) {
        final value = decodeFixed(type: type, bytes: bytes([1, 2, 3]));
        expect(value, isA<Uint8List>(), reason: 'type $type');
        expect(value, bytes([1, 2, 3]), reason: 'type $type');
      }
    });
  });

  group('character types', () {
    test('decode as UTF-8', () {
      final input = Uint8List.fromList(utf8.encode('İstanbul Şişli Ğ'));
      for (final type in <int>[
        Syb.charType,
        Syb.varchar,
        Syb.text,
        Syb.nchar,
        Syb.nvarchar,
        Syb.ntext,
      ]) {
        expect(
          decodeFixed(type: type, bytes: input),
          'İstanbul Şişli Ğ',
          reason: 'type $type',
        );
      }
    });
  });

  group('types that must go through dbconvert', () {
    const deferred = <int>[
      Syb.decimal,
      Syb.numeric,
      Syb.money,
      Syb.money4,
      Syb.moneyn,
      Syb.unique,
    ];

    const cracked = <int>[
      Syb.datetime,
      Syb.datetime4,
      Syb.datetimn,
      Syb.msdate,
      Syb.mstime,
      Syb.msdatetime2,
      Syb.msdatetimeoffset,
      Syb.bigdatetime,
      Syb.bigtime,
    ];

    test('are reported as needing conversion', () {
      for (final type in deferred) {
        expect(requiresTextConversion(type), isTrue, reason: 'type $type');
      }
    });

    test('return the sentinel rather than a value', () {
      for (final type in deferred) {
        expect(
          decodeFixed(type: type, bytes: bytes([0, 0, 0, 0, 0, 0, 0, 0])),
          same(needsConversion),
          reason: 'type $type',
        );
      }
    });

    test('date and time types are reported as needing dbanydatecrack', () {
      for (final type in cracked) {
        expect(requiresDateCrack(type), isTrue, reason: 'type $type');
        expect(
          decodeFixed(type: type, bytes: bytes([0, 0, 0, 0, 0, 0, 0, 0])),
          same(needsDateCrack),
          reason: 'type $type',
        );
      }
    });

    test('an unrecognised type is deferred rather than read as UTF-8', () {
      expect(requiresTextConversion(9999), isTrue);
      expect(
        decodeFixed(type: 9999, bytes: bytes([1, 2, 3])),
        same(needsConversion),
      );
    });

    test('money and decimal never come back as a double', () {
      for (final type in <int>[
        Syb.decimal,
        Syb.numeric,
        Syb.money,
        Syb.money4,
        Syb.moneyn,
      ]) {
        expect(
          decodeFixed(type: type, bytes: bytes([0, 0, 0, 0, 0, 0, 0, 0])),
          isNot(isA<double>()),
          reason: 'type $type',
        );
      }
    });

    test('plain integers and strings are not deferred', () {
      for (final type in <int>[
        Syb.int4,
        Syb.intn,
        Syb.bit,
        Syb.varchar,
        Syb.varbinary,
        Syb.real,
      ]) {
        expect(requiresTextConversion(type), isFalse, reason: 'type $type');
      }
    });
  });

  _typeMappingTests();

  test('an empty value is null regardless of type', () {
    expect(decodeFixed(type: Syb.int4, bytes: bytes(<int>[])), isNull);
    expect(decodeFixed(type: Syb.varchar, bytes: bytes(<int>[])), isNull);
  });
}

void _typeMappingTests() {
  group('logical type mapping', () {
    test('the families map as the bridge mapped them', () {
      expect(logicalTypeFor(Syb.bit), MssqlType.bit);
      expect(logicalTypeFor(Syb.bitn), MssqlType.bit);
      expect(logicalTypeFor(Syb.int4), MssqlType.int32);
      expect(logicalTypeFor(Syb.intn), MssqlType.int64);
      expect(logicalTypeFor(Syb.decimal), MssqlType.decimal);
      expect(logicalTypeFor(Syb.numeric), MssqlType.numeric);
      expect(logicalTypeFor(Syb.money), MssqlType.money);
      expect(logicalTypeFor(Syb.money4), MssqlType.smallMoney);
      expect(logicalTypeFor(Syb.msdate), MssqlType.date);
      expect(logicalTypeFor(Syb.bigtime), MssqlType.time);
      expect(logicalTypeFor(Syb.datetime4), MssqlType.smallDateTime);
      expect(logicalTypeFor(Syb.msdatetime2), MssqlType.dateTime2);
      expect(logicalTypeFor(Syb.msdatetimeoffset), MssqlType.dateTimeOffset);
    });

    test('an unknown type falls back to varchar, as the bridge did', () {
      expect(logicalTypeFor(9999), MssqlType.varchar);
    });
  });
}

