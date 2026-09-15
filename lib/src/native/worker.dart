// Each connection owns a worker isolate because DB-Library blocks and is not
// reentrant per DBPROCESS. Native C handlers receive FreeTDS callbacks; Dart
// trampolines cannot be called safely from FreeTDS-managed threads.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../exception.dart';
import '../models/bulk.dart';
import '../models/config.dart';
import '../models/decimal.dart';
import '../models/parameter.dart';
import '../models/result.dart';
import '../models/types.dart';
import 'code_pages.dart';
import 'dblib.dart';
import 'dblib_callbacks.dart';
import 'handlers.dart';
import 'numeric_decoder.dart';
import 'parameter_binder.dart';
import 'value_decoder.dart';
import 'worker_channel.dart';

// Protocol

/// What a worker call can be. Strings rather than an enum so a stray message
/// is readable in a stack trace.
abstract final class Op {
  static const String ping = 'ping';
  static const String close = 'close';
  static const String execute = 'execute';
  static const String nextResult = 'nextResult';
  static const String fetchBatch = 'fetchBatch';
  static const String finish = 'finish';
  static const String closeQuery = 'closeQuery';
  static const String cancelQuery = 'cancelQuery';
  static const String runSql = 'runSql';
  static const String useDatabase = 'useDatabase';
  static const String bulkOpen = 'bulkOpen';
  static const String bulkAddRows = 'bulkAddRows';
  static const String bulkComplete = 'bulkComplete';
  static const String bulkCancel = 'bulkCancel';
  static const String bulkClose = 'bulkClose';
}

/// A failure, flattened to primitives so it crosses the port whatever the
/// isolate group rules turn out to allow.
class WorkerFailure {
  WorkerFailure(
    this.code,
    this.typeIndex,
    this.message,
    this.retryable, [
    this.diagnostics = const <MssqlServerMessage>[],
  ]);
  final int code;
  final int typeIndex;
  final String message;
  final bool retryable;

  /// Everything the server said while the failing statement ran.
  ///
  /// A batch can report several errors and the exception can only carry one as
  /// its message, so the rest would otherwise be lost.
  final List<MssqlServerMessage> diagnostics;

  MssqlException toException() => MssqlException(
    type: MssqlErrorType.values[typeIndex],
    code: code,
    message: message,
    retryable: retryable,
    diagnostics: diagnostics,
  );
}

// Worker side

class _Worker {
  late final DbLib lib;
  late final Pointer<Void> dbproc;
  late final Pointer<Void> interruptState;

  /// What the C recorder said during this query, copied out message by
  /// message. See [_dispatch] for why it cannot be read only at the end.
  final List<MssqlServerMessage> queryMessages = <MssqlServerMessage>[];
  MssqlErrorType? failureType;
  int failureCode = 0;
  String failureMessage = '';
  bool failureRetryable = false;

  List<MssqlColumn>? columns;
  bool resultOpen = false;
  bool allResultsDone = false;
  int affectedRows = 0;

  /// Every row count the batch reported, kept apart rather than only summed.
  ///
  /// DB-Library hands over one count per statement that produced one, and a
  /// trigger's body produces its own. Summing them answers "how much did the
  /// server do", which is not the question a caller asking "did my UPDATE
  /// change one row" is asking; keeping the list makes the difference
  /// visible instead of unrecoverable.
  final List<int> rowCounts = <int>[];

  void recordRowCount(int count) {
    rowCounts.add(count);
    affectedRows += count;
  }

  late Handlers handlers;

  /// How decimal and money columns reach Dart.
  MssqlDecimalMode decimalMode = MssqlDecimalMode.exact;

  Pointer<Uint8>? convBuffer;
  int convBufferSize = 0;

  // Row and byte ceilings for the query in flight, and what has been read
  // against them.
  int maximumRows = 0;
  int maximumBytes = 0;
  int rowsRead = 0;
  int bytesRead = 0;

  // Bulk copy. FreeTDS binds one buffer per column once, then the row loop
  // rewrites those buffers and points bcp at them again.
  List<MssqlBulkColumn> bulkColumns = const <MssqlBulkColumn>[];
  List<Pointer<Uint8>> bulkBuffers = const <Pointer<Uint8>>[];
  List<int> bulkBufferSizes = const <int>[];
  MssqlBulkOptions? bulkOptions;

  /// The database code page single-byte bulk columns are encoded in.
  /// Zero when the load has no single-byte text column.
  int bulkCodePage = 0;
  int bulkRows = 0;
  int bulkInserted = 0;
  int bulkBatches = 0;
  int? bulkFailedRow;
  DateTime? bulkStarted;
}

/// Per-isolate. One connection per worker, so a single instance is enough for
/// Dart state. The native interrupt recorder is attached to its DBPROCESS.
final _Worker _w = _Worker();

const int _interruptCancelled = 1;
const int _interruptTimedOut = 2;

/// Grows the scratch buffer `dbconvert` writes into.
///
/// `DECIMAL(38,10)` needs 41 characters plus a sign and a terminator, and the
/// decimal gate showed 128 is comfortable; a wide `datetimeoffset` is shorter
/// still. Text columns are read from `dbdata` directly and never come through
/// here.
Pointer<Uint8> _conv(int needed) {
  if (_w.convBufferSize >= needed) return _w.convBuffer!;
  if (_w.convBuffer != null) calloc.free(_w.convBuffer!);
  final size = needed < 256 ? 256 : needed;
  _w.convBuffer = calloc<Uint8>(size);
  _w.convBufferSize = size;
  return _w.convBuffer!;
}

Never _fail(int code, MssqlErrorType type, String fallback) {
  syncErrorState(_w.handlers);
  final state = errorState;
  final diagnostics = <MssqlServerMessage>[
    ..._w.queryMessages,
    ...state.messages,
  ];
  if (state.hasError) {
    throw WorkerFailure(
      state.code != 0 ? state.code : code,
      state.type.index,
      state.message.isNotEmpty ? state.message : fallback,
      state.retryable,
      diagnostics,
    );
  }
  // Nothing was recorded during this message, so fall back to what the rest of
  // the query recorded; it may have been recorded on another OS thread, which
  // is why it is kept in Dart.
  final earlier = _w.failureType;
  if (earlier != null) {
    throw WorkerFailure(
      _w.failureCode != 0 ? _w.failureCode : code,
      earlier.index,
      _w.failureMessage.isNotEmpty ? _w.failureMessage : fallback,
      _w.failureRetryable,
      diagnostics,
    );
  }
  // DB-Library can answer FAIL for a dead connection without reporting anything
  // through the handlers, so check the process directly.
  if (_w.lib.dbdead(_w.dbproc) != 0) {
    throw WorkerFailure(
      code,
      MssqlErrorType.connectionLost.index,
      'The SQL connection was lost.',
      true,
      diagnostics,
    );
  }
  throw WorkerFailure(code, type.index, fallback, false, diagnostics);
}

