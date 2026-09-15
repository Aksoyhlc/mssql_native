import 'dart:typed_data';

import 'package:mssql_native/src/models/parameter.dart';
import 'package:mssql_native/src/models/types.dart';
import 'package:mssql_native/src/native/dblib.dart';
import 'package:mssql_native/src/native/parameter_binder.dart';
import 'package:test/test.dart';

void main() {
  group('parameterName', () {
    test('adds the @ SQL Server requires', () {
      expect(parameterName(MssqlParameter.int32('id', 1)), '@id');
    });

    test('does not double it up when the caller already wrote one', () {
      expect(parameterName(MssqlParameter.int32('@id', 1)), '@id');
    });

    test('can strip it, for the RPC parameter name', () {
      expect(
        parameterName(MssqlParameter.int32('@id', 1), withAt: false),
        'id',
      );
      expect(parameterName(MssqlParameter.int32('id', 1), withAt: false), 'id');
    });
  });

  group('sqlTypeOf', () {
    test('decimal and numeric carry precision and scale', () {
      expect(
        sqlTypeOf(
          MssqlParameter.decimal('amount', '1.5', precision: 18, scale: 4),
        ),
        'decimal(18,4)',
      );
    });

    test('an unsized varchar or nvarchar becomes (max)', () {
      for (final type in <MssqlType>[MssqlType.varchar, MssqlType.nvarchar]) {
        expect(
          sqlTypeOf(MssqlParameter.raw(name: 'a', type: type, value: 'x')),
          type == MssqlType.varchar ? 'varchar(max)' : 'nvarchar(max)',
        );
      }
    });

    test('a declared size is used', () {
      expect(
        sqlTypeOf(MssqlParameter.varchar('a', 'x', size: 50)),
        'varchar(50)',
      );
    });

    test('every logical type produces a type name', () {
      for (final type in MssqlType.values) {
        final declared = sqlTypeOf(
          MssqlParameter.raw(
            name: 'p',
            type: type,
            value: null,
            size: 10,
            precision: 18,
            scale: 4,
          ),
        );
        expect(declared, isNotEmpty, reason: '$type');
        expect(declared, isNot(contains('null')), reason: '$type');
      }
    });
  });

  group('sqlDeclaration', () {
    test('input parameters carry no OUTPUT', () {
      expect(sqlDeclaration(MssqlParameter.int32('id', 1)), '@id int');
    });

    test('output and inputOutput both carry OUTPUT', () {
      expect(
        sqlDeclaration(
          MssqlParameter.raw(
            name: 'total',
            type: MssqlType.int32,
            value: null,
            direction: MssqlParameterDirection.output,
          ),
        ),
        '@total int OUTPUT',
      );
      expect(
        sqlDeclaration(
          MssqlParameter.raw(
            name: 'total',
            type: MssqlType.int32,
            value: 1,
            direction: MssqlParameterDirection.inputOutput,
          ),
        ),
        '@total int OUTPUT',
      );
    });
  });

  test('sqlDeclarations joins with the comma sp_executesql expects', () {
    expect(
      sqlDeclarations(<MssqlParameter>[
        MssqlParameter.int32('id', 1),
        MssqlParameter.nvarchar('name', 'a', size: 50),
      ]),
      '@id int, @name nvarchar(50)',
    );
  });

  _encodeTests();

  test('an empty parameter list produces an empty string', () {
    expect(sqlDeclarations(const <MssqlParameter>[]), '');
  });

  group('zero-length values', () {
    test('an empty string is recognised, a null is not', () {
      expect(isEmptyValue(MssqlParameter.nvarchar('a', '', size: 10)), isTrue);
      expect(
        isEmptyValue(MssqlParameter.nvarchar('a', null, size: 10)),
        isFalse,
      );
      expect(
        isEmptyValue(MssqlParameter.nvarchar('a', 'x', size: 10)),
        isFalse,
      );
    });

    test('an empty blob is recognised', () {
      expect(
        isEmptyValue(MssqlParameter.varbinary('a', Uint8List(0), size: 10)),
        isTrue,
      );
      expect(
        isEmptyValue(MssqlParameter.varbinary('a', Uint8List(1), size: 10)),
        isFalse,
      );
    });

    test('a non-text value is never empty', () {
      expect(isEmptyValue(MssqlParameter.int32('a', 0)), isFalse);
      expect(isEmptyValue(MssqlParameter.bit('a', false)), isFalse);
    });

    test('the prelude assigns the right literal per type', () {
      expect(
        emptyValuePrelude(<MssqlParameter>[
          MssqlParameter.nvarchar('name', '', size: 10),
        ]),
        "SET @name = N''; ",
      );
      expect(
        emptyValuePrelude(<MssqlParameter>[
          MssqlParameter.varbinary('blob', Uint8List(0), size: 10),
        ]),
        'SET @blob = 0x; ',
      );
    });

    test('several empty parameters each get a statement', () {
      expect(
        emptyValuePrelude(<MssqlParameter>[
          MssqlParameter.nvarchar('a', '', size: 10),
          MssqlParameter.int32('b', 1),
          MssqlParameter.varchar('c', '', size: 10),
        ]),
        "SET @a = N''; SET @c = N''; ",
      );
    });

    test('nothing is prepended when no value is empty', () {
      expect(
        emptyValuePrelude(<MssqlParameter>[
          MssqlParameter.int32('a', 1),
          MssqlParameter.nvarchar('b', 'x', size: 10),
        ]),
        '',
      );
      expect(emptyValuePrelude(const <MssqlParameter>[]), '');
    });

    test('a name the caller already wrote with a sigil is not doubled', () {
      expect(
        emptyValuePrelude(<MssqlParameter>[
          MssqlParameter.nvarchar('@a', '', size: 10),
        ]),
        "SET @a = N''; ",
      );
    });
  });
}

