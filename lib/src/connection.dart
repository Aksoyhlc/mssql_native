import 'dart:async';

import 'cancellation.dart';
import 'connection/bulk_binder.dart';
import 'connection/login_guard.dart';
import 'connection/metadata_decoder.dart';
import 'connection/operation_gate.dart';
import 'connection/procedure_binder.dart';
import 'connection/row_budget.dart';
import 'exception.dart';
import 'metadata_cache.dart';
import 'models/bulk.dart';
import 'models/config.dart';
import 'models/parameter.dart';
import 'models/result.dart';
import 'models/types.dart';
import 'native/worker.dart';
import 'observability.dart';
import 'query_options.dart';
import 'runtime.dart';
import 'session.dart';
import 'session_state.dart';
import 'sql.dart';
import 'transaction.dart';

/// A single open connection to SQL Server.
///
/// Runs one operation at a time; concurrent calls on the same connection queue.
/// The owner of a connection returned by [open] must [close] it. For concurrent
/// work or short-lived operations, use [MssqlConnectionPool].
class MssqlConnection with MssqlSession {
  MssqlConnection._(
    this.config,
    this._worker,
    this._runtime, {
    MssqlMetadataCache? metadataCache,
    required MssqlObservationDispatcher observationDispatcher,
  }) : _databaseName = _worker.databaseName,
       _observationDispatcher = observationDispatcher,
       connectionId = MssqlObservationDispatcher.newConnectionId(),
       _lifetime = Stopwatch()..start(),
       _sessionState = MssqlSessionState(baselineDatabase: config.database),
       _metadataCache =
           metadataCache ??
           MssqlMetadataCache(
             maxEntries: config.metadataCacheSize,
             ttl: config.metadataCacheTtl,
           );

  @override
  final MssqlConnectionConfig config;
  final MssqlRuntime _runtime;
  final MssqlObservationDispatcher _observationDispatcher;
  final Stopwatch _lifetime;
  ConnectionWorker _worker;
  final OperationGate _operationGate = OperationGate();
  bool _closed = false;
  bool _closeObserved = false;
  Future<void>? _closingFuture;
  bool _leasedByTransaction = false;
  bool? _hasHiddenColumnFlag;
  static int _tableParameterCounter = 0;
  int _repairCount = 0;

  /// Reserved name for the return status of a procedure called through the
  /// table-valued path, where EXEC runs inside a batch.
  static const String _returnStatusParameter = 'mssql_native_return_status';
  int _nextOperationId = 0;
  int? _activeOperationId;
  String _databaseName;
  int? _databaseCodePageCache;
  final MssqlSessionState _sessionState;

  final MssqlMetadataCache _metadataCache;

  bool get isClosed => _closed || _worker.isClosed;
  final int connectionId;
  int get repairCount => _repairCount;

  MssqlObservationTarget get _observationTarget => MssqlObservationTarget(
    host: config.host,
    port: config.port,
    database: _databaseName,
  );

  /// Whether this session holds state the driver cannot undo.
  ///
  /// The pool checks this before reusing a connection; a dirty session is
  /// closed rather than handed on.
  bool get isSessionDirty => _sessionState.isDirty;

  /// Marks session state as unsafe for reuse by a connection pool.
  ///
  /// Call after unmanaged raw SQL changes settings such as `LANGUAGE`,
  /// `CONTEXT_INFO`, or persistent session-scoped temporary objects.
  void markSessionDirty(String reason) => _sessionState.markDirty(reason);
  int get nativeHandle => _closed ? 0 : _worker.dbprocAddress;
  String get databaseName => _databaseName;

  @override
  String get currentDatabase => _databaseName;
  String get negotiatedTdsVersion => tdsVersionName(_worker.negotiatedTdsCode);

  /// Invalidates one object's metadata, or all of it when omitted.
  ///
  /// [object] is a procedure or table name as it would be written in SQL:
  /// `'dbo.create_label'`, `'[dbo].[create_label]'` or `'create_label'`. It is
  /// not a cache key — an entry is keyed by server, database, object and
  /// schema version, so one object holds a family of them. A name given
  /// without a schema matches whichever schema the entry was described
  /// under.
  @override
  void invalidateMetadata({String? object}) {
    if (object == null) {
      _metadataCache.clear();
    } else {
      final identifier = MssqlMultipartIdentifier.parse(object);
      _metadataCache.invalidateWhere(
        MssqlMetadataCache.objectMatcher(
          host: config.host,
          port: config.port,
          database: _databaseName,
          quotedObject: identifier.quoted,
          bareName: identifier.parts.length == 1,
        ),
      );
    }
    _databaseCodePageCache = null;
  }

  /// What every session is set to at login and returned to before reuse.
  ///
  /// The isolation level is set here rather than left to the server, so it is
  /// the driver's contract rather than whoever held the connection last.
  static final List<String> _sessionSetup = <String>[
    'SET ARITHABORT ON',
    MssqlSessionState.isolationSql(MssqlSessionState.baselineIsolation),
  ];

  /// Opens a connection from the required settings and standard defaults.
  static Future<MssqlConnection> connect({
    required String host,
    required String database,
    required String username,
    required String password,
    int port = MssqlDefaults.port,
    String applicationName = MssqlDefaults.applicationName,
    Duration loginTimeout = MssqlDefaults.loginTimeout,
    Duration defaultQueryTimeout = MssqlDefaults.queryTimeout,
    int packetSize = MssqlDefaults.automaticPacketSize,
    String tdsVersion = MssqlDefaults.tdsVersion,
    String clientCharset = MssqlDefaults.clientCharset,
    MssqlEncryption encryption = MssqlDefaults.encryption,
    MssqlDecimalMode decimalMode = MssqlDefaults.decimalMode,
    MssqlObserver? observer,
  }) => open(
    MssqlConnectionConfig(
      host: host,
      port: port,
      database: database,
      username: username,
      password: password,
      applicationName: applicationName,
      loginTimeout: loginTimeout,
      defaultQueryTimeout: defaultQueryTimeout,
      packetSize: packetSize,
      tdsVersion: tdsVersion,
      clientCharset: clientCharset,
      encryption: encryption,
      decimalMode: decimalMode,
    ),
    observer: observer,
  );

  /// Opens a connection as the Windows account running the process.
  /// Windows only; see [MssqlConnectionConfig.integratedSecurity].
  static Future<MssqlConnection> connectIntegrated({
    required String host,
    required String database,
    int port = MssqlDefaults.port,
    String applicationName = MssqlDefaults.applicationName,
    Duration loginTimeout = MssqlDefaults.loginTimeout,
    Duration defaultQueryTimeout = MssqlDefaults.queryTimeout,
    int packetSize = MssqlDefaults.automaticPacketSize,
    String tdsVersion = MssqlDefaults.tdsVersion,
    String clientCharset = MssqlDefaults.clientCharset,
    MssqlEncryption encryption = MssqlDefaults.encryption,
    MssqlDecimalMode decimalMode = MssqlDefaults.decimalMode,
    MssqlObserver? observer,
  }) => open(
    MssqlConnectionConfig.integratedSecurity(
      host: host,
      port: port,
      database: database,
      applicationName: applicationName,
      loginTimeout: loginTimeout,
      defaultQueryTimeout: defaultQueryTimeout,
      packetSize: packetSize,
      tdsVersion: tdsVersion,
      clientCharset: clientCharset,
      encryption: encryption,
      decimalMode: decimalMode,
    ),
    observer: observer,
  );

  /// Opens a connection described by a .NET-style connection string.
  ///
  /// Keys this driver cannot honour are refused rather than ignored; see
  /// [MssqlConnectionConfig.fromConnectionString].
  static Future<MssqlConnection> connectString(
    String connectionString, {
    MssqlDecimalMode decimalMode = MssqlDefaults.decimalMode,
    void Function(List<String> keys)? onUnsupportedKeys,
    MssqlObserver? observer,
  }) => open(
    MssqlConnectionConfig.fromConnectionString(
      connectionString,
      decimalMode: decimalMode,
      onUnsupportedKeys: onUnsupportedKeys,
    ),
    observer: observer,
  );

  static Future<MssqlConnection> open(
    MssqlConnectionConfig config, {
    MssqlMetadataCache? metadataCache,
    MssqlObserver? observer,
  }) => _open(
    config,
    metadataCache: metadataCache,
    observationDispatcher: MssqlObservationDispatcher(observer),
  );

  static Future<MssqlConnection> _open(
    MssqlConnectionConfig config, {
    MssqlMetadataCache? metadataCache,
    required MssqlObservationDispatcher observationDispatcher,
  }) async {
    final openWatch = observationDispatcher.enabled
        ? (Stopwatch()..start())
        : null;
    config.validate();
    final runtime = MssqlRuntime.instance;
    if (!runtime.isInitialized) await runtime.initialize();
    ensureTransportIsTrusted(config, runtime);
    mssqlBeginConnectionOpen(runtime);
    ConnectionWorker? worker;
    try {
      worker = await ConnectionWorker.open(
        config,
        runtime.sybdbPath,
        mssqlRuntimeHandlersPath(runtime),
      );
      final connection = MssqlConnection._(
        config,
        worker,
        runtime,
        metadataCache: metadataCache,
        observationDispatcher: observationDispatcher,
      );
      await connection._applySessionSetup();
      mssqlRegisterConnection(
        runtime,
        connection,
        connection._closeForRuntimeShutdown,
      );
      observationDispatcher.connectionOpen(
        MssqlConnectionOpenEvent(
          connectionId: connection.connectionId,
          poolId: observationDispatcher.poolId,
          target: connection._observationTarget,
          elapsed: openWatch?.elapsed ?? Duration.zero,
        ),
      );
      return connection;
    } on MssqlException catch (error, stack) {
      await worker?.close();
      Error.throwWithStackTrace(
        withLoginHandshakeHint(error, config, runtime),
        stack,
      );
    } catch (_) {
      await worker?.close();
      rethrow;
    } finally {
      mssqlEndConnectionOpen(runtime);
    }
  }