void _entry(List<Object?> args) {
  final send = args[0] as SendPort;
  final config = args[1] as MssqlConnectionConfig;
  final sybdbPath = args[2] as String;
  final handlersPath = args[3] as String;

  final commands = ReceivePort();

  try {
    _w.lib = DbLib(DynamicLibrary.open(sybdbPath));
  } on Object catch (error) {
    send.send(<Object?>[
      -1,
      null,
      WorkerFailure(
        -100,
        MssqlErrorType.libraryLoad.index,
        'Could not load FreeTDS at $sybdbPath: $error',
        false,
      ),
    ]);
    return;
  }

  final lib = _w.lib;

  // DB-Library keeps error/message handlers in process-global pointers.
  // These are C functions because Dart callbacks cannot cross isolates;
  // installing the same C functions from every isolate is idempotent.
  try {
    _w.handlers = Handlers(DynamicLibrary.open(handlersPath));
  } on Object catch (error) {
    send.send(<Object?>[
      -1,
      null,
      WorkerFailure(
        -105,
        MssqlErrorType.libraryLoad.index,
        'Could not load the mssql_native handler library at '
        '$handlersPath: $error',
        false,
      ),
    ]);
    return;
  }
  if (_w.handlers.abi() != handlersAbi) {
    send.send(<Object?>[
      -1,
      null,
      WorkerFailure(
        -106,
        MssqlErrorType.libraryLoad.index,
        'The mssql_native handler library reports ABI '
        '${_w.handlers.abi()}, but this build expects $handlersAbi. '
        'Rebuild it with scripts/build_*.',
        false,
      ),
    ]);
    return;
  }
  // install() calls dbinit() itself, so the two always happen together.
  if (_w.handlers.install() == 0) {
    send.send(<Object?>[
      -1,
      null,
      WorkerFailure(
        -101,
        MssqlErrorType.libraryLoad.index,
        'dbinit failed.',
        false,
      ),
    ]);
    return;
  }

  if (_w.handlers.hasTls() != 1 &&
      (config.encryption == MssqlEncryption.require ||
          config.encryption == MssqlEncryption.strict)) {
    // Failing here rather than at login: without a TLS backend FreeTDS connects
    // without encrypting, so the caller would believe it had encryption.
    send.send(<Object?>[
      -1,
      null,
      WorkerFailure(
        -108,
        MssqlErrorType.configuration.index,
        'This build of FreeTDS has no TLS backend, so encryption '
        '"${encryptionSetting(config.encryption)}" cannot be honoured. '
        'Rebuild it with --with-openssl.',
        false,
      ),
    ]);
    _w.handlers.release();
    return;
  }

  if (config.integratedSecurity && !Platform.isWindows) {
    send.send(<Object?>[
      -1,
      null,
      WorkerFailure(
        -110,
        MssqlErrorType.configuration.index,
        'Integrated security needs SSPI, which the bundled FreeTDS only has '
        'on Windows; this is ${Platform.operatingSystem}. Log in with a '
        r'domain account instead: username "DOMAIN\user" and its password.',
        false,
      ),
    ]);
    _w.handlers.release();
    return;
  }

  _w.decimalMode = config.decimalMode;
  _w.handlers.reset();
  errorState.reset();
  lib.dbsetlogintime(
    config.loginTimeout.inSeconds < 1 ? 1 : config.loginTimeout.inSeconds,
  );
  final login = lib.dblogin();
  if (login == nullptr) {
    send.send(<Object?>[
      -1,
      null,
      WorkerFailure(
        -102,
        MssqlErrorType.connection.index,
        'Could not allocate a FreeTDS login record.',
        false,
      ),
    ]);
    _w.handlers.release();
    return;
  }

  if (config.integratedSecurity) {
    if (lib.enableNetworkAuthentication(login) != Syb.succeed) {
      lib.dbloginfree(login);
      send.send(<Object?>[
        -1,
        null,
        WorkerFailure(
          -111,
          MssqlErrorType.configuration.index,
          'FreeTDS rejected the request to log in as the current Windows '
          'account.',
          false,
        ),
      ]);
      _w.handlers.release();
      return;
    }
  } else {
    final user = config.username.toNativeUtf8();
    final password = config.password.toNativeUtf8();
    lib.dbsetlname(login, user, Syb.setUser);
    lib.dbsetlname(login, password, Syb.setPwd);
    calloc.free(user);
    calloc.free(password);
  }

  if (config.applicationName.isNotEmpty) {
    final app = config.applicationName.toNativeUtf8();
    lib.dbsetlname(login, app, Syb.setApp);
    calloc.free(app);
  }
  // FreeTDS converts the server's code page to this charset through iconv;
  // without it the connection falls back to FreeTDS's default and CP1254 data
  // arrives mangled.
  if (config.clientCharset.isNotEmpty) {
    final charset = config.clientCharset.toNativeUtf8();
    lib.dbsetlname(login, charset, Syb.setCharset);
    calloc.free(charset);
  }
  lib.dbsetlversion(login, DbLib.tdsVersionByte(config.tdsVersion));

  // The only TLS setting DB-Library exposes. Certificate trust comes from the
  // freetds.conf MssqlRuntime writes, which is process-wide.
  if (config.encryption != MssqlEncryption.off) {
    final level = encryptionSetting(config.encryption).toNativeUtf8();
    final applied = lib.dbsetlname(login, level, Syb.setEncryption);
    calloc.free(level);
    if (applied != Syb.succeed) {
      lib.dbloginfree(login);
      send.send(<Object?>[
        -1,
        null,
        WorkerFailure(
          -107,
          MssqlErrorType.configuration.index,
          'FreeTDS rejected the encryption level '
          '"${encryptionSetting(config.encryption)}".',
          false,
        ),
      ]);
      _w.handlers.release();
      return;
    }
  }
  if (config.packetSize > 0) {
    lib.dbsetllong(login, config.packetSize, Syb.setPacket);
  }
  lib.enableBulkCopy(login);

  final server = '${config.host}:${config.port}'.toNativeUtf8();
  final dbproc = lib.tdsdbopen(login, server, 1);
  calloc.free(server);
  lib.dbloginfree(login);

  if (dbproc == nullptr) {
    syncErrorState(_w.handlers);
    send.send(<Object?>[
      -1,
      null,
      WorkerFailure(
        errorState.code != 0 ? errorState.code : -103,
        (errorState.hasError ? errorState.type : MssqlErrorType.connection)
            .index,
        errorState.message.isNotEmpty
            ? errorState.message
            : 'Could not connect to SQL Server.',
        errorState.retryable,
      ),
    ]);
    _w.handlers.release();
    return;
  }
  _w.dbproc = dbproc;

  // The interrupt callbacks and their connection-local state are native. A
  // Dart Pointer.fromFunction callback here can abort the VM on Android when
  // FreeTDS invokes it without this worker isolate being current.
  final interruptState = _w.handlers.interruptAttach(dbproc);
  if (interruptState == nullptr) {
    lib.dbclose(dbproc);
    send.send(<Object?>[
      -1,
      null,
      WorkerFailure(
        -109,
        MssqlErrorType.libraryLoad.index,
        'Could not allocate the native interrupt state.',
        false,
      ),
    ]);
    _w.handlers.release();
    return;
  }
  _w.interruptState = interruptState;

  final database = config.database.toNativeUtf8();
  final used = lib.dbuse(dbproc, database);
  calloc.free(database);
  if (used != Syb.succeed) {
    syncErrorState(_w.handlers);
    _w.handlers.interruptDetach(dbproc);
    lib.dbclose(dbproc);
    send.send(<Object?>[
      -1,
      null,
      WorkerFailure(
        errorState.code != 0 ? errorState.code : -104,
        MssqlErrorType.configuration.index,
        errorState.message.isNotEmpty
            ? errorState.message
            : 'Could not switch to database ${config.database}.',
        false,
      ),
    ]);
    _w.handlers.release();
    return;
  }

  // Session preconditions, not caller policy, so they are applied here rather
  // than left to MssqlConnection.sessionSetup.
  //
  // TEXTSIZE is the one that bites: DB-Library defaults it to 4096 bytes, which
  // silently truncates text/ntext/image and every (max) column read - a 1 MB
  // varbinary comes back as 4 KB with no error at all.
  //
  // NOCOUNT is left OFF (the server default). SET NOCOUNT ON suppresses the
  // row-count DONE tokens that bcp_done() and affected-row reporting depend on,
  // which breaks BCP completion.
  try {
    _runSql(
      'SET XACT_ABORT ON; SET ANSI_NULLS ON; SET ANSI_WARNINGS ON; '
      'SET TEXTSIZE 2147483647;',
      config.loginTimeout,
    );
  } on WorkerFailure catch (failure) {
    _w.handlers.interruptDetach(dbproc);
    lib.dbclose(dbproc);
    send.send(<Object?>[-1, null, failure]);
    _w.handlers.release();
    return;
  }

  // Ready: hand back the command port and the opaque interrupt state. The main
  // isolate may atomically request cancellation through that state, but never
  // enters DB-Library on this worker's DBPROCESS.
  send.send(<Object?>[
    -1,
    <Object?>[
      commands.sendPort,
      dbproc.address,
      interruptState.address,
      lib.dbname(dbproc).toDartString(),
      lib.dbtds(dbproc),
    ],
    null,
  ]);

  commands.listen((Object? message) {
    final request = message as List<Object?>;
    final id = request[0] as int;
    final op = request[1] as String;
    final args = request[2] as List<Object?>;
    try {
      final result = _dispatch(op, args);
      send.send(<Object?>[id, result, null]);
      if (op == Op.close) commands.close();
    } on WorkerFailure catch (failure) {
      send.send(<Object?>[id, null, failure]);
    } on Object catch (error) {
      send.send(<Object?>[
        id,
        null,
        WorkerFailure(-199, MssqlErrorType.internal.index, '$error', false),
      ]);
    }
  });
}

