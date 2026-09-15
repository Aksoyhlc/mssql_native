import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

MssqlConnectionConfig parse(
  String text, {
  MssqlDecimalMode decimalMode = MssqlDecimalMode.exact,
  void Function(List<String>)? onUnsupportedKeys,
}) => MssqlConnectionConfig.fromConnectionString(
  text,
  decimalMode: decimalMode,
  onUnsupportedKeys: onUnsupportedKeys,
);

const String basic = 'Server=db.internal;Database=Shop;User Id=sa;Password=p';

void main() {
  mainSecrets();
  group('the ordinary string', () {
    test('reads through', () {
      final config = parse(basic);
      expect(config.host, 'db.internal');
      expect(config.port, 1433);
      expect(config.database, 'Shop');
      expect(config.username, 'sa');
      expect(config.password, 'p');
    });

    test('a trailing semicolon is fine, as is a missing one', () {
      expect(parse('$basic;').host, 'db.internal');
      expect(parse(basic).host, 'db.internal');
    });

    test('spacing around the separators is fine', () {
      final config = parse(
        ' Server = db.internal ; Database = Shop ; User Id = sa ; Password = p ',
      );
      expect(config.host, 'db.internal');
      expect(config.database, 'Shop');
      expect(config.password, 'p');
    });

    test('empty entries between semicolons are skipped', () {
      expect(parse('$basic;;').database, 'Shop');
    });
  });

  group('the synonyms SqlClient accepts', () {
    test('for the server', () {
      for (final key in <String>[
        'Server',
        'Data Source',
        'Address',
        'Addr',
        'Network Address',
      ]) {
        expect(
          parse('$key=h;Database=d;User Id=u;Password=p').host,
          'h',
          reason: key,
        );
      }
    });

    test('for the database, the user and the password', () {
      final config = parse('Server=h;Initial Catalog=Shop;UID=sa;PWD=secret');
      expect(config.database, 'Shop');
      expect(config.username, 'sa');
      expect(config.password, 'secret');
    });

    test('and the case and inner spaces do not matter', () {
      final config = parse('SERVER=h;database=d;userid=sa;password=p');
      expect(config.host, 'h');
      expect(config.database, 'd');
      expect(config.username, 'sa');
    });

    test('a later duplicate wins, as it does there', () {
      expect(
        parse('Server=a;Server=b;Database=d;User Id=u;Password=p').host,
        'b',
      );
    });
  });

  group('quoted values', () {
    test('let a password carry a semicolon', () {
      final config = parse("Server=h;Database=d;User Id=u;Password='a;b'");
      expect(config.password, 'a;b');
    });

    test('work with double quotes too', () {
      expect(
        parse('Server=h;Database=d;User Id=u;Password="a;b"').password,
        'a;b',
      );
    });

    test('a doubled quote inside stands for one', () {
      expect(
        parse("Server=h;Database=d;User Id=u;Password='it''s'").password,
        "it's",
      );
      expect(
        parse('Server=h;Database=d;User Id=u;Password="say ""hi"""').password,
        'say "hi"',
      );
    });

    test('keep the whitespace inside them', () {
      expect(
        parse("Server=h;Database=d;User Id=u;Password='  p  '").password,
        '  p  ',
      );
    });

    test('a quote that never closes is refused', () {
      expect(
        () => parse("Server=h;Database=d;User Id=u;Password='oops"),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('never closes'),
          ),
        ),
      );
    });

    test('an unquoted value may still contain an equals sign', () {
      expect(
        parse('Server=h;Database=d;User Id=u;Password=a=b').password,
        'a=b',
      );
    });
  });

  group('the server value', () {
    _Endpoint check(String source) {
      final config = parse('Server=$source;Database=d;User Id=u;Password=p');
      return _Endpoint(config.host, config.port);
    }

    test('carries a port after a comma', () {
      expect(check('db.internal,14330').host, 'db.internal');
      expect(check('db.internal,14330').port, 14330);
    });

    test('drops a tcp: prefix', () {
      expect(check('tcp:db.internal,1433').host, 'db.internal');
      expect(check('TCP:db.internal').host, 'db.internal');
    });

    test('. and (local) mean this machine', () {
      expect(check('.').host, '127.0.0.1');
      expect(check('(local)').host, '127.0.0.1');
      expect(check('(LOCAL)').host, '127.0.0.1');
    });

    test('an IPv4 address passes through, port and all', () {
      expect(check('10.0.0.5,1433').host, '10.0.0.5');
      expect(check('10.0.0.5,1433').port, 1433);
    });

    test('a named instance is refused, with the fix in the message', () {
      expect(
        () => check(r'db.internal\SQLEXPRESS'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('SQL Browser'), contains('Server=host,1433')),
          ),
        ),
      );
    });

    test('a protocol this driver does not speak is refused', () {
      expect(() => check(r'np:\\host\pipe\sql'), throwsArgumentError);
      expect(() => check('lpc:host'), throwsArgumentError);
    });

    test('something that is not a port is refused', () {
      expect(() => check('db.internal,http'), throwsArgumentError);
      expect(() => check('db.internal,0'), throwsArgumentError);
      expect(() => check('db.internal,99999'), throwsArgumentError);
    });
  });

  group('Windows authentication', () {
    test('every spelling of it asks for the process account', () {
      for (final entry in <String>[
        'Integrated Security=true',
        'Integrated Security=SSPI',
        'Trusted_Connection=yes',
      ]) {
        final config = parse('Server=h;Database=d;$entry');
        expect(config.integratedSecurity, isTrue, reason: entry);
        expect(config.username, isEmpty, reason: entry);
        expect(config.password, isEmpty, reason: entry);
      }
    });

    test('and then no User Id is required', () {
      expect(
        () => parse('Server=h;Database=d;Integrated Security=true'),
        returnsNormally,
      );
    });

    test('credentials in the same string are refused, not dropped', () {
      expect(
        () => parse('$basic;Integrated Security=true'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('Drop one of the two'),
          ),
        ),
      );
    });

    test('Integrated Security=false is simply ignored', () {
      final config = parse('$basic;Integrated Security=false');
      expect(config.username, 'sa');
      expect(config.integratedSecurity, isFalse);
    });
  });

  group('what it will not pretend to support', () {
    test('per-connection certificate verification', () {
      expect(
        () => parse('$basic;Encrypt=true;TrustServerCertificate=false'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('process-wide'), contains('doc/TLS.md')),
          ),
        ),
      );
    });

    test('TrustServerCertificate is never honoured on the string', () {
      expect(
        () => parse('$basic;TrustServerCertificate=false'),
        throwsArgumentError,
      );
    });
  });

  group('the settings it does carry over', () {
    test('Encrypt, mapped to what this driver actually does', () {
      MssqlEncryption of(String value) =>
          parse('$basic;Encrypt=$value').encryption;
      expect(of('true'), MssqlEncryption.require);
      expect(of('yes'), MssqlEncryption.require);
      expect(of('mandatory'), MssqlEncryption.require);
      expect(of('strict'), MssqlEncryption.strict);
      expect(of('optional'), MssqlEncryption.request);
      expect(of('false'), MssqlEncryption.off);
      expect(parse(basic).encryption, MssqlEncryption.off);
    });

    test('an Encrypt value nobody defines is refused', () {
      expect(() => parse('$basic;Encrypt=maybe'), throwsArgumentError);
    });

    test('the application name', () {
      expect(
        parse('$basic;Application Name=Reports').applicationName,
        'Reports',
      );
      expect(parse('$basic;App=Reports').applicationName, 'Reports');
      expect(parse(basic).applicationName, 'mssql_native');
    });

    test('the login timeout, in seconds', () {
      expect(
        parse('$basic;Connect Timeout=45').loginTimeout,
        const Duration(seconds: 45),
      );
      expect(
        parse('$basic;Connection Timeout=45').loginTimeout,
        const Duration(seconds: 45),
      );
      expect(parse(basic).loginTimeout, const Duration(seconds: 10));
    });

    test('a timeout that is not a positive number is refused', () {
      expect(() => parse('$basic;Connect Timeout=0'), throwsArgumentError);
      expect(() => parse('$basic;Connect Timeout=soon'), throwsArgumentError);
    });

    test('decimalAsDouble comes from the argument, not the string', () {
      expect(parse(basic).decimalMode, MssqlDecimalMode.exact);
      expect(
        parse(basic, decimalMode: MssqlDecimalMode.text).decimalMode,
        MssqlDecimalMode.text,
      );
    });
  });

  group('keys it has no use for', () {
    test('are handed to the caller rather than silently dropped', () {
      final ignored = <String>[];
      parse(
        '$basic;MultipleActiveResultSets=true;Pooling=false;Max Pool Size=50',
        onUnsupportedKeys: ignored.addAll,
      );
      expect(ignored, <String>[
        'Max Pool Size',
        'MultipleActiveResultSets',
        'Pooling',
      ]);
    });

    test('nothing is reported when everything was understood', () {
      var called = false;
      parse(basic, onUnsupportedKeys: (_) => called = true);
      expect(called, isFalse);
    });

    test('and the connection is built anyway when the caller accepts them', () {
      expect(
        parse('$basic;Pooling=false', onUnsupportedKeys: (_) {}).host,
        'db.internal',
      );
    });
  });

  group('what it insists on', () {
    test('a server', () {
      expect(
        () => parse('Database=d;User Id=u;Password=p'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('No Server'),
          ),
        ),
      );
    });

    test('a database', () {
      expect(
        () => parse('Server=h;User Id=u;Password=p'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('No Database'),
          ),
        ),
      );
    });

    test('a user, unless Integrated Security says who logs in', () {
      expect(
        () => parse('Server=h;Database=d;Password=p'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('No User Id'),
          ),
        ),
      );
    });

    test('an empty password is allowed, an empty user is not', () {
      expect(parse('Server=h;Database=d;User Id=u').password, '');
      expect(
        () => parse('Server=h;Database=d;User Id=;Password=p'),
        throwsArgumentError,
      );
    });

    test('an entry with no equals sign is refused', () {
      expect(
        () => parse('Server=h;Database=d;User Id=u;nonsense'),
        throwsArgumentError,
      );
    });

    test('an empty string is refused', () {
      expect(() => parse(''), throwsArgumentError);
      expect(() => parse('   '), throwsArgumentError);
    });

    test('the result passes the same validation a built config does', () {
      expect(() => parse(basic).validate(), returnsNormally);
    });
  });
}

