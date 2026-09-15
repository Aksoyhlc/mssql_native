import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'cancellation.dart';
import 'exception.dart';
import 'metadata_cache.dart';
import 'models/bulk.dart';
import 'models/config.dart';
import 'models/parameter.dart';
import 'models/result.dart';
import 'models/types.dart';
import 'native/worker.dart';
import 'query_options.dart';
import 'runtime.dart';
import 'session.dart';
import 'session_state.dart';
import 'sql.dart';
import 'transaction.dart';

class _OperationWaiter {
  _OperationWaiter(this.started);

  final Stopwatch started;
  final Completer<void> ready = Completer<void>();
  void Function()? unregisterCancellation;
}

class _OperationLease {
  _OperationLease(this.queueWait, this._release);

  final Duration queueWait;
  final void Function() _release;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

class _OperationGate {
  final Queue<_OperationWaiter> _waiters = Queue<_OperationWaiter>();
  bool _locked = false;

  Future<_OperationLease> acquire(MssqlCancellationToken? token) async {
    token?.throwIfCancelled();
    final started = Stopwatch()..start();
    if (!_locked) {
      _locked = true;
      return _OperationLease(started.elapsed, _release);
    }

    final waiter = _OperationWaiter(started);
    _waiters.addLast(waiter);
    if (token != null) {
      waiter.unregisterCancellation = token.register(() {
        if (!_waiters.remove(waiter) || waiter.ready.isCompleted) return;
        try {
          token.throwIfCancelled();
        } catch (error, stack) {
          waiter.ready.completeError(error, stack);
        }
      });
    }
    try {
      await waiter.ready.future;
      try {
        token?.throwIfCancelled();
      } catch (_) {
        // The waiter already owns the gate once [ready] completes. If the
        // token is cancelled between that completion and this continuation,
        // hand the gate to the next waiter instead of leaking the lock.
        _release();
        rethrow;
      }
      return _OperationLease(started.elapsed, _release);
    } catch (_) {
      waiter.unregisterCancellation?.call();
      rethrow;
    }
  }

  void _release() {
    while (_waiters.isNotEmpty) {
      final next = _waiters.removeFirst();
      next.unregisterCancellation?.call();
      if (next.ready.isCompleted) continue;
      next.ready.complete();
      return;
    }
    _locked = false;
  }
}

class _OperationContext {
  _OperationContext(this.id, this.lease, this.unregisterCancellation);

