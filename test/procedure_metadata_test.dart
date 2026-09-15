import 'package:mssql_native/mssql_native.dart';
import 'package:test/test.dart';

import 'support/live_server.dart';

void main() {
  group('procedure metadata', () {
    late MssqlConnection connection;

    setUpAll(() async {
      await initializeLive();
      connection = await MssqlConnection.open(
        liveConfig(decimalMode: MssqlDecimalMode.text),
      );
      await connection.execute('''
CREATE OR ALTER PROCEDURE dbo.mssql_native_meta_proc
  @required NVARCHAR(40),
  @optional INT = 7,
  @echo NVARCHAR(40) OUTPUT,
  @amount DECIMAL(28,8) = NULL OUTPUT
AS
BEGIN
  SET NOCOUNT OFF;
  SET @echo = CONCAT(N'yankı:', @required, N':', @optional);
  IF @amount IS NULL SET @amount = 12345678901234567890.12345678;
  SELECT @required AS taken, @optional AS chosen;
  RETURN @optional;
END;
''');
      await connection.execute('''
CREATE OR ALTER PROCEDURE dbo.mssql_native_plain_proc
  @input INT
AS
BEGIN
  SELECT @input AS doubled_input;
END;
''');
    });

    tearDownAll(() async {
      try {
        await connection.execute(
          'DROP PROCEDURE IF EXISTS dbo.mssql_native_meta_proc; '
          'DROP PROCEDURE IF EXISTS dbo.mssql_native_plain_proc;',
        );
      } finally {
        await connection.close();
        await MssqlRuntime.instance.shutdown();
      }
    });

    test(
      'an omitted parameter falls back to the default the server declares',
      () async {
        final result = await connection.callProcedure(
          'dbo.mssql_native_meta_proc',
          parameters: <String, Object?>{'required': 'bir'},
          outputParameters: <String>{'echo'},
        );
        expect(result.outputParameters['echo'], 'yankı:bir:7');
        expect(result.resultSets.single.rows.single['chosen'], 7);
        expect(result.returnStatus, 7);
      },
    );

    test('a supplied value wins over the default', () async {
      final result = await connection.callProcedure(
        'dbo.mssql_native_meta_proc',
        parameters: <String, Object?>{'required': 'iki', 'optional': 41},
        outputParameters: <String>{'echo'},
      );
      expect(result.outputParameters['echo'], 'yankı:iki:41');
      expect(result.returnStatus, 41);
    });

    test(
      'a parameter with no default and no value is the server’s error',
      () async {
        await expectLater(
          connection.callProcedure(
            'dbo.mssql_native_meta_proc',
            parameters: <String, Object?>{},
            outputParameters: <String>{'echo'},
          ),
          throwsA(
            isA<MssqlException>().having(
              (e) => e.message,
              'message',
              contains('required'),
            ),
          ),
        );
        expect(await connection.queryScalar<int>('SELECT 1'), 1);
      },
    );

    test('a name with the sigil means the same parameter', () async {
      final result = await connection.callProcedure(
        'dbo.mssql_native_meta_proc',
        parameters: <String, Object?>{'@required': 'üç', '@optional': 3},
        outputParameters: <String>{'@echo'},
      );
      expect(result.outputParameters['echo'], 'yankı:üç:3');
    });

    test(
      'the same parameter given twice in two spellings is refused',
      () async {
        await expectLater(
          connection.callProcedure(
            'dbo.mssql_native_meta_proc',
            parameters: <String, Object?>{'required': 'a', '@required': 'b'},
            outputParameters: <String>{'echo'},
          ),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    test('a parameter the procedure does not have is refused', () async {
      await expectLater(
        connection.callProcedure(
          'dbo.mssql_native_meta_proc',
          parameters: <String, Object?>{'required': 'a', 'nonexistent': 1},
          outputParameters: <String>{'echo'},
        ),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        connection.callProcedure(
          'dbo.mssql_native_meta_proc',
          parameters: <String, Object?>{'required': 'a'},
          outputParameters: <String>{'nonexistent'},
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'asking for OUTPUT on a parameter that is not declared OUTPUT fails',
      () async {
        await expectLater(
          connection.callProcedure(
            'dbo.mssql_native_meta_proc',
            parameters: <String, Object?>{'required': 'a'},
            outputParameters: <String>{'optional'},
          ),
          throwsA(isA<ArgumentError>()),
        );
        expect(await connection.queryScalar<int>('SELECT 1'), 1);
      },
    );

    test('an INPUT/OUTPUT parameter carries a value in and one out', () async {
      final result = await connection.callProcedure(
        'dbo.mssql_native_meta_proc',
        parameters: <String, Object?>{'required': 'io', 'echo': 'gidecek'},
        outputParameters: <String>{'echo'},
      );
      expect(
        result.outputParameters['echo'],
        'yankı:io:7',
        reason: 'the procedure overwrote what it was given',
      );
    });

    test('an OUTPUT decimal comes back with every digit intact', () async {
      final result = await connection.callProcedure(
        'dbo.mssql_native_meta_proc',
        parameters: <String, Object?>{'required': 'para'},
        outputParameters: <String>{'echo', 'amount'},
      );
      expect(
        result.outputParameters['amount'].toString(),
        '12345678901234567890.12345678',
      );
    });

    test(
      'an OUTPUT parameter that is never assigned comes back null',
      () async {
        await connection.execute('''
CREATE OR ALTER PROCEDURE dbo.mssql_native_silent_proc
  @unset NVARCHAR(20) OUTPUT
AS
BEGIN
  SELECT 1 AS ok;
END;
''');
        addTearDown(
          () => connection.execute(
            'DROP PROCEDURE IF EXISTS dbo.mssql_native_silent_proc;',
          ),
        );
        final result = await connection.callProcedure(
          'dbo.mssql_native_silent_proc',
          parameters: <String, Object?>{},
          outputParameters: <String>{'unset'},
        );
        expect(result.outputParameters.containsKey('unset'), isTrue);
        expect(result.outputParameters['unset'], isNull);
      },
    );

    test('a procedure that does not exist says so, once', () async {
      await expectLater(
        connection.callProcedure(
          'dbo.no_such_procedure_at_all',
          parameters: <String, Object?>{'x': 1},
        ),
        throwsA(
          isA<MssqlException>().having(
            (e) => e.message,
            'message',
            contains('not found'),
          ),
        ),
      );
      expect(await connection.queryScalar<int>('SELECT 1'), 1);
    });

    test(
      'a table-valued parameter is bound from rows, not from a bare list',
      () async {
        await connection.execute('''
IF TYPE_ID(N'dbo.mssql_native_tvp') IS NULL
  CREATE TYPE dbo.mssql_native_tvp AS TABLE (id INT);
''');
        await connection.execute('''
CREATE OR ALTER PROCEDURE dbo.mssql_native_tvp_proc
  @rows dbo.mssql_native_tvp READONLY
AS
BEGIN
  SELECT COUNT(*) AS n FROM @rows;
END;
''');
        addTearDown(() async {
          await connection.execute(
            'DROP PROCEDURE IF EXISTS dbo.mssql_native_tvp_proc;',
          );
          await connection.execute(
            "IF TYPE_ID(N'dbo.mssql_native_tvp') IS NOT NULL "
            'DROP TYPE dbo.mssql_native_tvp;',
          );
        });

        await expectLater(
          connection.callProcedure(
            'dbo.mssql_native_tvp_proc',
            parameters: <String, Object?>{
              'rows': <int>[1, 2],
            },
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.toString(),
              'message',
              contains('MssqlTableRows'),
            ),
          ),
        );

        final result = await connection.callProcedure(
          'dbo.mssql_native_tvp_proc',
          parameters: <String, Object?>{
            'rows': <Map<String, Object?>>[
              <String, Object?>{'id': 1},
              <String, Object?>{'id': 2},
              <String, Object?>{'id': 3},
            ],
          },
        );
        expect(result.resultSets.single.rows.single['n'], 3);
        expect(await connection.queryScalar<int>('SELECT 1'), 1);
      },
    );

    test('a three-part name reads its metadata from that database', () async {
      final database = connection.databaseName;
      final result = await connection.callProcedure(
        '$database.dbo.mssql_native_plain_proc',
        parameters: <String, Object?>{'input': 21},
      );
      expect(result.resultSets.single.rows.single['doubled_input'], 21);
    });

    test(
      'a procedure in another database is reached through its catalog',
      () async {
        await connection.execute('''
IF DB_ID(N'mssql_native_meta_other') IS NULL
  CREATE DATABASE mssql_native_meta_other;
''');
        addTearDown(() async {
          await connection.execute('''
IF DB_ID(N'mssql_native_meta_other') IS NOT NULL
BEGIN
  ALTER DATABASE mssql_native_meta_other SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
  DROP DATABASE mssql_native_meta_other;
END;
''');
        });
        await connection.execute('''
EXEC mssql_native_meta_other..sp_executesql
  N'CREATE OR ALTER PROCEDURE dbo.other_proc @n INT AS SELECT @n * 2 AS doubled;';
''');

        final home = connection.databaseName;
        final result = await connection.callProcedure(
          'mssql_native_meta_other.dbo.other_proc',
          parameters: <String, Object?>{'n': 8},
        );
        expect(result.resultSets.single.rows.single['doubled'], 16);
        expect(
          connection.databaseName,
          home,
          reason: 'reading metadata elsewhere must not move the session',
        );
      },
    );

    test('the explicit parameter API refuses outputParameters', () {
      expect(
        () => connection.callProcedure(
          'dbo.mssql_native_meta_proc',
          parameters: <MssqlParameter>[
            MssqlParameter.nvarchar('required', 'a', size: 40),
          ],
          outputParameters: <String>{'echo'},
        ),
        throwsArgumentError,
      );
    });
  }, skip: liveSkip);
}