/// One worker message, bracketed by the bookkeeping the C recorder needs.
///
/// The recorder's state is thread-local, and a Dart isolate does not stay on
/// one OS thread: it may resume the next message on another thread entirely.
/// So a message must never read state an earlier message recorded - that state
/// belongs to a thread this message may not be running on, and the thread it
/// is running on may hold another connection's leftovers. Each message
/// therefore starts the recorder empty and copies whatever it recorded into
/// Dart before returning; [_Worker.queryMessages] is what survives.
Object? _dispatch(String op, List<Object?> args) {
  if (op == Op.close) return _dispatchOp(op, args);
  _w.handlers.reset();
  errorState.reset();
  try {
    return _dispatchOp(op, args);
  } finally {
    _collectRecordedState();
  }
}

/// Copies the recorder's state for this message into the worker's own.
void _collectRecordedState() {
  syncErrorState(_w.handlers);
  _w.queryMessages.addAll(errorState.messages);
  if (errorState.hasError && _w.failureType == null) {
    _w.failureType = errorState.type;
    _w.failureCode = errorState.code;
    _w.failureMessage = errorState.message;
    _w.failureRetryable = errorState.retryable;
  }
}

void _clearRecordedState() {
  _w.queryMessages.clear();
  _w.failureType = null;
  _w.failureCode = 0;
  _w.failureMessage = '';
  _w.failureRetryable = false;
}

Object? _dispatchOp(String op, List<Object?> args) {
  switch (op) {
    case Op.ping:
      _runSql('SELECT 1', const Duration(seconds: 15));
      return null;

    case Op.close:
      if (_w.convBuffer != null) calloc.free(_w.convBuffer!);
      _w.handlers.interruptDetach(_w.dbproc);
      _w.lib.dbclose(_w.dbproc);
      _w.handlers.release();
      return null;

    case Op.runSql:
      _runSql(args[0] as String, args[1] as Duration);
      return null;

    case Op.useDatabase:
      final database = (args[0] as String).toNativeUtf8();
      final used = _w.lib.dbuse(_w.dbproc, database);
      calloc.free(database);
      if (used != Syb.succeed) {
        _fail(
          -104,
          MssqlErrorType.configuration,
          'Could not switch to the requested database.',
        );
      }
      return _w.lib.dbname(_w.dbproc).toDartString();

    case Op.execute:
      _openQuery(
        command: args[0] as String,
        procedure: args[1] as bool,
        parameters: (args[2] as List).cast<MssqlParameterBinding>(),
        timeout: args[3] as Duration,
        maximumRows: args[4] as int,
        maximumBytes: args[5] as int,
      );
      return null;

    case Op.nextResult:
      return _nextResult();

    case Op.fetchBatch:
      return _fetchBatch(args[0] as int);

    case Op.finish:
      return _finish();

    case Op.closeQuery:
      _closeQuery();
      return null;

    case Op.cancelQuery:
      _discardQueryResults();
      return null;

    case Op.bulkOpen:
      _bulkOpen(
        table: args[0] as String,
        columns: (args[1] as List).cast<MssqlBulkColumn>(),
        options: args[2] as MssqlBulkOptions,
        codePage: args[3] as int,
      );
      return null;

    case Op.bulkAddRows:
      for (final row in args[0] as List) {
        _bulkAddRow((row as List).cast<MssqlValue>());
      }
      return null;

    case Op.bulkComplete:
      return _bulkComplete();

    case Op.bulkCancel:
      _disarmDeadline();
      // No dbcancel/bcp_done sequence keeps both invariants: bcp_done() leaves
      // the connection usable but commits the rows already sent, which an
      // atomic load must never do. The copy is abandoned here and the caller
      // discards the connection if it is out of step; see
      // MssqlConnection._runBulkUnlocked.
      _w.lib.dbcancel(_w.dbproc);
      _discardQueryResults();
      _bulkRelease();
      return null;

    case Op.bulkClose:
      _bulkRelease();
      return null;

    default:
      throw WorkerFailure(
        -198,
        MssqlErrorType.internal.index,
        'Unknown worker operation "$op".',
        false,
      );
  }
}

void _armDeadline(Duration timeout) {
  _w.handlers.reset();
  errorState.reset();
  _clearRecordedState();
  _w.handlers.interruptArm(_w.interruptState, timeout.inMilliseconds);
}

int _interruptReason() => _w.handlers.interruptReason(_w.interruptState);

bool _deadlineExpired() => _interruptReason() == _interruptTimedOut;

bool _cancelRequested() => _interruptReason() == _interruptCancelled;

void _disarmDeadline() => _w.handlers.interruptDisarm(_w.interruptState);

Never _operationFail(int code, MssqlErrorType type, String fallback) {
  if (_deadlineExpired()) {
    _fail(-212, MssqlErrorType.queryTimeout, 'The SQL command timed out.');
  }
  if (_cancelRequested()) {
    _fail(-211, MssqlErrorType.cancelled, 'The query was cancelled.');
  }
  _fail(code, type, fallback);
}

void _runSql(String sql, Duration timeout) {
  _armDeadline(timeout);
  try {
    final lib = _w.lib;
    final text = sql.toNativeUtf8();
    final queued = lib.dbcmd(_w.dbproc, text);
    calloc.free(text);
    if (queued != Syb.succeed) {
      _operationFail(
        -200,
        MssqlErrorType.internal,
        'Could not queue the SQL command.',
      );
    }
    if (lib.dbsqlexec(_w.dbproc) != Syb.succeed) {
      _operationFail(
        -201,
        MssqlErrorType.querySyntax,
        'SQL command execution failed.',
      );
    }
    // Drain: the caller of runSql wants the side effect, not the rows.
    while (true) {
      final resultStatus = lib.dbresults(_w.dbproc);
      if (resultStatus == Syb.noMoreResults) break;
      if (resultStatus != Syb.succeed) {
        _operationFail(
          -213,
          MssqlErrorType.internal,
          'Could not drain the SQL command results.',
        );
      }
      while (true) {
        final rowStatus = lib.dbnextrow(_w.dbproc);
        if (rowStatus == Syb.noMoreRows) break;
        if (rowStatus == Syb.fail) {
          _operationFail(
            -222,
            MssqlErrorType.connectionLost,
            'Could not drain a SQL row.',
          );
        }
      }
    }
  } finally {
    _disarmDeadline();
  }
}

