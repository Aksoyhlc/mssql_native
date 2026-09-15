import 'package:mssql_native/src/models/result.dart';
import 'package:mssql_native/src/models/types.dart';
import 'package:test/test.dart';

MssqlColumn _column(int index, String name) => MssqlColumn(
  index: index,
  name: name,
  type: MssqlType.int32,
  nullable: true,
  maxLength: 4,
  precision: 0,
  scale: 0,
  nativeType: 56,
);

MssqlRow _row(List<String> names) => MssqlRow.fromValues(
  MssqlRowSchema(<MssqlColumn>[
    for (var i = 0; i < names.length; i++) _column(i, names[i]),
  ]),
  <Object?>[for (var i = 0; i < names.length; i++) i],
);

void main() {
  group('column lookup', () {
    test('an exact name is found', () {
      expect(_row(<String>['id', 'label'])['label'], 1);
    });

    test('a differently cased name is found too', () {
      final row = _row(<String>['OrderId', 'Total']);
      expect(row['orderid'], 0);
      expect(row['ORDERID'], 0);
      expect(row['oRdErId'], 0);
      expect(row['total'], 1);
    });

    test('the name as written wins over a case-insensitive match', () {
      final row = _row(<String>['id', 'ID']);
      expect(row['id'], 0);
      expect(row['ID'], 1);
    });

    test('a name matching two columns only by case is ambiguous', () {
      final row = _row(<String>['id', 'ID']);
      expect(() => row['Id'], throwsA(isA<MssqlRowAccessException>()));
    });

    test('a name that matches nothing still says so', () {
      expect(
        () => _row(<String>['id'])['nope'],
        throwsA(isA<MssqlRowAccessException>()),
      );
    });

    test('duplicate exact names stay ambiguous', () {
      final row = _row(<String>['n', 'n']);
      expect(() => row['n'], throwsA(isA<MssqlRowAccessException>()));
      expect(row.at(0), 0);
      expect(row.at(1), 1);
    });

    group('Turkish names are folded by nobody', () {
      test('the dotted and dotless I stay distinct', () {
        final row = _row(<String>['ISIM', 'İSİM', 'ısım']);
        expect(row['ISIM'], 0);
        expect(row['İSİM'], 1);
        expect(row['ısım'], 2);
        expect(
          row['isim'],
          0,
          reason: 'ASCII folding reaches ISIM, and only it',
        );
      });

      test('a non-ASCII name is reachable by its own spelling', () {
        final row = _row(<String>['ÜRÜN_ADI', 'fiyat']);
        expect(row['ÜRÜN_ADI'], 0);
        expect(row['ÜRÜN_adi'], 0, reason: 'the ASCII letters still fold');
        expect(
          () => row['ürün_adi'],
          throwsA(isA<MssqlRowAccessException>()),
          reason: 'Ü is left alone rather than folded by a foreign rule',
        );
      });
    });

    group('the helpers agree with the lookup', () {
      test('containsColumn sees a differently cased name', () {
        final row = _row(<String>['Total']);
        expect(row.containsColumn('Total'), isTrue);
        expect(row.containsColumn('total'), isTrue);
        expect(row.containsColumn('nope'), isFalse);
      });

      test('get and require follow the same rule', () {
        final row = _row(<String>['OrderId']);
        expect(row.get<int>('orderid'), 0);
        expect(row.require<int>('ORDERID'), 0);
      });
    });
  });
}

