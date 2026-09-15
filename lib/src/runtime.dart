import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import 'exception.dart';
import 'models/config.dart';
import 'models/types.dart';
import 'native/code_asset_paths.dart';
import 'native/dblib.dart';
import 'native/handlers.dart';
import 'native/library_paths.dart';

@immutable
class MssqlRuntimeDiagnostics {
  const MssqlRuntimeDiagnostics({
    required this.freeTdsVersion,
    required this.handlersAbiVersion,
    required this.tlsAvailable,
    required this.certificateTrust,
    required this.sybdbPath,
    required this.handlersPath,
    required this.platform,
  });

  final String freeTdsVersion;
  final int handlersAbiVersion;

  /// Whether the bundled FreeTDS has a TLS backend at all.
  final bool tlsAvailable;

  /// What this process trusts, in one line. Separate from [tlsAvailable]: a
  /// build can encrypt and still verify nothing.
  final String certificateTrust;

  final String sybdbPath;
  final String handlersPath;
  final String platform;
}

/// Locates FreeTDS and the handler library, and makes both loadable.
///
/// Each connection calls DB-Library through FFI from a worker isolate. The
/// native handler library owns DB-Library's process-wide callbacks, which
/// cannot safely call a Dart trampoline from arbitrary threads.
class MssqlRuntime {
  MssqlRuntime._();
  static final MssqlRuntime instance = MssqlRuntime._();

  String? _sybdbLocator;
  String? _handlersLocator;
  bool _initialized = false;
  bool _hasTls = false;
  bool _shuttingDown = false;
  Future<void>? _shutdownFuture;
  Future<void>? _initializeFuture;
  Handlers? _handlers;
  MssqlTlsTrust? _tlsTrust;
  bool _legacyTlsLogin = false;
  MssqlRuntimeDiagnostics? _diagnostics;
  final Map<Object, Future<void> Function()> _connections =
      <Object, Future<void> Function()>{};
  int _opensInProgress = 0;
  Completer<void>? _opensDrained;

  /// Whether the bundled FreeTDS was built with a TLS backend.
  ///
  /// Required encryption fails during `open` when this is false.
  bool get supportsTls => _hasTls;

  /// The certificate trust this process was initialized with.
  ///
  /// A null value prevents opening connections with `require` or `strict`
  /// encryption. Use
  /// `MssqlTlsTrust.insecureNoVerification()` only for explicit insecure trust.
  MssqlTlsTrust? get tlsTrust => _tlsTrust;

  /// Whether this process was initialized to accept a TLS 1.0 login
  /// handshake; see the [initialize] parameter of the same name.
  bool get allowLegacyTlsLogin => _legacyTlsLogin;

  bool get isInitialized => _initialized;
  bool get isShuttingDown => _shuttingDown;
  MssqlRuntimeDiagnostics get diagnostics =>
      _diagnostics ?? (throw StateError('MssqlRuntime is not initialized'));
  String get sybdbPath =>
      _sybdbLocator ?? (throw StateError('MssqlRuntime is not initialized'));

  /// The handler library — `mssql_native.dll`, `libmssql_native.so`,
  /// `MssqlNativeBridge.framework`.
  String get handlersPath =>
      _handlersLocator ?? (throw StateError('MssqlRuntime is not initialized'));

  /// Resolves and preloads FreeTDS and the handler library.
  ///
  /// [bridgePath] overrides the handler library's location.
  /// [tls] configures process-wide certificate trust. Reinitializing with a
  /// different trust configuration throws.
  ///
  /// [allowLegacyTlsLogin] permits a TLS 1.0 login handshake and lowers
  /// OpenSSL's security level to accept the certificates that come with it.
  ///
  /// TDS 7.1 and later encrypt the login packet whatever
  /// `MssqlEncryption` says, so this is about reaching a server at all, not
  /// about encrypting the session. SQL Server 2014 and earlier that never
  /// received the TLS 1.2 update offer only TLS 1.0 there, with a
  /// self-signed SHA-1 certificate, and FreeTDS and OpenSSL both refuse that
  /// by default. Without this, such a server is unreachable except through
  /// `tdsVersion: '7.0'`, which predates login encryption and gives up the
  /// datatypes TDS 7.1 and later added.
  ///
  /// It is process-wide and it weakens every connection's login, so it is
  /// spelled out rather than inferred. Update the server instead where that
  /// is possible.
  Future<void> initialize({
    String? bridgePath,
    String? sybdbPath,
    MssqlTlsTrust? tls,
    bool allowLegacyTlsLogin = false,
  }) async {
    if (_initialized) {
      _ensureTrustMatches(tls);
      _ensureLegacyTlsMatches(allowLegacyTlsLogin);
      return;
    }
    if (_shuttingDown) {
      throw StateError('MssqlRuntime is shutting down.');
    }
    final running = _initializeFuture;
    if (running != null) {
      // Awaited so a racing caller still compares its trust against what was
      // applied.
      await running;
      _ensureTrustMatches(tls);
      _ensureLegacyTlsMatches(allowLegacyTlsLogin);
      return;
    }
    final future = _initialize(
      bridgePath: bridgePath,
      sybdbPath: sybdbPath,
      tls: tls,
      allowLegacyTlsLogin: allowLegacyTlsLogin,
    );
    _initializeFuture = future;
    try {
      await future;
    } catch (_) {
      _resetFailedInitialization();
      rethrow;
    } finally {
      if (identical(_initializeFuture, future)) _initializeFuture = null;
    }
  }