  Future<void> _applySessionSetup() async {
    if (_sessionSetup.isEmpty) return;
    await _runOperation<void>(null, (context) async {
      await _executeUnlocked(
        command: _sessionSetup.join('; '),
        procedure: false,
        parameters: const <MssqlParameterBinding>[],
        timeout: null,
        batchRows: 1,
        maximumRows: 0,
        maximumBytes: 0,
        queueWait: context.lease.queueWait,
        allowTransaction: true,
        queryName: _sessionSetupQueryName,
      );
    });
  }

  /// The label the driver's own statements carry in a failure, so a caller can
  /// tell their query from the login-time SET batch or a metadata lookup.
  static const String _sessionSetupQueryName = 'mssql_native.sessionSetup';

  /// [allowTransaction] is for the transaction handle holding this
  /// connection; see [bulkInsert].
  @override
  Future<void> ping({
    MssqlCancellationToken? cancellationToken,
    bool allowTransaction = false,
  }) => _runOperation<void>(cancellationToken, (_) async {
    _ensureAvailable(allowTransaction: allowTransaction);
    await _worker.ping();
  });

  @override
  Future<MssqlExecutionResult> query(
    String sql, {
    Object parameters = const <String, Object?>{},
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
    int? batchRows,
    int? maximumRows,
    int? maximumBytes,
    MssqlRetryPolicy? retry,
  }) {
    final settings = options.merge(
      timeout: timeout,
      cancellationToken: cancellationToken,
      batchRows: batchRows,
      maximumRows: maximumRows,
      maximumBytes: maximumBytes,
      retry: retry,
    );
    final observation = _observationDispatcher.startQuery(
      kind: MssqlQueryKind.query,
      queryName: settings.queryName,
      target: _observationTarget,
      inTransaction: false,
      connectionId: connectionId,
      transactionId: null,
    );
    return _runObservedQuery(
      observation,
      () => _queryCore(sql, parameters: parameters, options: settings),
      retryAllowed: settings.retry != MssqlRetryPolicy.never,
    );
  }

  Future<MssqlExecutionResult> _queryCore(
    String sql, {
    required Object parameters,
    required MssqlQueryOptions options,
    bool allowTransaction = false,
  }) => _execute(
    command: sql,
    procedure: false,
    parameters: compileParameters(parameters),
    options: options,
    allowTransaction: allowTransaction,
  );

  Future<MssqlExecutionResult> _runObservedQuery(
    MssqlQueryObservation? observation,
    Future<MssqlExecutionResult> Function() action, {
    bool retryAllowed = false,
  }) async {
    if (observation != null) {
      observation.connectionId = connectionId;
      observation.repairCountAtStart = _repairCount;
    }
    try {
      final result = await action();
      if (retryAllowed &&
          observation != null &&
          _repairCount > observation.repairCountAtStart) {
        observation.attemptCount = 2;
      }
      observation?.complete(result, _repairCount);
      return result;
    } catch (error, stack) {
      if (retryAllowed &&
          observation != null &&
          _repairCount > observation.repairCountAtStart) {
        observation.attemptCount = 2;
      }
      observation?.fail(error, _repairCount);
      Error.throwWithStackTrace(error, stack);
    }
  }

  @override
  Future<MssqlExecutionResult> callProcedure(
    String procedure, {
    Object parameters = const <String, Object?>{},
    Set<String> outputParameters = const <String>{},
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
    int? batchRows,
    int? maximumRows,
    int? maximumBytes,
    MssqlProcedureMetadata? declared,
    MssqlMetadataDriftPolicy driftPolicy =
        MssqlMetadataDriftPolicy.preferDeclared,
  }) {
    final settings = options
        .merge(
          timeout: timeout,
          cancellationToken: cancellationToken,
          batchRows: batchRows,
          maximumRows: maximumRows,
          maximumBytes: maximumBytes,
        )
        .withoutRetry;
    final observation = _observationDispatcher.startQuery(
      kind: MssqlQueryKind.procedure,
      queryName: settings.queryName,
      target: _observationTarget,
      inTransaction: false,
      connectionId: connectionId,
      transactionId: null,
    );
    return _runObservedQuery(
      observation,
      () => _callProcedureCore(
        procedure,
        parameters: parameters,
        outputParameters: outputParameters,
        options: settings,
        declared: declared,
        driftPolicy: driftPolicy,
      ),
    );
  }

  Future<MssqlExecutionResult> _callProcedureCore(
    String procedure, {
    required Object parameters,
    required Set<String> outputParameters,
    required MssqlQueryOptions options,
    required MssqlProcedureMetadata? declared,
    required MssqlMetadataDriftPolicy driftPolicy,
    bool allowTransaction = false,
  }) {
    // A procedure body is opaque to the driver: it may write, and rows coming
    // back prove nothing about that. Retry stays off whatever the caller asked.
    final settings = options.withoutRetry;
    final timeoutValue = settings.timeout;
    final queryNameValue = settings.queryName;
    final cancellationTokenValue = settings.cancellationToken;
    final batchRowsValue = settings.batchRows;
    final maximumRowsValue = settings.maximumRows;
    final maximumBytesValue = settings.maximumBytes;
    if (parameters is Iterable) {
      if (outputParameters.isNotEmpty) {
        throw ArgumentError(
          'outputParameters is for map parameters. Set direction on each '
          'MssqlParameter when using the explicit parameter API.',
        );
      }
      return _execute(
        command: procedure,
        procedure: true,
        parameters: compileParameters(parameters),
        options: settings,
        allowTransaction: allowTransaction,
      );
    }
    if (parameters is! Map<String, Object?>) {
      throw ArgumentError.value(
        parameters,
        'parameters',
        'Expected Map<String, Object?> or Iterable<MssqlParameter>.',
      );
    }
    final identifier = MssqlMultipartIdentifier.parse(procedure);
    return _runOperation<MssqlExecutionResult>(cancellationTokenValue, (
      context,
    ) async {
      _ensureAvailable(allowTransaction: allowTransaction);
      final watch = Stopwatch()..start();
      final metadata = await _procedureMetadata(
        identifier,
        declared: declared,
        driftPolicy: driftPolicy,
      );
      final tables = splitTableParameters(metadata, parameters);
      if (tables.isNotEmpty) {
        return _callProcedureWithTablesUnlocked(
          identifier: identifier,
          metadata: metadata,
          tables: tables,
          parameters: parameters,
          outputParameters: outputParameters,
          timeout: timeoutValue,
          batchRows: batchRowsValue,
          maximumRows: maximumRowsValue,
          maximumBytes: maximumBytesValue,
          queueWait: context.lease.queueWait,
          watch: watch,
          queryName: queryNameValue,
          allowTransaction: allowTransaction,
        );
      }
      final bindings = compileProcedureParameters(
        metadata,
        parameters,
        outputParameters,
      );
      return _executeUnlocked(
        command: procedure,
        procedure: true,
        parameters: bindings,
        timeout: timeoutValue,
        batchRows: batchRowsValue,
        maximumRows: maximumRowsValue,
        maximumBytes: maximumBytesValue,
        queueWait: context.lease.queueWait,
        executionWatch: watch,
        queryName: queryNameValue,
        allowTransaction: allowTransaction,
      );
    });
  }

  @override
  Stream<MssqlStreamEvent> stream(
    String sql, {
    Object parameters = const <String, Object?>{},
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
    int? batchRows,
    int? maximumRows,
    int? maximumBytes,
  }) {
    final settings = options.merge(
      timeout: timeout,
      cancellationToken: cancellationToken,
      batchRows: batchRows,
      maximumRows: maximumRows,
      maximumBytes: maximumBytes,
    );
    if (!_observationDispatcher.enabled) {
      return _streamCore(sql, parameters: parameters, options: settings);
    }
    return _observedStream(
      kind: MssqlQueryKind.stream,
      queryName: settings.queryName,
      inTransaction: false,
      transactionId: null,
      create: () => _streamCore(sql, parameters: parameters, options: settings),
    );
  }

  Stream<MssqlStreamEvent> _streamCore(
    String sql, {
    required Object parameters,
    required MssqlQueryOptions options,
    bool allowTransaction = false,
  }) {
    final settings = options;
    final bindings = compileParameters(parameters);
    return withSubscriptionCancellation(
      settings.cancellationToken,
      (operationToken) => _streamBindings(
        allowTransaction: allowTransaction,
        command: sql,
        procedure: false,
        parameters: bindings,
        timeout: settings.timeout,
        cancellationToken: operationToken,
        batchRows: settings.batchRows,
        maximumRows: settings.maximumRows,
        maximumBytes: settings.maximumBytes,
        queryName: settings.queryName,
      ),
    );
  }