void _openQuery({
  required String command,
  required bool procedure,
  required List<MssqlParameterBinding> parameters,
  required Duration timeout,
  required int maximumRows,
  required int maximumBytes,
}) {
  _w.maximumRows = maximumRows;
  _w.maximumBytes = maximumBytes;
  _w.rowsRead = 0;
  _w.bytesRead = 0;
  _armDeadline(timeout);
  _w.columns = null;
  _w.resultOpen = false;
  _w.allResultsDone = false;
  _w.affectedRows = 0;
  _w.rowCounts.clear();

  final lib = _w.lib;
  final arena = Arena(calloc);
  try {
    if (procedure) {
      final name = command.toNativeUtf8(allocator: arena);
      if (lib.dbrpcinit(_w.dbproc, name, 0) != Syb.succeed) {
        _fail(
          -202,
          MssqlErrorType.procedure,
          'Could not begin the remote procedure call.',
        );
      }
      for (final parameter in parameters) {
        _bindParameter(parameter, arena);
      }
      if (lib.dbrpcsend(_w.dbproc) != Syb.succeed ||
          lib.dbsqlok(_w.dbproc) != Syb.succeed) {
        _operationFail(
          -203,
          MssqlErrorType.procedure,
          'The remote procedure call failed.',
        );
      }
    } else if (parameters.isNotEmpty) {
      final name = 'sp_executesql'.toNativeUtf8(allocator: arena);
      if (lib.dbrpcinit(_w.dbproc, name, 0) != Syb.succeed) {
        _fail(-202, MssqlErrorType.procedure, 'Could not begin sp_executesql.');
      }
      // A zero-length value cannot survive dbrpcparam, which reads datalen 0
      // as NULL. The parameter is still bound (sp_executesql requires every
      // declared parameter to be supplied) and the prelude puts the empty
      // value back before the caller's statement runs.
      _bindText('@stmt', emptyValuePrelude(parameters) + command, arena);
      _bindText('@params', sqlDeclarations(parameters), arena);
      for (final parameter in parameters) {
        _bindParameter(parameter, arena);
      }
      if (lib.dbrpcsend(_w.dbproc) != Syb.succeed ||
          lib.dbsqlok(_w.dbproc) != Syb.succeed) {
        _operationFail(
          -203,
          MssqlErrorType.querySyntax,
          'SQL command execution failed.',
        );
      }
    } else {
      final text = command.toNativeUtf8(allocator: arena);
      if (lib.dbcmd(_w.dbproc, text) != Syb.succeed) {
        _fail(
          -200,
          MssqlErrorType.internal,
          'Could not queue the SQL command.',
        );
      }
      if (lib.dbsqlexec(_w.dbproc) != Syb.succeed) {
        _operationFail(
          -201,
          MssqlErrorType.querySyntax,
          'SQL command execution failed.',
        );
      }
    }
  } finally {
    arena.releaseAll();
  }
}

/// `@stmt` and `@params` must be Unicode. FreeTDS only promotes SYBVARCHAR to
/// the wide wire type up to 4000 bytes, so a longer statement has to go as
/// SYBNTEXT or the server answers "@statement of type ntext/nchar/nvarchar".
void _bindText(String name, String value, Arena arena) {
  final bytes = Uint8List.fromList(utf8.encode(value));
  final type = bytes.length > 4000 ? Syb.ntext : Syb.varchar;
  Pointer<Uint8> data = nullptr;
  if (bytes.isNotEmpty) {
    data = arena<Uint8>(bytes.length);
    data.asTypedList(bytes.length).setAll(0, bytes);
  }
  final namePtr = name.toNativeUtf8(allocator: arena);
  if (_w.lib.dbrpcparam(_w.dbproc, namePtr, 0, type, -1, bytes.length, data) !=
      Syb.succeed) {
    _fail(
      -420,
      MssqlErrorType.procedure,
      'Could not bind RPC parameter $name.',
    );
  }
}

void _bindParameter(MssqlParameterBinding parameter, Arena arena) {
  final encoded = encodeParameter(parameter);
  // A zero-length value is bound as NULL because dbrpcparam offers no way to
  // say otherwise; emptyValuePrelude restores it inside the statement.
  Pointer<Uint8> data = nullptr;
  final bytes = encoded.bytes;
  if (bytes != null && bytes.isNotEmpty) {
    data = arena<Uint8>(bytes.length);
    data.asTypedList(bytes.length).setAll(0, bytes);
  }
  final namePtr = encoded.name.toNativeUtf8(allocator: arena);
  if (_w.lib.dbrpcparam(
        _w.dbproc,
        namePtr,
        encoded.status,
        encoded.nativeType,
        encoded.maxLength,
        encoded.dataLength,
        data,
      ) !=
      Syb.succeed) {
    _fail(
      -420,
      MssqlErrorType.procedure,
      'Could not bind RPC parameter ${encoded.name}.',
    );
  }
}

/// Advances to the next result set, returning its columns, or `null` when the
/// statement has no more.
List<MssqlColumn>? _nextResult() {
  if (_cancelRequested()) {
    throw WorkerFailure(
      -211,
      MssqlErrorType.cancelled.index,
      'The query was cancelled.',
      false,
    );
  }
  if (_w.allResultsDone) return null;

  final lib = _w.lib;
  while (true) {
    final status = lib.dbresults(_w.dbproc);
    if (status == Syb.noMoreResults) {
      _w.allResultsDone = true;
      _w.columns = null;
      return null;
    }
    if (status != Syb.succeed) {
      _operationFail(
        -213,
        MssqlErrorType.internal,
        'Could not advance to the next '
        'result set.',
      );
    }
    // A statement like UPDATE produces a result with no columns; its row count
    // belongs in affectedRows and the caller should see the next real set.
    final count = lib.dbnumcols(_w.dbproc);
    if (count <= 0) {
      if (lib.dbiscount(_w.dbproc) != 0) {
        _w.recordRowCount(lib.dbcount(_w.dbproc));
      }
      continue;
    }
    // Maps require unique, non-empty keys. Keep that stable public name while
    // retaining SQL Server's label separately for typed-row name lookup.
    final columns = <MssqlColumn>[];
    final used = <String>{};
    for (var i = 1; i <= count; i++) {
      final reported = lib.dbcolname(_w.dbproc, i).toDartString();
      var name = reported.isEmpty ? 'column$i' : reported;
      if (!used.add(name)) {
        var suffix = 2;
        while (!used.add('${name}_$suffix')) {
          suffix++;
        }
        name = '${name}_$suffix';
      }
      final nativeType = lib.dbcoltype(_w.dbproc, i);
      columns.add(
        MssqlColumn(
          index: i - 1,
          name: name,
          type: logicalTypeFor(nativeType),
          // DB-Library does not report nullability per column; the bridge
          // reported every column as nullable and callers rely on that.
          nullable: true,
          maxLength: lib.dbcollen(_w.dbproc, i),
          precision: 0,
          scale: 0,
          nativeType: nativeType,
          reportedName: reported,
        ),
      );
    }
    _w.columns = columns;
    _w.resultOpen = true;
    return columns;
  }
}