  final int id;
  final _OperationLease lease;
  final void Function()? unregisterCancellation;
}

Stream<T> _withSubscriptionCancellation<T>(
  MssqlCancellationToken? externalToken,
  Stream<T> Function(MssqlCancellationToken token) create,
) {
  late StreamController<T> controller;
  StreamSubscription<T>? subscription;
  late MssqlCancellationToken operationToken;
  void Function()? unregisterExternal;
  // `await for` cancels its subscription after both early exit and failure.
  // Only an early exit should cancel the command; after failure the connection
  // may already be processing another operation.
  var ended = false;

  controller = StreamController<T>(
    sync: true,
    onListen: () {
      operationToken = MssqlCancellationToken();
      unregisterExternal = externalToken?.register(
        () => operationToken.cancel(externalToken.reason),
      );
      subscription = create(operationToken).listen(
        controller.add,
        onError: (Object error, StackTrace stack) {
          ended = true;
          controller.addError(error, stack);
        },
        onDone: () {
          ended = true;
          unregisterExternal?.call();
          controller.close();
        },
      );
    },
    onPause: () => subscription?.pause(),
    onResume: () => subscription?.resume(),
    onCancel: () async {
      if (!ended) {
        operationToken.cancel('Stream subscription was cancelled');
      }
      unregisterExternal?.call();
      await subscription?.cancel();
    },
  );
  return controller.stream;
}

class _ProcedureParameterMetadata {
  const _ProcedureParameterMetadata({
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

class _BulkColumnMetadata {
  const _BulkColumnMetadata({
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
  }) : _databaseName = _worker.databaseName,
       _sessionState = MssqlSessionState(baselineDatabase: config.database),
       metadataCache =
           metadataCache ??
           MssqlMetadataCache(
             maxEntries: config.metadataCacheSize,
             ttl: config.metadataCacheTtl,
           );

  @override
  final MssqlConnectionConfig config;
  final MssqlRuntime _runtime;
  ConnectionWorker _worker;
  final _OperationGate _operationGate = _OperationGate();
  bool _closed = false;
  Future<void>? _closingFuture;
  bool _leasedByTransaction = false;
  bool? _hasHiddenColumnFlag;
  static int _tableParameterCounter = 0;

  /// Reserved name for the return status of a procedure called through the
  /// table-valued path, where EXEC runs inside a batch.
  static const String _returnStatusParameter = 'mssql_native_return_status';
  int _nextOperationId = 0;
  int? _activeOperationId;
  String _databaseName;
  int? _databaseCodePageCache;
  final MssqlSessionState _sessionState;

  /// Shared procedure and bulk-table metadata for this server.
  final MssqlMetadataCache metadataCache;

  bool get isClosed => _closed || _worker.isClosed;

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
  String get negotiatedTdsVersion => _tdsVersionName(_worker.negotiatedTdsCode);

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
      metadataCache.clear();
    } else {
      final identifier = MssqlMultipartIdentifier.parse(object);
      metadataCache.invalidateWhere(
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
  static final List<String> sessionSetup = <String>[
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
  );

  /// Opens a connection described by a .NET-style connection string.
  ///
  /// Keys this driver cannot honour are refused rather than ignored; see
  /// [MssqlConnectionConfig.fromConnectionString].
  static Future<MssqlConnection> connectString(
    String connectionString, {
    MssqlDecimalMode decimalMode = MssqlDefaults.decimalMode,
    void Function(List<String> keys)? onUnsupportedKeys,
  }) => open(
    MssqlConnectionConfig.fromConnectionString(
      connectionString,
      decimalMode: decimalMode,
      onUnsupportedKeys: onUnsupportedKeys,
    ),
  );

  static Future<MssqlConnection> open(
    MssqlConnectionConfig config, {
    MssqlMetadataCache? metadataCache,
  }) async {
    config.validate();
    final runtime = MssqlRuntime.instance;
    if (!runtime.isInitialized) await runtime.initialize();
    _ensureTransportIsTrusted(config, runtime);
    runtime.beginConnectionOpen();
    ConnectionWorker? worker;
    try {
      worker = await ConnectionWorker.open(
        config,
        runtime.sybdbPath,
        runtime.handlersPath,
      );
      final connection = MssqlConnection._(
        config,
        worker,
        runtime,
        metadataCache: metadataCache,
      );
      await connection._applySessionSetup();
      runtime.registerConnection(
        connection,
        connection.closeForRuntimeShutdown,
      );
      return connection;
    } on MssqlException catch (error, stack) {
      await worker?.close();
      Error.throwWithStackTrace(
        _withLoginHandshakeHint(error, config, runtime),
        stack,
      );
    } catch (_) {
      await worker?.close();
      rethrow;
    } finally {
      runtime.endConnectionOpen();
    }
  }

  /// Adds the one cause of a failed login that nothing else can report.
  ///
  /// TDS 7.1 and later encrypt the login packet whatever `encryption` says, so
  /// a server that offers only TLS 1.0 there is refused during the handshake.
  /// FreeTDS reports that as an ordinary "connection failed", which sends
  /// people to look at firewalls and credentials. The hint is added only when
  /// the configuration could actually be hitting it.
  static MssqlException _withLoginHandshakeHint(
    MssqlException error,
    MssqlConnectionConfig config,
    MssqlRuntime runtime,
  ) {
    if (error.type != MssqlErrorType.connection) return error;
    if (config.tdsVersion == '7.0') return error;
    if (runtime.allowLegacyTlsLogin) return error;
    return MssqlException.classify(
      type: error.type,
      message:
          '${error.message}\n'
          'If the server is SQL Server 2014 or earlier without the TLS 1.2 '
          'update, this is its login handshake being refused: TDS '
          '${config.tdsVersion} encrypts the login packet, such a server '
          'offers only TLS 1.0 there, and both FreeTDS and OpenSSL decline it '
          'by default. Update the server, or initialize with '
          'MssqlRuntime.instance.initialize(allowLegacyTlsLogin: true) — see '
          'doc/TLS.md.',
      code: error.code,
      state: error.state,
      retryable: error.retryable,
      operationId: error.operationId,
      queryName: error.queryName,
      diagnostics: error.diagnostics,
    );
  }

  /// Ensures encrypted connections have an explicit certificate trust policy.
  static void _ensureTransportIsTrusted(
    MssqlConnectionConfig config,
    MssqlRuntime runtime,
  ) {
    if (config.encryption != MssqlEncryption.require &&
        config.encryption != MssqlEncryption.strict) {
      return;
    }
    if (runtime.tlsTrust != null) return;
    throw MssqlTlsException(
      'This connection asks for encryption (${config.encryption.name}) but '
      'the process has no certificate trust configured, so FreeTDS would '
      'encrypt the session and then accept any certificate the server '
      'presented. Decide once, before the first connection:\n'
      '  MssqlRuntime.instance.initialize(tls: MssqlTlsTrust('
      "certificateAuthorityFile: '/path/to/ca.pem'))  // verify\n"
      '  MssqlRuntime.instance.initialize(tls: MssqlTlsTrust.system())'
      '                        // OpenSSL default paths\n'
      '  MssqlRuntime.instance.initialize(tls: '
      'MssqlTlsTrust.insecureNoVerification())    // encrypt, verify nothing\n'
      'Or set encryption: MssqlEncryption.off to connect in the clear. '
      'See doc/TLS.md.',
    );
  }

  Future<void> _applySessionSetup() async {
    if (sessionSetup.isEmpty) return;
    await _runOperation<void>(null, (context) async {
      await _executeUnlocked(
        command: sessionSetup.join('; '),
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
    return _execute(
      command: sql,
      procedure: false,
      parameters: compileParameters(parameters),
      options: settings,
    );
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
    bool allowTransaction = false,
  }) {
    // A procedure body is opaque to the driver: it may write, and rows coming
    // back prove nothing about that. Retry stays off whatever the caller asked.
    final settings = options
        .merge(
          timeout: timeout,
          cancellationToken: cancellationToken,
          batchRows: batchRows,
          maximumRows: maximumRows,
          maximumBytes: maximumBytes,
        )
        .withoutRetry;
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
      final tables = _splitTableParameters(metadata, parameters);
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
      final bindings = _compileProcedureParameters(
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
    bool allowTransaction = false,
  }) {
    final settings = options.merge(
      timeout: timeout,
      cancellationToken: cancellationToken,
      batchRows: batchRows,
      maximumRows: maximumRows,
      maximumBytes: maximumBytes,
    );
    final bindings = compileParameters(parameters);
    return _withSubscriptionCancellation(
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
    bool allowTransaction = false,
  }) {
    final settings = options.merge(
      timeout: timeout,
      cancellationToken: cancellationToken,
      batchRows: batchRows,
      maximumRows: maximumRows,
      maximumBytes: maximumBytes,
    );
    if (parameters is Iterable) {
      if (outputParameters.isNotEmpty) {
        throw ArgumentError(
          'outputParameters is for map parameters. Set direction on each '
          'MssqlParameter when using the explicit parameter API.',
        );
      }
      final bindings = compileParameters(parameters);
      return _withSubscriptionCancellation(
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
    return _withSubscriptionCancellation(
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
      final bindings = _compileProcedureParameters(
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
      cancellationToken.throwIfCancelled();
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
      cancellationToken?.throwIfCancelled();
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
    _validateQueryLimits(
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
        cancellationToken?.throwIfCancelled();
        final columns = await worker.nextResult();
        if (columns == null) break;
        final schema = MssqlRowSchema(columns);
        final setWatch = Stopwatch()..start();
        var rows = 0;
        var bytes = 0;
        yield MssqlResultSetStart(index: setIndex, columns: schema.columns);
        while (true) {
          cancellationToken?.throwIfCancelled();
          final values = await worker.fetchBatch(batchRows);
          if (values == null) break;
          if (values.isNotEmpty && firstRow == null) {
            firstRow = execution.elapsed;
          }
          final batch = <MssqlRow>[];
          for (final valueRow in values) {
            rows++;
            final size = _decodedRowBytes(valueRow);
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
      options.cancellationToken?.throwIfCancelled();
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
    _validateQueryLimits(
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
            decodedBytes += _decodedRowBytes(row);
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
  Future<MssqlExecutionResult> executeWithinTransaction(
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
  }) => _runOperation<MssqlTransaction>(cancellationToken, (_) async {
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
      return MssqlTransaction.internal(this, _worker);
    } catch (_) {
      _leasedByTransaction = false;
      rethrow;
    }
  });

  Future<T> transaction<T>(
    Future<T> Function(MssqlTransaction transaction) callback, {
    MssqlIsolationLevel isolationLevel = MssqlIsolationLevel.baseline,
    MssqlCancellationToken? cancellationToken,
  }) async {
    final transaction = await beginTransaction(
      isolationLevel: isolationLevel,
      cancellationToken: cancellationToken,
    );
    try {
      final value = await callback(transaction);
      await transaction.commit();
      await transaction.close();
      return value;
    } catch (error, stack) {
      // Cleanup must not replace the failure being diagnosed, so a failing
      // rollback or close is swallowed.
      try {
        await transaction.rollback();
      } catch (_) {}
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
    bool allowTransaction = false,
  }) {
    if (columns is List<MssqlBulkColumn>) {
      return bulkInsertRaw(
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
      final byName = <String, _BulkColumnMetadata>{
        for (final item in metadata) item.column.name: item,
      };
      final chosen = <_BulkColumnMetadata>[];
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
          _validateBulkKeys(current, selected, rowIndex);
          yield <MssqlValue>[
            for (final item in chosen)
              _bulkValue(current[item.column.name], item.column, rowIndex),
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
    bool allowTransaction = false,
  }) {
    final table = MssqlMultipartIdentifier.parse(tableName);
    options.validate();
    _validateRawBulkColumns(columns);
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
              _bulkValue(row[index], columns[index], rowIndex),
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
    final codePage = columns.any((column) => _isSingleByteText(column.type))
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
        cancellationToken?.throwIfCancelled();
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
  static Map<String, MssqlTableRows> _splitTableParameters(
    List<_ProcedureParameterMetadata> metadata,
    Map<String, Object?> parameters,
  ) {
    final tableParameters = <String, _ProcedureParameterMetadata>{
      for (final item in metadata)
        if (item.isTableType) item.name: item,
    };
    if (tableParameters.isEmpty) return const <String, MssqlTableRows>{};
    final tables = <String, MssqlTableRows>{};
    for (final entry in parameters.entries) {
      final name = normalizeParameterName(entry.key);
      if (!tableParameters.containsKey(name)) continue;
      final value = entry.value;
      if (value is MssqlTableRows) {
        tables[name] = value;
        continue;
      }
      if (value is Iterable<Map<String, Object?>>) {
        tables[name] = MssqlTableRows(value);
        continue;
      }
      throw ArgumentError.value(
        value,
        name,
        'Parameter "$name" is a table type. Pass MssqlTableRows or an '
        'Iterable<Map<String, Object?>>.',
      );
    }
    return tables;
  }

  /// Calls a procedure containing table-valued parameters.
  ///
  /// FreeTDS lacks TVP wire support, so rows are bulk-copied into a temporary
  /// table and transferred to a variable of the declared table type.
  Future<MssqlExecutionResult> _callProcedureWithTablesUnlocked({
    required MssqlMultipartIdentifier identifier,
    required List<_ProcedureParameterMetadata> metadata,
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
    final scalarMetadata = <_ProcedureParameterMetadata>[
      for (final item in metadata)
        if (!item.isTableType) item,
    ];
    final bindings = <MssqlParameterBinding>[
      ..._compileProcedureParameters(scalarMetadata, scalars, outputParameters),
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
    _ProcedureParameterMetadata parameter,
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
        _validateBulkKeys(row, names, rowIndex);
        yield <MssqlValue>[
          for (final column in columns)
            _bulkValue(row[column.name], column, rowIndex),
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
    _ProcedureParameterMetadata parameter,
  ) async {
    final result = await _executeUnlocked(
      command: '''
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
''',
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
    if (result.resultSets.isEmpty) return const <MssqlBulkColumn>[];
    return result.resultSets.first.typedRows
        .map((row) {
          final type = _typeFromSqlName(row.require<String>('type_name'));
          return MssqlBulkColumn(
            ordinal: row.require<int>('column_id'),
            name: row.require<String>('name'),
            type: type,
            size: _metadataSize(type, row.require<int>('max_length')),
            precision: row.require<int>('precision'),
            scale: row.require<int>('scale'),
            nullable: row.require<bool>('is_nullable'),
          );
        })
        .toList(growable: false);
  }

  Future<List<_ProcedureParameterMetadata>> _procedureMetadata(
    MssqlMultipartIdentifier procedure, {
    MssqlProcedureMetadata? declared,
    MssqlMetadataDriftPolicy driftPolicy =
        MssqlMetadataDriftPolicy.preferDeclared,
  }) async {
    if (declared != null) {
      _assertDeclaredIsFor(identifier: procedure, declared: declared);
    }
    if (declared != null &&
        driftPolicy == MssqlMetadataDriftPolicy.preferDeclared) {
      return _procedureMetadataFromDeclared(declared);
    }
    final key = MssqlMetadataCache.key(
      host: config.host,
      port: config.port,
      database: _databaseName,
      object: 'proc:${procedure.quoted}',
      schemaVersion: declared?.schemaVersion ?? '',
    );
    final live = await metadataCache.getOrLoad(
      key,
      () => _procedureMetadataUnlocked(procedure),
    );
    if (declared != null &&
        driftPolicy == MssqlMetadataDriftPolicy.verifyDeclared) {
      _assertProcedureMetadata(declared, live);
    }
    return live;
  }

  /// Refuses a declaration that describes some other procedure.
  ///
  /// `preferDeclared` skips the catalog, so the declaration is the only
  /// description of the call. The wrong one binds this procedure's arguments
  /// with another's types, sizes and directions. The name is what can be
  /// checked without a catalog query.
  void _assertDeclaredIsFor({
    required MssqlMultipartIdentifier identifier,
    required MssqlProcedureMetadata declared,
  }) {
    final MssqlMultipartIdentifier parsed;
    try {
      parsed = MssqlMultipartIdentifier.parse(declared.procedure);
    } on ArgumentError {
      throw MssqlException(
        type: MssqlErrorType.configuration,
        message:
            'MssqlProcedureMetadata.procedure is '
            '"${declared.procedure}", which is not a SQL identifier. It names '
            'the procedure the declaration describes, and is compared against '
            'the one being called.',
      );
    }
    // Compared on the trailing parts both names have, so `create_label`
    // matches `dbo.create_label` but `sales.create_label` does not.
    final a = identifier.parts;
    final b = parsed.parts;
    final shared = a.length < b.length ? a.length : b.length;
    for (var i = 1; i <= shared; i++) {
      if (a[a.length - i].toLowerCase() != b[b.length - i].toLowerCase()) {
        throw MssqlException(
          type: MssqlErrorType.configuration,
          message:
              'The declared metadata describes "${declared.procedure}", but '
              'this call is to "${identifier.quoted}". Passing one '
              'procedure\'s declaration to another binds its arguments with '
              'the wrong types, sizes and directions.',
        );
      }
    }
  }

  List<_ProcedureParameterMetadata> _procedureMetadataFromDeclared(
    MssqlProcedureMetadata declared,
  ) {
    return <_ProcedureParameterMetadata>[
      for (final parameter in declared.parameters)
        _ProcedureParameterMetadata(
          name: normalizeParameterName(parameter.name),
          type: parameter.type,
          size: parameter.size,
          precision: parameter.precision,
          scale: parameter.scale,
          isOutput: parameter.isOutput,
          isReadOnly: parameter.isReadOnly || parameter.tableTypeName != null,
          tableTypeName: parameter.tableTypeName,
          tableTypeSchema: parameter.tableTypeSchema,
        ),
    ];
  }

  void _assertProcedureMetadata(
    MssqlProcedureMetadata declared,
    List<_ProcedureParameterMetadata> live,
  ) {
    final expected = _procedureMetadataFromDeclared(declared);
    if (expected.length != live.length) {
      throw MssqlException(
        type: MssqlErrorType.configuration,
        message:
            'Procedure "${declared.procedure}" has ${live.length} parameter(s) '
            'on the server and ${expected.length} in generated metadata. '
            'Regenerate against the live procedure, or pass '
            'driftPolicy: MssqlMetadataDriftPolicy.alwaysDescribe.',
      );
    }
    for (var i = 0; i < live.length; i++) {
      final a = expected[i];
      final b = live[i];
      if (a.name == b.name &&
          a.type == b.type &&
          a.size == b.size &&
          a.precision == b.precision &&
          a.scale == b.scale &&
          a.isOutput == b.isOutput &&
          a.tableTypeName == b.tableTypeName &&
          a.tableTypeSchema == b.tableTypeSchema) {
        continue;
      }
      throw MssqlException(
        type: MssqlErrorType.configuration,
        message:
            'Procedure "${declared.procedure}" parameter "${b.name}" does not '
            'match generated metadata. The server has ${b.type.name} '
            '(size ${b.size}, precision ${b.precision}, scale ${b.scale}); '
            'generation has ${a.type.name} (size ${a.size}, precision '
            '${a.precision}, scale ${a.scale}). Regenerate, or pass '
            'driftPolicy: MssqlMetadataDriftPolicy.alwaysDescribe.',
      );
    }
  }

  Future<List<_BulkColumnMetadata>> _tableMetadata(
    MssqlMultipartIdentifier table,
  ) {
    final key = MssqlMetadataCache.key(
      host: config.host,
      port: config.port,
      database: _databaseName,
      object: 'table:${table.quoted}',
    );
    return metadataCache.getOrLoad(key, () => _tableMetadataUnlocked(table));
  }

  Future<List<_ProcedureParameterMetadata>> _procedureMetadataUnlocked(
    MssqlMultipartIdentifier procedure,
  ) async {
    final catalog = procedure.parts.length == 3
        ? '${MssqlSql.quoteIdentifier(procedure.parts.first)}.'
        : '';
    final result = await _executeUnlocked(
      command:
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
''',
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
    if (result.resultSets.isEmpty) return const <_ProcedureParameterMetadata>[];
    return result.resultSets.first.typedRows
        .map((row) {
          final rawName = row.require<String>('name');
          final isTableType = row.require<bool>('is_table_type');
          // A table type has no Dart-side equivalent; it is kept in the list
          // only so that naming it produces the unsupported-type error rather
          // than "no such parameter".
          final type = isTableType
              ? MssqlType.nvarchar
              : _typeFromSqlName(row.require<String>('type_name'));
          return _ProcedureParameterMetadata(
            name: normalizeParameterName(rawName),
            type: type,
            size: _metadataSize(type, row.require<int>('max_length')),
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

  List<MssqlParameterBinding> _compileProcedureParameters(
    List<_ProcedureParameterMetadata> metadata,
    Map<String, Object?> parameters,
    Set<String> outputParameters,
  ) {
    final inputs = <String, Object?>{};
    for (final entry in parameters.entries) {
      final name = normalizeParameterName(entry.key);
      if (inputs.containsKey(name)) {
        throw ArgumentError('Duplicate procedure parameter "$name".');
      }
      inputs[name] = entry.value;
    }
    final outputs = outputParameters.map(normalizeParameterName).toSet();
    final known = metadata.map((item) => item.name).toSet();
    for (final name in <String>{...inputs.keys, ...outputs}) {
      if (!known.contains(name)) {
        throw ArgumentError('The procedure has no parameter named "$name".');
      }
    }

    final bindings = <MssqlParameterBinding>[];
    for (final item in metadata) {
      final hasInput = inputs.containsKey(item.name);
      final wantsOutput = outputs.contains(item.name);
      if (!hasInput && !wantsOutput) continue;
      if (item.isReadOnly) {
        throw MssqlException(
          type: MssqlErrorType.unsupportedType,
          message: 'Table-valued parameter "${item.name}" is not supported.',
        );
      }
      if (wantsOutput && !item.isOutput) {
        throw ArgumentError(
          'Procedure parameter "${item.name}" is not declared OUTPUT.',
        );
      }
      final raw = hasInput ? inputs[item.name] : null;
      final value = wantsOutput
          ? coerceMssqlValue(
              raw is MssqlValue ? raw.value : raw,
              type: item.type,
              size: item.size,
              precision: item.precision,
              scale: item.scale,
            )
          : (raw is MssqlValue
                ? raw.validated()
                : coerceMssqlValue(
                    raw,
                    type: item.type,
                    size: item.size,
                    precision: item.precision,
                    scale: item.scale,
                  ));
      final direction = wantsOutput
          ? (hasInput
                ? MssqlParameterBindingDirection.inputOutput
                : MssqlParameterBindingDirection.output)
          : MssqlParameterBindingDirection.input;
      bindings.add(
        MssqlParameterBinding.fromValue(item.name, value, direction: direction),
      );
    }
    return bindings;
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

  Future<List<_BulkColumnMetadata>> _tableMetadataUnlocked(
    MssqlMultipartIdentifier table,
  ) async {
    final catalog = table.parts.length == 3
        ? '${MssqlSql.quoteIdentifier(table.parts.first)}.'
        : '';
    final hidden = await _hasHiddenColumnFlagUnlocked(catalog)
        ? 'c.is_hidden'
        : 'CAST(0 AS bit)';
    final result = await _executeUnlocked(
      command:
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
''',
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
    if (result.resultSets.isEmpty) return const <_BulkColumnMetadata>[];
    return result.resultSets.first.typedRows
        .map((row) {
          final typeName = row.require<String>('type_name');
          final rowVersion =
              typeName == 'timestamp' || typeName == 'rowversion';
          final type = rowVersion
              ? MssqlType.varbinary
              : _typeFromSqlName(typeName);
          return _BulkColumnMetadata(
            column: MssqlBulkColumn(
              ordinal: row.require<int>('column_id'),
              name: row.require<String>('name'),
              type: type,
              size: _metadataSize(type, row.require<int>('max_length')),
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
    Future<T> Function(_OperationContext context) action,
  ) async {
    final context = await _beginOperation(token);
    try {
      return await action(context);
    } catch (_) {
      token?.throwIfCancelled();
      rethrow;
    } finally {
      _endOperation(context);
    }
  }

  Future<_OperationContext> _beginOperation(
    MssqlCancellationToken? token,
  ) async {
    final lease = await _operationGate.acquire(token);
    final id = _nextOperationId++;
    _activeOperationId = id;
    void Function()? unregister;
    try {
      unregister = token?.register(() {
        if (_activeOperationId == id && !_closed) _worker.cancel();
      });
      token?.throwIfCancelled();
      return _OperationContext(id, lease, unregister);
    } catch (_) {
      unregister?.call();
      if (_activeOperationId == id) _activeOperationId = null;
      lease.release();
      rethrow;
    }
  }

  void _endOperation(_OperationContext context) {
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

  Future<void> closeForRuntimeShutdown() async {
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
      _runtime.unregisterConnection(this);
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
    _runtime.ensureCanOpenConnection();
    try {
      _worker = await ConnectionWorker.open(
        config.copyWith(database: _databaseName),
        _runtime.sybdbPath,
        _runtime.handlersPath,
      );
      _databaseName = _worker.databaseName;
      invalidateMetadata();
    } catch (_) {
      _closed = true;
      _runtime.unregisterConnection(this);
      rethrow;
    }
    if (sessionSetup.isNotEmpty) {
      await _executeUnlocked(
        command: sessionSetup.join('; '),
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
  }

  Future<T> runTransactionNative<T>(Future<T> Function() action) =>
      _runOperation<T>(null, (_) async {
        _ensureAvailable(allowTransaction: true);
        return action();
      });

  void releaseTransactionLease() => _leasedByTransaction = false;

  /// Gives the connection back after a transaction has finished with it.
  ///
  /// Restoring whatever the transaction changed about the session is part of
  /// giving it back, so this is a future: see [restoreSessionBaseline].
  Future<void> releaseAfterTransaction() async {
    _leasedByTransaction = false;
    await restoreSessionBaseline();
  }

  /// Restores reusable session state without replacing an earlier error.
  ///
  /// A failed restore marks the session dirty instead of throwing, preventing
  /// the pool from leasing it again.
  Future<void> restoreSessionBaseline() async {
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
  Future<void> settleAfterFailedRollback() async {
    try {
      final result = await executeWithinTransaction(
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
    await discardAfterTransactionFailure();
  }

  /// Drops a connection whose transaction state could not be resolved.
  ///
  /// A rollback that failed leaves the session ambiguous, so the lease is
  /// released and the worker is torn down instead of being reused or pooled.
  Future<void> discardAfterTransactionFailure() async {
    _leasedByTransaction = false;
    try {
      await close();
    } catch (_) {}
  }

  static bool _isSingleByteText(MssqlType type) =>
      type == MssqlType.char ||
      type == MssqlType.varchar ||
      type == MssqlType.text;

  static int _decodedRowBytes(List<Object?> row) {
    var bytes = 0;
    for (final value in row) {
      bytes += switch (value) {
        null => 0,
        final String text => text.length * 2,
        final Uint8List data => data.length,
        final bool _ => 1,
        _ => 8,
      };
    }
    return bytes;
  }

  static void _validateBulkKeys(
    Map<String, Object?> row,
    List<String> selected,
    int rowIndex,
  ) {
    if (row.length == selected.length && selected.every(row.containsKey)) {
      return;
    }
    final selectedSet = selected.toSet();
    final missing = selected.where((name) => !row.containsKey(name)).toList();
    final extra = row.keys
        .where((name) => !selectedSet.contains(name))
        .toList();
    final column = missing.isNotEmpty
        ? missing.first
        : (extra.isNotEmpty ? extra.first : '<row>');
    throw MssqlBulkRowException(
      rowIndex: rowIndex,
      columnName: column,
      detail: missing.isNotEmpty
          ? 'the selected column is missing.'
          : 'the row contains a column outside the selected set.',
    );
  }

  static MssqlValue _bulkValue(
    Object? raw,
    MssqlBulkColumn column,
    int rowIndex,
  ) {
    try {
      final value = raw is MssqlParameter
          ? (raw..validate()).toValue()
          : raw is MssqlValue
          ? raw.validated()
          : coerceMssqlValue(
              raw,
              type: column.type,
              size: column.size,
              precision: column.precision,
              scale: column.scale,
            );
      if (value.type != column.type) {
        throw StateError('explicit value type does not match destination');
      }
      if (value.value == null && !column.nullable) {
        throw StateError('NULL is not allowed');
      }
      return value;
    } catch (_) {
      throw MssqlBulkRowException(
        rowIndex: rowIndex,
        columnName: column.name,
        detail:
            'expected ${column.type}; received ${raw is MssqlParameter
                ? raw.type
                : raw is MssqlValue
                ? raw.type
                : raw?.runtimeType ?? 'NULL'}.',
      );
    }
  }

  static void _validateRawBulkColumns(List<MssqlBulkColumn> columns) {
    if (columns.isEmpty) {
      throw ArgumentError('At least one bulk column is required.');
    }
    final ordinals = <int>{};
    final names = <String>{};
    for (final column in columns) {
      column.validate();
      if (!ordinals.add(column.ordinal)) {
        throw ArgumentError('Bulk column ordinals must be unique.');
      }
      if (!names.add(column.name)) {
        throw ArgumentError('Bulk column names must be unique.');
      }
    }
  }

  static MssqlType _typeFromSqlName(String name) => switch (name
      .toLowerCase()) {
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

  static int _metadataSize(MssqlType type, int maxLength) {
    if (maxLength < 0) return 0;
    if (type == MssqlType.nchar || type == MssqlType.nvarchar) {
      return maxLength ~/ 2;
    }
    return maxLength;
  }

  static String _tdsVersionName(int code) => switch (code) {
    1 => '2.0',
    2 => '3.4',
    3 => '4.0',
    4 => '4.2',
    5 => '4.6',
    6 => '4.9.5',
    7 => '5.0',
    8 => '7.0',
    9 => '7.1',
    10 => '7.2',
    11 => '7.3',
    12 => '7.4',
    13 => '8.0',
    _ => 'unknown($code)',
  };

  static void _validateQueryLimits(
    String sql, {
    required int batchRows,
    required int maximumRows,
    required int maximumBytes,
    required Duration? timeout,
  }) {
    if (sql.trim().isEmpty) throw ArgumentError.value(sql, 'sql');
    if (batchRows < 1 || batchRows > 1000) {
      throw RangeError.range(batchRows, 1, 1000, 'batchRows');
    }
    if (maximumRows < 0) throw RangeError.value(maximumRows, 'maximumRows');
    if (maximumBytes < 0) throw RangeError.value(maximumBytes, 'maximumBytes');
    if (timeout != null && timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout');
    }
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