  Stream<MssqlStreamEvent> _observedStream({
    required MssqlQueryKind kind,
    required String? queryName,
    required bool inTransaction,
    required int? transactionId,
    required Stream<MssqlStreamEvent> Function() create,
    MssqlQueryObservation? delegatedObservation,
  }) async* {
    final observation =
        delegatedObservation ??
        _observationDispatcher.startQuery(
          kind: kind,
          queryName: queryName,
          target: _observationTarget,
          inTransaction: inTransaction,
          connectionId: connectionId,
          transactionId: transactionId,
        );
    if (observation != null) {
      observation.connectionId = connectionId;
      observation.repairCountAtStart = _repairCount;
    }
    MssqlExecutionComplete? completion;
    try {
      await for (final event in create()) {
        if (event is MssqlExecutionComplete) completion = event;
        yield event;
      }
      final result = completion;
      if (result != null) {
        observation?.completeStream(result, _repairCount);
      } else {
        observation?.fail(
          const MssqlCancelledException(
            message: 'The SQL stream ended before execution completed.',
          ),
          _repairCount,
        );
      }
    } catch (error, stack) {
      observation?.fail(error, _repairCount);
      Error.throwWithStackTrace(error, stack);
    } finally {
      if (observation != null && !observation.ended) {
        observation.fail(
          const MssqlCancelledException(
            message: 'The SQL stream subscription was cancelled.',
          ),
          _repairCount,
        );
      }
    }
  }

  Stream<MssqlStreamEvent> streamProcedure(
    String procedure, {
    Object parameters = const <String, Object?>{},
    Set<String> outputParameters = const <String>{},
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
    int? batchRows,
    int? maximumRows,
    int? maximumBytes,
  }) {
    final settings = options.merge(
      timeout: timeout,
      cancellationToken: cancellationToken,
      batchRows: batchRows,
      maximumRows: maximumRows,
      maximumBytes: maximumBytes,
    );
    if (!_observationDispatcher.enabled) {
      return _streamProcedureCore(
        procedure,
        parameters: parameters,
        outputParameters: outputParameters,
        options: settings,
      );
    }
    return _observedStream(
      kind: MssqlQueryKind.stream,
      queryName: settings.queryName,
      inTransaction: false,
      transactionId: null,
      create: () => _streamProcedureCore(
        procedure,
        parameters: parameters,
        outputParameters: outputParameters,
        options: settings,
      ),
    );
  }

  Stream<MssqlStreamEvent> _streamProcedureCore(
    String procedure, {
    required Object parameters,
    required Set<String> outputParameters,
    required MssqlQueryOptions options,
    bool allowTransaction = false,
  }) {
    final settings = options;
    if (parameters is Iterable) {
      if (outputParameters.isNotEmpty) {
        throw ArgumentError(
          'outputParameters is for map parameters. Set direction on each '
          'MssqlParameter when using the explicit parameter API.',
        );
      }
      final bindings = compileParameters(parameters);
      return withSubscriptionCancellation(
        settings.cancellationToken,
        (operationToken) => _streamBindings(
          allowTransaction: allowTransaction,
          command: procedure,
          procedure: true,
          parameters: bindings,
          timeout: settings.timeout,
          cancellationToken: operationToken,
          batchRows: settings.batchRows,
          maximumRows: settings.maximumRows,
          maximumBytes: settings.maximumBytes,
          queryName: settings.queryName,
        ),
      );
    }
    if (parameters is! Map<String, Object?>) {
      throw ArgumentError.value(
        parameters,
        'parameters',
        'Expected Map<String, Object?> or Iterable<MssqlParameter>.',
      );
    }
    final identifier = MssqlMultipartIdentifier.parse(procedure);
    return withSubscriptionCancellation(
      settings.cancellationToken,
      (operationToken) => _streamProcedureBindings(
        allowTransaction: allowTransaction,
        procedure: procedure,
        identifier: identifier,
        parameters: parameters,
        outputParameters: outputParameters,
        timeout: settings.timeout,
        cancellationToken: operationToken,
        batchRows: settings.batchRows,
        maximumRows: settings.maximumRows,
        maximumBytes: settings.maximumBytes,
        queryName: settings.queryName,
      ),
    );
  }

  Stream<MssqlStreamEvent> _streamProcedureBindings({
    bool allowTransaction = false,
    required String procedure,
    required MssqlMultipartIdentifier identifier,
    required Map<String, Object?> parameters,
    required Set<String> outputParameters,
    required Duration? timeout,
    required MssqlCancellationToken cancellationToken,
    required int batchRows,
    required int maximumRows,
    required int maximumBytes,
    String? queryName,
  }) async* {
    final context = await _beginOperation(cancellationToken);
    try {
      final metadata = await _procedureMetadata(identifier);
      final bindings = compileProcedureParameters(
        metadata,
        parameters,
        outputParameters,
      );
      yield* _streamBindingsUnlocked(
        allowTransaction: allowTransaction,
        command: procedure,
        procedure: true,
        parameters: bindings,
        timeout: timeout,
        cancellationToken: cancellationToken,
        batchRows: batchRows,
        maximumRows: maximumRows,
        maximumBytes: maximumBytes,
        queueWait: context.lease.queueWait,
        queryName: queryName,
      );
    } catch (_) {
      mssqlThrowIfCancelled(cancellationToken);
      rethrow;
    } finally {
      _endOperation(context);
    }
  }

  Stream<MssqlStreamEvent> _streamBindings({
    bool allowTransaction = false,
    required String command,
    required bool procedure,
    required List<MssqlParameterBinding> parameters,
    required Duration? timeout,
    required MssqlCancellationToken? cancellationToken,
    required int batchRows,
    required int maximumRows,
    required int maximumBytes,
    String? queryName,
  }) async* {
    final context = await _beginOperation(cancellationToken);
    try {
      yield* _streamBindingsUnlocked(
        allowTransaction: allowTransaction,
        command: command,
        procedure: procedure,
        parameters: parameters,
        timeout: timeout,
        cancellationToken: cancellationToken,
        batchRows: batchRows,
        maximumRows: maximumRows,
        maximumBytes: maximumBytes,
        queueWait: context.lease.queueWait,
        queryName: queryName,
      );
    } catch (_) {
      mssqlThrowIfCancelled(cancellationToken);
      rethrow;
    } finally {
      _endOperation(context);
    }
  }

  Stream<MssqlStreamEvent> _streamBindingsUnlocked({
    bool allowTransaction = false,
    required String command,
    required bool procedure,
    required List<MssqlParameterBinding> parameters,
    required Duration? timeout,
    required MssqlCancellationToken? cancellationToken,
    required int batchRows,
    required int maximumRows,
    required int maximumBytes,
    required Duration queueWait,
    String? queryName,
  }) async* {
    _ensureAvailable(allowTransaction: allowTransaction);
    validateQueryLimits(
      command,
      batchRows: batchRows,
      maximumRows: maximumRows,
      maximumBytes: maximumBytes,
      timeout: timeout,
    );
    final worker = _worker;
    final execution = Stopwatch()..start();
    final setMetrics = <MssqlResultSetMetrics>[];
    Duration? firstRow;
    var totalRows = 0;
    var totalBytes = 0;
    var opened = false;
    var completed = false;
    try {
      await worker.openQuery(
        command: command,
        procedure: procedure,
        parameters: parameters,
        timeout: timeout ?? config.defaultQueryTimeout,
        maximumRows: maximumRows,
        maximumBytes: maximumBytes,
      );
      opened = true;
      var setIndex = 0;
      while (true) {
        mssqlThrowIfCancelled(cancellationToken);
        final columns = await worker.nextResult();
        if (columns == null) break;
        final schema = MssqlRowSchema(columns);
        final setWatch = Stopwatch()..start();
        var rows = 0;
        var bytes = 0;
        yield MssqlResultSetStart(index: setIndex, columns: schema.columns);
        while (true) {
          mssqlThrowIfCancelled(cancellationToken);
          final values = await worker.fetchBatch(batchRows);
          if (values == null) break;
          if (values.isNotEmpty && firstRow == null) {
            firstRow = execution.elapsed;
          }
          final batch = <MssqlRow>[];
          for (final valueRow in values) {
            rows++;
            final size = decodedRowBytes(valueRow);
            bytes += size;
            batch.add(MssqlRow.fromValues(schema, valueRow));
          }
          if (batch.isNotEmpty) {
            yield MssqlRowBatch(
              resultSetIndex: setIndex,
              rows: List<MssqlRow>.unmodifiable(batch),
            );
          }
        }
        final metric = MssqlResultSetMetrics(
          index: setIndex,
          rowCount: rows,
          decodedBytes: bytes,
          elapsed: setWatch.elapsed,
        );
        setMetrics.add(metric);
        totalRows += rows;
        totalBytes += bytes;
        yield MssqlResultSetEnd(metrics: metric);
        setIndex++;
      }
      final finish = await worker.finish();
      final metrics = MssqlExecutionMetrics(
        queueWait: queueWait,
        executionElapsed: execution.elapsed,
        timeToFirstRow: firstRow,
        rowCount: totalRows,
        decodedBytes: totalBytes,
        resultSets: List<MssqlResultSetMetrics>.unmodifiable(setMetrics),
      );
      completed = true;
      yield MssqlExecutionComplete(
        affectedRows: finish.affectedRows,
        outputParameters: finish.outputParameters,
        messages: finish.messages,
        returnStatus: finish.returnStatus,
        metrics: metrics,
        statementRowCounts: finish.rowCounts,
      );
    } catch (error, stack) {
      if (error is MssqlException) {
        Error.throwWithStackTrace(
          error.classified(queryName: queryName),
          stack,
        );
      }
      rethrow;
    } finally {
      // Not guarded by [opened]: a failed open can leave results queued too,
      // and only the discard clears them.
      if (!_closed) {
        try {
          if (opened && completed) {
            await worker.closeQuery();
          } else {
            await worker.cancelQuery();
          }
        } catch (_) {}
      }
    }
  }

