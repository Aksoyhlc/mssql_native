import 'cancellation.dart';
import 'exception.dart';
import 'metadata_cache.dart';
import 'models/bulk.dart';
import 'models/config.dart';
import 'models/result.dart';
import 'models/types.dart';
import 'query_options.dart';

/// Operations shared by connections, transactions and pooled sessions.
///
/// Implementations differ in how they acquire and retain a connection. The
/// query API and derived convenience methods remain the same.
abstract mixin class MssqlSession {
  /// Runs [sql] and buffers every result set.
  ///
  /// [parameters] is either a `Map<String, Object?>` of named parameters or an
  /// `Iterable<MssqlParameter>` for full control over SQL type, size and
  /// direction.
  ///
  /// [options] carries the reusable settings; the named arguments after it
  /// override individual fields when they are given, and change nothing when
  /// they are omitted.
  Future<MssqlExecutionResult> query(
    String sql, {
    Object parameters,
    MssqlQueryOptions options,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
    int? batchRows,
    int? maximumRows,
    int? maximumBytes,
    MssqlRetryPolicy? retry,
  });

  /// Calls a stored procedure, binding parameters from its declared metadata.
  ///
  /// Never retried: a procedure's body is opaque to the driver.
  ///
  /// [declared] is generator-supplied parameter metadata. When it is
  /// present and [driftPolicy] is [MssqlMetadataDriftPolicy.preferDeclared],
  /// the catalog is not queried. [MssqlMetadataDriftPolicy.verifyDeclared]
  /// still describes (through the cache) and refuses when the two disagree.
  Future<MssqlExecutionResult> callProcedure(
    String procedure, {
    Object parameters,
    Set<String> outputParameters,
    MssqlQueryOptions options,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
    int? batchRows,
    int? maximumRows,
    int? maximumBytes,
    MssqlProcedureMetadata? declared,
    MssqlMetadataDriftPolicy driftPolicy,
  });

  /// Runs [sql] and yields results as they arrive, without buffering them all.
  Stream<MssqlStreamEvent> stream(
    String sql, {
    Object parameters,
    MssqlQueryOptions options,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
    int? batchRows,
    int? maximumRows,
    int? maximumBytes,
  });

  /// Checks that the session still answers.
  Future<void> ping({MssqlCancellationToken? cancellationToken});

  /// How the underlying connection was configured.
  ///
  /// Includes settings such as decimal decoding and the default query timeout,
  /// which also apply through transactions and pools.
  MssqlConnectionConfig get config;

  /// The database this session is currently in.
  ///
  /// This can differ from [MssqlConnectionConfig.database] after
  /// [MssqlConnection.useDatabase].
  String get currentDatabase => config.database;

  /// Whether commands on this handle run inside an open transaction.
  bool get inTransaction;

  /// Drops cached procedure and bulk-table metadata.
  ///
  /// A no-op on sessions that do not describe objects. A connection and a
  /// pool clear the cache they share; a transaction forwards to the
  /// connection it holds.
  void invalidateMetadata({String? object}) {}

  // Derived commands

  /// Runs [sql] for its effect and returns the affected row count.
  Future<int> execute(
    String sql, {
    Object parameters = const <String, Object?>{},
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
  }) async {
    final result = await query(
      sql,
      parameters: parameters,
      options: options.withoutRetry,
      timeout: timeout,
      cancellationToken: cancellationToken,
    );
    return result.affectedRows;
  }

  /// The first result set as maps.
  ///
  /// Retry is disabled by default because returning rows does not prove that a
  /// statement is read-only. See [MssqlRetryPolicy].
  Future<List<Map<String, Object?>>> queryRows(
    String sql, {
    Object parameters = const <String, Object?>{},
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
    int? batchRows,
    int? maximumRows,
    int? maximumBytes,
    MssqlRetryPolicy? retry,
  }) async {
    final result = await query(
      sql,
      parameters: parameters,
      options: options,
      timeout: timeout,
      cancellationToken: cancellationToken,
      batchRows: batchRows,
      maximumRows: maximumRows,
      maximumBytes: maximumBytes,
      retry: retry,
    );
    return result.resultSets.isEmpty
        ? const <Map<String, Object?>>[]
        : result.resultSets.first.rows;
  }

  /// The first result set as typed rows, keeping each column's SQL type.
  Future<List<MssqlRow>> queryTypedRows(
    String sql, {
    Object parameters = const <String, Object?>{},
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
    int? batchRows,
    int? maximumRows,
    int? maximumBytes,
    MssqlRetryPolicy? retry,
  }) async {
    final result = await query(
      sql,
      parameters: parameters,
      options: options,
      timeout: timeout,
      cancellationToken: cancellationToken,
      batchRows: batchRows,
      maximumRows: maximumRows,
      maximumBytes: maximumBytes,
      retry: retry,
    );
    return result.resultSets.isEmpty
        ? const <MssqlRow>[]
        : result.resultSets.first.typedRows;
  }

  /// Exactly one row, as a map. More than one is an error, not a choice.
  Future<Map<String, Object?>> querySingle(
    String sql, {
    Object parameters = const <String, Object?>{},
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
  }) async {
    final rows = await queryRows(
      sql,
      parameters: parameters,
      options: options.limitedTo(2),
      timeout: timeout,
      cancellationToken: cancellationToken,
    );
    if (rows.isEmpty) throw const MssqlNoRowsException();
    if (rows.length > 1) throw const MssqlMultipleRowsException();
    return rows.single;
  }

  /// At most one row, as a map.
  Future<Map<String, Object?>?> querySingleOrNull(
    String sql, {
    Object parameters = const <String, Object?>{},
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
  }) async {
    final rows = await queryRows(
      sql,
      parameters: parameters,
      options: options.limitedTo(2),
      timeout: timeout,
      cancellationToken: cancellationToken,
    );
    if (rows.length > 1) throw const MssqlMultipleRowsException();
    return rows.isEmpty ? null : rows.single;
  }

  /// Exactly one typed row.
  Future<MssqlRow> queryTypedSingle(
    String sql, {
    Object parameters = const <String, Object?>{},
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
  }) async {
    final rows = await queryTypedRows(
      sql,
      parameters: parameters,
      options: options.limitedTo(2),
      timeout: timeout,
      cancellationToken: cancellationToken,
    );
    if (rows.isEmpty) throw const MssqlNoRowsException();
    if (rows.length > 1) throw const MssqlMultipleRowsException();
    return rows.single;
  }

  /// At most one typed row.
  Future<MssqlRow?> queryTypedSingleOrNull(
    String sql, {
    Object parameters = const <String, Object?>{},
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
  }) async {
    final rows = await queryTypedRows(
      sql,
      parameters: parameters,
      options: options.limitedTo(2),
      timeout: timeout,
      cancellationToken: cancellationToken,
    );
    if (rows.length > 1) throw const MssqlMultipleRowsException();
    return rows.isEmpty ? null : rows.single;
  }

  /// The first column of the single row, as [T].
  ///
  /// A SQL NULL is a conversion error here unless [T] is nullable; use
  /// [queryScalarOrNull] when NULL is a legitimate answer.
  Future<T> queryScalar<T>(
    String sql, {
    Object parameters = const <String, Object?>{},
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
  }) async {
    final row = await querySingle(
      sql,
      parameters: parameters,
      options: options,
      timeout: timeout,
      cancellationToken: cancellationToken,
    );
    return _scalarOf<T>(row);
  }

  /// The first column of the single row, or null when there is no row.
  Future<T?> queryScalarOrNull<T>(
    String sql, {
    Object parameters = const <String, Object?>{},
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
  }) async {
    final row = await querySingleOrNull(
      sql,
      parameters: parameters,
      options: options,
      timeout: timeout,
      cancellationToken: cancellationToken,
    );
    if (row == null) return null;
    return _scalarOf<T?>(row);
  }

  /// Copies [rows] into [tableName] through BCP.
  ///
  /// Not an INSERT: trigger, CHECK, default and NULL handling follow
  /// [MssqlBulkOptions], which default to BCP's own (triggers off, CHECKs
  /// off, nulls become defaults). A session that cannot bulk-copy — a
  /// hand-written [MssqlSession] — throws rather than falling back to
  /// INSERT, because the two are not interchangeable.
  Future<MssqlBulkResult> bulkInsert({
    required String tableName,
    required Iterable<Object> rows,
    Object? columns,
    MssqlBulkOptions options = const MssqlBulkOptions(),
    MssqlCancellationToken? cancellationToken,
    void Function(int sentRows)? onProgress,
  }) {
    throw StateError(
      'This session cannot bulk-copy. Use a MssqlConnection, a '
      'MssqlTransaction, or a pool handle.',
    );
  }

  static T _scalarOf<T>(Map<String, Object?> row) {
    if (row.isEmpty) {
      throw const MssqlException(
        type: MssqlErrorType.protocol,
        message: 'The scalar query returned no columns.',
      );
    }
    final value = row.values.first;
    if (value is T) return value;
    throw MssqlException(
      type: MssqlErrorType.conversion,
      message: 'The scalar result is ${value?.runtimeType ?? 'NULL'}, not $T.',
    );
  }

  /// Typed rows from a single row-producing result set, as they arrive.
  Stream<MssqlRow> streamRows(
    String sql, {
    Object parameters = const <String, Object?>{},
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
    int? batchRows,
    int? maximumRows,
    int? maximumBytes,
  }) async* {
    var resultSets = 0;
    await for (final event in stream(
      sql,
      parameters: parameters,
      options: options,
      timeout: timeout,
      cancellationToken: cancellationToken,
      batchRows: batchRows,
      maximumRows: maximumRows,
      maximumBytes: maximumBytes,
    )) {
      if (event is MssqlResultSetStart && ++resultSets > 1) {
        throw const MssqlException(
          type: MssqlErrorType.protocol,
          message: 'streamRows supports one row-producing result set.',
        );
      }
      if (event is MssqlRowBatch) {
        for (final row in event.rows) {
          yield row;
        }
      }
    }
  }

  /// Batches of maps from a single row-producing result set.
  Stream<List<Map<String, Object?>>> streamBatches(
    String sql, {
    Object parameters = const <String, Object?>{},
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
    int? batchRows,
    int? maximumRows,
    int? maximumBytes,
  }) async* {
    var resultSets = 0;
    await for (final event in stream(
      sql,
      parameters: parameters,
      options: options,
      timeout: timeout,
      cancellationToken: cancellationToken,
      batchRows: batchRows,
      maximumRows: maximumRows,
      maximumBytes: maximumBytes,
    )) {
      if (event is MssqlResultSetStart && ++resultSets > 1) {
        throw const MssqlException(
          type: MssqlErrorType.protocol,
          message: 'streamBatches supports one row-producing result set.',
        );
      }
      if (event is MssqlRowBatch) {
        yield event.rows.map((row) => row.toMap()).toList(growable: false);
      }
    }
  }
}