  /// Refuses a second, different certificate trust configuration.
  ///
  /// Trust is process-wide, and changing it would silently re-point open
  /// connections; passing null conflicts with nothing.
  void _ensureTrustMatches(MssqlTlsTrust? tls) {
    if (tls == null) return;
    final applied = _tlsTrust;
    if (applied == tls) return;
    throw MssqlTlsException.configuration(
      'MssqlRuntime is already initialized with a different certificate '
      'trust: ${applied == null ? 'none was configured' : applied.describe()}, '
      'and this call asks for ${tls.describe()}. FreeTDS keeps trust '
      'process-wide, so it cannot be changed per connection or replaced once '
      'connections exist. Configure it once, at startup, before the first '
      'connection — see doc/TLS.md.',
    );
  }

  /// Refuses a second call that disagrees about the legacy login handshake.
  ///
  /// Like trust, it is written into one process-wide FreeTDS configuration
  /// file, so a later caller cannot have it both ways.
  void _ensureLegacyTlsMatches(bool requested) {
    if (requested == _legacyTlsLogin) return;
    throw MssqlTlsException.configuration(
      'MssqlRuntime is already initialized with '
      'allowLegacyTlsLogin: $_legacyTlsLogin, and this call asks for '
      '$requested. It is written into the process-wide FreeTDS configuration '
      'before the first connection and cannot be changed afterwards.',
    );
  }

  void _resetFailedInitialization() {
    _initialized = false;
    _sybdbLocator = null;
    _handlersLocator = null;
    _hasTls = false;
    _handlers = null;
    _tlsTrust = null;
    _diagnostics = null;
    try {
      _tlsConfigDirectory?.deleteSync(recursive: true);
    } on FileSystemException {
      // A later initialize call can replace the config path.
    }
    _tlsConfigDirectory = null;
  }

