import 'package:flutter_test/flutter_test.dart';
import 'package:mssql_native/mssql_native.dart';

import '../support/android_context.dart';

/// Stored procedures: the one call shape that carries result sets, output
/// parameters and a return status at the same time, and the only path that
/// goes through dbrpcinit rather than sp_executesql.
///
/// There is no single-byte OUTPUT parameter here, and that is not an omission.
/// SQL Server gives every variable and parameter the *database's* default
/// collation and offers no way to override it - COLLATE is not accepted in a
/// parameter declaration - so on a Latin1 database a VARCHAR OUTPUT flattens
/// İ to I before the driver ever sees it. The first version of this file
/// asserted otherwise and failed on exactly that. The single-byte path is
/// covered where it can be: a column, in the result set below.
void registerProcedureTests() {
  group('stored procedures', () {
    late MssqlConnection conn;

    setUpAll(() async {
      conn = await sharedConnection();
      // Its own procedure rather than the seeded one: the seeded customers
      // carry no Turkish-specific letters, so asserting about them would prove
      // nothing about the decode path.
      await conn.execute('''
CREATE OR ALTER PROCEDURE dbo.usp_and_echo
    @inbound  NVARCHAR(100),
    @outbound NVARCHAR(100) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @outbound = @inbound;
    SELECT @inbound AS echoed;
    -- The single-byte column, read through the RPC path rather than through
    -- sp_executesql. This is the one that needs iconv.
    SELECT label, label_n FROM dbo.charset_probe;
    RETURN 7;
END
''');
    });

    tearDownAll(
      () async => conn.execute(
        "IF OBJECT_ID('dbo.usp_and_echo','P') IS NOT NULL DROP PROCEDURE dbo.usp_and_echo",
      ),
    );

    testWidgets(
      'multiple result sets, an output parameter and a return status',
      (_) async {
        final result = await conn.callProcedure(
          'dbo.usp_customer_dashboard',
          parameters: [
            MssqlParameter.int32('customer_id', 1),
            MssqlParameter.int32(
              'order_count',
              null,
              direction: MssqlParameterDirection.output,
            ),
          ],
        );
        expect(result.resultSets.length, 2, reason: 'header + order lines');
        expect(result.resultSets[0].rows.single['segment'], 'wholesale');
        expect(result.resultSets[1].rows, isNotEmpty);
        expect(result.outputParameters['order_count'], isA<int>());
        expect(result.outputParameters['order_count'], greaterThan(0));
        expect(result.returnStatus, 0);
      },
    );

    testWidgets('the not-found path returns 404 and a -1 output', (_) async {
      final result = await conn.callProcedure(
        'dbo.usp_customer_dashboard',
        parameters: [
          MssqlParameter.int32('customer_id', 999999),
          MssqlParameter.int32(
            'order_count',
            null,
            direction: MssqlParameterDirection.output,
          ),
        ],
      );
      expect(result.returnStatus, 404);
      expect(result.outputParameters['order_count'], -1);
    });

    testWidgets('a non-zero return status is reported, not swallowed', (
      _,
    ) async {
      final result = await conn.callProcedure(
        'dbo.usp_and_echo',
        parameters: [
          MssqlParameter.nvarchar('inbound', 'plain', size: 100),
          MssqlParameter.nvarchar(
            'outbound',
            null,
            size: 100,
            direction: MssqlParameterDirection.output,
          ),
        ],
      );
      expect(result.returnStatus, 7);
    });

    testWidgets('Turkish text survives an NVARCHAR output parameter', (
      _,
    ) async {
      const text = 'İstanbul Şişli ÇĞİÖŞÜ çğıöşü';
      final result = await conn.callProcedure(
        'dbo.usp_and_echo',
        parameters: [
          MssqlParameter.nvarchar('inbound', text, size: 100),
          MssqlParameter.nvarchar(
            'outbound',
            null,
            size: 100,
            direction: MssqlParameterDirection.output,
          ),
        ],
      );
      expect(
        result.outputParameters['outbound'],
        text,
        reason:
            'an output parameter takes a different decode path '
            'from a result-set column',
      );
      expect(result.resultSets[0].rows.single['echoed'], text);
    });

    testWidgets('a single-byte column survives a procedure result set', (
      _,
    ) async {
      // dbrpcinit rather than sp_executesql, and a CP1254 column at the end of
      // it. Without the bundled libiconv the Turkish letters arrive as Ý/Þ/Ð.
      final result = await conn.callProcedure(
        'dbo.usp_and_echo',
        parameters: [
          MssqlParameter.nvarchar('inbound', 'x', size: 100),
          MssqlParameter.nvarchar(
            'outbound',
            null,
            size: 100,
            direction: MssqlParameterDirection.output,
          ),
        ],
      );
      final probe = result.resultSets[1].rows.single;
      expect(
        probe['label'],
        probe['label_n'],
        reason: 'the single-byte column must match its Unicode mirror',
      );
      expect(probe['label'] as String, contains('ÇÖĞÜŞİ'));
      expect(
        probe['label'] as String,
        isNot(contains('Ý')),
        reason: 'Ý is what a missing iconv produces for İ',
      );
    });
  });
}