/// Reads up to [maximumRows] rows, or `null` once the current result set is
/// exhausted.
/// Reads a packed date/time value into an [MssqlDateTimeValue].
///
/// `dbanydatecrack` is used rather than text, because each SQL Server date type
/// has its own packed layout and hand-decoding them produces plausible wrong
/// dates rather than errors.
MssqlDateTimeValue? _crackDate(int type, Pointer<Uint8> data) {
  final record = calloc<Int32>(DbLib.dateCrackFields);
  try {
    if (_w.lib.dbanydatecrack(_w.dbproc, record, type, data) != Syb.succeed) {
      return null;
    }
    final f = record.asTypedList(DbLib.dateCrackFields);
    return MssqlDateTimeValue(
      year: f[0],
      month: f[2],
      day: f[3],
      hour: f[7],
      minute: f[8],
      second: f[9],
      nanosecond: f[10],
      timezoneOffsetMinutes: f[11],
    );
  } finally {
    calloc.free(record);
  }
}

/// Applies [MssqlConnectionConfig.decimalMode] to a converted value.
///
/// This is the slow path: a value the byte decoder could not handle exactly —
/// a magnitude past 64 bits, an unusual precision — that came back through
/// dbconvert as invariant text.
///
/// Only the exact numeric families are eligible: uniqueidentifier and any
/// unrecognised type reach dbconvert too, and a number is not what they are.
Object _fromInvariantText(String text, int nativeType) {
  if (!isExactNumeric(nativeType)) return text;
  switch (_w.decimalMode) {
    case MssqlDecimalMode.text:
      return text;
    case MssqlDecimalMode.exact:
      final exact = MssqlDecimal.tryParse(text);
      if (exact == null) {
        _fail(
          -405,
          MssqlErrorType.conversion,
          'Could not read "$text" as an exact number for a decimal or money '
          'column.',
        );
      }
      return exact;
    case MssqlDecimalMode.doublePrecision:
      final value = double.tryParse(text);
      if (value == null) {
        // Should not happen - dbconvert emits invariant decimal text - so it
        // is reported rather than silently handed back as a string, which
        // would make the column's Dart type depend on its contents.
        _fail(
          -405,
          MssqlErrorType.conversion,
          'Could not read "$text" as a number for a decimal or money column.',
        );
      }
      return value;
  }
}

int _rowBytes(List<Object?> row) {
  var total = 0;
  for (final value in row) {
    total += switch (value) {
      null => 0,
      final String s => s.length * 2,
      final Uint8List b => b.length,
      final bool _ => 1,
      _ => 8,
    };
  }
  return total;
}

List<List<Object?>>? _fetchBatch(int maximumRows) {
  final columns = _w.columns;
  if (columns == null || !_w.resultOpen) return null;
  if (_cancelRequested()) {
    throw WorkerFailure(
      -211,
      MssqlErrorType.cancelled.index,
      'The query was cancelled.',
      false,
    );
  }

  final lib = _w.lib;
  final rows = <List<Object?>>[];
  while (rows.length < maximumRows) {
    // A row ceiling is a silent truncation, not an error: querySingle asks for
    // two rows to detect duplicates and expects to be handed what there is.
    // dbcanquery discards the rest so the connection is usable again.
    if (_w.maximumRows > 0 && _w.rowsRead >= _w.maximumRows) {
      lib.dbcanquery(_w.dbproc);
      _w.resultOpen = false;
      _w.allResultsDone = true;
      break;
    }
    final status = lib.dbnextrow(_w.dbproc);
    if (status == Syb.fail) {
      // Without this the FAIL status fell through to the `continue` below and
      // span forever.
      _w.resultOpen = false;
      if (_deadlineExpired()) {
        _fail(-212, MssqlErrorType.queryTimeout, 'The SQL command timed out.');
      }
      if (_cancelRequested()) {
        _fail(-211, MssqlErrorType.cancelled, 'The query was cancelled.');
      }
      _fail(-222, MssqlErrorType.connectionLost, 'Could not fetch a SQL row.');
    }
    if (status == Syb.noMoreRows) {
      _w.resultOpen = false;
      if (lib.dbiscount(_w.dbproc) != 0) {
        _w.recordRowCount(lib.dbcount(_w.dbproc));
      }
      break;
    }
    // Anything other than a regular row - a compute row, a buffer-full
    // signal - is not ours to return.
    if (status != Syb.regRow) continue;

    final row = <Object?>[];
    for (var i = 1; i <= columns.length; i++) {
      final column = columns[i - 1];
      final length = lib.dbdatlen(_w.dbproc, i);
      final data = lib.dbdata(_w.dbproc, i);
      if (data == nullptr || length <= 0) {
        row.add(null);
        continue;
      }
      final raw = data.asTypedList(length);
      // The exact numeric families first: decoding them here skips a
      // dbconvert, a UTF-8 decode and a parse per cell, and the fast path
      // hands back fallBackToConvert whenever it cannot be exact.
      final numeric = switch (column.nativeType) {
        Syb.money ||
        Syb.money4 ||
        Syb.moneyn => decodeMoney(raw, mode: _w.decimalMode),
        Syb.decimal || Syb.numeric => decodeNumeric(raw, mode: _w.decimalMode),
        _ => null,
      };
      if (numeric != null && !identical(numeric, fallBackToConvert)) {
        row.add(numeric);
        continue;
      }

      final decoded = decodeFixed(type: column.nativeType, bytes: raw);
      if (decoded == needsDateCrack) {
        row.add(_crackDate(column.nativeType, data));
      } else if (decoded == needsConversion) {
        final buffer = _conv(length * 4 + 64);
        final written = lib.dbconvert(
          _w.dbproc,
          column.nativeType,
          data,
          length,
          Syb.charType,
          buffer,
          _w.convBufferSize,
        );
        row.add(
          written > 0
              ? _fromInvariantText(
                  utf8
                      .decode(buffer.asTypedList(written), allowMalformed: true)
                      .trimRight(),
                  column.nativeType,
                )
              : null,
        );
      } else {
        row.add(decoded);
      }
    }
    rows.add(row);
    _w.rowsRead++;
    if (_w.maximumBytes > 0) {
      // Measured on the decoded Dart values, so it is an estimate rather than
      // the wire size the bridge could count. It is a guard against runaway
      // result sets, not an accounting figure.
      _w.bytesRead += _rowBytes(row);
      if (_w.bytesRead > _w.maximumBytes) {
        lib.dbcanquery(_w.dbproc);
        _w.resultOpen = false;
        _fail(
          -224,
          MssqlErrorType.protocol,
          'The query exceeded its maximum byte limit.',
        );
      }
    }
  }
  if (rows.isEmpty && !_w.resultOpen) return null;
  return rows;
}

