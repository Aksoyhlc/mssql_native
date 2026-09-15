import 'dart:typed_data';

import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_native/src/models/parameter.dart';
import 'package:test/test.dart';

const _intColumn = MssqlColumn(
  index: 0,
  name: 'id',
  type: MssqlType.int32,
  nullable: false,
  maxLength: 4,
  precision: 10,
  scale: 0,
  nativeType: 56,
);

void main() {
  group('dual parameter API', () {
    test('plain map values infer stable SQL types', () {
      final bytes = Uint8List.fromList(<int>[0, 1, 255]);
      final instant = DateTime.utc(2026, 9, 5, 10, 11, 12, 13, 14);
      final bindings = compileParameters(<String, Object?>{
        'enabled': true,
        'small': 2147483647,
        'large': 2147483648,
        'ratio': 1.25,
        'name': 'İstanbul',
        'created': instant,
        'payload': bytes,
      });

      expect(bindings.map((binding) => binding.type), <MssqlType>[
        MssqlType.bit,
        MssqlType.int32,
        MssqlType.int64,
        MssqlType.float64,
        MssqlType.nvarchar,
        MssqlType.dateTime2,
        MssqlType.varbinary,
      ]);
      expect(bindings[4].size, 8);
      expect(bindings[5].value, isA<MssqlDateTimeValue>());
      expect(bindings[6].value, same(bytes));
    });

    test('typed map values preserve null, precision, scale and size', () {
      final bindings = compileParameters(<String, Object?>{
        '@name': const MssqlValue.nvarchar(null, size: 100),
        'price': MssqlValue.decimal(
          '99999999999999.9999',
          precision: 18,
          scale: 4,
        ),
      });

      expect(bindings[0].name, 'name');
      expect(bindings[0].value, isNull);
      expect(bindings[0].size, 100);
      expect(bindings[1].value, '99999999999999.9999');
      expect(bindings[1].precision, 18);
      expect(bindings[1].scale, 4);
    });

    test('plain null is rejected because its SQL type is unknowable', () {
      expect(
        () => compileParameters(<String, Object?>{'value': null}),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            contains('MssqlValue'),
          ),
        ),
      );
    });

    test('explicit parameter list keeps names and output direction', () {
      final bindings = compileParameters(<MssqlParameter>[
        MssqlParameter.int32('customer_id', 12),
        MssqlParameter.nvarchar(
          '@label',
          null,
          size: 96,
          direction: MssqlParameterDirection.output,
        ),
      ]);

      expect(bindings.map((binding) => binding.name), <String>[
        'customer_id',
        'label',
      ]);
      expect(bindings[1].direction, MssqlParameterBindingDirection.output);
    });

    test('parameter names are duplicate regardless of a leading @', () {
      expect(
        () => compileParameters(<String, Object?>{'id': 1, '@id': 2}),
        throwsArgumentError,
      );
      expect(
        () => compileParameters(<MssqlParameter>[
          MssqlParameter.int32('@name', 1),
          MssqlParameter.int32('name', 2),
        ]),
        throwsArgumentError,
      );
    });

    test('parameter casing is preserved for case-sensitive servers', () {
      final bindings = compileParameters(<String, Object?>{'id': 1, '@ID': 2});
      expect(bindings.map((binding) => binding.name), <String>['id', 'ID']);
    });

    test('unsupported values and non-finite doubles fail locally', () {
      expect(
        () => compileParameters(<String, Object?>{'value': Object()}),
        throwsArgumentError,
      );
      expect(
        () => compileParameters(<String, Object?>{'value': double.nan}),
        throwsArgumentError,
      );
    });

    test('exact integer decimal formatting does not pass through double', () {
      final value = MssqlValue.decimal(
        9007199254740993,
        precision: 20,
        scale: 2,
      ).validated();
      expect(value.value, '9007199254740993.00');
    });
  });

  group('map and typed rows coexist', () {
    test('one result exposes legacy maps and typed row views', () {
      final set = MssqlResultSet.fromValues(
        columns: const <MssqlColumn>[
          _intColumn,
          MssqlColumn(
            index: 1,
            name: 'name',
            type: MssqlType.nvarchar,
            nullable: true,
            maxLength: 100,
            precision: 0,
            scale: 0,
            nativeType: 103,
          ),
        ],
        values: const <List<Object?>>[
          <Object?>[7, 'İstek'],
        ],
        metrics: const MssqlResultSetMetrics(
          index: 0,
          rowCount: 1,
          decodedBytes: 12,
          elapsed: Duration(milliseconds: 2),
        ),
      );

      expect(set.rows.single, <String, Object?>{'id': 7, 'name': 'İstek'});
      expect(set.typedRows.single.require<int>('id'), 7);
      expect(set.typedRows.single.get<String>('name'), 'İstek');
      expect(set.typedRows.single.at(0), 7);
      expect(set.metrics.rowCount, 1);
    });

    test('typed lookup rejects absent, null, wrong and duplicate labels', () {
      const duplicate = MssqlColumn(
        index: 1,
        name: 'id_2',
        reportedName: 'id',
        type: MssqlType.nvarchar,
        nullable: true,
        maxLength: 20,
        precision: 0,
        scale: 0,
        nativeType: 103,
      );
      final set = MssqlResultSet.fromValues(
        columns: const <MssqlColumn>[_intColumn, duplicate],
        values: const <List<Object?>>[
          <Object?>[7, null],
        ],
        metrics: MssqlResultSetMetrics.empty,
      );
      final row = set.typedRows.single;

      expect(row.at(0), 7);
      expect(() => row['id'], throwsA(isA<MssqlRowAccessException>()));
      expect(
        () => row.get<int>('missing'),
        throwsA(isA<MssqlRowAccessException>()),
      );
      expect(set.rows.single, <String, Object?>{'id': 7, 'id_2': null});
    });

    test('old const result constructors retain empty metric defaults', () {
      const set = MssqlResultSet(
        columns: <MssqlColumn>[_intColumn],
        rows: <Map<String, Object?>>[
          <String, Object?>{'id': 1},
        ],
      );
      const result = MssqlExecutionResult(
        resultSets: <MssqlResultSet>[set],
        affectedRows: 0,
        outputParameters: <String, Object?>{},
        messages: <MssqlServerMessage>[],
      );

      expect(result.resultSets.single.rows.single['id'], 1);
      expect(result.metrics, same(MssqlExecutionMetrics.empty));
      expect(set.typedRows, isEmpty);
    });
  });

  group('SQL escaping helpers', () {
    test('identifier quoting doubles closing brackets', () {
      expect(MssqlSql.quoteIdentifier('order]detail'), '[order]]detail]');
      expect(
        MssqlSql.quoteMultipartIdentifier(<String>['erp', 'dbo', 'order']),
        '[erp].[dbo].[order]',
      );
    });

    test('invalid identifier shapes are rejected', () {
      expect(() => MssqlSql.quoteIdentifier(''), throwsArgumentError);
      expect(() => MssqlSql.quoteIdentifier('a' * 129), throwsArgumentError);
      expect(
        () => MssqlSql.quoteMultipartIdentifier(const <String>[]),
        throwsArgumentError,
      );
      expect(
        () => MssqlSql.quoteMultipartIdentifier(<String>[
          'a',
          'b',
          'c',
          'd',
          'e',
        ]),
        throwsArgumentError,
      );
    });

    test('LIKE escaping handles the escape character before wildcards', () {
      expect(MssqlSql.escapeLike(r'50%_[x]\y'), r'50\%\_\[x]\\y');
      expect(
        MssqlSql.escapeLike('a%b_c[d', escapeCharacter: '!'),
        r'a!%b!_c![d',
      );
    });

    test('LIKE escape character cannot itself be a wildcard', () {
      for (final escape in <String>['', 'ab', '%', '_', '[']) {
        expect(
          () => MssqlSql.escapeLike('value', escapeCharacter: escape),
          throwsArgumentError,
          reason: 'escape=$escape',
        );
      }
    });

    test('a multipart identifier parses and quotes every part', () {
      expect(
        MssqlMultipartIdentifier.parse('dbo.Users').quoted,
        '[dbo].[Users]',
      );
      expect(MssqlMultipartIdentifier.parse('Users').parts, <String>['Users']);
      expect(
        MssqlMultipartIdentifier.parse('[my schema].[Order Lines]').quoted,
        '[my schema].[Order Lines]',
      );
      expect(MssqlMultipartIdentifier.parse('[order]]detail]').parts, <String>[
        'order]detail',
      ]);
      expect(MssqlMultipartIdentifier.parse('#staging').parts, <String>[
        '#staging',
      ]);
    });

    test('a malformed multipart identifier is rejected', () {
      for (final input in <String>[
        '',
        ' dbo.Users',
        'dbo.',
        '.Users',
        '[unclosed',
        'a.b.c.d',
      ]) {
        expect(
          () => MssqlMultipartIdentifier.parse(input),
          throwsArgumentError,
          reason: 'input=$input',
        );
      }
    });
  });

  group('cancellation and stream values', () {
    test('cancellation is single-use and reports the first reason', () {
      final token = MssqlCancellationToken();
      var calls = 0;
      token.register(() => calls++);

      token.cancel('HTTP request ended');
      token.cancel('later reason');

      expect(token.isCancelled, isTrue);
      expect(token.reason, 'HTTP request ended');
      expect(calls, 1);
      expect(
        token.throwIfCancelled,
        throwsA(
          isA<MssqlException>()
              .having((error) => error.type, 'type', MssqlErrorType.cancelled)
              .having(
                (error) => error.message,
                'message',
                contains('HTTP request ended'),
              ),
        ),
      );
    });

    test('unregistered and late listeners behave deterministically', () {
      final token = MssqlCancellationToken();
      var removedCalls = 0;
      final unregister = token.register(() => removedCalls++);
      unregister();
      token.cancel();
      expect(removedCalls, 0);

      var lateCalls = 0;
      token.register(() => lateCalls++);
      expect(lateCalls, 1);
    });

    test(
      'stream event collections cannot be mutated through the input list',
      () {
        final columns = <MssqlColumn>[_intColumn];
        final start = MssqlResultSetStart(index: 0, columns: columns);
        columns.clear();
        expect(start.columns, hasLength(1));
        expect(() => start.columns.add(_intColumn), throwsUnsupportedError);
      },
    );
  });
}

