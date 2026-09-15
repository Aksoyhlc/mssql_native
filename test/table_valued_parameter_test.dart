import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

import 'support/live_server.dart';

void main() {
  group('table-valued parameters', () {
    late MssqlConnection connection;

    Future<int> leftoverStagingTables() => connection.queryScalar<int>(
      "SELECT COUNT(*) FROM tempdb.sys.tables WHERE name LIKE '#__mssql_tvp%'",
    );

    setUpAll(() async {
      await initializeLive();
      connection = await MssqlConnection.open(
        liveConfig(decimalMode: MssqlDecimalMode.text),
      );
      await connection.execute('''
DROP PROCEDURE IF EXISTS dbo.mssql_native_tvp_sum;
DROP PROCEDURE IF EXISTS dbo.mssql_native_tvp_pair;
IF TYPE_ID(N'dbo.mssql_native_tvp_rows') IS NOT NULL
  DROP TYPE dbo.mssql_native_tvp_rows;
IF TYPE_ID(N'dbo.mssql_native_tvp_tags') IS NOT NULL
  DROP TYPE dbo.mssql_native_tvp_tags;
CREATE TYPE dbo.mssql_native_tvp_rows AS TABLE (
  id INT NOT NULL,
  label NVARCHAR(40) NULL,
  amount DECIMAL(28,8) NULL
);
''');
      await connection.execute('''
CREATE TYPE dbo.mssql_native_tvp_tags AS TABLE (tag NVARCHAR(20) NOT NULL);
''');
      await connection.execute('''
CREATE PROCEDURE dbo.mssql_native_tvp_sum
  @rows dbo.mssql_native_tvp_rows READONLY,
  @factor INT = 2,
  @total DECIMAL(28,8) OUTPUT
AS
BEGIN
  SELECT @total = ISNULL(SUM(amount), 0) * @factor FROM @rows;
  SELECT id, label, amount FROM @rows ORDER BY id;
  RETURN 77;
END;
''');
      await connection.execute('''
CREATE PROCEDURE dbo.mssql_native_tvp_pair
  @rows dbo.mssql_native_tvp_rows READONLY,
  @tags dbo.mssql_native_tvp_tags READONLY
AS
BEGIN
  SELECT (SELECT COUNT(*) FROM @rows) AS rows_seen,
         (SELECT COUNT(*) FROM @tags) AS tags_seen,
         (SELECT TOP (1) tag FROM @tags ORDER BY tag) AS first_tag;
END;
''');
    });

    tearDownAll(() async {
      try {
        await connection.execute('''
DROP PROCEDURE IF EXISTS dbo.mssql_native_tvp_sum;
DROP PROCEDURE IF EXISTS dbo.mssql_native_tvp_pair;
IF TYPE_ID(N'dbo.mssql_native_tvp_rows') IS NOT NULL
  DROP TYPE dbo.mssql_native_tvp_rows;
IF TYPE_ID(N'dbo.mssql_native_tvp_tags') IS NOT NULL
  DROP TYPE dbo.mssql_native_tvp_tags;
''');
      } finally {
        if (!connection.isClosed) await connection.close();
        await MssqlRuntime.instance.shutdown();
      }
    });

    tearDown(() async {
      if (connection.isClosed) return;
      expect(
        await leftoverStagingTables(),
        0,
        reason: 'every staging table must be dropped',
      );
    });

    test('a list of maps becomes the table the procedure declares', () async {
      final result = await connection.callProcedure(
        'dbo.mssql_native_tvp_sum',
        parameters: <String, Object?>{
          'rows': <Map<String, Object?>>[
            <String, Object?>{
              'id': 1,
              'label': 'bir',
              'amount': MssqlValue.decimal('1.5', precision: 28, scale: 8),
            },
            <String, Object?>{
              'id': 2,
              'label': 'iki',
              'amount': MssqlValue.decimal('2.25', precision: 28, scale: 8),
            },
          ],
          'factor': 4,
        },
        outputParameters: <String>{'total'},
      );
      expect(result.outputParameters['total'].toString(), '15.00000000');
      expect(
        result.returnStatus,
        77,
        reason: 'the return status survives the wrapper batch',
      );
      expect(result.resultSets.single.rows.map((row) => row['label']), <String>[
        'bir',
        'iki',
      ]);
    });

    test('MssqlTableRows says the same thing explicitly', () async {
      final result = await connection.callProcedure(
        'dbo.mssql_native_tvp_sum',
        parameters: <String, Object?>{
          'rows': const MssqlTableRows(<Map<String, Object?>>[
            <String, Object?>{'id': 9, 'label': 'dokuz', 'amount': null},
          ]),
        },
        outputParameters: <String>{'total'},
      );
      expect(result.resultSets.single.rows.single['id'], 9);
      expect(result.resultSets.single.rows.single['amount'], isNull);
      expect(result.outputParameters['total'].toString(), '0.00000000');
    });

    test('a scalar parameter left out still takes its default', () async {
      final result = await connection.callProcedure(
        'dbo.mssql_native_tvp_sum',
        parameters: <String, Object?>{
          'rows': <Map<String, Object?>>[
            <String, Object?>{
              'id': 1,
              'label': null,
              'amount': MssqlValue.decimal('3', precision: 28, scale: 8),
            },
          ],
        },
        outputParameters: <String>{'total'},
      );
      expect(
        result.outputParameters['total'].toString(),
        '6.00000000',
        reason: 'the declared default of 2 applied',
      );
    });

    test('an empty table is a legitimate argument', () async {
      final result = await connection.callProcedure(
        'dbo.mssql_native_tvp_sum',
        parameters: <String, Object?>{'rows': const <Map<String, Object?>>[]},
        outputParameters: <String>{'total'},
      );
      expect(result.outputParameters['total'].toString(), '0.00000000');
      expect(result.resultSets.single.rows, isEmpty);
    });

    test('two table parameters in one call stay apart', () async {
      final result = await connection.callProcedure(
        'dbo.mssql_native_tvp_pair',
        parameters: <String, Object?>{
          'rows': <Map<String, Object?>>[
            for (var i = 1; i <= 4; i++)
              <String, Object?>{'id': i, 'label': 's-$i', 'amount': null},
          ],
          'tags': <Map<String, Object?>>[
            <String, Object?>{'tag': 'çay'},
            <String, Object?>{'tag': 'ağaç'},
          ],
        },
      );
      final row = result.resultSets.single.rows.single;
      expect(row['rows_seen'], 4);
      expect(row['tags_seen'], 2);
      expect(row['first_tag'], 'ağaç');
    });

    test(
      'Turkish text and exact decimals survive the staging round trip',
      () async {
        const labels = <String>['şğüıöç', 'İĞÜ', 'ıIiİ'];
        const amounts = <String>[
          '12345678901234.12345678',
          '-0.00000001',
          '99999999999.99999999',
        ];
        final result = await connection.callProcedure(
          'dbo.mssql_native_tvp_sum',
          parameters: <String, Object?>{
            'rows': <Map<String, Object?>>[
              for (var i = 0; i < labels.length; i++)
                <String, Object?>{
                  'id': i,
                  'label': labels[i],
                  'amount': MssqlValue.decimal(
                    amounts[i],
                    precision: 28,
                    scale: 8,
                  ),
                },
            ],
            'factor': 1,
          },
          outputParameters: <String>{'total'},
        );
        final rows = result.resultSets.single.rows;
        expect(rows.map((row) => row['label']), labels);
        expect(rows.map((row) => row['amount'].toString()), amounts);
      },
    );

    test('a large table goes through in one bulk load', () async {
      final result = await connection.callProcedure(
        'dbo.mssql_native_tvp_sum',
        parameters: <String, Object?>{
          'rows': <Map<String, Object?>>[
            for (var i = 1; i <= 20000; i++)
              <String, Object?>{
                'id': i,
                'label': 'satır-$i',
                'amount': MssqlValue.decimal(
                  '0.00000001',
                  precision: 28,
                  scale: 8,
                ),
              },
          ],
          'factor': 1,
        },
        outputParameters: <String>{'total'},
        maximumRows: 5,
      );
      expect(result.outputParameters['total'].toString(), '0.00020000');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('the same connection can do it again and again', () async {
      for (var attempt = 0; attempt < 5; attempt++) {
        final result = await connection.callProcedure(
          'dbo.mssql_native_tvp_sum',
          parameters: <String, Object?>{
            'rows': <Map<String, Object?>>[
              <String, Object?>{
                'id': attempt,
                'label': 'tur-$attempt',
                'amount': MssqlValue.decimal('1', precision: 28, scale: 8),
              },
            ],
            'factor': attempt + 1,
          },
          outputParameters: <String>{'total'},
        );
        expect(
          result.outputParameters['total'].toString(),
          '${attempt + 1}.00000000',
        );
        expect(await leftoverStagingTables(), 0, reason: 'attempt $attempt');
      }
    });

    group('rows that do not fit the type', () {
      test('a row missing one of the type\'s columns names it', () async {
        try {
          await connection.callProcedure(
            'dbo.mssql_native_tvp_sum',
            parameters: <String, Object?>{
              'rows': <Map<String, Object?>>[
                <String, Object?>{'id': 1, 'label': 'tam', 'amount': null},
                <String, Object?>{'id': 2, 'label': 'eksik'},
              ],
            },
            outputParameters: <String>{'total'},
          );
          fail('the second row had to be rejected');
        } on MssqlBulkRowException catch (error) {
          expect(error.rowIndex, 1);
          expect(error.columnName, 'amount');
        }
        expect(await connection.queryScalar<int>('SELECT 1'), 1);
      });

      test('a row with a column the type does not have is rejected', () async {
        await expectLater(
          connection.callProcedure(
            'dbo.mssql_native_tvp_sum',
            parameters: <String, Object?>{
              'rows': <Map<String, Object?>>[
                <String, Object?>{
                  'id': 1,
                  'label': 'x',
                  'amount': null,
                  'extra': 1,
                },
              ],
            },
            outputParameters: <String>{'total'},
          ),
          throwsA(isA<MssqlBulkRowException>()),
        );
      });

      test('a value the column cannot hold is a conversion error', () async {
        await expectLater(
          connection.callProcedure(
            'dbo.mssql_native_tvp_sum',
            parameters: <String, Object?>{
              'rows': <Map<String, Object?>>[
                <String, Object?>{
                  'id': DateTime.utc(2026),
                  'label': 'x',
                  'amount': null,
                },
              ],
            },
            outputParameters: <String>{'total'},
          ),
          throwsA(
            isA<MssqlException>().having(
              (e) => e.type,
              'type',
              MssqlErrorType.conversion,
            ),
          ),
        );
        expect(await connection.queryScalar<int>('SELECT 1'), 1);
      });

      test(
        'a null in a NOT NULL column of the type is the server\'s error',
        () async {
          await expectLater(
            connection.callProcedure(
              'dbo.mssql_native_tvp_sum',
              parameters: <String, Object?>{
                'rows': <Map<String, Object?>>[
                  <String, Object?>{'id': null, 'label': 'x', 'amount': null},
                ],
              },
              outputParameters: <String>{'total'},
            ),
            throwsA(isA<MssqlException>()),
          );
        },
      );

      test('something that is not rows at all is refused up front', () async {
        await expectLater(
          connection.callProcedure(
            'dbo.mssql_native_tvp_sum',
            parameters: <String, Object?>{'rows': 42},
            outputParameters: <String>{'total'},
          ),
          throwsA(isA<ArgumentError>()),
        );
        expect(await connection.queryScalar<int>('SELECT 1'), 1);
      });
    });

    test('a pooled connection is returned in a reusable state', () async {
      final pool = MssqlConnectionPool(
        liveConfig(decimalMode: MssqlDecimalMode.text),
        poolConfig: const MssqlPoolConfig(maximumSize: 1),
      );
      addTearDown(pool.close);
      for (var attempt = 0; attempt < 3; attempt++) {
        await pool.withConnection((borrowed) async {
          final result = await borrowed.callProcedure(
            'dbo.mssql_native_tvp_sum',
            parameters: <String, Object?>{
              'rows': <Map<String, Object?>>[
                <String, Object?>{
                  'id': attempt,
                  'label': 'havuz',
                  'amount': MssqlValue.decimal('2', precision: 28, scale: 8),
                },
              ],
              'factor': 1,
            },
            outputParameters: <String>{'total'},
          );
          expect(result.outputParameters['total'].toString(), '2.00000000');
        });
      }
    });
  }, skip: liveSkip);
}

