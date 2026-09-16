import '../exception.dart';
import '../models/bulk.dart';
import '../models/parameter.dart';
import '../models/result.dart';
import '../models/types.dart';
import '../sql.dart';

class ProcedureParameterMetadata {
  const ProcedureParameterMetadata({
    required this.name,
    required this.type,
    required this.size,
    required this.precision,
    required this.scale,
    required this.isOutput,
    required this.isReadOnly,
    this.tableTypeName,
    this.tableTypeSchema,
  });

  final String name;
  final MssqlType type;
  final int size;
  final int precision;
  final int scale;
  final bool isOutput;
  final bool isReadOnly;

  /// Set only for a table-valued parameter, naming the type to build.
  final String? tableTypeName;
  final String? tableTypeSchema;

  bool get isTableType => tableTypeName != null;

  String get quotedTableType => MssqlSql.quoteMultipartIdentifier(<String>[
    tableTypeSchema ?? 'dbo',
    tableTypeName!,
  ]);
}

class BulkColumnMetadata {
  const BulkColumnMetadata({
    required this.column,
    required this.identity,
    required this.computed,
    required this.hidden,
    required this.rowVersion,
  });

  final MssqlBulkColumn column;
  final bool identity;
  final bool computed;
  final bool hidden;
  final bool rowVersion;
}

/// The SQL type a catalog view names, as this driver binds it.
MssqlType typeFromSqlName(String name) => switch (name.toLowerCase()) {
  'bit' => MssqlType.bit,
  'tinyint' => MssqlType.tinyInt,
  'smallint' => MssqlType.smallInt,
  'int' => MssqlType.int32,
  'bigint' => MssqlType.int64,
  'real' => MssqlType.real,
  'float' => MssqlType.float64,
  'decimal' => MssqlType.decimal,
  'numeric' => MssqlType.numeric,
  'money' => MssqlType.money,
  'smallmoney' => MssqlType.smallMoney,
  'char' => MssqlType.char,
  'varchar' => MssqlType.varchar,
  'nchar' => MssqlType.nchar,
  'nvarchar' || 'sysname' => MssqlType.nvarchar,
  'text' => MssqlType.text,
  'ntext' => MssqlType.ntext,
  'binary' => MssqlType.binary,
  'varbinary' => MssqlType.varbinary,
  'image' => MssqlType.image,
  'date' => MssqlType.date,
  'time' => MssqlType.time,
  'smalldatetime' => MssqlType.smallDateTime,
  'datetime' => MssqlType.dateTime,
  'datetime2' => MssqlType.dateTime2,
  'datetimeoffset' => MssqlType.dateTimeOffset,
  'uniqueidentifier' => MssqlType.uniqueIdentifier,
  'xml' => MssqlType.xml,
  final unsupported => throw MssqlException(
    type: MssqlErrorType.unsupportedType,
    message: 'SQL type "$unsupported" is not supported by this operation.',
  ),
};

int metadataSize(MssqlType type, int maxLength) {
  if (maxLength < 0) return 0;
  if (type == MssqlType.nchar || type == MssqlType.nvarchar) {
    return maxLength ~/ 2;
  }
  return maxLength;
}

/// Describes a stored procedure's parameters from the catalog views.
///
/// [catalog] is the database prefix for a three-part name, empty otherwise.
String procedureMetadataSql(String catalog) =>
    '''
DECLARE @object_id int = OBJECT_ID(@procedure, 'P');
IF @object_id IS NULL
BEGIN
  RAISERROR('Stored procedure was not found.', 16, 1);
  RETURN;
END;
SELECT
  p.name,
  COALESCE(t.name, user_type.name) AS type_name,
  user_type.name AS user_type_name,
  SCHEMA_NAME(user_type.schema_id) AS user_type_schema,
  p.max_length,
  p.precision,
  p.scale,
  p.is_output,
  p.is_readonly,
  user_type.is_table_type
FROM ${catalog}sys.parameters AS p
JOIN ${catalog}sys.types AS user_type
  ON user_type.user_type_id = p.user_type_id
-- LEFT, because a table type has no base row here: an inner join dropped the
-- parameter entirely, and the caller was told the procedure had no such
-- parameter instead of that table-valued parameters are not supported.
LEFT JOIN ${catalog}sys.types AS t
  ON t.system_type_id = p.system_type_id
 AND t.user_type_id = t.system_type_id
WHERE p.object_id = @object_id
  AND p.parameter_id > 0
ORDER BY p.parameter_id;
''';