  Future<void> _initialize({
    String? bridgePath,
    String? sybdbPath,
    MssqlTlsTrust? tls,
    bool allowLegacyTlsLogin = false,
  }) async {
    if (!Platform.isWindows &&
        !Platform.isLinux &&
        !Platform.isMacOS &&
        !Platform.isIOS &&
        !Platform.isAndroid) {
      throw const MssqlException(
        type: MssqlErrorType.configuration,
        message:
            'mssql_native supports Windows, Linux, macOS, iOS and '
            'Android.',
      );
    }

    // Desktop hooks own the default locations, including `dart run` where
    // resolvedExecutable is the Dart VM rather than the user's script.
    // Explicit paths retain the existing manual/native-build integration.
    ({String sybdb, String handlers})? assets;
    if (sybdbPath == null &&
        bridgePath == null &&
        (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
      try {
        assets = desktopCodeAssetPaths();
      } catch (error) {
        throw MssqlException(
          type: MssqlErrorType.libraryLoad,
          message:
              'Could not load the bundled desktop code assets: $error. '
              'Use Dart 3.10+ with dart run or dart build cli, or a compatible '
              'Flutter build, and distribute the entire application bundle.',
        );
      }
    }
    final resolved = sybdbPath ?? assets?.sybdb ?? _defaultSybdbLocator();
    // On Android the locators are bare sonames the loader resolves against the
    // APK, not paths, so there is no file to stat and nothing to preload.
    if (resolved != processLibraryLocator && !Platform.isAndroid) {
      if (!File(resolved).existsSync()) {
        throw MssqlException(
          type: MssqlErrorType.libraryLoad,
          message: 'FreeTDS DB-Library was not found: $resolved',
        );
      }
      // FreeTDS depends on iconv (win-iconv on Windows) for single-byte code
      // pages. When sybdb is opened by explicit path, the Windows loader does
      // not search sybdb's directory for it, so preload the neighbouring
      // iconv.dll. Harmless when absent.
      if (Platform.isWindows) {
        final iconv =
            '${File(resolved).parent.path}${Platform.pathSeparator}iconv.dll';
        if (File(iconv).existsSync()) DynamicLibrary.open(iconv);
      }
      // Opened here too so a broken install fails at initialize() rather than
      // in the first connection. dlopen is refcounted, so this is cheap.
      DynamicLibrary.open(resolved);
    }

    final handlers =
        bridgePath ?? assets?.handlers ?? _defaultHandlersLocator();
    if (handlers != processLibraryLocator &&
        !Platform.isAndroid &&
        !File(handlers).existsSync()) {
      throw MssqlException(
        type: MssqlErrorType.libraryLoad,
        message:
            'The mssql_native handler library was not found: $handlers. '
            'Run the platform build script under scripts/.',
      );
    }

    // Loaded here too so TLS capability and trust are established before the
    // first connection.
    final library = Handlers(DynamicLibrary.open(handlers));
    if (library.abi() != handlersAbi) {
      throw MssqlException(
        type: MssqlErrorType.libraryLoad,
        message:
            'The mssql_native handler library reports ABI '
            '${library.abi()}, but this build expects $handlersAbi. Rebuild it '
            'with the script under scripts/ for this platform.',
      );
    }
    _hasTls = library.hasTls() == 1;

    if (tls != null) {
      tls.validate();
      if (!_hasTls) {
        throw const MssqlTlsException.configuration(
          'Certificate trust was configured, but this build of FreeTDS has no '
          'TLS backend, so nothing can be encrypted and nothing can be '
          'verified. Rebuild it with --with-openssl, or use the distributed '
          'binaries, which include one.',
        );
      }
      final ca = tls.certificateAuthorityFile;
      if (ca != null && ca != 'system') {
        // Fail closed: FreeTDS treats an unreadable CA file as no CA file,
        // then encrypts and accepts any certificate.
        final file = File(ca);
        if (!file.existsSync()) {
          throw MssqlTlsException.configuration(
            'The certificate authority file was not found: $ca. FreeTDS would '
            'read a missing trust store as "verify nothing" and connect '
            'anyway, so initialization stops instead. Check the path, or '
            'install a bundled CA asset with '
            'MssqlTlsTrust.installPemBundle(bytes, file: ...).',
          );
        }
        if (file.lengthSync() == 0) {
          throw MssqlTlsException.configuration(
            'The certificate authority file is empty: $ca. An empty trust '
            'store verifies nothing, and FreeTDS would connect anyway. This '
            'is usually an asset that was declared but not loaded, or a '
            'download that produced an error page.',
          );
        }
      }
    }
    if ((tls != null && tls.requiresConfigurationFile) || allowLegacyTlsLogin) {
      _writeFreeTdsConfig(
        library,
        tls: tls,
        allowLegacyTlsLogin: allowLegacyTlsLogin,
      );
    }

    _tlsTrust = tls;
    _legacyTlsLogin = allowLegacyTlsLogin;
    _sybdbLocator = resolved;
    _handlersLocator = handlers;
    _handlers = library;
    final dbLibrary = DbLib(DynamicLibrary.open(resolved));
    _diagnostics = MssqlRuntimeDiagnostics(
      freeTdsVersion: dbLibrary.dbversion().toDartString(),
      handlersAbiVersion: library.abi(),
      tlsAvailable: _hasTls,
      certificateTrust: tls == null ? 'not configured' : tls.describe(),
      sybdbPath: resolved,
      handlersPath: handlers,
      platform: Platform.operatingSystem,
    );
    _initialized = true;
  }

  void ensureCanOpenConnection() {
    if (!_initialized || _shuttingDown) {
      throw StateError(
        _shuttingDown
            ? 'MssqlRuntime is shutting down.'
            : 'MssqlRuntime is not initialized.',
      );
    }
  }

  @internal
  void beginConnectionOpen() {
    ensureCanOpenConnection();
    _opensInProgress++;
  }

  @internal
  void endConnectionOpen() {
    if (_opensInProgress > 0) _opensInProgress--;
    if (_opensInProgress == 0) {
      _opensDrained?.complete();
      _opensDrained = null;
    }
  }

  @internal
  void registerConnection(
    Object connection,
    Future<void> Function() closeForShutdown,
  ) {
    _connections[connection] = closeForShutdown;
  }

  @internal
  void unregisterConnection(Object connection) {
    _connections.remove(connection);
  }

  /// Writes the `freetds.conf` FreeTDS needs and points the process at it.
  ///
  /// A file rather than an API call: DB-Library exposes only the `encryption`
  /// TLS setting and none of the functions that reach the rest.
  void _writeFreeTdsConfig(
    Handlers library, {
    required MssqlTlsTrust? tls,
    required bool allowLegacyTlsLogin,
  }) {
    final settings = StringBuffer('[global]\n');
    if (tls != null) settings.write(tls.configSettings());
    if (allowLegacyTlsLogin) {
      // Two settings, because FreeTDS and OpenSSL each refuse separately.
      // `enable tls v1` clears FreeTDS's own SSL_OP_NO_TLSv1; the cipher
      // string lowers OpenSSL's security level, which otherwise rejects the
      // SHA-1 self-signed certificate these servers present.
      settings
        ..writeln('\tenable tls v1 = yes')
        ..writeln('\topenssl ciphers = DEFAULT@SECLEVEL=0');
    }
    final directory = Directory.systemTemp.createTempSync('mssql_native_tls_');
    final file = File('${directory.path}${Platform.pathSeparator}freetds.conf')
      ..writeAsStringSync(settings.toString());
    final path = file.path.toNativeUtf8();
    final applied = library.setConfigPath(path);
    calloc.free(path);
    if (applied != 1) {
      throw const MssqlTlsException.configuration(
        'Could not point FreeTDS at a generated freetds.conf, so the '
        'certificate trust that was asked for is not in force. Initialization '
        'stops rather than continue with FreeTDS defaults, which verify '
        'nothing.',
      );
    }
    _tlsConfigDirectory = directory;
  }

  Directory? _tlsConfigDirectory;

  Future<void> shutdown() {
    final running = _shutdownFuture;
    if (running != null) return running;
    final initializing = _initializeFuture;
    if (initializing != null) {
      return initializing.then((_) => shutdown());
    }
    if (!_initialized && _connections.isEmpty) return Future<void>.value();
    _shuttingDown = true;
    final future = _shutdown();
    _shutdownFuture = future;
    return future;
  }

  Future<void> _shutdown() async {
    if (_opensInProgress > 0) {
      _opensDrained ??= Completer<void>();
      await _opensDrained!.future;
    }
    final closes = List<Future<void> Function()>.of(_connections.values);
    await Future.wait(
      closes.map((close) async {
        try {
          await close();
        } catch (_) {}
      }),
    );
    _handlers?.releaseAll();
    _initialized = false;
    _sybdbLocator = null;
    _handlersLocator = null;
    _hasTls = false;
    _handlers = null;
    _tlsTrust = null;
    _diagnostics = null;
    // FREETDSCONF still points at the deleted file: it cannot be unset from
    // here, and FreeTDS treats an unreadable path as no config.
    try {
      _tlsConfigDirectory?.deleteSync(recursive: true);
    } on FileSystemException {
      // A leftover temp directory must not fail shutdown.
    }
    _tlsConfigDirectory = null;
    _connections.clear();
    _shuttingDown = false;
    _shutdownFuture = null;
  }

  static String _defaultHandlersLocator() {
    final candidates = bridgeCandidates(
      os: Platform.operatingSystem,
      executableDir: File(Platform.resolvedExecutable).parent.path,
      separator: Platform.pathSeparator,
    );
    for (final candidate in candidates) {
      final file = File(candidate);
      if (file.existsSync()) return file.absolute.path;
    }
    return candidates.isEmpty ? processLibraryLocator : candidates.first;
  }

  static String _defaultSybdbLocator() {
    final candidates = sybdbCandidates(
      os: Platform.operatingSystem,
      executableDir: File(Platform.resolvedExecutable).parent.path,
      separator: Platform.pathSeparator,
    );
    for (final candidate in candidates) {
      final file = File(candidate);
      if (file.existsSync()) return file.absolute.path;
    }
    return candidates.isEmpty ? processLibraryLocator : candidates.first;
  }
}