/// Everything the statement leaves behind once its rows are read.
List<Object?> _finish() {
  final lib = _w.lib;
  // Drain anything the caller did not read, so the connection is reusable.
  while (true) {
    final resultStatus = lib.dbresults(_w.dbproc);
    if (resultStatus == Syb.noMoreResults) break;
    if (resultStatus != Syb.succeed) {
      _operationFail(
        -213,
        MssqlErrorType.internal,
        'Could not finish the SQL command results.',
      );
    }
    while (true) {
      final rowStatus = lib.dbnextrow(_w.dbproc);
      if (rowStatus == Syb.noMoreRows) break;
      if (rowStatus == Syb.fail) {
        _operationFail(
          -222,
          MssqlErrorType.connectionLost,
          'Could not discard a SQL row.',
        );
      }
    }
    if (lib.dbiscount(_w.dbproc) != 0) {
      _w.recordRowCount(lib.dbcount(_w.dbproc));
    }
  }

  int? returnStatus;
  if (lib.dbhasretstat(_w.dbproc) != 0) {
    returnStatus = lib.dbretstatus(_w.dbproc);
  }

  final outputs = <String, Object?>{};
  final count = lib.dbnumrets(_w.dbproc);
  for (var i = 1; i <= count; i++) {
    final namePtr = lib.dbretname(_w.dbproc, i);
    var name = namePtr == nullptr ? 'out$i' : namePtr.toDartString();
    // The server reports these as "@order_count"; callers index them by the
    // name they passed, without the sigil.
    if (name.startsWith('@')) name = name.substring(1);
    final type = lib.dbrettype(_w.dbproc, i);
    final length = lib.dbretlen(_w.dbproc, i);
    final data = lib.dbretdata(_w.dbproc, i);
    if (data == nullptr || length <= 0) {
      outputs[name] = null;
      continue;
    }
    final decoded = decodeFixed(type: type, bytes: data.asTypedList(length));
    if (decoded == needsDateCrack) {
      outputs[name] = _crackDate(type, data);
    } else if (decoded == needsConversion) {
      final buffer = _conv(length * 4 + 64);
      final written = lib.dbconvert(
        _w.dbproc,
        type,
        data,
        length,
        Syb.charType,
        buffer,
        _w.convBufferSize,
      );
      outputs[name] = written > 0
          ? _fromInvariantText(
              utf8
                  .decode(buffer.asTypedList(written), allowMalformed: true)
                  .trimRight(),
              type,
            )
          : null;
    } else {
      outputs[name] = decoded;
    }
  }

  // Collected rather than read straight from the recorder: severity-under-11
  // messages are PRINT output and row counts, which callers read from
  // MssqlExecutionResult.messages, and they may have been recorded by an
  // earlier message on another thread.
  _collectRecordedState();
  // DB-Library does not always answer FAIL for a statement the server
  // rejected: `SELECT 1/0` and an arithmetic overflow both come back as an
  // empty result set with SUCCEED everywhere, and the failure survives only as
  // a recorded message. Reporting that as success is how a rejected query
  // turns into silently missing data, so it is raised here instead.
  final failureType = _w.failureType;
  if (failureType != null) {
    _disarmDeadline();
    if (_deadlineExpired()) {
      _fail(-212, MssqlErrorType.queryTimeout, 'The SQL command timed out.');
    }
    throw WorkerFailure(
      _w.failureCode,
      failureType.index,
      _w.failureMessage,
      _w.failureRetryable,
      List<MssqlServerMessage>.of(_w.queryMessages),
    );
  }
  _disarmDeadline();
  return <Object?>[
    _w.affectedRows,
    returnStatus,
    outputs,
    List<MssqlServerMessage>.of(_w.queryMessages),
    List<int>.of(_w.rowCounts),
  ];
}

/// `DB_IN` — sybdb.h:588. Bulk copy into the server.
const int _dbIn = 1;

bool _bulkVariableLength(MssqlType t) => switch (t) {
  MssqlType.bit ||
  MssqlType.tinyInt ||
  MssqlType.smallInt ||
  MssqlType.int32 ||
  MssqlType.int64 ||
  MssqlType.real ||
  MssqlType.float64 => false,
  _ => true,
};

bool _bulkUnicode(MssqlType t) =>
    t == MssqlType.nchar || t == MssqlType.nvarchar || t == MssqlType.ntext;

/// The host type to tell `bcp_bind`.
///
/// Unicode columns are handed pre-encoded UTF-16LE bytes, and `SYBVARCHAR`
/// makes FreeTDS copy them verbatim into the UCS-2 column instead of
/// re-encoding them. Ported from `bcp_host_type` in mssql_native.cpp.
int _bulkHostType(MssqlType t) => switch (t) {
  MssqlType.bit => Syb.bit,
  MssqlType.tinyInt => Syb.int1,
  MssqlType.smallInt => Syb.int2,
  MssqlType.int32 => Syb.int4,
  MssqlType.int64 => Syb.int8,
  MssqlType.real => Syb.real,
  MssqlType.float64 => Syb.flt8,
  MssqlType.binary || MssqlType.varbinary || MssqlType.image => Syb.varbinary,
  _ => Syb.varchar,
};

/// Text gets four bytes per declared character plus slack, because a UTF-16LE
/// encoding of it is wider than the declaration.
int _bulkBufferSize(MssqlBulkColumn c) => switch (c.type) {
  MssqlType.bit || MssqlType.tinyInt => 1,
  MssqlType.smallInt => 2,
  MssqlType.int32 || MssqlType.real => 4,
  MssqlType.int64 || MssqlType.float64 => 8,
  MssqlType.binary ||
  MssqlType.varbinary ||
  MssqlType.image => c.size > 1 ? c.size : 1,
  _ => () {
    final wanted = c.size > 0 ? c.size * 4 + 64 : 8192;
    return wanted < 256 ? 256 : wanted;
  }(),
};

void _bulkRelease() {
  for (final buffer in _w.bulkBuffers) {
    calloc.free(buffer);
  }
  _w.bulkBuffers = const <Pointer<Uint8>>[];
  _w.bulkBufferSizes = const <int>[];
  _w.bulkColumns = const <MssqlBulkColumn>[];
  _w.bulkOptions = null;
  _w.bulkCodePage = 0;
  _disarmDeadline();
}

void _bulkOpen({
  required String table,
  required List<MssqlBulkColumn> columns,
  required MssqlBulkOptions options,
  required int codePage,
}) {
  final lib = _w.lib;
  _bulkRelease();
  _armDeadline(options.timeout);
  _w.bulkRows = 0;
  _w.bulkInserted = 0;
  _w.bulkBatches = 0;
  _w.bulkFailedRow = null;
  _w.bulkStarted = DateTime.now();
  _w.bulkColumns = columns;
  _w.bulkOptions = options;
  _w.bulkCodePage = codePage;

  final tablePtr = table.toNativeUtf8();
  final started = lib.bcpInit(_w.dbproc, tablePtr, nullptr, nullptr, _dbIn);
  calloc.free(tablePtr);
  if (started != Syb.succeed) {
    _fail(-403, MssqlErrorType.bulkCopy, 'Could not initialize BCP.');
  }

  final hints = <String>[
    if (options.keepNulls) 'KEEP_NULLS',
    if (options.checkConstraints) 'CHECK_CONSTRAINTS',
    if (options.fireTriggers) 'FIRE_TRIGGERS',
    if (options.tableLock) 'TABLOCK',
  ];
  if (hints.isNotEmpty) {
    final bytes = utf8.encode(hints.join(', '));
    final buffer = calloc<Uint8>(bytes.length);
    buffer.asTypedList(bytes.length).setAll(0, bytes);
    final applied = lib.bcpOptions(
      _w.dbproc,
      Syb.bcpHints,
      buffer,
      bytes.length,
    );
    calloc.free(buffer);
    if (applied != Syb.succeed) {
      lib.dbcancel(_w.dbproc);
      _bulkRelease();
      _fail(-419, MssqlErrorType.bulkCopy, 'Could not apply BCP hints.');
    }
  }
  if (options.keepIdentity &&
      lib.bcpControl(_w.dbproc, Syb.bcpKeepIdentity, 1) != Syb.succeed) {
    lib.dbcancel(_w.dbproc);
    _bulkRelease();
    _fail(
      -418,
      MssqlErrorType.bulkCopy,
      'Could not enable identity preservation for BCP.',
    );
  }

  final buffers = <Pointer<Uint8>>[];
  final sizes = <int>[];
  for (final column in columns) {
    final size = _bulkBufferSize(column);
    final buffer = calloc<Uint8>(size);
    buffers.add(buffer);
    sizes.add(size);
    // bcp_bind wants varlen -1 for fixed host types, which carry their own
    // size; only variable-length columns pass the buffer size.
    final varlen = _bulkVariableLength(column.type) ? size : -1;
    if (lib.bcpBind(
          _w.dbproc,
          buffer,
          0,
          varlen,
          nullptr,
          0,
          _bulkHostType(column.type),
          column.ordinal,
        ) !=
        Syb.succeed) {
      _w.bulkBuffers = buffers;
      _w.bulkBufferSizes = sizes;
      lib.dbcancel(_w.dbproc);
      _bulkRelease();
      _fail(-404, MssqlErrorType.bulkCopy, 'Could not bind a BCP column.');
    }
  }
  _w.bulkBuffers = buffers;
  _w.bulkBufferSizes = sizes;
}