void _encodeTests() {
  group('encodeParameter', () {
    test('integers are little-endian and truncated to their width', () {
      final p = encodeParameter(MssqlParameter.int32('id', 258));
      expect(p.nativeType, Syb.int4);
      expect(p.dataLength, 4);
      expect(p.bytes, Uint8List.fromList([0x02, 0x01, 0, 0]));
      expect(p.maxLength, -1, reason: 'input parameters must pass -1');
    });

    test('a bit becomes one byte', () {
      expect(
        encodeParameter(MssqlParameter.bit('f', true)).bytes,
        Uint8List.fromList([1]),
      );
      expect(
        encodeParameter(MssqlParameter.bit('f', false)).bytes,
        Uint8List.fromList([0]),
      );
    });

    test('a null carries no bytes and zero length', () {
      final p = encodeParameter(MssqlParameter.int32('id', null));
      expect(p.bytes, isNull);
      expect(p.dataLength, 0);
    });

    test('short strings go as SYBVARCHAR, not SYBNVARCHAR', () {
      final p = encodeParameter(
        MssqlParameter.nvarchar('name', 'İstanbul', size: 50),
      );
      expect(p.nativeType, Syb.varchar);
    });

    test('long unicode is promoted to SYBNTEXT', () {
      final long = 'a' * 5000;
      final p = encodeParameter(
        MssqlParameter.nvarchar('name', long, size: 8000),
      );
      expect(p.nativeType, Syb.ntext);
      expect(p.dataLength, 5000);
    });

    test('an unsized string counts as large', () {
      final p = encodeParameter(
        MssqlParameter.raw(name: 'name', type: MssqlType.nvarchar, value: 'x'),
      );
      expect(p.nativeType, Syb.ntext);
    });

    test('long 8-bit text is promoted to SYBTEXT', () {
      final p = encodeParameter(
        MssqlParameter.raw(
          name: 'name',
          type: MssqlType.varchar,
          value: 'a' * 5000,
        ),
      );
      expect(p.nativeType, Syb.text);
    });

    test('binary over 8000 bytes is promoted to SYBIMAGE', () {
      final big = Uint8List(9000);
      final p = encodeParameter(
        MssqlParameter.varbinary('blob', big, size: 9000),
      );
      expect(p.nativeType, Syb.image);
      expect(p.dataLength, 9000);
    });

    test('small sized binary stays SYBVARBINARY', () {
      final p = encodeParameter(
        MssqlParameter.varbinary(
          'blob',
          Uint8List.fromList([1, 2, 3]),
          size: 10,
        ),
      );
      expect(p.nativeType, Syb.varbinary);
    });

    test('output parameters carry DBRPCRETURN and a return buffer size', () {
      final p = encodeParameter(
        MssqlParameter.raw(
          name: 'name',
          type: MssqlType.nvarchar,
          value: 'x',
          size: 50,
          direction: MssqlParameterDirection.output,
        ),
      );
      expect(p.status, dbRpcReturn);
      expect(p.maxLength, 200);
    });

    test('a fixed-type output still passes -1', () {
      final p = encodeParameter(
        MssqlParameter.raw(
          name: 'total',
          type: MssqlType.int32,
          value: 1,
          direction: MssqlParameterDirection.output,
        ),
      );
      expect(p.status, dbRpcReturn);
      expect(p.maxLength, -1);
    });
  });

  group('parameterText', () {
    MssqlParameter dated(MssqlType type, MssqlDateTimeValue v) =>
        MssqlParameter.raw(name: 'd', type: type, value: v, scale: 7);

    const value = MssqlDateTimeValue(
      year: 2026,
      month: 3,
      day: 9,
      hour: 7,
      minute: 5,
      second: 4,
      nanosecond: 123456789,
      timezoneOffsetMinutes: -150,
    );

    test('date drops the time', () {
      expect(parameterText(dated(MssqlType.date, value)), '2026-03-09');
    });

    test('time honors SQL Server scale instead of emitting nine digits', () {
      expect(parameterText(dated(MssqlType.time, value)), '07:05:04.1234567');
    });

    test('datetime2 is ISO without an offset', () {
      expect(
        parameterText(dated(MssqlType.dateTime2, value)),
        '2026-03-09T07:05:04.1234567',
      );
    });

    test('a negative offset is signed and split into hours and minutes', () {
      expect(
        parameterText(dated(MssqlType.dateTimeOffset, value)),
        '2026-03-09T07:05:04.1234567-02:30',
      );
    });

    test('scale zero omits the decimal separator', () {
      final p = MssqlParameter.raw(
        name: 'd',
        type: MssqlType.dateTime2,
        value: value,
        scale: 0,
      );
      expect(parameterText(p), '2026-03-09T07:05:04');
    });

    test('BCP uses the space separator FreeTDS parses', () {
      expect(
        bulkParameterText(dated(MssqlType.dateTime2, value)),
        '2026-03-09 07:05:04.1234567',
      );
      expect(
        bulkParameterText(dated(MssqlType.dateTimeOffset, value)),
        '2026-03-09 07:05:04.1234567-02:30',
      );
    });
  });
}