  Future<MssqlExecutionResult> _execute({
    required String command,
    required bool procedure,
    required List<MssqlParameterBinding> parameters,
    required MssqlQueryOptions options,
    bool allowTransaction = false,
  }) => _runOperation<MssqlExecutionResult>(options.cancellationToken, (
    context,
  ) async {
    try {
      return await _executeUnlocked(
        command: command,
        procedure: procedure,
        parameters: parameters,
        timeout: options.timeout,
        batchRows: options.batchRows,
        maximumRows: options.maximumRows,
        maximumBytes: options.maximumBytes,
        queueWait: context.lease.queueWait,
        allowTransaction: allowTransaction,
        queryName: options.queryName,
      );
    } on MssqlException catch (error) {
      final reconnectable =
          error.type == MssqlErrorType.connection ||
          error.type == MssqlErrorType.connectionLost;
      // Reconnecting inside a transaction would start a second, empty one and
      // let the rest of the callback run as though nothing happened. The
      // transaction is gone either way, so the error is reported.
      if (options.retry == MssqlRetryPolicy.never ||
          allowTransaction ||
          !reconnectable) {
        // The statement is not repeated, but the connection is repaired for
        // the next one: DB-Library marks the DBPROCESS dead after a timeout, so
        // the session is rebuilt and the caller still receives the original
        // error. Inside a transaction repair is skipped because the transaction
        // cannot be rebuilt with it.
        await _repairIfProcessIsDead(error, allowTransaction: allowTransaction);
        rethrow;
      }
      mssqlThrowIfCancelled(options.cancellationToken);
      await _reconnectUnlocked();
      return _executeUnlocked(
        command: command,
        procedure: procedure,
        parameters: parameters,
        timeout: options.timeout,
        batchRows: options.batchRows,
        maximumRows: options.maximumRows,
        maximumBytes: options.maximumBytes,
        queueWait: context.lease.queueWait,
        allowTransaction: false,
        queryName: options.queryName,
      );
    }
  });

  Future<MssqlExecutionResult> _executeUnlocked({
    required String command,
    required bool procedure,
    required List<MssqlParameterBinding> parameters,
    required Duration? timeout,
    required int batchRows,
    required int maximumRows,
    required int maximumBytes,
    required Duration queueWait,
    bool allowTransaction = false,
    Stopwatch? executionWatch,
    String? queryName,
  }) async {
    _ensureAvailable(allowTransaction: allowTransaction);
    validateQueryLimits(
      command,
      batchRows: batchRows,
      maximumRows: maximumRows,
      maximumBytes: maximumBytes,
      timeout: timeout,
    );
    final worker = _worker;
    final execution = executionWatch ?? (Stopwatch()..start());
    Duration? firstRow;
    var totalRows = 0;
    var totalBytes = 0;
    final setMetrics = <MssqlResultSetMetrics>[];
    // Inside the try: a statement the server rejects while it is being started
    // still leaves results queued on the connection, and skipping the discard
    // leaves every later command failing with "results pending".
    try {
      await worker.openQuery(
        command: command,
        procedure: procedure,
        parameters: parameters,
        timeout: timeout ?? config.defaultQueryTimeout,
        maximumRows: maximumRows,
        maximumBytes: maximumBytes,
      );
      final sets = <MssqlResultSet>[];
      while (true) {
        final columns = await worker.nextResult();
        if (columns == null) break;
        final setIndex = sets.length;
        final setWatch = Stopwatch()..start();
        final values = <List<Object?>>[];
        var decodedBytes = 0;
        while (true) {
          final batch = await worker.fetchBatch(batchRows);
          if (batch == null) break;
          if (batch.isNotEmpty && firstRow == null) {
            firstRow = execution.elapsed;
          }
          for (final row in batch) {
            decodedBytes += decodedRowBytes(row);
          }
          values.addAll(batch);
        }
        final metric = MssqlResultSetMetrics(
          index: setIndex,
          rowCount: values.length,
          decodedBytes: decodedBytes,
          elapsed: setWatch.elapsed,
        );
        setMetrics.add(metric);
        totalRows += values.length;
        totalBytes += decodedBytes;
        sets.add(
          MssqlResultSet.fromValues(
            columns: columns,
            values: values,
            metrics: metric,
          ),
        );
      }
      final finish = await worker.finish();
      return MssqlExecutionResult(
        resultSets: sets,
        affectedRows: finish.affectedRows,
        outputParameters: finish.outputParameters,
        messages: finish.messages,
        returnStatus: finish.returnStatus,
        statementRowCounts: finish.rowCounts,
        metrics: MssqlExecutionMetrics(
          queueWait: queueWait,
          executionElapsed: execution.elapsed,
          timeToFirstRow: firstRow,
          rowCount: totalRows,
          decodedBytes: totalBytes,
          resultSets: List<MssqlResultSetMetrics>.unmodifiable(setMetrics),
        ),
      );
    } catch (error, stack) {
      try {
        await worker.cancelQuery();
      } catch (_) {}
      // Translate worker failures at the public command boundary.
      if (error is MssqlException) {
        Error.throwWithStackTrace(
          error.classified(queryName: queryName),
          stack,
        );
      }
      rethrow;
    } finally {
      if (!_closed) {
        try {
          await worker.closeQuery();
        } catch (_) {}
      }
    }
  }

  /// Runs a command on a transaction-held connection with retries disabled.
  Future<MssqlExecutionResult> _executeWithinTransaction(
    String command, {
    Object parameters = const <String, Object?>{},
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
    bool procedure = false,
  }) => _execute(
    command: command,
    procedure: procedure,
    parameters: compileParameters(parameters),
    options: options.withoutRetry,
    allowTransaction: true,
  );

  Future<MssqlTransaction> beginTransaction({
    MssqlIsolationLevel isolationLevel = MssqlIsolationLevel.baseline,
    MssqlCancellationToken? cancellationToken,
    String? transactionName,
  }) {
    final observation = _observationDispatcher.startTransaction(
      transactionName: transactionName,
      target: _observationTarget,
      connectionId: connectionId,
    );
    return _beginTransactionCore(
      isolationLevel: isolationLevel,
      cancellationToken: cancellationToken,
      observation: observation,
    );
  }