/// Writes one value into its bound buffer and returns the byte length.
int _bulkWrite(int index, MssqlValue value) {
  final column = _w.bulkColumns[index];
  if (value.value == null) return 0;
  if (value.type != column.type) {
    throw WorkerFailure(
      -700,
      MssqlErrorType.conversion.index,
      'Bulk value type does not match its column definition.',
      false,
    );
  }
  void put(Uint8List bytes) {
    if (bytes.length > _w.bulkBufferSizes[index]) {
      var capacity = _w.bulkBufferSizes[index];
      while (capacity < bytes.length) {
        capacity = capacity < 1024 * 1024
            ? capacity * 2
            : capacity + 1024 * 1024;
      }
      final replacement = calloc<Uint8>(capacity);
      calloc.free(_w.bulkBuffers[index]);
      _w.bulkBuffers[index] = replacement;
      _w.bulkBufferSizes[index] = capacity;
    }
    _w.bulkBuffers[index].asTypedList(bytes.length).setAll(0, bytes);
  }

  Pointer<Uint8> buffer() => _w.bulkBuffers[index];

  switch (column.type) {
    case MssqlType.bit:
      buffer().value = value.value == true ? 1 : 0;
      return 1;
    case MssqlType.tinyInt:
      buffer().value = (value.value as int) & 0xFF;
      return 1;
    case MssqlType.smallInt:
      put(
        Uint8List.sublistView(
          ByteData(2)..setInt16(0, value.value as int, Endian.little),
        ),
      );
      return 2;
    case MssqlType.int32:
      put(
        Uint8List.sublistView(
          ByteData(4)..setInt32(0, value.value as int, Endian.little),
        ),
      );
      return 4;
    case MssqlType.int64:
      put(
        Uint8List.sublistView(
          ByteData(8)..setInt64(0, value.value as int, Endian.little),
        ),
      );
      return 8;
    case MssqlType.real:
      put(
        Uint8List.sublistView(
          ByteData(4)
            ..setFloat32(0, (value.value as num).toDouble(), Endian.little),
        ),
      );
      return 4;
    case MssqlType.float64:
      put(
        Uint8List.sublistView(
          ByteData(8)
            ..setFloat64(0, (value.value as num).toDouble(), Endian.little),
        ),
      );
      return 8;
    case MssqlType.binary:
    case MssqlType.varbinary:
    case MssqlType.image:
      final bytes = value.value as Uint8List;
      put(bytes);
      return bytes.length;
    default:
      final text = bulkParameterText(
        MssqlParameterBinding.fromValue(column.name, value),
      );
      if (_bulkUnicode(column.type)) {
        // Hand BCP UTF-16LE and let SYBVARCHAR copy it verbatim into the UCS-2
        // column. Re-encoding is what corrupts non-Latin1 text here.
        final units = text.codeUnits;
        final bytes = Uint8List(units.length * 2);
        final view = ByteData.sublistView(bytes);
        for (var i = 0; i < units.length; i++) {
          view.setUint16(i * 2, units[i], Endian.little);
        }
        put(bytes);
        return bytes.length;
      }
      // Single-byte column. FreeTDS will not convert what bcp_bind is given,
      // so the bytes have to be in the column's own code page before they
      // leave here - UTF-8 is what wrote 'Ã–ZEL' into a CP1254 column.
      final Uint8List bytes;
      try {
        bytes = encodeForCodePage(text, _w.bulkCodePage, column.name);
      } on CodePageError catch (error) {
        throw WorkerFailure(
          -417,
          MssqlErrorType.conversion.index,
          error.message,
          false,
        );
      }
      put(bytes);
      return bytes.length;
  }
}

void _bulkAddRow(List<MssqlValue> values) {
  final lib = _w.lib;
  final columns = _w.bulkColumns;
  if (values.length != columns.length) {
    throw WorkerFailure(
      -702,
      MssqlErrorType.conversion.index,
      'The row has ${values.length} values for ${columns.length} columns.',
      false,
    );
  }

  for (var i = 0; i < columns.length; i++) {
    final length = _bulkWrite(i, values[i]);
    final isNull = values[i].value == null;
    final pointer = isNull ? nullptr : _w.bulkBuffers[i];
    // Fixed host types take collen -1; only variable-length columns report
    // the per-row byte length.
    final collen = isNull
        ? 0
        : (_bulkVariableLength(columns[i].type) ? length : -1);
    if (lib.bcpColptr(_w.dbproc, pointer, columns[i].ordinal) != Syb.succeed ||
        lib.bcpCollen(_w.dbproc, collen, columns[i].ordinal) != Syb.succeed) {
      _w.bulkFailedRow = _w.bulkRows;
      _operationFail(
        -413,
        MssqlErrorType.bulkCopy,
        'Could not prepare a BCP row.',
      );
    }
  }

  if (lib.bcpSendrow(_w.dbproc) != Syb.succeed) {
    _w.bulkFailedRow = _w.bulkRows;
    _operationFail(-414, MssqlErrorType.bulkCopy, 'Could not send a BCP row.');
  }
  _w.bulkRows++;

  final options = _w.bulkOptions!;
  if (options.mode == MssqlBulkMode.batched &&
      options.batchSize > 0 &&
      _w.bulkRows % options.batchSize == 0) {
    // bcp_batch returns the rows it saved in this batch, not the running
    // total. The inserted count is the sum of bcp_batch and bcp_done.
    final sent = lib.bcpBatch(_w.dbproc);
    if (sent < 0) {
      _w.bulkFailedRow = _w.bulkRows;
      _operationFail(
        -415,
        MssqlErrorType.bulkCopy,
        'Could not commit a BCP batch.',
      );
    }
    _w.bulkInserted += sent;
    _w.bulkBatches++;
  }
}

List<Object?> _bulkComplete() {
  final finalRows = _w.lib.bcpDone(_w.dbproc);
  if (finalRows < 0) {
    _operationFail(
      -416,
      MssqlErrorType.bulkCopy,
      'The bulk copy failed to commit.',
    );
  }
  _w.bulkInserted += finalRows;
  // An atomic load commits everything here and has no batch of its own yet;
  // a batched load whose last batch already flushed must not gain a spurious
  // one.
  if (finalRows > 0 || _w.bulkBatches == 0) _w.bulkBatches++;

  final elapsed = DateTime.now().difference(_w.bulkStarted ?? DateTime.now());
  final result = <Object?>[
    _w.bulkRows,
    _w.bulkInserted,
    _w.bulkBatches,
    _w.bulkFailedRow,
    elapsed,
  ];
  _bulkRelease();
  return result;
}