class _Endpoint {
  const _Endpoint(this.host, this.port);
  final String host;
  final int port;
}

void _expectNoSecret(Object error, String secret) {
  expect(error.toString(), isNot(contains(secret)));
  if (error is ArgumentError) {
    expect(error.invalidValue.toString(), isNot(contains(secret)));
  }
}

void mainSecrets() {
  group('a refused connection string never carries the password', () {
    const secret = 'sup3rs3cr3t';

    final cases = <String, String>{
      'Integrated Security':
          'Server=h;Database=d;User Id=u;Password=$secret;Integrated Security=true',
      'no server': 'Database=d;User Id=u;Password=$secret',
      'no database': 'Server=h;User Id=u;Password=$secret',
      'no user': 'Server=h;Database=d;Password=$secret',
      'TrustServerCertificate':
          'Server=h;Database=d;User Id=u;Password=$secret;TrustServerCertificate=true',
      'security-sensitive key':
          'Server=h;Database=d;User Id=u;Password=$secret;Column Encryption Setting=Enabled',
      'unsupported key':
          'Server=h;Database=d;User Id=u;Password=$secret;Application Name=x',
      'entry without =': 'Server=h;Database=d;User Id=u;Password=$secret;oops',
      'unclosed quote': "Server=h;Database=d;User Id=u;Password='$secret",
      'quoted password that is otherwise fine but the port is not':
          "Server=h,notaport;Database=d;User Id=u;Password='$secret'",
    };

    cases.forEach((name, connectionString) {
      test(name, () {
        try {
          parse(connectionString);
          fail('Expected $name to be refused.');
        } catch (error) {
          _expectNoSecret(error, secret);
        }
      });
    });

    test('the redacted string still identifies itself to the caller', () {
      try {
        parse('Server=h;User Id=u;Password=$secret');
        fail('Expected a refusal.');
      } on ArgumentError catch (error) {
        final shown = error.invalidValue.toString();
        expect(shown, contains('Server=h'));
        expect(shown, contains('Password=***'));
        expect(shown, isNot(contains(secret)));
      }
    });

    test('PWD is folded the same way', () {
      try {
        parse('Server=h;PWD=$secret');
        fail('Expected a refusal.');
      } on ArgumentError catch (error) {
        expect(error.invalidValue.toString(), contains('PWD=***'));
        expect(error.toString(), isNot(contains(secret)));
      }
    });

    test('a quoted password with a semicolon inside is masked whole', () {
      try {
        parse("Server=h;Password='a;$secret';Application Name=x");
        fail('Expected a refusal.');
      } on ArgumentError catch (error) {
        expect(error.toString(), isNot(contains(secret)));
        expect(error.invalidValue.toString(), contains('Application Name=x'));
      }
    });
  });
}

