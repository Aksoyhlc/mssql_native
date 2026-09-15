import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

import 'support/live_server.dart';

void main() {
  group('metadata-driven bulk insert', () {
    late MssqlConnection connection;
    const table = 'dbo.mssql_native_meta_bulk';

    setUpAll(initializeLive);
    tearDownAll(() async {
      final cleanup = await MssqlConnection.open(liveConfig());
      try {
        await cleanup.execute('DROP TABLE IF EXISTS $table;');
      } finally {
        await cleanup.close();
        await MssqlRuntime.instance.shutdown();
      }
    });

    tearDown(() async {
      if (!connection.isClosed) await connection.close();
    });

    setUp(() async {
      connection = await MssqlConnection.open(
        liveConfig(decimalMode: MssqlDecimalMode.text),
      );
      await connection.execute('''
DROP TABLE IF EXISTS $table;
CREATE TABLE $table (
  id INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
  label NVARCHAR(40) NOT NULL,
  amount DECIMAL(28,8) NULL,
  note NVARCHAR(30) NOT NULL CONSTRAINT DF_meta_note DEFAULT N'generated',
  label_length AS LEN(label),
  version ROWVERSION NOT NULL
);
''');
    });

    Future<List<Map<String, Object?>>> contents() => connection.queryRows(
      'SELECT id, label, amount, note FROM $table ORDER BY id',
    );

    group('column selection', () {
      test(
        'columns come from the first row and generated ones are excluded',
        () async {
          final result = await connection.bulkInsert(
            tableName: table,
            rows: <Map<String, Object?>>[
              <String, Object?>{'label': 'bir'},
              <String, Object?>{'label': 'iki'},
            ],
          );
          expect(result.insertedRows, 2);
          final rows = await contents();
          expect(rows.map((row) => row['label']), <String>['bir', 'iki']);
          expect(rows.map((row) => row['note']), <String>[
            'generated',
            'generated',
          ], reason: 'the default filled the column the caller did not send');
          expect(rows.map((row) => row['id']), <int>[
            1,
            2,
          ], reason: 'the identity belongs to the server');
        },
      );

      test(
        'an explicit subset is honoured whatever order it is given in',
        () async {
          await connection.bulkInsert(
            tableName: table,
            columns: <String>['note', 'label'],
            rows: <Map<String, Object?>>[
              <String, Object?>{'note': 'elle', 'label': 'ters'},
            ],
          );
          final rows = await contents();
          expect(rows.single['label'], 'ters');
          expect(rows.single['note'], 'elle');
        },
      );

      test('an unknown column is refused before anything is sent', () async {
        await expectLater(
          connection.bulkInsert(
            tableName: table,
            columns: <String>['label', 'no_such_column'],
            rows: <Map<String, Object?>>[
              <String, Object?>{'label': 'x', 'no_such_column': 1},
            ],
          ),
          throwsA(isA<ArgumentError>()),
        );
        expect(await contents(), isEmpty);
      });

      test('a computed column cannot be written', () async {
        await expectLater(
          connection.bulkInsert(
            tableName: table,
            columns: <String>['label', 'label_length'],
            rows: <Map<String, Object?>>[
              <String, Object?>{'label': 'x', 'label_length': 1},
            ],
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('a rowversion column cannot be written', () async {
        await expectLater(
          connection.bulkInsert(
            tableName: table,
            columns: <String>['label', 'version'],
            rows: <Map<String, Object?>>[
              <String, Object?>{'label': 'x', 'version': 1},
            ],
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test(
        'an identity column needs keepIdentity, and keepIdentity needs one',
        () async {
          await expectLater(
            connection.bulkInsert(
              tableName: table,
              columns: <String>['id', 'label'],
              rows: <Map<String, Object?>>[
                <String, Object?>{'id': 7, 'label': 'x'},
              ],
            ),
            throwsA(isA<ArgumentError>()),
          );
          await expectLater(
            connection.bulkInsert(
              tableName: table,
              columns: <String>['label'],
              rows: <Map<String, Object?>>[
                <String, Object?>{'label': 'x'},
              ],
              options: const MssqlBulkOptions(keepIdentity: true),
            ),
            throwsA(isA<ArgumentError>()),
          );
          await connection.bulkInsert(
            tableName: table,
            columns: <String>['id', 'label'],
            rows: <Map<String, Object?>>[
              <String, Object?>{'id': 41, 'label': 'x'},
            ],
            options: const MssqlBulkOptions(keepIdentity: true),
          );
          expect((await contents()).single['id'], 41);
        },
      );

      test('duplicate or empty column lists are refused', () {
        expect(
          () => connection.bulkInsert(
            tableName: table,
            columns: <String>['label', 'label'],
            rows: <Map<String, Object?>>[
              <String, Object?>{'label': 'x'},
            ],
          ),
          throwsArgumentError,
        );
        expect(
          () => connection.bulkInsert(
            tableName: table,
            columns: <String>[],
            rows: <Map<String, Object?>>[
              <String, Object?>{'label': 'x'},
            ],
          ),
          throwsArgumentError,
        );
      });

      test('no rows means no work and no error', () async {
        final result = await connection.bulkInsert(
          tableName: table,
          rows: const <Map<String, Object?>>[],
        );
        expect(result.totalRows, 0);
        expect(result.insertedRows, 0);
        expect(await contents(), isEmpty);
      });
    });

    group('rows that disagree with the first one', () {
      test(
        'a later row missing a column names the row and the column',
        () async {
          try {
            await connection.bulkInsert(
              tableName: table,
              rows: <Map<String, Object?>>[
                <String, Object?>{'label': 'bir', 'note': 'a'},
                <String, Object?>{'label': 'iki', 'note': 'b'},
                <String, Object?>{'label': 'üç'},
              ],
            );
            fail('the third row had to be rejected');
          } on MssqlBulkRowException catch (error) {
            expect(error.rowIndex, 2);
            expect(error.columnName, 'note');
            expect(error.message, contains('missing'));
          }
          expect(
            await contents(),
            isEmpty,
            reason: 'an atomic load must not leave the first rows behind',
          );
        },
      );

      test('a later row with an extra column is rejected too', () async {
        try {
          await connection.bulkInsert(
            tableName: table,
            rows: <Map<String, Object?>>[
              <String, Object?>{'label': 'bir'},
              <String, Object?>{'label': 'iki', 'note': 'fazla'},
            ],
          );
          fail('the second row had to be rejected');
        } on MssqlBulkRowException catch (error) {
          expect(error.rowIndex, 1);
          expect(error.columnName, 'note');
          expect(error.message, contains('outside the selected set'));
        }
      });

      test('a value the column cannot hold names its row', () async {
        try {
          await connection.bulkInsert(
            tableName: table,
            rows: <Map<String, Object?>>[
              <String, Object?>{'label': 'bir'},
              <String, Object?>{'label': DateTime.utc(2026)},
            ],
          );
          fail('the second row had to be rejected');
        } on MssqlException catch (error) {
          expect(error.type, MssqlErrorType.conversion);
        }
        expect(await contents(), isEmpty);
      });

      test(
        'a null in a NOT NULL column fails and the connection survives',
        () async {
          await expectLater(
            connection.bulkInsert(
              tableName: table,
              rows: <Map<String, Object?>>[
                <String, Object?>{'label': null},
              ],
            ),
            throwsA(isA<MssqlException>()),
          );
          expect(await connection.queryScalar<int>('SELECT 1'), 1);
          expect(await contents(), isEmpty);
        },
      );

      test(
        'an iterator that throws leaves the table and connection clean',
        () async {
          Iterable<Map<String, Object?>> rows() sync* {
            yield <String, Object?>{'label': 'bir'};
            yield <String, Object?>{'label': 'iki'};
            throw StateError('the source gave up');
          }

          await expectLater(
            connection.bulkInsert(tableName: table, rows: rows()),
            throwsA(isA<StateError>()),
          );
          expect(await contents(), isEmpty);
          expect(await connection.queryScalar<int>('SELECT 1'), 1);
        },
      );
    });

    group('batches and progress', () {
      test('a batched load reports its batches and every row lands', () async {
        final result = await connection.bulkInsert(
          tableName: table,
          rows: <Map<String, Object?>>[
            for (var i = 0; i < 250; i++)
              <String, Object?>{'label': 'satır-$i'},
          ],
          options: const MssqlBulkOptions(
            mode: MssqlBulkMode.batched,
            batchSize: 100,
          ),
        );
        expect(result.totalRows, 250);
        expect(result.insertedRows, 250);
        expect(result.committedBatches, greaterThanOrEqualTo(3));
        expect(
          await connection.queryScalar<int>('SELECT COUNT(*) FROM $table'),
          250,
        );
      });

      test(
        'a row count that is an exact multiple of the batch size counts once',
        () async {
          for (final (rows, batch, expected) in <(int, int, int)>[
            (100, 100, 1),
            (200, 100, 2),
            (250, 100, 3),
          ]) {
            await connection.execute('TRUNCATE TABLE $table;');
            final result = await connection.bulkInsert(
              tableName: table,
              rows: <Map<String, Object?>>[
                for (var i = 0; i < rows; i++)
                  <String, Object?>{'label': 'satır-$i'},
              ],
              options: MssqlBulkOptions(
                mode: MssqlBulkMode.batched,
                batchSize: batch,
              ),
            );
            final reason = '$rows rows in batches of $batch';
            expect(result.totalRows, rows, reason: reason);
            expect(result.insertedRows, rows, reason: reason);
            expect(result.committedBatches, expected, reason: reason);
            expect(
              await connection.queryScalar<int>('SELECT COUNT(*) FROM $table'),
              rows,
              reason: reason,
            );
          }
        },
      );

      test('progress is reported in order and never overcounts', () async {
        final seen = <int>[];
        final result = await connection.bulkInsert(
          tableName: table,
          rows: <Map<String, Object?>>[
            for (var i = 0; i < 120; i++) <String, Object?>{'label': 's-$i'},
          ],
          options: const MssqlBulkOptions(
            mode: MssqlBulkMode.batched,
            batchSize: 40,
          ),
          onProgress: seen.add,
        );
        expect(seen, isNotEmpty);
        expect(seen, orderedEquals(<int>[...seen]..sort()));
        expect(seen.last, result.totalRows);
        expect(seen.every((sent) => sent <= 120), isTrue);
      });

      test('an atomic load abandoned by the caller commits nothing', () async {
        await expectLater(
          connection.bulkInsert(
            tableName: table,
            rows: <Map<String, Object?>>[
              for (var i = 0; i < 120; i++) <String, Object?>{'label': 'p-$i'},
            ],
            options: const MssqlBulkOptions(batchSize: 40),
            onProgress: (_) => throw StateError('callback blew up'),
          ),
          throwsA(isA<StateError>()),
        );
        expect(connection.isClosed, isTrue);

        final check = await MssqlConnection.open(liveConfig());
        addTearDown(check.close);
        expect(
          await check.queryScalar<int>('SELECT COUNT(*) FROM $table'),
          0,
          reason: 'an atomic load is all or nothing',
        );
      });

      test(
        'a batched load abandoned by the caller keeps whole batches',
        () async {
          await expectLater(
            connection.bulkInsert(
              tableName: table,
              rows: <Map<String, Object?>>[
                for (var i = 0; i < 120; i++)
                  <String, Object?>{'label': 'b-$i'},
              ],
              options: const MssqlBulkOptions(
                mode: MssqlBulkMode.batched,
                batchSize: 40,
              ),
              onProgress: (_) => throw StateError('callback blew up'),
            ),
            throwsA(isA<StateError>()),
          );
          expect(connection.isClosed, isTrue);

          final check = await MssqlConnection.open(liveConfig());
          addTearDown(check.close);
          final count = await check.queryScalar<int>(
            'SELECT COUNT(*) FROM $table',
          );
          expect(
            count % 40,
            0,
            reason: 'batched means committed batches survive, and only those',
          );
        },
      );

      test(
        'a pool replaces the connection an abandoned copy cost it',
        () async {
          final pool = MssqlConnectionPool(
            liveConfig(),
            poolConfig: const MssqlPoolConfig(maximumSize: 1),
          );
          addTearDown(pool.close);
          MssqlConnection? borrowed;
          await expectLater(
            pool.withConnection<void>((connection) async {
              borrowed = connection;
              await connection.bulkInsert(
                tableName: table,
                rows: <Map<String, Object?>>[
                  for (var i = 0; i < 120; i++)
                    <String, Object?>{'label': 'q-$i'},
                ],
                options: const MssqlBulkOptions(batchSize: 40),
                onProgress: (_) => throw StateError('callback blew up'),
              );
            }),
            throwsA(isA<StateError>()),
          );
          expect(borrowed!.isClosed, isTrue);
          await pool.withConnection((next) async {
            expect(identical(next, borrowed), isFalse);
            expect(await next.queryScalar<int>('SELECT 1'), 1);
          });
        },
      );
    });

    group('values survive the round trip exactly', () {
      test('a 28,8 decimal comes back digit for digit', () async {
        const values = <String>[
          '12345678901234567890.12345678',
          '-12345678901234567890.12345678',
          '0.00000001',
          '99999999999999999999.99999999',
        ];
        await connection.bulkInsert(
          tableName: table,
          rows: <Map<String, Object?>>[
            for (final value in values)
              <String, Object?>{
                'label': value.length.toString(),
                'amount': MssqlValue.decimal(value, precision: 28, scale: 8),
              },
          ],
        );
        final rows = await connection.queryRows(
          'SELECT amount FROM $table ORDER BY id',
        );
        expect(rows.map((row) => row['amount'].toString()), values);
      });

      test('Turkish text and its length survive the metadata path', () async {
        const labels = <String>['şğüıöçİĞÜ', 'ÇOK-uzun-ŞEY', 'ıIiİ'];
        await connection.bulkInsert(
          tableName: table,
          rows: <Map<String, Object?>>[
            for (final label in labels) <String, Object?>{'label': label},
          ],
        );
        final rows = await connection.queryRows(
          'SELECT label, label_length FROM $table ORDER BY id',
        );
        expect(rows.map((row) => row['label']), labels);
        expect(
          rows.map((row) => row['label_length']),
          labels.map((label) => label.length),
        );
      });

      test('nulls stay null and defaults still apply per column', () async {
        await connection.bulkInsert(
          tableName: table,
          columns: <String>['label', 'amount'],
          rows: <Map<String, Object?>>[
            <String, Object?>{'label': 'bos', 'amount': null},
          ],
        );
        final row = (await contents()).single;
        expect(row['amount'], isNull);
        expect(row['note'], 'generated');
      });
    });
  }, skip: liveSkip);
}

