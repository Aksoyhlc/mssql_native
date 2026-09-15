import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mssql_native/mssql_native.dart';

import '../support/android_context.dart';

/// Types, parameters and BLOBs.
///
/// Worth running here rather than trusting the desktop result: every value
/// crosses the FFI boundary through dbconvert on a 32/64-bit-clean but
/// differently-aligned ABI, and arm64 is not x86_64.
void registerTypeTests() {
  group('types, decimals and BLOBs', () {
    late MssqlConnection asDouble;
    late MssqlConnection asText;

    setUpAll(() async {
      asDouble = await sharedConnection();
      // The exact-decimal half of this group needs the convenience turned off.
      asText = await MssqlConnection.open(
        androidConfig(decimalMode: MssqlDecimalMode.text),
      );
    });

    tearDownAll(() async => asText.close());

    testWidgets('a seeded row decodes every column to its Dart type', (
      _,
    ) async {
      final row = await asDouble.querySingle(
        'SELECT id, name, price, cost, weight_kg, stock_qty, is_active, '
        'rowguid, thumbnail, created_at FROM dbo.products WHERE sku = @sku',
        parameters: [MssqlParameter.varchar('sku', 'DSK-LMP-001', size: 24)],
      );
      expect(row['name'], 'Işıklı Masa Lambası');
      expect(row['id'], isA<int>());
      expect(row['price'], isA<double>(), reason: 'MONEY, decimalAsDouble on');
      expect(row['cost'], isA<double>(), reason: 'DECIMAL(18,4)');
      expect(row['weight_kg'], isA<double>(), reason: 'FLOAT');
      expect(row['stock_qty'], isA<int>(), reason: 'SMALLINT');
      expect(row['is_active'], true, reason: 'BIT');
      expect(row['rowguid'], matches(RegExp(r'^[0-9A-Fa-f-]{36}$')));
      expect(row['thumbnail'], isA<Uint8List>());
      expect(
        row['thumbnail'],
        equals(Uint8List.fromList(<int>[0x1A, 0x2B, 0x3C, 0x4D])),
      );
      expect(row['created_at'], isA<MssqlDateTimeValue>());
    });

    testWidgets('null columns decode as null', (_) async {
      final row = await asDouble.querySingle(
        'SELECT grammage, barcode, thumbnail FROM dbo.products WHERE sku = @sku',
        parameters: [MssqlParameter.varchar('sku', 'PPR-A4C-101', size: 24)],
      );
      expect(row['grammage'], isNull, reason: 'REAL null');
      expect(row['thumbnail'], isNull, reason: 'VARBINARY null');
    });

    testWidgets('decimal, numeric, money and smallmoney all arrive as double', (
      _,
    ) async {
      final row = await asDouble.querySingle('''
SELECT CAST(19.99 AS DECIMAL(18,4)) AS d,
       CAST(19.99 AS NUMERIC(18,4)) AS n,
       CAST(19.99 AS MONEY) AS m,
       CAST(19.99 AS SMALLMONEY) AS s
''');
      for (final key in const <String>['d', 'n', 'm', 's']) {
        expect(row[key], isA<double>(), reason: key);
        expect(row[key], closeTo(19.99, 1e-9), reason: key);
      }
    });

    testWidgets('with the option off, the same columns are exact text', (
      _,
    ) async {
      final row = await asText.querySingle(
        'SELECT CAST(19.99 AS DECIMAL(18,4)) AS d, CAST(19.99 AS MONEY) AS m',
      );
      expect(row['d'], '19.9900');
      expect(row['m'], isA<String>());
    });

    testWidgets('the option changes nothing but the numeric families', (
      _,
    ) async {
      // uniqueidentifier and dates travel the same dbconvert path, and turning
      // them into numbers would be nonsense.
      final row = await asDouble.querySingle('''
SELECT CAST('6F9619FF-8B86-D011-B42D-00C04FC964FF' AS UNIQUEIDENTIFIER) AS g,
       CAST('2026-03-09' AS DATE) AS d,
       CAST(1 AS INT) AS i,
       CAST(1.5 AS FLOAT) AS f
''');
      expect(row['g'], isA<String>());
      expect(row['d'], isA<MssqlDateTimeValue>());
      expect(row['i'], isA<int>());
      expect(row['f'], isA<double>());
    });

    testWidgets('exact decimal(38,10) precision, no rounding', (_) async {
      const value = '1234567890123456789012345678.1234567890';
      final row = await asText.querySingle(
        'SELECT CAST(@v AS DECIMAL(38,10)) AS d',
        parameters: [
          MssqlParameter.decimal('v', value, precision: 38, scale: 10),
        ],
      );
      expect(row['d'], value);
    });

    testWidgets('what the default costs, stated rather than implied', (
      _,
    ) async {
      // Eighteen significant digits do not fit in a double. This is the
      // trade-off the option makes; decimalMode: MssqlDecimalMode.text is how to avoid it.
      const exact = '99999999999999.9999';
      final rounded = await asDouble.querySingle(
        'SELECT CAST(@v AS DECIMAL(18,4)) AS d',
        parameters: [
          MssqlParameter.decimal('v', exact, precision: 18, scale: 4),
        ],
      );
      final kept = await asText.querySingle(
        'SELECT CAST(@v AS DECIMAL(18,4)) AS d',
        parameters: [
          MssqlParameter.decimal('v', exact, precision: 18, scale: 4),
        ],
      );
      expect(kept['d'], exact);
      expect(rounded['d'], isA<double>());
      expect(rounded['d'].toString(), isNot(exact));
    });

    testWidgets('money boundaries round-trip exactly', (_) async {
      for (final v in const <String>[
        '922337203685477.5807',
        '-922337203685477.5808',
        '0.0000',
        '19.9900',
      ]) {
        final row = await asText.querySingle(
          'SELECT CAST(@v AS MONEY) AS m',
          parameters: [
            MssqlParameter.raw(name: 'v', type: MssqlType.money, value: v),
          ],
        );
        expect(
          double.parse(row['m'].toString()),
          double.parse(v),
          reason: 'money $v',
        );
      }
    });

    testWidgets('bigint min/max round-trip', (_) async {
      // The one that would expose a 32-bit truncation on arm.
      final row = await asDouble.querySingle(
        'SELECT @lo AS lo, @hi AS hi',
        parameters: [
          MssqlParameter.int64('lo', -9223372036854775808),
          MssqlParameter.int64('hi', 9223372036854775807),
        ],
      );
      expect(row['lo'], -9223372036854775808);
      expect(row['hi'], 9223372036854775807);
    });

    testWidgets('datetimeoffset preserves the timezone offset', (_) async {
      // The device has its own timezone; the value must not pick it up.
      const value = MssqlDateTimeValue(
        year: 2026,
        month: 3,
        day: 14,
        hour: 9,
        minute: 30,
        second: 15,
        nanosecond: 123456700,
        timezoneOffsetMinutes: 180,
      );
      final row = await asDouble.querySingle(
        'SELECT CAST(@v AS DATETIMEOFFSET(7)) AS dto',
        parameters: [
          MssqlParameter.raw(
            name: 'v',
            type: MssqlType.dateTimeOffset,
            value: value,
            scale: 7,
          ),
        ],
      );
      final got = row['dto'] as MssqlDateTimeValue;
      expect(got.year, 2026);
      expect(got.month, 3);
      expect(got.day, 14);
      expect(got.hour, 9);
      expect(got.minute, 30);
      expect(got.second, 15);
      expect(got.timezoneOffsetMinutes, 180);
    });

    testWidgets('the minimum DATE round-trips', (_) async {
      final row = await asDouble.querySingle(
        'SELECT CAST(@d AS DATE) AS d',
        parameters: [
          MssqlParameter.raw(
            name: 'd',
            type: MssqlType.date,
            value: const MssqlDateTimeValue(year: 1, month: 1, day: 1),
          ),
        ],
      );
      final d = row['d'] as MssqlDateTimeValue;
      expect(d.year, 1);
      expect(d.month, 1);
      expect(d.day, 1);
    });

    testWidgets('a 1 MB varbinary(max) BLOB round-trips byte-for-byte', (
      _,
    ) async {
      // A megabyte through the FFI boundary on a device with a tighter heap
      // than a CI runner, read back and compared byte by byte.
      final blob = Uint8List(1024 * 1024);
      for (var i = 0; i < blob.length; i++) {
        blob[i] = (i * 31 + 7) & 0xFF;
      }
      await dropTable(asDouble, 'dbo.and_blob');
      await asDouble.execute(
        'CREATE TABLE dbo.and_blob (id INT IDENTITY PRIMARY KEY, b VARBINARY(MAX) NOT NULL)',
      );
      addTearDown(() => dropTable(asDouble, 'dbo.and_blob'));

      await asDouble.execute(
        'INSERT INTO dbo.and_blob (b) VALUES (@b)',
        parameters: [MssqlParameter.varbinary('b', blob, size: 0)],
      );
      final row = await asDouble.querySingle(
        'SELECT b, DATALENGTH(b) AS len FROM dbo.and_blob',
      );
      expect(row['len'], blob.length);
      final read = row['b'] as Uint8List;
      expect(read.length, blob.length);
      var equal = true;
      for (var i = 0; i < blob.length; i++) {
        if (read[i] != blob[i]) {
          equal = false;
          break;
        }
      }
      expect(equal, isTrue, reason: '1 MB BLOB must round-trip byte-for-byte');
    });

    testWidgets('NULLs for the financial and blob types', (_) async {
      final row = await asDouble.querySingle(
        'SELECT CAST(@d AS DECIMAL(18,2)) AS d, CAST(@m AS MONEY) AS m, '
        'CAST(@b AS VARBINARY(MAX)) AS b, CAST(@dt AS DATETIMEOFFSET) AS dt',
        parameters: [
          MssqlParameter.decimal('d', null, precision: 18, scale: 2),
          MssqlParameter.raw(name: 'm', type: MssqlType.money, value: null),
          MssqlParameter.varbinary('b', null, size: 0),
          MssqlParameter.raw(
            name: 'dt',
            type: MssqlType.dateTimeOffset,
            value: null,
          ),
        ],
      );
      expect(row['d'], isNull);
      expect(row['m'], isNull);
      expect(row['b'], isNull);
      expect(row['dt'], isNull);
    });
  });
}
