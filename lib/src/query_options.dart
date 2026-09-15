import 'cancellation.dart';

/// Whether a command may be run a second time when the connection dies
/// mid-flight.
///
/// Not inferred from the shape of the result: `INSERT … OUTPUT` and procedures
/// that write and select also return rows, so the driver does not guess.
enum MssqlRetryPolicy {
  /// Never re-run. The default everywhere in the driver.
  ///
  /// A lost connection surfaces as an error the caller decides about, with the
  /// command's outcome reported as unknown when the server never answered.
  never,

  /// Re-run once, after reconnecting, when the failure was a lost connection.
  ///
  /// Only for a command the caller knows has no side effects. The ORM sets
  /// this for a read it compiled itself and can prove is a plain SELECT; it is
  /// never set for raw SQL, for a procedure, or for anything inside a
  /// transaction, where a reconnect would silently drop the transaction.
  idempotentRead,
}

/// The execution settings every layer carries: driver, pool, transaction and
/// the ORM on top of them.
///
/// One reusable object so a timeout and token chosen once are not retyped at
/// every call site and cannot be dropped when a request crosses a layer.
final class MssqlQueryOptions {
  const MssqlQueryOptions({
    this.timeout,
    this.cancellationToken,
    this.batchRows = defaultBatchRows,
    this.maximumRows = 0,
    this.maximumBytes = 0,
    this.retry = MssqlRetryPolicy.never,
    this.queryName,
  });

  /// Rows fetched from the server per round of decoding, shared by
  /// connections, transactions and the pool.
  static const int defaultBatchRows = 500;

  /// Settings with every default. Cheap to pass; a `const` singleton.
  static const MssqlQueryOptions defaults = MssqlQueryOptions();

  /// How long the server is given, or null for the connection's configured
  /// default query timeout.
  final Duration? timeout;

  /// Cancels the operation, including while it is queued behind another one on
  /// the same connection.
  final MssqlCancellationToken? cancellationToken;

  /// Rows per fetch. Must be positive.
  final int batchRows;

  /// Stop after this many rows; 0 means no cap.
  final int maximumRows;

  /// Stop after this many decoded bytes; 0 means no cap.
  final int maximumBytes;

  /// Whether the driver may re-run the command after a lost connection.
  final MssqlRetryPolicy retry;

  /// A short label for the statement, carried on any failure it causes.
  ///
  /// SQL text is never put in exceptions or logs because it can contain
  /// literals or parameter values; this names the statement instead, for
  /// example `'orders.byDate'`. Reaches the caller as
  /// `MssqlException.queryName`.
  final String? queryName;

  /// Applies arguments a caller passed explicitly on top of these options.
  ///
  /// Every parameter is nullable so null can mean "not given", distinct from
  /// the field's default: a call site can override one setting without
  /// resetting the rest.
  MssqlQueryOptions merge({
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
    int? batchRows,
    int? maximumRows,
    int? maximumBytes,
    MssqlRetryPolicy? retry,
    String? queryName,
  }) {
    if (timeout == null &&
        cancellationToken == null &&
        batchRows == null &&
        maximumRows == null &&
        maximumBytes == null &&
        retry == null &&
        queryName == null) {
      return this;
    }
    return MssqlQueryOptions(
      timeout: timeout ?? this.timeout,
      cancellationToken: cancellationToken ?? this.cancellationToken,
      batchRows: batchRows ?? this.batchRows,
      maximumRows: maximumRows ?? this.maximumRows,
      maximumBytes: maximumBytes ?? this.maximumBytes,
      retry: retry ?? this.retry,
      queryName: queryName ?? this.queryName,
    );
  }

  /// These options under a different label, for reusing a configured object
  /// across statements that stay distinguishable in a log.
  MssqlQueryOptions named(String name) =>
      queryName == name ? this : merge(queryName: name);

  /// These options with retry forced off: inside a transaction, or for any
  /// command the driver did not build.
  MssqlQueryOptions get withoutRetry => retry == MssqlRetryPolicy.never
      ? this
      : merge(retry: MssqlRetryPolicy.never);

  /// These options capped to [rows], for existence checks.
  MssqlQueryOptions limitedTo(int rows) =>
      maximumRows == rows ? this : merge(maximumRows: rows);

  @override
  String toString() =>
      'MssqlQueryOptions(timeout: $timeout, batchRows: $batchRows, '
      'maximumRows: $maximumRows, maximumBytes: $maximumBytes, '
      'retry: ${retry.name}'
      '${queryName == null ? '' : ', queryName: $queryName'}'
      '${cancellationToken == null ? '' : ', cancellable'})';
}
