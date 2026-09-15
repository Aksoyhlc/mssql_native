import 'dart:typed_data';

import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_native/src/native/dblib.dart';
import 'package:mssql_native/src/native/parameter_binder.dart';
import 'package:mssql_native/src/native/value_decoder.dart';
import 'package:test/test.dart';

void main() {
  group('bulk column definitions', () {
    MssqlBulkColumn column({
      int ordinal = 1,
      String name = 'qty',
      MssqlType type = MssqlType.int32,
      int size = 0,
      int precision = 0,
      int scale = 0,
    }) => MssqlBulkColumn(
      ordinal: ordinal,
      name: name,
      type: type,
      size: size,
      precision: precision,
      scale: scale,
    );

    test('ordinals are one-based, as BCP counts them', () {
      expect(() => column(ordinal: 0).validate(), throwsRangeError);
      expect(() => column(ordinal: -3).validate(), throwsRangeError);
      expect(() => column(ordinal: 1).validate(), returnsNormally);
    });

    test('names must be plain identifiers', () {
      for (final name in <String>[
        '',
        '1qty',
        'qty;DROP TABLE x',
        'qty col',
        'qty-col',
        '[qty]',
        'qty)--',
      ]) {
        expect(
          () => column(name: name).validate(),
          throwsArgumentError,
          reason: 'name "$name"',
        );
      }
    });

    test('underscores and digits after the first character are fine', () {
      for (final name in <String>['qty', '_qty', 'qty_2', 'QtyOnHand', 'a1']) {
        expect(
          () => column(name: name).validate(),
          returnsNormally,
          reason: 'name "$name"',
        );
      }
    });

    test('a 128-character name is allowed and 129 is not', () {
      expect(() => column(name: 'a${'b' * 127}').validate(), returnsNormally);
      expect(
        () => column(name: 'a${'b' * 128}').validate(),
        throwsArgumentError,
      );
    });

    test('a negative size is refused', () {
      expect(
        () => column(size: -1, type: MssqlType.varchar).validate(),
        throwsRangeError,
      );
    });

    test('decimal and numeric require a precision', () {
      for (final type in <MssqlType>[MssqlType.decimal, MssqlType.numeric]) {
        expect(
          () => column(type: type).validate(),
          throwsArgumentError,
          reason: '$type',
        );
        expect(
          () => column(type: type, precision: 18, scale: 4).validate(),
          returnsNormally,
          reason: '$type',
        );
      }
    });

    test('precision is capped at 38, SQL Server\'s maximum', () {
      expect(
        () => column(precision: 39, scale: 0).validate(),
        throwsRangeError,
      );
      expect(() => column(precision: 38, scale: 0).validate(), returnsNormally);
    });

    test('scale cannot exceed precision', () {
      expect(() => column(precision: 5, scale: 6).validate(), throwsRangeError);
      expect(() => column(precision: 5, scale: 5).validate(), returnsNormally);
    });
  });

  group('bulk options', () {
    test('a batch size below one is refused', () {
      expect(
        () => const MssqlBulkOptions(batchSize: 0).validate(),
        throwsRangeError,
      );
      expect(
        () => const MssqlBulkOptions(batchSize: -100).validate(),
        throwsRangeError,
      );
    });

    test('a non-positive timeout is refused', () {
      expect(
        () => const MssqlBulkOptions(timeout: Duration.zero).validate(),
        throwsArgumentError,
      );
      expect(
        () => const MssqlBulkOptions(timeout: Duration(seconds: -1)).validate(),
        throwsArgumentError,
      );
    });

    test('the defaults are the ones the driver documents', () {
      const options = MssqlBulkOptions();
      expect(options.mode, MssqlBulkMode.atomic);
      expect(options.batchSize, 1000);
      expect(options.keepNulls, isFalse);
      expect(options.tableLock, isFalse);
      expect(options.checkConstraints, isFalse);
      expect(options.fireTriggers, isFalse);
    });
  });

  group('parameters', () {
    test('a decimal keeps its text form rather than becoming a double', () {
      final p = MssqlParameter.decimal(
        'amount',
        '99999999999999.9999',
        precision: 18,
        scale: 4,
      );
      expect(p.value, isA<String>());
      expect(p.value, '99999999999999.9999');
    });

    test('null is a legal value for every factory', () {
      expect(MssqlParameter.int32('a', null).value, isNull);
      expect(MssqlParameter.int64('a', null).value, isNull);
      expect(MssqlParameter.bit('a', null).value, isNull);
      expect(MssqlParameter.float64('a', null).value, isNull);
      expect(MssqlParameter.varchar('a', null, size: 10).value, isNull);
      expect(MssqlParameter.nvarchar('a', null, size: 10).value, isNull);
      expect(MssqlParameter.varbinary('a', null, size: 10).value, isNull);
      expect(MssqlParameter.guid('a', null).value, isNull);
      expect(MssqlParameter.dateTime2('a', null).value, isNull);
    });

    test('binary values are kept as bytes, not text', () {
      final bytes = Uint8List.fromList(<int>[0, 255, 10, 13, 26]);
      final p = MssqlParameter.varbinary('blob', bytes, size: 8);
      expect(p.value, same(bytes));
    });

    test('a byte sequence that is not valid UTF-8 is still acceptable', () {
      final p = MssqlParameter.varbinary(
        'blob',
        Uint8List.fromList(<int>[0xFF, 0xFE, 0x00]),
        size: 4,
      );
      expect((p.value as Uint8List).length, 3);
    });

    test('direction defaults to input', () {
      expect(
        MssqlParameter.int32('a', 1).direction,
        MssqlParameterDirection.input,
      );
    });
  });

  group('parameter validation', () {
    test('a name with a sigil is accepted either way', () {
      expect(MssqlParameter.int32('@id', 1).validate, returnsNormally);
      expect(MssqlParameter.int32('id', 1).validate, returnsNormally);
    });

    test('names that are not identifiers are refused', () {
      for (final name in <String>[
        '',
        '@',
        '1st',
        'id col',
        'id;SELECT 1',
        "id'--",
        'id)',
        '@@version',
      ]) {
        expect(
          MssqlParameter.int32(name, 1).validate,
          throwsArgumentError,
          reason: 'name "$name"',
        );
      }
    });

    test('integer ranges are checked per width, not just per type', () {
      MssqlParameter tiny(int v) =>
          MssqlParameter.raw(name: 'p', type: MssqlType.tinyInt, value: v);
      expect(tiny(0).validate, returnsNormally);
      expect(tiny(255).validate, returnsNormally);
      expect(tiny(256).validate, throwsArgumentError);
      expect(tiny(-1).validate, throwsArgumentError);

      MssqlParameter small(int v) =>
          MssqlParameter.raw(name: 'p', type: MssqlType.smallInt, value: v);
      expect(small(-32768).validate, returnsNormally);
      expect(small(32767).validate, returnsNormally);
      expect(small(32768).validate, throwsArgumentError);
      expect(small(-32769).validate, throwsArgumentError);

      expect(MssqlParameter.int32('p', 2147483647).validate, returnsNormally);
      expect(
        MssqlParameter.int32('p', 2147483648).validate,
        throwsArgumentError,
      );
      expect(
        MssqlParameter.int32('p', -2147483649).validate,
        throwsArgumentError,
      );
    });

    test('a value of the wrong Dart type is refused', () {
      expect(
        MssqlParameter.raw(name: 'p', type: MssqlType.bit, value: 1).validate,
        throwsArgumentError,
        reason: 'bit wants a bool, not 1',
      );
      expect(
        MssqlParameter.raw(
          name: 'p',
          type: MssqlType.int64,
          value: '5',
        ).validate,
        throwsArgumentError,
      );
      expect(
        MssqlParameter.raw(
          name: 'p',
          type: MssqlType.varchar,
          value: 5,
          size: 10,
        ).validate,
        throwsArgumentError,
      );
      expect(
        MssqlParameter.raw(
          name: 'p',
          type: MssqlType.varbinary,
          value: 'x',
          size: 10,
        ).validate,
        throwsArgumentError,
      );
    });

    test('a float parameter accepts an int, since num covers both', () {
      expect(
        MssqlParameter.raw(
          name: 'p',
          type: MssqlType.float64,
          value: 5,
        ).validate,
        returnsNormally,
      );
    });

    test('a string longer than its declared size is refused', () {
      expect(
        MssqlParameter.varchar('p', 'abcdef', size: 5).validate,
        throwsArgumentError,
      );
      expect(
        MssqlParameter.varchar('p', 'abcde', size: 5).validate,
        returnsNormally,
      );
    });

    test('length is counted in runes, so an emoji is one character', () {
      expect(
        MssqlParameter.nvarchar('p', '🧿🧿', size: 2).validate,
        returnsNormally,
      );
      expect(
        MssqlParameter.nvarchar('p', '🧿🧿🧿', size: 2).validate,
        throwsArgumentError,
      );
    });

    test('a blob longer than its declared size is refused', () {
      expect(
        MssqlParameter.varbinary('p', Uint8List(9), size: 8).validate,
        throwsArgumentError,
      );
      expect(
        MssqlParameter.varbinary('p', Uint8List(8), size: 8).validate,
        returnsNormally,
      );
    });

    test('fixed-width types require a size', () {
      for (final type in <MssqlType>[
        MssqlType.char,
        MssqlType.nchar,
        MssqlType.binary,
      ]) {
        expect(
          MssqlParameter.raw(name: 'p', type: type, value: null).validate,
          throwsArgumentError,
          reason: '$type',
        );
      }
    });

    test('variable-length output parameters require a size', () {
      expect(
        MssqlParameter.raw(
          name: 'p',
          type: MssqlType.nvarchar,
          value: null,
          direction: MssqlParameterDirection.output,
        ).validate,
        throwsArgumentError,
      );
      expect(
        MssqlParameter.raw(
          name: 'p',
          type: MssqlType.nvarchar,
          value: null,
          size: 64,
          direction: MssqlParameterDirection.output,
        ).validate,
        returnsNormally,
      );
    });

    test('a fixed-width output parameter needs no size', () {
      expect(
        MssqlParameter.raw(
          name: 'total',
          type: MssqlType.int32,
          value: null,
          direction: MssqlParameterDirection.output,
        ).validate,
        returnsNormally,
      );
    });

    test('GUIDs must be canonical, with or without braces', () {
      const guid = '6F9619FF-8B86-D011-B42D-00C04FC964FF';
      expect(MssqlParameter.guid('p', guid).validate, returnsNormally);
      expect(MssqlParameter.guid('p', '{$guid}').validate, returnsNormally);
      expect(
        MssqlParameter.guid('p', guid.toLowerCase()).validate,
        returnsNormally,
      );
      for (final bad in <String>[
        '',
        'not-a-guid',
        '6F9619FF8B86D011B42D00C04FC964FF',
        '6F9619FF-8B86-D011-B42D-00C04FC964F',
        '6F9619FF-8B86-D011-B42D-00C04FC964FFF',
        '6F9619GG-8B86-D011-B42D-00C04FC964FF',
      ]) {
        expect(
          MssqlParameter.guid('p', bad).validate,
          throwsArgumentError,
          reason: 'guid "$bad"',
        );
      }
    });

    test('a date/time value must be a real calendar point', () {
      MssqlParameter dated(MssqlDateTimeValue v) => MssqlParameter.raw(
        name: 'p',
        type: MssqlType.dateTime2,
        value: v,
        scale: 7,
      );
      expect(
        dated(const MssqlDateTimeValue(year: 2026, month: 2, day: 28)).validate,
        returnsNormally,
      );
      expect(
        dated(const MssqlDateTimeValue(year: 2026, month: 13, day: 1)).validate,
        throwsArgumentError,
        reason: 'month 13',
      );
      expect(
        dated(const MssqlDateTimeValue(year: 2026, month: 2, day: 30)).validate,
        throwsArgumentError,
        reason: 'February 30th',
      );
      expect(
        dated(
          const MssqlDateTimeValue(year: 2026, month: 1, day: 1, hour: 24),
        ).validate,
        throwsArgumentError,
        reason: 'hour 24',
      );
      expect(
        dated(
          const MssqlDateTimeValue(
            year: 2026,
            month: 1,
            day: 1,
            nanosecond: 1000000000,
          ),
        ).validate,
        throwsArgumentError,
        reason: 'a full second of nanoseconds',
      );
    });

    test('a leap day is accepted in a leap year and refused otherwise', () {
      MssqlParameter feb29(int year) => MssqlParameter.raw(
        name: 'p',
        type: MssqlType.date,
        value: MssqlDateTimeValue(year: year, month: 2, day: 29),
      );
      expect(feb29(2024).validate, returnsNormally);
      expect(feb29(2000).validate, returnsNormally, reason: 'divisible by 400');
      expect(feb29(2026).validate, throwsArgumentError);
      expect(
        feb29(1900).validate,
        throwsArgumentError,
        reason: 'divisible by 100 but not 400',
      );
    });

    test('a timezone offset beyond SQL Server\'s range is refused', () {
      MssqlParameter offset(int minutes) => MssqlParameter.raw(
        name: 'p',
        type: MssqlType.dateTimeOffset,
        scale: 7,
        value: MssqlDateTimeValue(
          year: 2026,
          month: 1,
          day: 1,
          timezoneOffsetMinutes: minutes,
        ),
      );
      expect(offset(840).validate, returnsNormally, reason: '+14:00');
      expect(offset(-840).validate, returnsNormally, reason: '-14:00');
      expect(offset(841).validate, throwsArgumentError);
      expect(offset(-841).validate, throwsArgumentError);
    });
  });

  group('connection configuration', () {
    MssqlConnectionConfig config({
      String host = 'db.internal',
      int port = 1433,
      String database = 'app',
      String username = 'sa',
      Duration loginTimeout = const Duration(seconds: 10),
      Duration queryTimeout = const Duration(seconds: 30),
    }) => MssqlConnectionConfig(
      host: host,
      port: port,
      database: database,
      username: username,
      password: 'irrelevant',
      loginTimeout: loginTimeout,
      defaultQueryTimeout: queryTimeout,
    );

    test('a blank host is refused, whitespace included', () {
      expect(() => config(host: '').validate(), throwsArgumentError);
      expect(() => config(host: '   ').validate(), throwsArgumentError);
    });

    test('a blank database is refused', () {
      expect(() => config(database: '').validate(), throwsArgumentError);
      expect(() => config(database: '  ').validate(), throwsArgumentError);
    });

    test('an empty username is refused', () {
      expect(() => config(username: '').validate(), throwsArgumentError);
    });

    test('port boundaries are 1 and 65535', () {
      expect(() => config(port: 0).validate(), throwsRangeError);
      expect(() => config(port: -1).validate(), throwsRangeError);
      expect(() => config(port: 65536).validate(), throwsRangeError);
      expect(() => config(port: 1).validate(), returnsNormally);
      expect(() => config(port: 65535).validate(), returnsNormally);
    });

    test('non-positive timeouts are refused', () {
      expect(
        () => config(loginTimeout: Duration.zero).validate(),
        throwsArgumentError,
      );
      expect(
        () => config(queryTimeout: Duration.zero).validate(),
        throwsArgumentError,
      );
      expect(
        () => config(loginTimeout: const Duration(seconds: -5)).validate(),
        throwsArgumentError,
      );
    });

    test('an empty password is allowed', () {
      expect(
        () => const MssqlConnectionConfig(
          host: 'db',
          database: 'app',
          username: 'sa',
          password: '',
        ).validate(),
        returnsNormally,
      );
    });

    test('the defaults are UTF-8 and TDS 7.4', () {
      const c = MssqlConnectionConfig(
        host: 'db',
        database: 'app',
        username: 'sa',
        password: 'x',
      );
      expect(c.clientCharset, 'UTF-8');
      expect(c.tdsVersion, '7.4');
      expect(c.port, 1433);
      expect(c.packetSize, 0, reason: '0 means the server default');
    });
  });

  group('pool configuration', () {
    test('a maximum below the minimum is refused', () {
      expect(
        () => const MssqlPoolConfig(minimumSize: 5, maximumSize: 2).validate(),
        throwsA(anything),
      );
    });

    test('a negative minimum is refused', () {
      expect(
        () => const MssqlPoolConfig(minimumSize: -1).validate(),
        throwsA(anything),
      );
    });

    test('the validation grace period defaults to zero', () {
      expect(const MssqlPoolConfig().validationGracePeriod, Duration.zero);
    });
  });

  group('decimalMode', () {
    test('defaults to exact', () {
      const c = MssqlConnectionConfig(
        host: 'db',
        database: 'app',
        username: 'sa',
        password: 'x',
      );
      expect(c.decimalMode, MssqlDecimalMode.exact);
    });

    test('only the exact numeric families are eligible', () {
      for (final type in <int>[
        Syb.decimal,
        Syb.numeric,
        Syb.money,
        Syb.money4,
        Syb.moneyn,
      ]) {
        expect(isExactNumeric(type), isTrue, reason: 'type $type');
      }
      for (final type in <int>[
        Syb.unique,
        Syb.msxml,
        Syb.msdate,
        Syb.varchar,
        Syb.int4,
        9999,
      ]) {
        expect(isExactNumeric(type), isFalse, reason: 'type $type');
      }
    });

    test('a decimal parameter takes a string or a number', () {
      expect(
        MssqlParameter.decimal('a', '1.5000', precision: 18, scale: 4).value,
        '1.5000',
      );
      expect(
        MssqlParameter.decimal('a', 1.5, precision: 18, scale: 4).value,
        '1.5000',
      );
      expect(
        MssqlParameter.decimal('a', 42, precision: 18, scale: 4).value,
        '42.0000',
      );
      expect(
        MssqlParameter.decimal('a', null, precision: 18, scale: 4).value,
        isNull,
      );
    });

    test('a number is rendered at the column scale, not by toString', () {
      expect(
        MssqlParameter.decimal('a', 1.0, precision: 18, scale: 0).value,
        '1',
      );
      expect(
        MssqlParameter.decimal('a', 0.5, precision: 18, scale: 4).value,
        '0.5000',
      );
    });

    test('a number too large to render is refused, not sent broken', () {
      expect(
        () => MssqlParameter.decimal('a', 1e21, precision: 38, scale: 2),
        throwsArgumentError,
      );
      expect(
        MssqlParameter.decimal(
          'a',
          '1000000000000000000000.00',
          precision: 38,
          scale: 2,
        ).value,
        '1000000000000000000000.00',
      );
    });

    test('anything that is neither is refused at construction', () {
      expect(
        () => MssqlParameter.decimal('a', true, precision: 18, scale: 4),
        throwsArgumentError,
      );
    });
  });

  group('encryption settings', () {
    test('the level maps to the four spellings FreeTDS accepts', () {
      expect(encryptionSetting(MssqlEncryption.off), 'off');
      expect(encryptionSetting(MssqlEncryption.request), 'request');
      expect(encryptionSetting(MssqlEncryption.require), 'require');
      expect(encryptionSetting(MssqlEncryption.strict), 'strict');
    });

    test('every level has a spelling', () {
      for (final level in MssqlEncryption.values) {
        expect(encryptionSetting(level), isNotEmpty, reason: '$level');
      }
    });

    test('a config written in Dart defaults to off', () {
      const c = MssqlConnectionConfig(
        host: 'db',
        database: 'app',
        username: 'sa',
        password: 'x',
      );
      expect(c.encryption, MssqlEncryption.off);
      expect(c.encryption, MssqlDefaults.encryption);
    });

    test('a connection string with no Encrypt defaults to off too', () {
      final c = MssqlConnectionConfig.fromConnectionString(
        'Server=db,1433;Database=app;User Id=sa;Password=x',
      );
      expect(c.encryption, MssqlEncryption.off);
      expect(c.encryption, MssqlDefaults.encryption);
    });
  });

  group('TLS trust', () {
    test('insecure verification needs no config file at all', () {
      expect(
        const MssqlTlsTrust.insecureNoVerification().requiresConfigurationFile,
        isFalse,
      );
      expect(
        const MssqlTlsTrust(
          certificateAuthorityFile: '/etc/ca.pem',
        ).requiresConfigurationFile,
        isTrue,
      );
    });

    test('the system store is spelled the way FreeTDS expects', () {
      expect(const MssqlTlsTrust.system().certificateAuthorityFile, 'system');
      expect(const MssqlTlsTrust.system().validateHostname, isTrue);
    });

    test('the rendered config is a global section FreeTDS can read', () {
      const trust = MssqlTlsTrust(
        certificateAuthorityFile: '/etc/ssl/ca.pem',
        certificateRevocationFile: '/etc/ssl/crl.pem',
        expectedHostname: 'sql.internal',
      );
      final config = trust.toConfig();
      expect(config, startsWith('[global]'));
      expect(config, contains('\tca file = /etc/ssl/ca.pem'));
      expect(config, contains('\tcrl file = /etc/ssl/crl.pem'));
      expect(config, contains('\tcheck certificate hostname = yes'));
      expect(config, contains('\tcertificate hostname = sql.internal'));
    });

    test('hostname checking off is written as no, not omitted', () {
      expect(
        const MssqlTlsTrust(
          certificateAuthorityFile: '/etc/ca.pem',
          validateHostname: false,
        ).toConfig(),
        contains('check certificate hostname = no'),
      );
    });

    test('absent settings produce no line rather than an empty one', () {
      final config = const MssqlTlsTrust.insecureNoVerification().toConfig();
      expect(config, isNot(contains('ca file')));
      expect(config, isNot(contains('crl file')));
      expect(config, isNot(contains('\tcertificate hostname')));
    });

    test('a CA plus a revocation list is accepted', () {
      expect(
        const MssqlTlsTrust(
          certificateAuthorityFile: '/ca.pem',
          certificateRevocationFile: '/crl.pem',
        ).validate,
        returnsNormally,
      );
    });

    test('an expected hostname with checking off is refused', () {
      expect(
        () => const MssqlTlsTrust(
          certificateAuthorityFile: 'system',
          expectedHostname: 'sql.internal',
          validateHostname: false,
        ).validate(),
        throwsArgumentError,
      );
    });

    test('a blank CA file is refused', () {
      expect(
        () => const MssqlTlsTrust(certificateAuthorityFile: '  ').validate(),
        throwsArgumentError,
      );
      expect(const MssqlTlsTrust.system().validate, returnsNormally);
    });
  });

  group('exceptions', () {
    test('the single-row helpers have distinct failures', () {
      expect(const MssqlNoRowsException().type, MssqlErrorType.protocol);
      expect(const MssqlMultipleRowsException().type, MssqlErrorType.protocol);
      expect(
        const MssqlNoRowsException().message,
        isNot(const MssqlMultipleRowsException().message),
      );
    });

    test('toString names the type and code, for a log line', () {
      const error = MssqlException(
        type: MssqlErrorType.deadlock,
        message: 'Transaction was deadlocked.',
        code: 1205,
        retryable: true,
      );
      expect(error.toString(), contains('deadlock'));
      expect(error.toString(), contains('1205'));
      expect(error.toString(), contains('Transaction was deadlocked.'));
    });

    test('an exception carries no diagnostics unless given some', () {
      const error = MssqlException(type: MssqlErrorType.internal, message: 'x');
      expect(error.diagnostics, isEmpty);
      expect(error.retryable, isFalse);
      expect(error.code, 0);
    });
  });
}