  Future<MssqlTransaction> _beginTransactionCore({
    required MssqlIsolationLevel isolationLevel,
    required MssqlCancellationToken? cancellationToken,
    required MssqlTransactionObservation? observation,
  }) async {
    try {
      return await _runOperation<MssqlTransaction>(cancellationToken, (
        _,
      ) async {
        _ensureAvailable();
        _leasedByTransaction = true;
        // What the session is at now, recorded before it moves, so that commit,
        // rollback and close all have the same thing to put back.
        final previous = _sessionState.isolation;
        final wanted = isolationLevel == MssqlIsolationLevel.baseline
            ? MssqlSessionState.baselineIsolation
            : isolationLevel;
        try {
          final prelude = wanted == previous
              ? ''
              : '${MssqlSessionState.isolationSql(wanted)} ';
          await _worker.runSql(
            '${prelude}BEGIN TRANSACTION;',
            config.defaultQueryTimeout,
          );
          _sessionState.recordIsolation(wanted);
          return mssqlCreateTransaction(
            this,
            _worker,
            observation: observation,
          );
        } catch (_) {
          _leasedByTransaction = false;
          rethrow;
        }
      });
    } catch (error, stack) {
      observation?.fail(error, MssqlTransactionSettlement.unknown);
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<T> transaction<T>(
    Future<T> Function(MssqlTransaction transaction) callback, {
    MssqlIsolationLevel isolationLevel = MssqlIsolationLevel.baseline,
    MssqlCancellationToken? cancellationToken,
    String? transactionName,
  }) async {
    final transaction = await beginTransaction(
      isolationLevel: isolationLevel,
      cancellationToken: cancellationToken,
      transactionName: transactionName,
    );
    try {
      final value = await callback(transaction);
      await transaction.commit();
      await transaction.close();
      return value;
    } catch (error, stack) {
      // Cleanup must not replace the failure being diagnosed, so a failing
      // rollback or close is swallowed.
      await mssqlRollbackAfterCallbackError(transaction, error);
      try {
        await transaction.close();
      } catch (_) {}
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<String> useDatabase(
    String database, {
    MssqlCancellationToken? cancellationToken,
  }) {
    final identifier = MssqlMultipartIdentifier.parse(
      database,
      maximumParts: 1,
    );
    return _runOperation<String>(cancellationToken, (_) async {
      _ensureAvailable();
      final selected = await _worker.useDatabase(identifier.parts.single);
      _databaseName = selected;
      invalidateMetadata();
      _sessionState.recordDatabase(selected);
      return selected;
    });
  }

  Future<MssqlServerInfo> serverInfo({
    MssqlCancellationToken? cancellationToken,
  }) async {
    final row = await queryTypedSingle('''
SELECT
  CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS product_version,
  CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(128)) AS product_level,
  CAST(SERVERPROPERTY('Edition') AS nvarchar(256)) AS edition,
  CAST(SERVERPROPERTY('EngineEdition') AS int) AS engine_edition,
  CAST(SERVERPROPERTY('ServerName') AS nvarchar(256)) AS server_name
''', cancellationToken: cancellationToken);
    return MssqlServerInfo(
      productVersion: row.require<String>('product_version'),
      productLevel: row.require<String>('product_level'),
      edition: row.require<String>('edition'),
      engineEdition: row.require<int>('engine_edition'),
      serverName: row.require<String>('server_name'),
    );
  }

  /// Copies [rows] into [tableName] through BCP, not through INSERT.
  ///
  /// [allowTransaction] is for the transaction handle that already holds
  /// this connection: a BCP on the raw connection during an open
  /// transaction would sit behind it and would not be part of it. The ORM
  /// never sets this; [MssqlTransaction.bulkInsert] does.
  @override
  Future<MssqlBulkResult> bulkInsert({
    required String tableName,
    required Iterable<Object> rows,
    Object? columns,
    MssqlBulkOptions options = const MssqlBulkOptions(),
    MssqlCancellationToken? cancellationToken,
    void Function(int sentRows)? onProgress,
  }) {
    final observation = _observationDispatcher.startBulk(
      bulkName: options.bulkName,
      target: _observationTarget,
      inTransaction: false,
      connectionId: connectionId,
      transactionId: null,
    );
    return _runObservedBulk(
      observation,
      () => _bulkInsertCore(
        tableName: tableName,
        rows: rows,
        columns: columns,
        options: options,
        cancellationToken: cancellationToken,
        onProgress: onProgress,
      ),
    );
  }

  Future<MssqlBulkResult> _bulkInsertCore({
    required String tableName,
    required Iterable<Object> rows,
    Object? columns,
    required MssqlBulkOptions options,
    MssqlCancellationToken? cancellationToken,
    void Function(int sentRows)? onProgress,
    bool allowTransaction = false,
  }) {
    if (columns is List<MssqlBulkColumn>) {
      return _bulkInsertRawCore(
        tableName: tableName,
        columns: columns,
        rows: rows.map((row) {
          if (row is! List<Object?>) {
            throw ArgumentError.value(
              row,
              'rows',
              'Explicit bulk rows must be List<MssqlParameter> or List<Object?>.',
            );
          }
          return row;
        }),
        options: options,
        cancellationToken: cancellationToken,
        onProgress: onProgress,
        allowTransaction: allowTransaction,
      );
    }
    if (columns != null && columns is! List<String>) {
      throw ArgumentError.value(
        columns,
        'columns',
        'Expected List<String> for inferred bulk or List<MssqlBulkColumn> for explicit bulk.',
      );
    }
    final mappedRows = rows.map((row) {
      if (row is! Map<String, Object?>) {
        throw ArgumentError.value(
          row,
          'rows',
          'Inferred bulk rows must be Map<String, Object?>.',
        );
      }
      return row;
    });
    final table = MssqlMultipartIdentifier.parse(tableName);
    options.validate();
    final iterator = mappedRows.iterator;
    if (!iterator.moveNext()) {
      return Future<MssqlBulkResult>.value(MssqlBulkResult.empty);
    }
    final first = iterator.current;
    final selected = columns == null
        ? List<String>.of(first.keys)
        : List<String>.of(columns as List<String>);
    if (selected.isEmpty || selected.toSet().length != selected.length) {
      throw ArgumentError('Bulk columns must be non-empty and unique.');
    }

    return _runOperation<MssqlBulkResult>(cancellationToken, (_) async {
      _ensureAvailable(allowTransaction: allowTransaction);
      final metadata = await _tableMetadata(table);
      final byName = <String, BulkColumnMetadata>{
        for (final item in metadata) item.column.name: item,
      };
      final chosen = <BulkColumnMetadata>[];
      for (final name in selected) {
        final item = byName[name];
        if (item == null) {
          throw ArgumentError(
            'The destination table has no column named "$name".',
          );
        }
        if (item.computed || item.hidden || item.rowVersion) {
          throw ArgumentError(
            'Column "$name" is generated by SQL Server and cannot be bulk inserted.',
          );
        }
        if (item.identity && !options.keepIdentity) {
          throw ArgumentError(
            'Column "$name" is an identity column. Set keepIdentity to insert it explicitly.',
          );
        }
        chosen.add(item);
      }
      chosen.sort(
        (left, right) => left.column.ordinal.compareTo(right.column.ordinal),
      );
      if (options.keepIdentity && !chosen.any((item) => item.identity)) {
        throw ArgumentError(
          'keepIdentity requires an identity column in the selected column set.',
        );
      }

      Iterable<List<MssqlValue>> converted() sync* {
        var rowIndex = 0;
        var current = first;
        while (true) {
          validateBulkKeys(current, selected, rowIndex);
          yield <MssqlValue>[
            for (final item in chosen)
              bulkValue(current[item.column.name], item.column, rowIndex),
          ];
          rowIndex++;
          if (!iterator.moveNext()) break;
          current = iterator.current;
        }
      }

      return _runBulkUnlocked(
        table: table.quoted,
        columns: chosen.map((item) => item.column).toList(growable: false),
        rows: converted(),
        options: options,
        cancellationToken: cancellationToken,
        onProgress: onProgress,
      );
    });
  }

  Future<MssqlBulkResult> bulkInsertRaw({
    required String tableName,
    required List<MssqlBulkColumn> columns,
    required Iterable<List<Object?>> rows,
    MssqlBulkOptions options = const MssqlBulkOptions(),
    MssqlCancellationToken? cancellationToken,
    void Function(int sentRows)? onProgress,
  }) {
    final observation = _observationDispatcher.startBulk(
      bulkName: options.bulkName,
      target: _observationTarget,
      inTransaction: false,
      connectionId: connectionId,
      transactionId: null,
    );
    return _runObservedBulk(
      observation,
      () => _bulkInsertRawCore(
        tableName: tableName,
        columns: columns,
        rows: rows,
        options: options,
        cancellationToken: cancellationToken,
        onProgress: onProgress,
      ),
    );
  }

  Future<MssqlBulkResult> _bulkInsertRawCore({
    required String tableName,
    required List<MssqlBulkColumn> columns,
    required Iterable<List<Object?>> rows,
    required MssqlBulkOptions options,
    MssqlCancellationToken? cancellationToken,
    void Function(int sentRows)? onProgress,
    bool allowTransaction = false,
  }) {
    final table = MssqlMultipartIdentifier.parse(tableName);
    options.validate();
    validateRawBulkColumns(columns);
    return _runOperation<MssqlBulkResult>(cancellationToken, (_) async {
      _ensureAvailable(allowTransaction: allowTransaction);
      Iterable<List<MssqlValue>> converted() sync* {
        var rowIndex = 0;
        for (final row in rows) {
          if (row.length != columns.length) {
            throw MssqlBulkRowException(
              rowIndex: rowIndex,
              columnName: '<row>',
              detail:
                  'received ${row.length} values; expected ${columns.length}.',
            );
          }
          yield <MssqlValue>[
            for (var index = 0; index < columns.length; index++)
              bulkValue(row[index], columns[index], rowIndex),
          ];
          rowIndex++;
        }
      }

      return _runBulkUnlocked(
        table: table.quoted,
        columns: List<MssqlBulkColumn>.of(columns),
        rows: converted(),
        options: options,
        cancellationToken: cancellationToken,
        onProgress: onProgress,
      );
    });
  }

  Future<MssqlBulkResult> _runObservedBulk(
    MssqlBulkObservation? observation,
    Future<MssqlBulkResult> Function() action,
  ) async {
    if (observation != null) observation.connectionId = connectionId;
    try {
      final result = await action();
      observation?.complete(result, _repairCount);
      return result;
    } catch (error, stack) {
      observation?.fail(error, _repairCount);
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<MssqlBulkResult> _runBulkUnlocked({
    required String table,
    required List<MssqlBulkColumn> columns,
    required Iterable<List<MssqlValue>> rows,
    required MssqlBulkOptions options,
    required MssqlCancellationToken? cancellationToken,
    required void Function(int sentRows)? onProgress,
  }) async {
    final iterator = rows.iterator;
    if (!iterator.moveNext()) return MssqlBulkResult.empty;
    final codePage = columns.any((column) => isSingleByteText(column.type))
        ? await _databaseCodePageUnlocked()
        : 0;
    final worker = _worker;
    await worker.bulkOpen(
      table: table,
      columns: columns,
      options: options,
      codePage: codePage,
    );
    var sent = 0;
    var lastProgress = 0;
    var current = iterator.current;
    var hasMore = true;
    try {
      while (hasMore) {
        mssqlThrowIfCancelled(cancellationToken);
        final chunk = <List<MssqlValue>>[];
        while (chunk.length < 128) {
          chunk.add(current);
          if (!iterator.moveNext()) {
            hasMore = false;
            break;
          }
          current = iterator.current;
        }
        await worker.bulkAddRows(chunk);
        sent += chunk.length;
        if (sent - lastProgress >= options.batchSize) {
          onProgress?.call(sent);
          lastProgress = sent;
        }
      }
      final result = await worker.bulkComplete();
      if (sent != lastProgress) onProgress?.call(sent);
      return result;
    } catch (_) {
      try {
        await worker.bulkCancel();
      } catch (_) {}
      // An abandoned copy is the one case the driver cannot tidy away: ending
      // the BCP session cleanly would commit the rows already sent, and an
      // atomic load promises the opposite. The rows are therefore left
      // uncommitted, and if that leaves the session out of step with the
      // server it is discarded rather than handed back to the caller or to a
      // pool. The check costs one round trip, on an error path only.
      if (!await _sessionRespondsUnlocked(worker)) {
        await _closeWorker();
      }
      rethrow;
    }
  }

  /// Whether the connection can still carry out an ordinary command.
  ///
  /// Runs without taking the operation gate: the caller already holds it.
  Future<bool> _sessionRespondsUnlocked(ConnectionWorker worker) async {
    try {
      await worker.ping();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Picks out the parameters the caller supplied as tables.
  ///
  /// A value is a table only when the procedure says the parameter is one, so
  /// an ordinary list bound to a scalar parameter still fails as it did.
  /// Calls a procedure containing table-valued parameters.
  ///
  /// FreeTDS lacks TVP wire support, so rows are bulk-copied into a temporary
  /// table and transferred to a variable of the declared table type.
  Future<MssqlExecutionResult> _callProcedureWithTablesUnlocked({
    required MssqlMultipartIdentifier identifier,
    required List<ProcedureParameterMetadata> metadata,
    required Map<String, MssqlTableRows> tables,
    required Map<String, Object?> parameters,
    required Set<String> outputParameters,
    required Duration? timeout,
    required int batchRows,
    required int maximumRows,
    required int maximumBytes,
    required Duration queueWait,
    required Stopwatch watch,
    String? queryName,
    bool allowTransaction = false,
  }) async {
    final scalars = <String, Object?>{
      for (final entry in parameters.entries)
        if (!tables.containsKey(normalizeParameterName(entry.key)))
          entry.key: entry.value,
    };
    final scalarMetadata = <ProcedureParameterMetadata>[
      for (final item in metadata)
        if (!item.isTableType) item,
    ];
    final bindings = <MssqlParameterBinding>[
      ...compileProcedureParameters(scalarMetadata, scalars, outputParameters),
      // The return status is an ordinary OUTPUT parameter here: EXEC inside a
      // batch does not reach dbretstatus.
      MssqlParameterBinding.fromValue(
        _returnStatusParameter,
        coerceMssqlValue(null, type: MssqlType.int32),
        direction: MssqlParameterBindingDirection.output,
      ),
    ];

    final staging = <String, String>{};
    final prologue = StringBuffer();
    final arguments = <String>[];
    try {
      var index = 0;
      for (final item in metadata) {
        if (!item.isTableType) {
          final supplied = scalars.keys
              .map(normalizeParameterName)
              .contains(item.name);
          final wantsOutput = outputParameters
              .map(normalizeParameterName)
              .contains(item.name);
          if (!supplied && !wantsOutput) continue;
          arguments.add(
            '@${item.name} = @${item.name}${wantsOutput ? ' OUTPUT' : ''}',
          );
          continue;
        }
        final rows = tables[item.name];
        if (rows == null) continue;
        final variable = '@__mssql_tvp_$index';
        final table = '#__mssql_tvp_${_tableParameterCounter++}';
        staging[item.name] = table;
        await _stageTableParameterUnlocked(item, table, rows);
        prologue
          ..writeln('DECLARE $variable ${item.quotedTableType};')
          ..writeln(
            'INSERT INTO $variable SELECT * FROM '
            '${MssqlSql.quoteIdentifier(table)};',
          );
        arguments.add('@${item.name} = $variable');
        index++;
      }

      final command = StringBuffer(prologue.toString())
        ..write('EXEC @$_returnStatusParameter = ${identifier.quoted}')
        ..write(arguments.isEmpty ? '' : ' ${arguments.join(', ')}')
        ..write(';');

      final result = await _executeUnlocked(
        command: command.toString(),
        procedure: false,
        parameters: bindings,
        timeout: timeout,
        batchRows: batchRows,
        maximumRows: maximumRows,
        maximumBytes: maximumBytes,
        queueWait: queueWait,
        executionWatch: watch,
        queryName: queryName,
        allowTransaction: allowTransaction,
      );
      final outputs = Map<String, Object?>.of(result.outputParameters);
      final status = outputs.remove(_returnStatusParameter);
      return MssqlExecutionResult(
        resultSets: result.resultSets,
        affectedRows: result.affectedRows,
        outputParameters: outputs,
        messages: result.messages,
        returnStatus: status is int ? status : result.returnStatus,
        statementRowCounts: result.statementRowCounts,
        metrics: result.metrics,
      );
    } finally {
      for (final table in staging.values) {
        try {
          await _executeUnlocked(
            command: 'DROP TABLE IF EXISTS ${MssqlSql.quoteIdentifier(table)};',
            procedure: false,
            parameters: const <MssqlParameterBinding>[],
            timeout: null,
            batchRows: 1,
            maximumRows: 0,
            maximumBytes: 1024,
            queueWait: Duration.zero,
            allowTransaction: true,
            queryName: 'mssql_native.dropTableParameterStaging',
          );
        } catch (_) {
          // A staging table lives and dies with the session; failing to drop
          // it must not replace whatever the caller is already dealing with.
        }
      }
    }
  }

  /// Builds the staging table for one table-valued parameter and fills it.
  Future<void> _stageTableParameterUnlocked(
    ProcedureParameterMetadata parameter,
    String table,
    MssqlTableRows rows,
  ) async {
    final columns = await _tableTypeColumnsUnlocked(parameter);
    if (columns.isEmpty) {
      throw MssqlException(
        type: MssqlErrorType.configuration,
        message:
            'Table type ${parameter.quotedTableType} has no columns to fill.',
      );
    }
    // Created from the type itself rather than from rendered DDL, so the
    // staging table matches it column for column without the driver having to
    // reproduce SQL Server's type syntax.
    await _executeUnlocked(
      command:
          'DECLARE @__mssql_shape ${parameter.quotedTableType}; '
          'SELECT * INTO ${MssqlSql.quoteIdentifier(table)} '
          'FROM @__mssql_shape WHERE 1 = 0;',
      procedure: false,
      parameters: const <MssqlParameterBinding>[],
      timeout: null,
      batchRows: 1,
      maximumRows: 0,
      maximumBytes: 1024,
      queueWait: Duration.zero,
      allowTransaction: true,
      queryName: 'mssql_native.createTableParameterStaging',
    );

    final names = <String>[for (final column in columns) column.name];
    Iterable<List<MssqlValue>> converted() sync* {
      var rowIndex = 0;
      for (final row in rows.rows) {
        validateBulkKeys(row, names, rowIndex);
        yield <MssqlValue>[
          for (final column in columns)
            bulkValue(row[column.name], column, rowIndex),
        ];
        rowIndex++;
      }
    }

    await _runBulkUnlocked(
      table: MssqlSql.quoteIdentifier(table),
      columns: columns,
      rows: converted(),
      options: const MssqlBulkOptions(),
      cancellationToken: null,
      onProgress: null,
    );
  }

  /// The columns of a table type, in the order the type declares them.
  Future<List<MssqlBulkColumn>> _tableTypeColumnsUnlocked(
    ProcedureParameterMetadata parameter,
  ) async {
    final result = await _executeUnlocked(
      command: tableTypeColumnsSql,
      procedure: false,
      parameters: compileParameters(<String, Object?>{
        'type_name': MssqlValue.nvarchar(parameter.tableTypeName, size: 128),
        'type_schema': MssqlValue.nvarchar(
          parameter.tableTypeSchema ?? 'dbo',
          size: 128,
        ),
      }),
      timeout: null,
      batchRows: 128,
      maximumRows: 0,
      maximumBytes: 1024 * 1024,
      queueWait: Duration.zero,
      allowTransaction: true,
      queryName: 'mssql_native.tableTypeColumns',
    );
    return decodeTableTypeColumns(result);
  }

  Future<List<ProcedureParameterMetadata>> _procedureMetadata(
    MssqlMultipartIdentifier procedure, {
    MssqlProcedureMetadata? declared,
    MssqlMetadataDriftPolicy driftPolicy =
        MssqlMetadataDriftPolicy.preferDeclared,
  }) async {
    if (declared != null) {
      assertDeclaredIsFor(identifier: procedure, declared: declared);
    }
    if (declared != null &&
        driftPolicy == MssqlMetadataDriftPolicy.preferDeclared) {
      return procedureMetadataFromDeclared(declared);
    }
    final key = MssqlMetadataCache.key(
      host: config.host,
      port: config.port,
      database: _databaseName,
      object: 'proc:${procedure.quoted}',
      schemaVersion: declared?.schemaVersion ?? '',
    );
    final live = await _metadataCache.getOrLoad(
      key,
      () => _procedureMetadataUnlocked(procedure),
    );
    if (declared != null &&
        driftPolicy == MssqlMetadataDriftPolicy.verifyDeclared) {
      assertProcedureMetadata(declared, live);
    }
    return live;
  }

  /// Refuses a declaration that describes some other procedure.
  ///
  /// `preferDeclared` skips the catalog, so the declaration is the only
  /// description of the call. The wrong one binds this procedure's arguments
  /// with another's types, sizes and directions. The name is what can be
  /// checked without a catalog query.
  Future<List<BulkColumnMetadata>> _tableMetadata(
    MssqlMultipartIdentifier table,
  ) {
    final key = MssqlMetadataCache.key(
      host: config.host,
      port: config.port,
      database: _databaseName,
      object: 'table:${table.quoted}',
    );
    return _metadataCache.getOrLoad(key, () => _tableMetadataUnlocked(table));
  }

  Future<List<ProcedureParameterMetadata>> _procedureMetadataUnlocked(
    MssqlMultipartIdentifier procedure,
  ) async {
    final catalog = procedure.parts.length == 3
        ? '${MssqlSql.quoteIdentifier(procedure.parts.first)}.'
        : '';
    final result = await _executeUnlocked(
      command: procedureMetadataSql(catalog),
      procedure: false,
      parameters: compileParameters(<String, Object?>{
        'procedure': MssqlValue.nvarchar(procedure.quoted, size: 776),
      }),
      timeout: null,
      batchRows: 128,
      maximumRows: 0,
      maximumBytes: 1024 * 1024,
      queueWait: Duration.zero,
      allowTransaction: true,
      queryName: 'mssql_native.procedureMetadata',
    );
    return decodeProcedureMetadata(result);
  }

  /// Whether `sys.columns` on this server has an `is_hidden` column.
  ///
  /// Present since SQL Server 2016. Older servers have no hidden columns, so
  /// `false` is the right answer there.
  ///
  /// Resolved once per connection, and only when a bulk load first needs it.
  Future<bool> _hasHiddenColumnFlagUnlocked(String catalog) async {
    final cached = _hasHiddenColumnFlag;
    if (cached != null) return cached;
    final result = await _executeUnlocked(
      command:
          "SELECT CASE WHEN COL_LENGTH('${catalog}sys.columns', 'is_hidden') "
          'IS NULL THEN 0 ELSE 1 END AS present',
      procedure: false,
      parameters: const <MssqlParameterBinding>[],
      timeout: null,
      batchRows: 1,
      maximumRows: 0,
      maximumBytes: 1024,
      queueWait: Duration.zero,
      allowTransaction: true,
      queryName: 'mssql_native.hiddenColumnSupport',
    );
    final rows = result.resultSets.isEmpty
        ? const <MssqlRow>[]
        : result.resultSets.first.typedRows;
    final present = rows.isNotEmpty && rows.first.require<int>('present') == 1;
    _hasHiddenColumnFlag = present;
    return present;
  }

  Future<List<BulkColumnMetadata>> _tableMetadataUnlocked(
    MssqlMultipartIdentifier table,
  ) async {
    final catalog = table.parts.length == 3
        ? '${MssqlSql.quoteIdentifier(table.parts.first)}.'
        : '';
    final hidden = await _hasHiddenColumnFlagUnlocked(catalog)
        ? 'c.is_hidden'
        : 'CAST(0 AS bit)';
    final result = await _executeUnlocked(
      command: tableMetadataSql(catalog: catalog, hidden: hidden),
      procedure: false,
      parameters: compileParameters(<String, Object?>{
        'table': MssqlValue.nvarchar(table.quoted, size: 776),
      }),
      timeout: null,
      batchRows: 128,
      maximumRows: 0,
      maximumBytes: 2 * 1024 * 1024,
      queueWait: Duration.zero,
      allowTransaction: true,
      queryName: 'mssql_native.bulkTableMetadata',
    );
    return decodeTableMetadata(result);
  }

  Future<int> _databaseCodePageUnlocked() async {
    final cached = _databaseCodePageCache;
    if (cached != null) return cached;
    final result = await _executeUnlocked(
      command:
          "SELECT CAST(ISNULL(COLLATIONPROPERTY(CAST(DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS nvarchar(128)), 'CodePage'), 0) AS int) AS cp",
      procedure: false,
      parameters: const <MssqlParameterBinding>[],
      timeout: null,
      batchRows: 1,
      maximumRows: 1,
      maximumBytes: 1024,
      queueWait: Duration.zero,
      allowTransaction: true,
      queryName: 'mssql_native.databaseCodePage',
    );
    if (result.resultSets.isEmpty || result.resultSets.first.rows.isEmpty) {
      throw const MssqlException(
        type: MssqlErrorType.configuration,
        message: 'Could not determine the database code page.',
      );
    }
    return _databaseCodePageCache = result.resultSets.first.typedRows.single
        .require<int>('cp');
  }

  Future<T> _runOperation<T>(
    MssqlCancellationToken? token,
    Future<T> Function(OperationContext context) action,
  ) async {
    final context = await _beginOperation(token);
    try {
      return await action(context);
    } catch (_) {
      mssqlThrowIfCancelled(token);
      rethrow;
    } finally {
      _endOperation(context);
    }
  }

  Future<OperationContext> _beginOperation(
    MssqlCancellationToken? token,
  ) async {
    final lease = await _operationGate.acquire(token);
    final id = _nextOperationId++;
    _activeOperationId = id;
    void Function()? unregister;
    try {
      unregister = mssqlRegisterCancellation(token, () {
        if (_activeOperationId == id && !_closed) _worker.cancel();
      });
      mssqlThrowIfCancelled(token);
      return OperationContext(id, lease, unregister);
    } catch (_) {
      unregister?.call();
      if (_activeOperationId == id) _activeOperationId = null;
      lease.release();
      rethrow;
    }
  }

  void _endOperation(OperationContext context) {
    context.unregisterCancellation?.call();
    if (_activeOperationId == context.id) _activeOperationId = null;
    context.lease.release();
  }

  Future<void> close() async {
    if (_closed) return;
    final context = await _beginOperation(null);
    try {
      if (_closed) return;
      if (_leasedByTransaction) {
        throw StateError(
          'Cannot close a connection with an active transaction.',
        );
      }
      await _closeWorker();
    } finally {
      _endOperation(context);
    }
  }

  Future<void> _closeForRuntimeShutdown() async {
    if (_closed) return;
    _worker.cancel();
    _leasedByTransaction = false;
    await _closeWorker();
  }

  Future<void> _closeWorker() async {
    if (_closed) return;
    final closing = _closingFuture;
    if (closing != null) return closing;
    final future = _closeWorkerOnce();
    _closingFuture = future;
    return future;
  }

  Future<void> _closeWorkerOnce() async {
    try {
      await _worker.close();
    } finally {
      _closed = true;
      mssqlUnregisterConnection(_runtime, this);
      _notifyConnectionClose();
    }
  }

  /// SQL Server error 20047: the DB-Library process is dead or disabled.
  ///
  /// FreeTDS reports it both as the failure that killed the session and on
  /// every attempt to use it afterwards.
  static const int _deadProcessCode = 20047;

  /// Rebuilds an unusable DBPROCESS outside transactions.
  ///
  /// Reconnecting would discard an open transaction, so transaction-held
  /// sessions are never repaired. Repair failures close the connection while
  /// preserving the original command error.
  Future<void> _repairIfProcessIsDead(
    MssqlException error, {
    required bool allowTransaction,
  }) async {
    if (allowTransaction || _leasedByTransaction || _closed) return;
    // The failures the retry branch treats as reconnectable, plus a timeout. A
    // killed session first surfaces as `connection` (code 20017, "Unexpected
    // EOF from the server") and only later as 20047, so `connection` must be
    // included.
    final dead =
        error.code == _deadProcessCode ||
        error.type == MssqlErrorType.queryTimeout ||
        error.type == MssqlErrorType.connection ||
        error.type == MssqlErrorType.connectionLost;
    if (!dead) return;
    try {
      await _reconnectUnlocked();
    } catch (_) {
      // Swallowed: the caller receives the original error, and
      // `_reconnectUnlocked` has already marked the connection closed.
    }
  }

  Future<void> _reconnectUnlocked() async {
    try {
      await _worker.close();
    } catch (_) {}
    mssqlEnsureCanOpenConnection(_runtime);
    try {
      _worker = await ConnectionWorker.open(
        config.copyWith(database: _databaseName),
        _runtime.sybdbPath,
        mssqlRuntimeHandlersPath(_runtime),
      );
      _databaseName = _worker.databaseName;
      invalidateMetadata();
    } catch (_) {
      _closed = true;
      mssqlUnregisterConnection(_runtime, this);
      _notifyConnectionClose();
      rethrow;
    }
    if (_sessionSetup.isNotEmpty) {
      await _executeUnlocked(
        command: _sessionSetup.join('; '),
        procedure: false,
        parameters: const <MssqlParameterBinding>[],
        timeout: null,
        batchRows: 1,
        maximumRows: 0,
        maximumBytes: 0,
        queueWait: Duration.zero,
        allowTransaction: true,
        queryName: _sessionSetupQueryName,
      );
    }
    _repairCount++;
  }

  void _notifyConnectionClose() {
    if (_closeObserved) return;
    _closeObserved = true;
    _observationDispatcher.connectionClose(
      MssqlConnectionCloseEvent(
        connectionId: connectionId,
        poolId: _observationDispatcher.poolId,
        target: _observationTarget,
        lifetime: _lifetime.elapsed,
        repairCount: _repairCount,
      ),
    );
  }

  Future<T> _runTransactionNative<T>(Future<T> Function() action) =>
      _runOperation<T>(null, (_) async {
        _ensureAvailable(allowTransaction: true);
        return action();
      });

  /// Gives the connection back after a transaction has finished with it.
  ///
  /// Restoring whatever the transaction changed about the session is part of
  /// giving it back, so this is a future: see [_restoreSessionBaseline].
  Future<void> _releaseAfterTransaction() async {
    _leasedByTransaction = false;
    await _restoreSessionBaseline();
  }

  /// Restores reusable session state without replacing an earlier error.
  ///
  /// A failed restore marks the session dirty instead of throwing, preventing
  /// the pool from leasing it again.
  Future<void> _restoreSessionBaseline() async {
    if (isClosed || !_sessionState.needsRestore) return;
    final statements = _sessionState.restoreStatements();
    if (statements.isEmpty) return;
    try {
      await _worker.runSql(statements.join(' '), config.defaultQueryTimeout);
      _sessionState.markRestored();
    } catch (error) {
      _sessionState.markDirty('restoring the session baseline failed: $error');
    }
  }

  /// Whether an [MssqlTransaction] currently holds this connection.
  @override
  bool get inTransaction => _leasedByTransaction;

  /// Decides what happens to a session whose ROLLBACK was rejected.
  ///
  /// A rejected rollback is not proof of damage: an aborted batch or a
  /// server-side rollback leaves nothing to roll back, and error 3903 is the
  /// server saying so. The session is asked for its own transaction depth, and
  /// only a session that cannot answer, or that still holds an open
  /// transaction, is discarded.
  Future<void> _settleAfterFailedRollback() async {
    try {
      final result = await _executeWithinTransaction(
        'SELECT @@TRANCOUNT AS open_transactions;',
        options: const MssqlQueryOptions(
          maximumRows: 2,
          queryName: 'mssql_native.transactionDepth',
        ),
      );
      final open = result.resultSets.single.rows.single['open_transactions'];
      if (open == 0) {
        _leasedByTransaction = false;
        return;
      }
    } catch (_) {
      // Fall through: a session that cannot be inspected cannot be trusted.
    }
    await _discardAfterTransactionFailure();
  }

  /// Drops a connection whose transaction state could not be resolved.
  ///
  /// A rollback that failed leaves the session ambiguous, so the lease is
  /// released and the worker is torn down instead of being reused or pooled.
  Future<void> _discardAfterTransactionFailure() async {
    _leasedByTransaction = false;
    try {
      await close();
    } catch (_) {}
  }

  void _ensureAvailable({bool allowTransaction = false}) {
    if (_closed) throw StateError('The SQL connection is closed.');
    if (_leasedByTransaction && !allowTransaction) {
      throw StateError(
        'The connection is leased by an active transaction. Run this through '
        'the transaction handle the callback was given — a command sent to '
        'the connection instead would sit behind the open transaction and '
        'would not be part of it.',
      );
    }
  }
}

/// Package-internal entry points used by pool and transaction wrappers.
///
/// These remain explicit arguments rather than ambient Zone state. They are
/// hidden from the package export with `show MssqlConnection`.
Future<MssqlConnection> mssqlOpenPooledConnection(
  MssqlConnectionConfig config, {
  required MssqlMetadataCache metadataCache,
  required MssqlObservationDispatcher dispatcher,
}) => MssqlConnection._open(
  config,
  metadataCache: metadataCache,
  observationDispatcher: dispatcher,
);

MssqlQueryObservation? mssqlStartConnectionQueryObservation(
  MssqlConnection connection, {
  required MssqlQueryKind kind,
  required String? queryName,
  required bool inTransaction,
  required int? transactionId,
}) => connection._observationDispatcher.startQuery(
  kind: kind,
  queryName: queryName,
  target: connection._observationTarget,
  inTransaction: inTransaction,
  connectionId: connection.connectionId,
  transactionId: transactionId,
);

Future<MssqlExecutionResult> mssqlRunDelegatedQuery(
  MssqlConnection connection, {
  required MssqlQueryObservation? observation,
  required String sql,
  required Object parameters,
  required MssqlQueryOptions options,
  required bool allowTransaction,
}) => connection._runObservedQuery(
  observation,
  () => connection._queryCore(
    sql,
    parameters: parameters,
    options: options,
    allowTransaction: allowTransaction,
  ),
  retryAllowed: options.retry != MssqlRetryPolicy.never,
);

Future<MssqlExecutionResult> mssqlRunDelegatedProcedure(
  MssqlConnection connection, {
  required MssqlQueryObservation? observation,
  required String procedure,
  required Object parameters,
  required Set<String> outputParameters,
  required MssqlQueryOptions options,
  required MssqlProcedureMetadata? declared,
  required MssqlMetadataDriftPolicy driftPolicy,
  required bool allowTransaction,
}) => connection._runObservedQuery(
  observation,
  () => connection._callProcedureCore(
    procedure,
    parameters: parameters,
    outputParameters: outputParameters,
    options: options,
    declared: declared,
    driftPolicy: driftPolicy,
    allowTransaction: allowTransaction,
  ),
);

Stream<MssqlStreamEvent> mssqlRunDelegatedStream(
  MssqlConnection connection, {
  required MssqlQueryObservation? observation,
  required String sql,
  required Object parameters,
  required MssqlQueryOptions options,
  required bool allowTransaction,
}) => connection._observedStream(
  kind: MssqlQueryKind.stream,
  queryName: options.queryName,
  inTransaction: allowTransaction,
  transactionId: observation?.transactionId,
  delegatedObservation: observation,
  create: () => connection._streamCore(
    sql,
    parameters: parameters,
    options: options,
    allowTransaction: allowTransaction,
  ),
);

MssqlBulkObservation? mssqlStartConnectionBulkObservation(
  MssqlConnection connection, {
  required String? bulkName,
  required bool inTransaction,
  required int? transactionId,
}) => connection._observationDispatcher.startBulk(
  bulkName: bulkName,
  target: connection._observationTarget,
  inTransaction: inTransaction,
  connectionId: connection.connectionId,
  transactionId: transactionId,
);

Future<MssqlBulkResult> mssqlRunDelegatedBulk(
  MssqlConnection connection, {
  required MssqlBulkObservation? observation,
  required String tableName,
  required Iterable<Object> rows,
  required Object? columns,
  required MssqlBulkOptions options,
  required MssqlCancellationToken? cancellationToken,
  required void Function(int sentRows)? onProgress,
  required bool allowTransaction,
}) => connection._runObservedBulk(
  observation,
  () => connection._bulkInsertCore(
    tableName: tableName,
    rows: rows,
    columns: columns,
    options: options,
    cancellationToken: cancellationToken,
    onProgress: onProgress,
    allowTransaction: allowTransaction,
  ),
);

Future<MssqlTransaction> mssqlBeginDelegatedTransaction(
  MssqlConnection connection, {
  required MssqlIsolationLevel isolationLevel,
  required MssqlCancellationToken? cancellationToken,
  required MssqlTransactionObservation? observation,
}) => connection._beginTransactionCore(
  isolationLevel: isolationLevel,
  cancellationToken: cancellationToken,
  observation: observation,
);

Future<MssqlExecutionResult> mssqlExecuteWithinTransaction(
  MssqlConnection connection,
  String command, {
  Object parameters = const <String, Object?>{},
  MssqlQueryOptions options = MssqlQueryOptions.defaults,
  bool procedure = false,
}) => connection._executeWithinTransaction(
  command,
  parameters: parameters,
  options: options,
  procedure: procedure,
);

Future<T> mssqlRunTransactionNative<T>(
  MssqlConnection connection,
  Future<T> Function() action,
) => connection._runTransactionNative(action);

Future<void> mssqlReleaseAfterTransaction(MssqlConnection connection) =>
    connection._releaseAfterTransaction();

Future<void> mssqlRestoreSessionBaseline(MssqlConnection connection) =>
    connection._restoreSessionBaseline();

Future<void> mssqlSettleAfterFailedRollback(MssqlConnection connection) =>
    connection._settleAfterFailedRollback();

Future<void> mssqlDiscardAfterTransactionFailure(MssqlConnection connection) =>
    connection._discardAfterTransactionFailure();
