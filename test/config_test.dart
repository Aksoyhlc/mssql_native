import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

void main() {
  test('connection configuration validates standard values', () {
    const config = MssqlConnectionConfig(
      host: '127.0.0.1',
      database: 'mssql_native_test',
      username: 'sa',
      password: 'secret',
    );
    expect(config.validate, returnsNormally);
  });

  test('pool rejects inverted bounds', () {
    const config = MssqlPoolConfig(minimumSize: 3, maximumSize: 2);
    expect(config.validate, throwsArgumentError);
  });
}
