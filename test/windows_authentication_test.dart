import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

void main() {
  group('a domain account with a password', () {
    const config = MssqlConnectionConfig(
      host: 'db.internal',
      database: 'Shop',
      username: r'CONTOSO\aksoyhlc',
      password: 'secret',
    );

    test('is an ordinary configuration, on every platform', () {
      expect(config.validate, returnsNormally);
      expect(config.integratedSecurity, isFalse);
    });

    test('keeps the backslash, which is what selects NTLM', () {
      expect(config.username, r'CONTOSO\aksoyhlc');
    });

    test('reads through a connection string unchanged', () {
      final parsed = MssqlConnectionConfig.fromConnectionString(
        r'Server=db.internal;Database=Shop;User Id=CONTOSO\aksoyhlc;Password=p',
      );
      expect(parsed.username, r'CONTOSO\aksoyhlc');
      expect(parsed.integratedSecurity, isFalse);
    });
  });

  group('integrated security', () {
    const config = MssqlConnectionConfig.integratedSecurity(host: 'db.internal', database: 'Shop');

    test('carries no credentials', () {
      expect(config.integratedSecurity, isTrue);
      expect(config.username, isEmpty);
      expect(config.password, isEmpty);
    });

    test('keeps the rest of the defaults', () {
      expect(config.port, MssqlDefaults.port);
      expect(config.applicationName, MssqlDefaults.applicationName);
      expect(config.encryption, MssqlDefaults.encryption);
    });

    test('never prints a user name it does not have', () {
      expect(config.toString(), contains('integrated security'));
    });

    test('validates on Windows and is refused everywhere else', () {
      if (Platform.isWindows) {
        expect(config.validate, returnsNormally);
      } else {
        expect(
          config.validate,
          throwsA(
            isA<ArgumentError>().having((e) => e.message, 'message', allOf(contains('SSPI'), contains(r'DOMAIN\user'))),
          ),
        );
      }
    });

    test('a user name alongside it is refused', () {
      const mixed = MssqlConnectionConfig(
        host: 'db.internal',
        database: 'Shop',
        username: 'sa',
        password: 'p',
        integratedSecurity: true,
      );
      expect(mixed.validate, throwsA(isA<ArgumentError>()));
    });
  });

  group('copyWith', () {
    const integrated = MssqlConnectionConfig.integratedSecurity(host: 'db.internal', database: 'Shop');

    test('keeps integrated security across an unrelated change', () {
      final copy = integrated.copyWith(database: 'Reporting');
      expect(copy.database, 'Reporting');
      expect(copy.integratedSecurity, isTrue);
      expect(copy.username, isEmpty);
    });

    test('refuses credentials that would be ignored', () {
      expect(() => integrated.copyWith(username: 'sa', password: 'p'), throwsA(isA<ArgumentError>()));
    });

    test('moves to a login when asked to, credentials and all', () {
      final copy = integrated.copyWith(integratedSecurity: false, username: r'CONTOSO\aksoyhlc', password: 'secret');
      expect(copy.integratedSecurity, isFalse);
      expect(copy.username, r'CONTOSO\aksoyhlc');
      expect(copy.validate, returnsNormally);
    });

    test('turns a login into an integrated one', () {
      const login = MssqlConnectionConfig(host: 'db.internal', database: 'Shop', username: 'sa', password: 'secret');
      final copy = login.copyWith(integratedSecurity: true);
      expect(copy.integratedSecurity, isTrue);
      expect(copy.username, isEmpty);
      expect(copy.password, isEmpty);
    });
  });
}

