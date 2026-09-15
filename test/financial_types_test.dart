
import 'dart:io';
import 'dart:typed_data';

import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

String? _e(String k) => Platform.environment[k];

MssqlConnectionConfig _config() => MssqlConnectionConfig(
  host: _e('MSSQL_NATIVE_HOST') ?? '127.0.0.1',
  port: int.parse(_e('MSSQL_NATIVE_PORT') ?? '1433'),
  database: _e('MSSQL_NATIVE_DB') ?? 'mssql_native_test',
  username: _e('MSSQL_NATIVE_USER') ?? 'sa',
  password: _e('MSSQL_NATIVE_PASSWORD') ?? 'Mssql@Native2026',
  encryption: MssqlEncryption.off,
  defaultQueryTimeout: const Duration(seconds: 60),
  decimalMode: MssqlDecimalMode.text,
);

void main() {
  final live = _e('MSSQL_NATIVE_LIVE') == '1';
  final skip = live
      ? null
      : 'Set MSSQL_NATIVE_LIVE=1 with a reachable SQL Server to run.';

  group('financial, types & BLOB', () {
    late MssqlConnection conn;

    setUpAll(() async {
      await MssqlRuntime.instance.initialize(
        bridgePath: _e('MSSQL_NATIVE_BRIDGE'),
        sybdbPath: _e('MSSQL_NATIVE_SYBDB'),
      );
      conn = await MssqlConnection.open(_config());
    });

    tearDownAll(() async {
      await conn.close();
      await MssqlRuntime.instance.shutdown();
    });

    test('exact decimal(38,10) precision, no rounding', () async {
      const value = '1234567890123456789012345678.1234567890';
      final row = await conn.querySingle(
        'SELECT CAST(@v AS DECIMAL(38,10)) AS d',
        parameters: [
          MssqlParameter.decimal('v', value, precision: 38, scale: 10),
        ],
      );
      expect(row['d'], value);
    });

    test('money boundaries round-trip exactly', () async {
      for (final v in const [
        '922337203685477.5807',
        '-922337203685477.5808',
        '0.0000',
        '19.9900',
      ]) {
        final row = await conn.querySingle(
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

    test('bigint min/max round-trip', () async {
      final row = await conn.querySingle(
        'SELECT @lo AS lo, @hi AS hi',
        parameters: [
          MssqlParameter.int64('lo', -9223372036854775808),
          MssqlParameter.int64('hi', 9223372036854775807),
        ],
      );
      expect(row['lo'], -9223372036854775808);
      expect(row['hi'], 9223372036854775807);
    });

    test('datetimeoffset preserves the timezone offset', () async {
      final value = const MssqlDateTimeValue(
        year: 2026,
        month: 3,
        day: 14,
        hour: 9,
        minute: 30,
        second: 15,
        nanosecond: 123456700,
        timezoneOffsetMinutes: 180,
      );
      final row = await conn.querySingle(
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

    test('date and time boundaries', () async {
      final minDate = await conn.querySingle(
        'SELECT CAST(@d AS DATE) AS d',
        parameters: [
          MssqlParameter.raw(
            name: 'd',
            type: MssqlType.date,
            value: const MssqlDateTimeValue(year: 1, month: 1, day: 1),
          ),
        ],
      );
      final d = minDate['d'] as MssqlDateTimeValue;
      expect(d.year, 1);
      expect(d.month, 1);
      expect(d.day, 1);
    });

    test(
      'emoji and surrogate-pair Unicode round-trip (RPC parameter)',
      () async {
        const text = 'Deneme 🧿 İstek ğüşöç 😀 örnek';
        final row = await conn.querySingle(
          'SELECT CAST(@t AS NVARCHAR(100)) AS t',
          parameters: [MssqlParameter.nvarchar('t', text, size: 100)],
        );
        expect(row['t'], text);
      },
    );

    test('emoji and surrogate-pair Unicode round-trip (BCP)', () async {
      await conn.execute(
        "IF OBJECT_ID('dbo.uc_blob') IS NOT NULL DROP TABLE dbo.uc_blob",
      );
      await conn.execute(
        'CREATE TABLE dbo.uc_blob (id INT IDENTITY PRIMARY KEY, t NVARCHAR(100) NOT NULL)',
      );
      try {
        const text = 'Emoji 😀🧿🇹🇷 karışık İstek ğ';
        await conn.bulkInsert(
          tableName: 'dbo.uc_blob',
          columns: const [
            MssqlBulkColumn(
              ordinal: 2,
              name: 't',
              type: MssqlType.nvarchar,
              size: 100,
            ),
          ],
          rows: [
            [MssqlParameter.nvarchar('t', text, size: 100)],
          ],
        );
        final row = await conn.querySingle('SELECT t FROM dbo.uc_blob');
        expect(row['t'], text);
      } finally {
        await conn.execute(
          "IF OBJECT_ID('dbo.uc_blob') IS NOT NULL DROP TABLE dbo.uc_blob",
        );
      }
    });

    test('large varbinary(max) BLOB round-trips byte-for-byte (1 MB)', () async {
      final blob = Uint8List(1024 * 1024);
      for (var i = 0; i < blob.length; i++) {
        blob[i] = (i * 31 + 7) & 0xFF;
      }
      await conn.execute(
        "IF OBJECT_ID('dbo.blob_t') IS NOT NULL DROP TABLE dbo.blob_t",
      );
      await conn.execute(
        'CREATE TABLE dbo.blob_t (id INT IDENTITY PRIMARY KEY, b VARBINARY(MAX) NOT NULL)',
      );
      try {
        await conn.execute(
          'INSERT INTO dbo.blob_t (b) VALUES (@b)',
          parameters: [MssqlParameter.varbinary('b', blob, size: 0)],
        );
        final row = await conn.querySingle(
          'SELECT b, DATALENGTH(b) AS len FROM dbo.blob_t',
        );
        expect(row['len'], blob.length);
        final read = row['b'] as Uint8List;
        expect(read.length, blob.length);
        expect(read[0], blob[0]);
        expect(read[blob.length ~/ 2], blob[blob.length ~/ 2]);
        expect(read[blob.length - 1], blob[blob.length - 1]);
        var equal = true;
        for (var i = 0; i < blob.length; i++) {
          if (read[i] != blob[i]) {
            equal = false;
            break;
          }
        }
        expect(
          equal,
          isTrue,
          reason: '1 MB BLOB must round-trip byte-for-byte',
        );
      } finally {
        await conn.execute(
          "IF OBJECT_ID('dbo.blob_t') IS NOT NULL DROP TABLE dbo.blob_t",
        );
      }
    });

    test('large nvarchar(max) text round-trips (200k chars)', () async {
      final big = ('Kayıt-Örn-😀-' * 20000);
      final row = await conn.querySingle(
        'SELECT LEN(@t) AS n, CAST(@t AS NVARCHAR(MAX)) AS t',
        parameters: [MssqlParameter.nvarchar('t', big, size: 0)],
      );
      expect(row['t'], big);
    });

    test('NULLs for financial and blob types', () async {
      final row = await conn.querySingle(
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
  }, skip: skip);

  group('decimalAsDouble', () {
    late MssqlConnection asDouble;
    late MssqlConnection asText;

    setUpAll(() async {
      await MssqlRuntime.instance.initialize(
        bridgePath: _e('MSSQL_NATIVE_BRIDGE'),
        sybdbPath: _e('MSSQL_NATIVE_SYBDB'),
      );
      final base = _config();
      asDouble = await MssqlConnection.open(
        MssqlConnectionConfig(
          host: base.host,
          port: base.port,
          database: base.database,
          username: base.username,
          password: base.password,
          encryption: MssqlEncryption.off,
          decimalMode: MssqlDecimalMode.doublePrecision,
        ),
      );
      asText = await MssqlConnection.open(_config());
    });

    tearDownAll(() async {
      await asDouble.close();
      await asText.close();
      await MssqlRuntime.instance.shutdown();
    });

    test(
      'decimal, numeric, money and smallmoney all arrive as double',
      () async {
        final row = await asDouble.querySingle('''
SELECT CAST(19.99 AS DECIMAL(18,4)) AS d,
       CAST(19.99 AS NUMERIC(18,4)) AS n,
       CAST(19.99 AS MONEY) AS m,
       CAST(19.99 AS SMALLMONEY) AS s
''');
        for (final key in const ['d', 'n', 'm', 's']) {
          expect(row[key], isA<double>(), reason: key);
          expect(row[key], closeTo(19.99, 1e-9), reason: key);
        }
      },
    );

    test('off, the same columns are exact text', () async {
      final row = await asText.querySingle(
        'SELECT CAST(19.99 AS DECIMAL(18,4)) AS d, CAST(19.99 AS MONEY) AS m',
      );
      expect(row['d'], '19.9900');
      expect(row['m'], isA<String>());
    });

    test('the option changes nothing but the numeric families', () async {
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

    test('what the default costs, stated rather than implied', () async {
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

    test('a double read back can be written straight back', () async {
      final row = await asDouble.querySingle(
        'SELECT CAST(1234.5678 AS DECIMAL(18,4)) AS d',
      );
      final value = row['d'] as double;
      final back = await asDouble.querySingle(
        'SELECT CAST(@v AS DECIMAL(18,4)) AS d',
        parameters: [
          MssqlParameter.decimal('v', value, precision: 18, scale: 4),
        ],
      );
      expect(back['d'], closeTo(1234.5678, 1e-9));
    });
  }, skip: skip);
}