List<ProcedureParameterMetadata> decodeProcedureMetadata(
  MssqlExecutionResult result,
) {
  if (result.resultSets.isEmpty) return const <ProcedureParameterMetadata>[];
  return result.resultSets.first.typedRows
      .map((row) {
        final rawName = row.require<String>('name');
        final isTableType = row.require<bool>('is_table_type');
        // A table type has no Dart-side equivalent; it is kept in the list
        // only so that naming it produces the unsupported-type error rather
        // than "no such parameter".
        final type = isTableType
            ? MssqlType.nvarchar
            : typeFromSqlName(row.require<String>('type_name'));
        return ProcedureParameterMetadata(
          name: normalizeParameterName(rawName),
          type: type,
          size: metadataSize(type, row.require<int>('max_length')),
          precision: row.require<int>('precision'),
          scale: row.require<int>('scale'),
          isOutput: row.require<bool>('is_output'),
          isReadOnly: row.require<bool>('is_readonly') || isTableType,
          tableTypeName: isTableType
              ? row.require<String>('user_type_name')
              : null,
          tableTypeSchema: isTableType
              ? row.require<String>('user_type_schema')
              : null,
        );
      })
      .toList(growable: false);
}

/// Describes the columns of a table type, so rows can be staged for it.
const String tableTypeColumnsSql = '''
SELECT
  c.column_id,
  c.name,
  t.name AS type_name,
  c.max_length,
  c.precision,
  c.scale,
  c.is_nullable
FROM sys.table_types AS tt
JOIN sys.columns AS c ON c.object_id = tt.type_table_object_id
JOIN sys.types AS t
  ON t.system_type_id = c.system_type_id
 AND t.user_type_id = t.system_type_id
WHERE tt.name = @type_name AND SCHEMA_NAME(tt.schema_id) = @type_schema
ORDER BY c.column_id;
''';

List<MssqlBulkColumn> decodeTableTypeColumns(MssqlExecutionResult result) {
  if (result.resultSets.isEmpty) return const <MssqlBulkColumn>[];
  return result.resultSets.first.typedRows
      .map((row) {
        final type = typeFromSqlName(row.require<String>('type_name'));
        return MssqlBulkColumn(
          ordinal: row.require<int>('column_id'),
          name: row.require<String>('name'),
          type: type,
          size: metadataSize(type, row.require<int>('max_length')),
          precision: row.require<int>('precision'),
          scale: row.require<int>('scale'),
          nullable: row.require<bool>('is_nullable'),
        );
      })
      .toList(growable: false);
}

/// Describes a bulk destination table.
///
/// [catalog] is the database prefix for a three-part name, empty otherwise.
/// [hidden] is the expression yielding `is_hidden`, which older servers lack.
String tableMetadataSql({required String catalog, required String hidden}) =>
    '''
DECLARE @object_id int = OBJECT_ID(@table, 'U');
IF @object_id IS NULL
BEGIN
  RAISERROR('Bulk destination table was not found.', 16, 1);
  RETURN;
END;
SELECT
  c.column_id,
  c.name,
  t.name AS type_name,
  c.max_length,
  c.precision,
  c.scale,
  c.is_nullable,
  c.is_identity,
  c.is_computed,
  $hidden AS is_hidden
FROM ${catalog}sys.columns AS c
JOIN ${catalog}sys.types AS user_type
  ON user_type.user_type_id = c.user_type_id
JOIN ${catalog}sys.types AS t
  ON t.system_type_id = c.system_type_id
 AND t.user_type_id = t.system_type_id
WHERE c.object_id = @object_id
ORDER BY c.column_id;
''';

List<BulkColumnMetadata> decodeTableMetadata(MssqlExecutionResult result) {
  if (result.resultSets.isEmpty) return const <BulkColumnMetadata>[];
  return result.resultSets.first.typedRows
      .map((row) {
        final typeName = row.require<String>('type_name');
        final rowVersion = typeName == 'timestamp' || typeName == 'rowversion';
        final type = rowVersion
            ? MssqlType.varbinary
            : typeFromSqlName(typeName);
        return BulkColumnMetadata(
          column: MssqlBulkColumn(
            ordinal: row.require<int>('column_id'),
            name: row.require<String>('name'),
            type: type,
            size: metadataSize(type, row.require<int>('max_length')),
            precision: row.require<int>('precision'),
            scale: row.require<int>('scale'),
            nullable: row.require<bool>('is_nullable'),
          ),
          identity: row.require<bool>('is_identity'),
          computed: row.require<bool>('is_computed'),
          hidden: row.require<bool>('is_hidden'),
          rowVersion: rowVersion,
        );
      })
      .toList(growable: false);
}
