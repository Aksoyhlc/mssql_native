import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

void main() {
  test('parameter names are validated', () {
    final valid = MssqlParameter.int32('@company_id', 1);
    expect(valid.validate, returnsNormally);
    final invalid = MssqlParameter.int32('company id; DROP TABLE x', 1);
    expect(invalid.validate, throwsArgumentError);
  });

  test('decimal validates precision and scale', () {
    final valid = MssqlParameter.decimal(
      'price',
      '123.4500',
      precision: 18,
      scale: 4,
    );
    expect(valid.validate, returnsNormally);
    final invalid = MssqlParameter.decimal(
      'price',
      '1',
      precision: 2,
      scale: 3,
    );
    expect(invalid.validate, throwsRangeError);
  });
}
