/// SQL Server driver: connections, sessions, parameters and results.
///
/// Three ways in, one config: [MssqlConnection.connect] (named host /
/// database / username / password), [MssqlConnection.open] (a
/// [MssqlConnectionConfig]), [MssqlConnection.connectString] (.NET-style).
/// Defaults live in [MssqlDefaults]: `decimalMode` is
/// [MssqlDecimalMode.exact], `encryption` is [MssqlEncryption.off].
library;

export 'src/cancellation.dart' show MssqlCancellationToken;
export 'src/connection.dart' show MssqlConnection;
export 'src/connection_pool.dart' show MssqlConnectionPool;
export 'src/exception.dart'
    show
        MssqlAuthenticationException,
        MssqlBulkRowException,
        MssqlCancelledException,
        MssqlConnectionException,
        MssqlConstraintException,
        MssqlConversionException,
        MssqlException,
        MssqlMultipleRowsException,
        MssqlNoRowsException,
        MssqlPoolTimeoutException,
        MssqlQueryTimeoutException,
        MssqlTlsException,
        MssqlUnknownCommitOutcomeException;
export 'src/metadata_cache.dart'
    show
        MssqlMetadataCache,
        MssqlMetadataDriftPolicy,
        MssqlProcedureMetadata,
        MssqlProcedureParameter;
export 'src/models/bulk.dart'
    show MssqlBulkColumn, MssqlBulkOptions, MssqlBulkResult;
export 'src/models/config.dart'
    show MssqlConnectionConfig, MssqlDefaults, MssqlPoolConfig, MssqlTlsTrust;
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
export 'src/models/types.dart'
    show
        MssqlBulkMode,
        MssqlDecimalMode,
        MssqlEncryption,
        MssqlErrorType,
        MssqlIsolationLevel,
        MssqlParameterDirection,
        MssqlType;
export 'src/observability.dart'
    show
        MssqlBulkCompleteEvent,
        MssqlBulkErrorEvent,
        MssqlBulkStartEvent,
        MssqlConnectionCloseEvent,
        MssqlConnectionOpenEvent,
        MssqlObservationTarget,
        MssqlObservedError,
        MssqlObserver,
        MssqlPoolMetricsSnapshot,
        MssqlPoolWaitEvent,
        MssqlPoolWaitOutcome,
        MssqlQueryCompleteEvent,
        MssqlQueryErrorEvent,
        MssqlQueryKind,
        MssqlQueryStartEvent,
        MssqlTransactionCompleteEvent,
        MssqlTransactionErrorEvent,
        MssqlTransactionOutcome,
        MssqlTransactionSettlement,
        MssqlTransactionStartEvent;
export 'src/query_options.dart' show MssqlQueryOptions, MssqlRetryPolicy;
export 'src/runtime.dart' show MssqlRuntime, MssqlRuntimeDiagnostics;
export 'src/session.dart' show MssqlSession;
export 'src/sql.dart' show MssqlMultipartIdentifier, MssqlSql;
export 'src/transaction.dart' show MssqlTransaction;
export 'src/type_codec.dart'
    show MssqlColumnType, MssqlTypeCodec, MssqlTypeCodecs;