void _closeQuery() {
  _w.columns = null;
  _w.resultOpen = false;
  _w.allResultsDone = false;
  _disarmDeadline();
}

/// A statement can only fail so many times before the drain gives up and
/// resorts to ATTENTION. High enough that no real batch reaches it, low enough
/// that a wedged DBPROCESS cannot spin here.
const int _discardFailureBudget = 64;

/// Leaves the DBPROCESS ready for its next command after a stream is abandoned.
///
/// `dbcancel` alone is insufficient when FreeTDS has already buffered another
/// result set: it sends ATTENTION to the server, but the buffered row format
/// remains current and the next command fails with SYBEABNC (20019). First
/// discard the current result, then consume every remaining result token.
///
/// A failing `dbresults` is not the end of the stream either. A batch that
/// raises twice answers FAIL for the first error and still has the second
/// error, and the tokens behind it, waiting to be read; stopping there is what
/// left the next command facing SYBEABNC. Keep draining until the server says
/// there is nothing left, and only fall back to ATTENTION if that never comes.
void _discardQueryResults() {
  final lib = _w.lib;
  _disarmDeadline();

  if (lib.dbcanquery(_w.dbproc) != Syb.succeed) {
    lib.dbcancel(_w.dbproc);
    _closeQuery();
    return;
  }

  var failures = 0;
  drain:
  while (true) {
    final resultStatus = lib.dbresults(_w.dbproc);
    if (resultStatus == Syb.noMoreResults) break;
    if (resultStatus != Syb.succeed) {
      if (++failures >= _discardFailureBudget) {
        lib.dbcancel(_w.dbproc);
        break;
      }
      continue;
    }
    while (true) {
      final rowStatus = lib.dbnextrow(_w.dbproc);
      if (rowStatus == Syb.noMoreRows) break;
      if (rowStatus == Syb.fail) {
        if (++failures >= _discardFailureBudget) {
          lib.dbcancel(_w.dbproc);
          break drain;
        }
        break;
      }
    }
  }
  _closeQuery();
}

// Main side

/// The driver's handle on one connection's worker isolate.
class ConnectionWorker {
  ConnectionWorker._(
    this._channel,
    this.dbprocAddress,
    this.interruptStateAddress,
    this.databaseName,
    this.negotiatedTdsCode,
    this._handlersPath,
  );

  final WorkerChannel _channel;

  /// Diagnostic only: DB-Library calls belong exclusively to the worker.
  final int dbprocAddress;
  final int interruptStateAddress;
  String databaseName;
  final int negotiatedTdsCode;
  final String _handlersPath;
  bool _closed = false;
  Future<void>? _closing;

  bool get isClosed => _closed || _channel.isClosed;

  static Future<ConnectionWorker> open(
    MssqlConnectionConfig config,
    String sybdbPath,
    String handlersPath,
  ) async {
    final channel = await WorkerChannel.start(
      _entry,
      <Object?>[config, sybdbPath, handlersPath],
      decodeFailure: (error) => (error as WorkerFailure).toException(),
      // Login and initial session setup each have the configured native
      // timeout. Leave scheduling headroom for their startup handshake.
      startupTimeout: config.loginTimeout * 2 + const Duration(seconds: 10),
    );
    try {
      final data = channel.handshake;
      return ConnectionWorker._(
        channel,
        data[1] as int,
        data[2] as int,
        data[3] as String,
        data[4] as int,
        handlersPath,
      );
    } catch (_) {
      channel.dispose();
      rethrow;
    }
  }

  Future<Object?> _call(String op, [List<Object?> args = const <Object?>[]]) =>
      _channel.call(op, args);

  Future<void> ping() => _call(Op.ping).then((_) {});

  Future<void> runSql(String sql, Duration timeout) =>
      _call(Op.runSql, <Object?>[sql, timeout]).then((_) {});

  Future<String> useDatabase(String database) async {
    final selected = await _call(Op.useDatabase, <Object?>[database]) as String;
    return databaseName = selected;
  }

  Future<void> openQuery({
    required String command,
    required bool procedure,
    required List<MssqlParameterBinding> parameters,
    required Duration timeout,
    int maximumRows = 0,
    int maximumBytes = 0,
  }) => _call(Op.execute, <Object?>[
    command,
    procedure,
    parameters,
    timeout,
    maximumRows,
    maximumBytes,
  ]).then((_) {});

  Future<List<MssqlColumn>?> nextResult() async {
    final result = await _call(Op.nextResult);
    return result == null ? null : (result as List).cast<MssqlColumn>();
  }

  Future<List<List<Object?>>?> fetchBatch(int maximumRows) async {
    final result = await _call(Op.fetchBatch, <Object?>[maximumRows]);
    return result == null
        ? null
        : (result as List)
              .map((row) => (row as List).cast<Object?>())
              .toList(growable: false);
  }

  Future<
    ({
      int affectedRows,
      int? returnStatus,
      Map<String, Object?> outputParameters,
      List<MssqlServerMessage> messages,
      List<int> rowCounts,
    })
  >
  finish() async {
    final parts = (await _call(Op.finish)) as List<Object?>;
    return (
      affectedRows: parts[0] as int,
      returnStatus: parts[1] as int?,
      outputParameters: (parts[2] as Map).cast<String, Object?>(),
      messages: (parts[3] as List).cast<MssqlServerMessage>(),
      // Kept apart from the sum so that a caller who knows its batch's shape
      // can attribute a count; see MssqlExecutionResult.affectedRows.
      rowCounts: (parts[4] as List).cast<int>(),
    );
  }

  Future<void> closeQuery() => _call(Op.closeQuery).then((_) {});

  Future<void> cancelQuery() => _call(Op.cancelQuery).then((_) {});

  Future<void> bulkOpen({
    required String table,
    required List<MssqlBulkColumn> columns,
    required MssqlBulkOptions options,
    required int codePage,
  }) => _call(Op.bulkOpen, <Object?>[
    table,
    columns,
    options,
    codePage,
  ]).then((_) {});

  Future<void> bulkAddRows(List<List<MssqlValue>> rows) =>
      _call(Op.bulkAddRows, <Object?>[rows]).then((_) {});

  Future<MssqlBulkResult> bulkComplete() async {
    final parts = (await _call(Op.bulkComplete)) as List<Object?>;
    return MssqlBulkResult(
      totalRows: parts[0] as int,
      insertedRows: parts[1] as int,
      committedBatches: parts[2] as int,
      failedRowIndex: parts[3] as int?,
      elapsed: parts[4] as Duration,
    );
  }

  Future<void> bulkCancel() => _call(Op.bulkCancel).then((_) {});

  Future<void> bulkClose() => _call(Op.bulkClose).then((_) {});

  /// Interrupts the statement in flight.
  ///
  /// Not a message: the worker can be blocked inside `dbsqlexec` or
  /// `dbnextrow` and unable to read its port. This only sets an atomic flag
  /// that FreeTDS observes through a C callback on the worker's native call.
  void cancel() {
    if (isClosed) return;
    final handlers = Handlers(DynamicLibrary.open(_handlersPath));
    handlers.interruptRequest(Pointer<Void>.fromAddress(interruptStateAddress));
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    try {
      if (!_channel.isClosed) await _call(Op.close);
    } on Object {
      // A dead worker has already failed every pending request. There is no
      // native connection that can safely be operated from this isolate.
    } finally {
      _closed = true;
      _channel.dispose();
    }
  }
}
