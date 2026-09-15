/// SQL Server driver: connections, sessions, parameters and results.
///
/// Three ways in, one config: [MssqlConnection.connect] (named host /
/// database / username / password), [MssqlConnection.open] (a
/// [MssqlConnectionConfig]), [MssqlConnection.connectString] (.NET-style).
/// Defaults live in [MssqlDefaults]: `decimalMode` is
/// [MssqlDecimalMode.exact], `encryption` is [MssqlEncryption.off].
library;

export 'src/cancellation.dart' show MssqlCancellationToken;
export 'src/connection.dart';
export 'src/connection_pool.dart';
export 'src/exception.dart';
export 'src/metadata_cache.dart'
    show
        MssqlMetadataCache,
        MssqlMetadataDriftPolicy,
        MssqlProcedureMetadata,
        MssqlProcedureParameter;
export 'src/models/bulk.dart';
export 'src/models/config.dart';
export 'src/models/decimal.dart' show MssqlDecimal, MssqlRounding;
export 'src/models/parameter.dart'
    show MssqlDateTimeValue, MssqlParameter, MssqlTableRows, MssqlValue;
export 'src/models/result.dart'
    show
        MssqlColumn,
        MssqlExecutionComplete,
        MssqlExecutionMetrics,
        MssqlExecutionResult,
        MssqlResultSet,
        MssqlResultSetEnd,
        MssqlResultSetMetrics,
        MssqlResultSetStart,
        MssqlRow,
        MssqlRowAccessException,
        MssqlRowBatch,
        MssqlServerInfo,
        MssqlServerMessage,
        MssqlStreamEvent;
export 'src/models/types.dart';
export 'src/query_options.dart' show MssqlQueryOptions, MssqlRetryPolicy;
export 'src/runtime.dart';
export 'src/session.dart' show MssqlSession;
export 'src/session_state.dart' show MssqlSessionState;
export 'src/sql.dart' show MssqlMultipartIdentifier, MssqlSql;
export 'src/transaction.dart';
export 'src/type_codec.dart'
    show MssqlColumnType, MssqlTypeCodec, MssqlTypeCodecs;
