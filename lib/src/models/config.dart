import 'dart:io';

import 'package:meta/meta.dart';

import 'session_options.dart';
import 'types.dart';

/// The driver's default connection settings.
///
/// Connection entry points and pools use these values consistently.
abstract final class MssqlDefaults {
  /// The TDS port. Named instances are not resolved; see
  /// [MssqlConnectionConfig.fromConnectionString].
  static const int port = 1433;

  /// What shows up in `sys.dm_exec_sessions.program_name`.
  static const String applicationName = 'mssql_native';

  /// How long login may take, including the TLS handshake.
  static const Duration loginTimeout = Duration(seconds: 10);

  /// How long a command may take when it does not ask for its own timeout.
  static const Duration queryTimeout = Duration(seconds: 30);

  /// Let FreeTDS and the server negotiate the TDS packet size.
  ///
  /// Set a fixed size only after measuring the workload.
  static const int automaticPacketSize = 0;

  /// The TDS protocol version requested at login.
  static const String tdsVersion = '7.4';

  /// Every TDS version string this driver can ask FreeTDS for.
  ///
  /// Anything else is refused by [MssqlConnectionConfig.validate], rather than
  /// logging in as 7.4 under a name the configuration did not give.
  static const List<String> tdsVersions = <String>[
    '7.0',
    '7.1',
    '7.2',
    '7.3',
    '7.4',
  ];

  /// The client character set. UTF-8 for every platform the driver supports.
  static const String clientCharset = 'UTF-8';

  /// Encryption for the whole session, not just the login packet.
  ///
  /// Plaintext is the default. Applications that require transport encryption
  /// opt in with [MssqlEncryption.require] or [MssqlEncryption.strict] and
  /// configure process-wide certificate trust before opening a connection.
  static const MssqlEncryption encryption = MssqlEncryption.off;

  /// How `DECIMAL`, `NUMERIC` and `MONEY` reach Dart.
  static const MssqlDecimalMode decimalMode = MssqlDecimalMode.exact;

  /// The SET options every session is logged in with.
  static const MssqlSessionOptions sessionOptions = MssqlSessionOptions.ansi;

  /// Connections opened before the pool is asked for one.
  static const int poolMinimumSize = 0;

  /// The most connections one pool will own.
  ///
  /// Increase this only after measuring server and application contention.
  static const int poolMaximumSize = 2;

  /// The budget for a whole `acquire`: queueing, validating and opening.
  static const Duration poolAcquireTimeout = Duration(seconds: 15);

  /// How long an idle connection above the minimum is kept.
  static const Duration poolIdleTimeout = Duration(minutes: 5);

  /// How recently a connection must have been used to skip validation.
  ///
  /// The zero default validates every reuse.
  static const Duration poolValidationGracePeriod = Duration.zero;

  /// How many procedure/bulk describes one cache will hold.
  static const int metadataCacheSize = 128;

  /// How long a describe is reused without asking the catalog again.
  static const Duration metadataCacheTtl = Duration(minutes: 10);
}

/// Everything needed to open one connection.
@immutable
class MssqlConnectionConfig {
  const MssqlConnectionConfig({
    required this.host,
    required this.database,
    required this.username,
    required this.password,
    this.port = MssqlDefaults.port,
    this.applicationName = MssqlDefaults.applicationName,
    this.loginTimeout = MssqlDefaults.loginTimeout,
    this.defaultQueryTimeout = MssqlDefaults.queryTimeout,
    this.packetSize = MssqlDefaults.automaticPacketSize,
    this.tdsVersion = MssqlDefaults.tdsVersion,
    this.clientCharset = MssqlDefaults.clientCharset,
    this.encryption = MssqlDefaults.encryption,
    this.decimalMode = MssqlDefaults.decimalMode,
    this.metadataCacheSize = MssqlDefaults.metadataCacheSize,
    this.metadataCacheTtl = MssqlDefaults.metadataCacheTtl,
    this.sessionOptions = MssqlDefaults.sessionOptions,
    this.integratedSecurity = false,
  });

  /// Logs in as the Windows account running the process. Windows only;
  /// [validate] refuses it elsewhere.
  const MssqlConnectionConfig.integratedSecurity({
    required this.host,
    required this.database,
    this.port = MssqlDefaults.port,
    this.applicationName = MssqlDefaults.applicationName,
    this.loginTimeout = MssqlDefaults.loginTimeout,
    this.defaultQueryTimeout = MssqlDefaults.queryTimeout,
    this.packetSize = MssqlDefaults.automaticPacketSize,
    this.tdsVersion = MssqlDefaults.tdsVersion,
    this.clientCharset = MssqlDefaults.clientCharset,
    this.encryption = MssqlDefaults.encryption,
    this.decimalMode = MssqlDefaults.decimalMode,
    this.metadataCacheSize = MssqlDefaults.metadataCacheSize,
    this.metadataCacheTtl = MssqlDefaults.metadataCacheTtl,
    this.sessionOptions = MssqlDefaults.sessionOptions,
  }) : username = '',
       password = '',
       integratedSecurity = true;

  final String host;
  final int port;
  final String database;

  /// The SQL Server login, or a `DOMAIN\user` Windows account. Empty only
  /// when [integratedSecurity] is set.
  final String username;
  final String password;
  final String applicationName;

  /// Whether login uses the Windows account running the process.
  final bool integratedSecurity;

  /// How long login and its handshake may take.
  final Duration loginTimeout;

  /// The timeout every command gets unless it asks for its own.
  ///
  /// Per-operation overrides go through `MssqlQueryOptions.timeout` or the
  /// `timeout:` argument on `query`, `callProcedure` and `stream`.
  final Duration defaultQueryTimeout;

  /// The TDS packet size, or [MssqlDefaults.automaticPacketSize] to negotiate.
  final int packetSize;

  final String tdsVersion;
  final String clientCharset;

  /// How `DECIMAL`, `NUMERIC`, `MONEY` and `SMALLMONEY` reach Dart.
  ///
  /// [MssqlDecimalMode.doublePrecision] is available when precision loss is
  /// acceptable.
  final MssqlDecimalMode decimalMode;

  /// How much of the session to encrypt.
  ///
  /// [MssqlEncryption.require] and [MssqlEncryption.strict] also require
  /// process-wide certificate trust configured through `MssqlRuntime`.
  /// See `doc/TLS.md`.
  final MssqlEncryption encryption;

  /// How many procedure and bulk-table describes this connection caches.
  final int metadataCacheSize;

  /// How long a cached describe is reused.
  ///
  /// [Duration.zero] still coalesces in-flight loads and then forgets the
  /// answer, so a schema change is visible on the next call without a
  /// process restart.
  final Duration metadataCacheTtl;

  /// The SET options this connection is logged in with.
  final MssqlSessionOptions sessionOptions;

  /// Reads a .NET-style connection string.
  ///
  /// ```dart
  /// MssqlConnectionConfig.fromConnectionString(
  ///   'Server=tcp:db.internal,1433;Database=Shop;User Id=sa;Password=…',
  /// );
  /// ```
  ///
  /// Keys ignore case and internal spaces. Common SqlClient aliases such as
  /// `Server`, `Database`, `UID` and `PWD` are accepted. Quoted values may
  /// contain semicolons. Missing settings use [MssqlDefaults].
  ///
  /// Unsupported keys cause an error unless [onUnsupportedKeys] handles them.
  /// Security features that the driver cannot honor are always rejected.
  factory MssqlConnectionConfig.fromConnectionString(
    String connectionString, {
    MssqlDecimalMode decimalMode = MssqlDefaults.decimalMode,
    MssqlSessionOptions sessionOptions = MssqlDefaults.sessionOptions,
    void Function(List<String> keys)? onUnsupportedKeys,
  }) {
    final values = _parseConnectionString(connectionString);

    String? read(List<String> names) {
      for (final name in names) {
        final entry = values.remove(_foldKey(name));
        if (entry != null) return entry.value;
      }
      return null;
    }

    final integratedSecurity = _isTrue(
      read(<String>['Integrated Security', 'Trusted_Connection']),
    );

    final source = read(<String>[
      'Data Source',
      'Server',
      'Address',
      'Addr',
      'Network Address',
    ]);
    if (source == null || source.trim().isEmpty) {
      throw ArgumentError.value(
        redactConnectionString(connectionString),
        'connectionString',
        'No Server (or Data Source) in the connection string.',
      );
    }
    final endpoint = _parseEndpoint(source);

    final database = read(<String>['Initial Catalog', 'Database']);
    if (database == null || database.trim().isEmpty) {
      throw ArgumentError.value(
        redactConnectionString(connectionString),
        'connectionString',
        'No Database (or Initial Catalog) in the connection string.',
      );
    }

    final username = read(<String>['User ID', 'UID', 'User']);
    if (!integratedSecurity && (username == null || username.isEmpty)) {
      throw ArgumentError.value(
        redactConnectionString(connectionString),
        'connectionString',
        'No User Id in the connection string. Add Integrated Security=true to '
            'log in as the Windows account running the process, which needs '
            'Windows, or give User Id and Password.',
      );
    }

    final encryption = _parseEncryption(read(<String>['Encrypt']));
    final trustCertificate = read(<String>['TrustServerCertificate']);
    if (trustCertificate != null) {
      throw ArgumentError.value(
        redactConnectionString(connectionString),
        'connectionString',
        _isTrue(trustCertificate)
            ? 'TrustServerCertificate=true asks for an encrypted session with '
                  'no certificate check. FreeTDS decides that process-wide, so '
                  'say it once and out loud: '
                  'MssqlRuntime.initialize(tls: '
                  'MssqlTlsTrust.insecureNoVerification()). Then drop the key '
                  'from the string.'
            : 'TrustServerCertificate=false asks for the certificate to be '
                  'verified per connection, which FreeTDS decides '
                  'process-wide instead. Configure it through '
                  'MssqlRuntime.initialize(tls: MssqlTlsTrust(...)) — see '
                  'doc/TLS.md — and drop the key from the string.',
      );
    }

    final timeout = read(<String>[
      'Connect Timeout',
      'Connection Timeout',
      'Timeout',
    ]);

    // Read every remaining key before reporting, or keys read below would
    // still be in the map and be reported as unsupported.
    final password = read(<String>['Password', 'PWD']) ?? '';
    final applicationName = read(<String>['Application Name', 'App']);

    if (integratedSecurity && (username != null || password.isNotEmpty)) {
      throw ArgumentError.value(
        redactConnectionString(connectionString),
        'connectionString',
        'Integrated Security asks to log in as the Windows account running '
            'the process, so the User Id and Password in the same string '
            'cannot be used. Drop one of the two.',
      );
    }

    if (values.isNotEmpty) {
      _reportUnsupportedKeys(connectionString, values, onUnsupportedKeys);
    }

    final loginTimeout = timeout == null
        ? MssqlDefaults.loginTimeout
        : Duration(seconds: _parseSeconds(timeout, 'Connect Timeout'));

    if (integratedSecurity) {
      return MssqlConnectionConfig.integratedSecurity(
        host: endpoint.host,
        port: endpoint.port ?? MssqlDefaults.port,
        database: database.trim(),
        applicationName: applicationName ?? MssqlDefaults.applicationName,
        loginTimeout: loginTimeout,
        encryption: encryption,
        decimalMode: decimalMode,
      );
    }

    return MssqlConnectionConfig(
      host: endpoint.host,
      port: endpoint.port ?? MssqlDefaults.port,
      database: database.trim(),
      username: username!,
      password: password,
      applicationName: applicationName ?? MssqlDefaults.applicationName,
      loginTimeout: loginTimeout,
      encryption: encryption,
      decimalMode: decimalMode,
      sessionOptions: sessionOptions,
    );
  }

  /// This configuration with individual settings replaced.
  ///
  /// Keeps one configured template and varies only what differs, without
  /// restating every field.
  MssqlConnectionConfig copyWith({
    String? host,
    int? port,
    String? database,
    String? username,
    String? password,
    String? applicationName,
    Duration? loginTimeout,
    Duration? defaultQueryTimeout,
    int? packetSize,
    String? tdsVersion,
    String? clientCharset,
    MssqlEncryption? encryption,
    MssqlDecimalMode? decimalMode,
    int? metadataCacheSize,
    Duration? metadataCacheTtl,
    MssqlSessionOptions? sessionOptions,
    bool? integratedSecurity,
  }) {
    final integrated = integratedSecurity ?? this.integratedSecurity;
    if (integrated && (username != null || password != null)) {
      throw ArgumentError(
        'An integrated security login carries no user name and no password. '
        'Pass integratedSecurity: false along with the credentials to move '
        'this configuration to a SQL Server or domain login.',
      );
    }
    if (integrated) {
      return MssqlConnectionConfig.integratedSecurity(
        host: host ?? this.host,
        port: port ?? this.port,
        database: database ?? this.database,
        applicationName: applicationName ?? this.applicationName,
        loginTimeout: loginTimeout ?? this.loginTimeout,
        defaultQueryTimeout: defaultQueryTimeout ?? this.defaultQueryTimeout,
        packetSize: packetSize ?? this.packetSize,
        tdsVersion: tdsVersion ?? this.tdsVersion,
        clientCharset: clientCharset ?? this.clientCharset,
        encryption: encryption ?? this.encryption,
        decimalMode: decimalMode ?? this.decimalMode,
        metadataCacheSize: metadataCacheSize ?? this.metadataCacheSize,
        metadataCacheTtl: metadataCacheTtl ?? this.metadataCacheTtl,
        sessionOptions: sessionOptions ?? this.sessionOptions,
      );
    }
    return MssqlConnectionConfig(
      host: host ?? this.host,
      port: port ?? this.port,
      database: database ?? this.database,
      username: username ?? this.username,
      password: password ?? this.password,
      applicationName: applicationName ?? this.applicationName,
      loginTimeout: loginTimeout ?? this.loginTimeout,
      defaultQueryTimeout: defaultQueryTimeout ?? this.defaultQueryTimeout,
      packetSize: packetSize ?? this.packetSize,
      tdsVersion: tdsVersion ?? this.tdsVersion,
      clientCharset: clientCharset ?? this.clientCharset,
      encryption: encryption ?? this.encryption,
      decimalMode: decimalMode ?? this.decimalMode,
      metadataCacheSize: metadataCacheSize ?? this.metadataCacheSize,
      metadataCacheTtl: metadataCacheTtl ?? this.metadataCacheTtl,
      sessionOptions: sessionOptions ?? this.sessionOptions,
    );
  }

  void validate() {
    sessionOptions.validate();
    if (host.trim().isEmpty) throw ArgumentError.value(host, 'host');
    if (database.trim().isEmpty) {
      throw ArgumentError.value(database, 'database');
    }
    if (integratedSecurity) {
      if (!Platform.isWindows) {
        throw ArgumentError.value(
          integratedSecurity,
          'integratedSecurity',
          'Windows authentication needs SSPI, which the bundled FreeTDS only '
              'has on Windows; this is ${Platform.operatingSystem}. Log in '
              'with a domain account instead: username "DOMAIN\\user" and '
              'its password, which authenticates over NTLMv2 from any '
              'platform.',
        );
      }
      if (username.isNotEmpty || password.isNotEmpty) {
        throw ArgumentError.value(
          username,
          'username',
          'Integrated security logs in as the Windows account running the '
              'process, so a user name or password here would be ignored.',
        );
      }
    } else if (username.isEmpty) {
      throw ArgumentError.value(username, 'username');
    }
    if (port < 1 || port > 65535) {
      throw RangeError.range(port, 1, 65535, 'port');
    }
    if (loginTimeout <= Duration.zero) {
      throw ArgumentError.value(loginTimeout, 'loginTimeout');
    }
    if (defaultQueryTimeout <= Duration.zero) {
      throw ArgumentError.value(defaultQueryTimeout, 'defaultQueryTimeout');
    }
    // Zero means "let the server decide"; anything else is a real TDS packet
    // size the server rejects at login if out of range.
    if (packetSize != MssqlDefaults.automaticPacketSize &&
        (packetSize < 512 || packetSize > 32767)) {
      throw RangeError.range(
        packetSize,
        512,
        32767,
        'packetSize',
        'packetSize must be 0 to negotiate, or 512..32767',
      );
    }
    if (!MssqlDefaults.tdsVersions.contains(tdsVersion)) {
      final known = MssqlDefaults.tdsVersions.join(', ');
      throw ArgumentError.value(
        tdsVersion,
        'tdsVersion',
        'Unknown TDS version. Use one of: $known.',
      );
    }
    if (clientCharset.trim().isEmpty) {
      throw ArgumentError.value(clientCharset, 'clientCharset');
    }
    if (metadataCacheSize < 1) {
      throw ArgumentError.value(
        metadataCacheSize,
        'metadataCacheSize',
        'A metadata cache with no room cannot share a describe.',
      );
    }
    if (metadataCacheTtl < Duration.zero) {
      throw ArgumentError.value(
        metadataCacheTtl,
        'metadataCacheTtl',
        'A negative TTL is not a bound.',
      );
    }
  }

  /// Names the endpoint without the credentials, which can reach logs and
  /// failure messages.
  @override
  String toString() =>
      'MssqlConnectionConfig($host:$port/$database, '
      'user: ${integratedSecurity ? '<integrated security>' : username}, '
      'encryption: ${encryption.name}, decimal: ${decimalMode.name})';
}

/// A `Server=` value, which carries more than a host name.
class _Endpoint {
  const _Endpoint(this.host, this.port);
  final String host;
  final int? port;
}

/// One key and value from a connection string, keeping the caller's spelling so
/// a complaint quotes the key as written rather than folded.
class _ConnectionStringEntry {
  const _ConnectionStringEntry(this.key, this.value);
  final String key;
  final String value;
}

/// Keys SqlClient understands that change how a connection is secured and this
/// driver cannot honour.
///
/// Refused rather than reported: the caller stated a security requirement, and
/// carrying on would meet a weaker one silently. Folded spelling, so
/// `Column Encryption Setting` and `columnencryptionsetting` are one key.
const Set<String> _securitySensitiveKeys = <String>{
  'authentication',
  'clientcertificate',
  'clientkey',
  'columnencryptionsetting',
  'enclaveattestationurl',
  'hostnameincertificate',
  'keystoreauthentication',
  'servercertificate',
  'sslprotocol',
};

void _reportUnsupportedKeys(
  String connectionString,
  Map<String, _ConnectionStringEntry> remaining,
  void Function(List<String> keys)? onUnsupportedKeys,
) {
  final security = <String>[
    for (final entry in remaining.entries)
      if (_securitySensitiveKeys.contains(entry.key)) entry.value.key,
  ]..sort();
  if (security.isNotEmpty) {
    throw ArgumentError.value(
      redactConnectionString(connectionString),
      'connectionString',
      'These keys decide how the connection is secured, and this driver '
          'cannot honour them: ${security.join(', ')}. Certificate trust is '
          'process-wide here and is configured through '
          'MssqlRuntime.initialize(tls: ...) — see doc/TLS.md; Always '
          'Encrypted and certificate-based logins are not implemented. Remove '
          'the keys once the equivalent is configured, so that the string '
          'stops claiming a guarantee it does not get.',
    );
  }
  final keys = <String>[for (final entry in remaining.values) entry.key]
    ..sort();
  if (onUnsupportedKeys == null) {
    throw ArgumentError.value(
      redactConnectionString(connectionString),
      'connectionString',
      'This driver has no use for these keys: ${keys.join(', ')}. Remove '
          'them, or pass onUnsupportedKeys to be told about them and carry '
          'on. They are not ignored silently, because a key that looks '
          'honoured and is not is how a connection ends up configured '
          'differently from the string that describes it.',
    );
  }
  onUnsupportedKeys(keys);
}

/// Splits a connection string into folded keys and their values.
///
/// SqlClient's own rules: pairs separated by `;`, the key up to the first `=`,
/// and a value that may be quoted with `'` or `"` so that it can contain a
/// semicolon — a doubled quote inside standing for one. A later duplicate wins,
/// as it does there.
/// Connection-string keys whose value must not reach an exception or a log.
const Set<String> _secretConnectionStringKeys = <String>{'password', 'pwd'};

/// The string with every secret value replaced, for the `invalidValue` of an
/// [ArgumentError] — which is what `toString()` prints.
///
/// On a parse failure the scanner cannot say where a malformed value ends, so
/// everything from that point on is masked rather than guessed at.
String redactConnectionString(String text) {
  const mask = '***';
  final out = StringBuffer();
  var index = 0;

  while (index < text.length) {
    final runStart = index;
    while (index < text.length &&
        (text[index] == ';' || text[index].trim().isEmpty)) {
      index++;
    }
    out.write(text.substring(runStart, index));
    if (index >= text.length) break;

    final equals = text.indexOf('=', index);
    if (equals < 0) {
      out.write(mask);
      return out.toString();
    }
    final key = text.substring(index, equals).trim();
    final secret = _secretConnectionStringKeys.contains(_foldKey(key));
    out.write(text.substring(index, equals + 1));
    index = equals + 1;

    final spaceStart = index;
    while (index < text.length && text[index] == ' ') {
      index++;
    }
    out.write(text.substring(spaceStart, index));

    final valueStart = index;
    if (index < text.length && (text[index] == "'" || text[index] == '"')) {
      final quote = text[index];
      index++;
      var closed = false;
      while (index < text.length) {
        if (text[index] != quote) {
          index++;
          continue;
        }
        if (index + 1 < text.length && text[index + 1] == quote) {
          index += 2;
          continue;
        }
        index++;
        closed = true;
        break;
      }
      if (!closed) {
        out.write(mask);
        return out.toString();
      }
      final next = text.indexOf(';', index);
      final end = next < 0 ? text.length : next + 1;
      out.write(secret ? mask : text.substring(valueStart, index));
      if (!secret) out.write(text.substring(index, end));
      if (secret && next >= 0) out.write(';');
      index = end;
    } else {
      final semicolon = text.indexOf(';', index);
      final end = semicolon < 0 ? text.length : semicolon;
      out.write(secret ? mask : text.substring(valueStart, end));
      index = end + 1;
      if (semicolon >= 0) out.write(';');
    }
  }
  return out.toString();
}

Map<String, _ConnectionStringEntry> _parseConnectionString(String text) {
  final values = <String, _ConnectionStringEntry>{};
  var index = 0;

  while (index < text.length) {
    while (index < text.length &&
        (text[index] == ';' || text[index].trim().isEmpty)) {
      index++;
    }
    if (index >= text.length) break;

    final equals = text.indexOf('=', index);
    if (equals < 0) {
      throw ArgumentError.value(
        redactConnectionString(text),
        'connectionString',
        'The entry starting at ${index + 1} has no "=".',
      );
    }
    final key = text.substring(index, equals).trim();
    if (key.isEmpty) {
      throw ArgumentError.value(
        redactConnectionString(text),
        'connectionString',
        'An entry at ${index + 1} has no key.',
      );
    }
    index = equals + 1;
    while (index < text.length && text[index] == ' ') {
      index++;
    }

    final String value;
    if (index < text.length && (text[index] == "'" || text[index] == '"')) {
      final quote = text[index];
      final buffer = StringBuffer();
      index++;
      var closed = false;
      while (index < text.length) {
        if (text[index] != quote) {
          buffer.write(text[index++]);
          continue;
        }
        // A doubled quote is one quote; a single one ends the value.
        if (index + 1 < text.length && text[index + 1] == quote) {
          buffer.write(quote);
          index += 2;
          continue;
        }
        index++;
        closed = true;
        break;
      }
      if (!closed) {
        throw ArgumentError.value(
          redactConnectionString(text),
          'connectionString',
          'The value for "$key" opens with $quote and never closes.',
        );
      }
      value = buffer.toString();
      final next = text.indexOf(';', index);
      index = next < 0 ? text.length : next + 1;
    } else {
      final semicolon = text.indexOf(';', index);
      final end = semicolon < 0 ? text.length : semicolon;
      value = text.substring(index, end).trim();
      index = end + 1;
    }
    values[_foldKey(key)] = _ConnectionStringEntry(key, value);
  }
  return values;
}

/// `tcp:host,1433`, `host\INSTANCE`, `(local)`, `.` — all legal in .NET.
_Endpoint _parseEndpoint(String source) {
  var host = source.trim();
  for (final prefix in const <String>['tcp:', 'np:', 'lpc:', 'admin:']) {
    if (host.toLowerCase().startsWith(prefix)) {
      if (prefix != 'tcp:') {
        throw ArgumentError.value(
          source,
          'connectionString',
          'This driver speaks TDS over TCP only; "$prefix" asks for another '
              'protocol.',
        );
      }
      host = host.substring(prefix.length).trim();
      break;
    }
  }

  int? port;
  final comma = host.lastIndexOf(',');
  if (comma > 0) {
    final text = host.substring(comma + 1).trim();
    port = int.tryParse(text);
    if (port == null || port < 1 || port > 65535) {
      throw ArgumentError.value(
        source,
        'connectionString',
        '"$text" is not a port.',
      );
    }
    host = host.substring(0, comma).trim();
  }

  if (host.contains(r'\')) {
    // A named instance is resolved through the SQL Browser on UDP 1434, which
    // DB-Library does not speak; give the port instead.
    throw ArgumentError.value(
      source,
      'connectionString',
      'A named instance ("$host") is resolved through the SQL Browser, which '
          'this driver does not speak. Give the instance\'s port instead, as '
          'Server=host,1433.',
    );
  }

  // `.` and `(local)` are how .NET spells the local machine.
  if (host == '.' || host.toLowerCase() == '(local)' || host.isEmpty) {
    host = '127.0.0.1';
  }
  return _Endpoint(host, port);
}

MssqlEncryption _parseEncryption(String? value) {
  // An absent Encrypt means off, matching MssqlDefaults.encryption.
  //
  // This differs from modern SqlClient, which defaults Encrypt to true.
  // Matching it would make a string with no Encrypt key demand a configured
  // trust store, turning the common local and intranet case into an error.
  // Transport encryption is opt-in: Encrypt=true or MssqlEncryption.require,
  // with trust configured through MssqlRuntime.initialize(tls: ...).
  if (value == null) return MssqlDefaults.encryption;
  return switch (value.trim().toLowerCase()) {
    // SqlClient's true means "encrypt the session" (require here); optional
    // offers encryption and lets the server decide (MssqlEncryption.request).
    'true' || 'yes' || 'mandatory' => MssqlEncryption.require,
    'strict' => MssqlEncryption.strict,
    'false' || 'no' => MssqlEncryption.off,
    'optional' => MssqlEncryption.request,
    _ => throw ArgumentError.value(
      value,
      'Encrypt',
      'Expected true, false, mandatory, optional or strict.',
    ),
  };
}

int _parseSeconds(String value, String key) {
  final seconds = int.tryParse(value.trim());
  if (seconds == null || seconds <= 0) {
    throw ArgumentError.value(value, key, 'Expected a positive whole number.');
  }
  return seconds;
}

bool _isTrue(String? value) => switch (value?.trim().toLowerCase()) {
  'true' || 'yes' || 'sspi' => true,
  _ => false,
};

/// SqlClient matches keys without regard to case or inner spaces, so
/// `User ID`, `userid` and `User Id` are one key.
String _foldKey(String key) =>
    key.replaceAll(' ', '').replaceAll('_', '').toLowerCase();

/// Process-wide TLS certificate trust.
///
/// Separate from [MssqlConnectionConfig] because FreeTDS makes it so: trust is
/// set through a `freetds.conf` found via an environment variable, so it
/// belongs to the process. Pass it to `MssqlRuntime.initialize`; the runtime
/// refuses a second, conflicting configuration.
///
/// Three ways to state what to trust, and none leaves it unstated:
///
/// * `MssqlTlsTrust(certificateAuthorityFile: ...)` — verify against a PEM
///   bundle you ship or install.
/// * [MssqlTlsTrust.system] — verify against OpenSSL's default certificate
///   paths, which are not the platform certificate store.
/// * [MssqlTlsTrust.insecureNoVerification] — encrypt and accept any
///   certificate.
@immutable
class MssqlTlsTrust {
  /// Verifies the server certificate against a PEM bundle.
  ///
  /// [certificateAuthorityFile] is required: a trust configuration that
  /// verifies nothing is [MssqlTlsTrust.insecureNoVerification], which says so
  /// in its name.
  const MssqlTlsTrust({
    required String this.certificateAuthorityFile,
    this.certificateRevocationFile,
    this.validateHostname = true,
    this.expectedHostname,
  });

  /// Use OpenSSL's default certificate paths.
  ///
  /// Not the platform certificate store: FreeTDS calls OpenSSL's
  /// `SSL_CTX_set_default_verify_paths`, and those paths are normally empty on
  /// iOS, Android and Windows, so the handshake fails. Ship a PEM bundle with
  /// [installPemBundle] there instead.
  const MssqlTlsTrust.system()
    : certificateAuthorityFile = 'system',
      certificateRevocationFile = null,
      validateHostname = true,
      expectedHostname = null;

  /// Encrypt the session and accept whatever certificate the server presents.
  ///
  /// Protects against passive reading, not a man in the middle. It suits a
  /// self-signed certificate on a private segment, or a first connection made
  /// to fetch the real certificate.
  const MssqlTlsTrust.insecureNoVerification()
    : certificateAuthorityFile = null,
      certificateRevocationFile = null,
      validateHostname = false,
      expectedHostname = null;

  /// A PEM file of trusted authorities, the literal `system`, or null when
  /// [MssqlTlsTrust.insecureNoVerification] was chosen.
  final String? certificateAuthorityFile;

  /// A PEM revocation list. Only consulted when a CA file is set.
  final String? certificateRevocationFile;

  /// Whether the certificate has to match the host being connected to.
  ///
  /// Only has an effect when [certificateAuthorityFile] is set, because
  /// without it nothing about the certificate is checked.
  final bool validateHostname;

  /// The name to match instead of the host, when a server is reached by an
  /// address or a tunnel but presents a certificate for its real name.
  final String? expectedHostname;

  /// Writes a PEM bundle carried as an asset to [file] and trusts it.
  ///
  /// FreeTDS reads its trust store from a path while an asset is bytes, so this
  /// is the single step between them, with input failures checked up front.
  ///
  /// [file] is a path the caller chooses: the right directory is application
  /// knowledge, and on mobile it is the application support directory, which
  /// this package cannot resolve without a Flutter dependency.
  ///
  /// Empty or non-PEM [pemBytes] is an error here rather than a handshake
  /// failure later.
  static Future<MssqlTlsTrust> installPemBundle(
    List<int> pemBytes, {
    required String file,
    bool validateHostname = true,
    String? expectedHostname,
  }) async {
    if (pemBytes.isEmpty) {
      throw ArgumentError.value(
        pemBytes,
        'pemBytes',
        'The certificate bundle is empty. Check that the asset is declared '
            'and was loaded before this call.',
      );
    }
    const header = '-----BEGIN CERTIFICATE-----';
    final head = String.fromCharCodes(
      pemBytes.take(4096).map((byte) => byte & 0x7f),
    );
    if (!head.contains(header)) {
      throw ArgumentError.value(
        '${pemBytes.length} bytes',
        'pemBytes',
        'This is not a PEM certificate bundle: no "$header" line. A DER '
            'certificate has to be converted first, and an error page fetched '
            'instead of a bundle looks exactly like this.',
      );
    }
    final target = File(file);
    await target.parent.create(recursive: true);
    await target.writeAsBytes(pemBytes, flush: true);
    return MssqlTlsTrust(
      certificateAuthorityFile: target.path,
      validateHostname: validateHostname,
      expectedHostname: expectedHostname,
    );
  }

  /// Whether the server's certificate is checked at all.
  bool get verifiesCertificate => certificateAuthorityFile != null;

  /// Whether FreeTDS needs a generated `freetds.conf` to honour this.
  ///
  /// [MssqlTlsTrust.insecureNoVerification] needs none: it is what FreeTDS
  /// does when told nothing.
  bool get requiresConfigurationFile =>
      certificateAuthorityFile != null ||
      certificateRevocationFile != null ||
      expectedHostname != null;

  /// One line naming what is trusted, for a diagnostic or a log.
  String describe() {
    final ca = certificateAuthorityFile;
    if (ca == null) return 'encrypted, certificate not verified';
    final host = expectedHostname;
    return 'verified against ${ca == 'system' ? 'OpenSSL default paths' : ca}'
        '${validateHostname ? '' : ', hostname not checked'}'
        '${host == null ? '' : ', hostname expected to be $host'}';
  }

  /// Renders the `[global]` section FreeTDS reads.
  ///
  /// Kept a pure function so the file's contents can be inspected without
  /// writing anything to disk.
  String toConfig() => '[global]\n${configSettings()}';

  /// The trust settings alone, without the `[global]` header, so the runtime
  /// can write them into one file next to settings of its own.
  String configSettings() {
    final out = StringBuffer();
    final ca = certificateAuthorityFile;
    if (ca != null) out.writeln('\tca file = $ca');
    final crl = certificateRevocationFile;
    if (crl != null) out.writeln('\tcrl file = $crl');
    out.writeln(
      '\tcheck certificate hostname = ${validateHostname ? 'yes' : 'no'}',
    );
    final expected = expectedHostname;
    // The FreeTDS constant is named TDS_STR_SSLHOSTNAME but its value is
    // "certificate hostname". An unrecognised key is ignored silently, so the
    // wrong spelling would skip the override and verify the real host.
    if (expected != null) out.writeln('\tcertificate hostname = $expected');
    return out.toString();
  }

  void validate() {
    final ca = certificateAuthorityFile;
    if (ca != null && ca.trim().isEmpty) {
      throw ArgumentError.value(ca, 'certificateAuthorityFile');
    }
    if (certificateRevocationFile != null && ca == null) {
      throw ArgumentError(
        'A revocation list is only consulted when a CA file is set.',
      );
    }
    if (expectedHostname != null && !validateHostname) {
      throw ArgumentError(
        'expectedHostname is pointless when validateHostname is false.',
      );
    }
    if (expectedHostname != null && ca == null) {
      throw ArgumentError(
        'expectedHostname is only matched when a CA file is set; without one '
        'the certificate, and therefore its name, is not checked.',
      );
    }
  }

  /// Value equality, so that the runtime can tell a repeated configuration
  /// from a conflicting one.
  @override
  bool operator ==(Object other) =>
      other is MssqlTlsTrust &&
      other.certificateAuthorityFile == certificateAuthorityFile &&
      other.certificateRevocationFile == certificateRevocationFile &&
      other.validateHostname == validateHostname &&
      other.expectedHostname == expectedHostname;

  @override
  int get hashCode => Object.hash(
    certificateAuthorityFile,
    certificateRevocationFile,
    validateHostname,
    expectedHostname,
  );

  @override
  String toString() => 'MssqlTlsTrust(${describe()})';
}

/// How one [MssqlConnectionPool] behaves.
///
/// Every default is deliberately small: a pool is a queue in front of a shared
/// server, and large numbers move contention onto SQL Server, where it costs
/// worker threads and lock waits instead of a short client-side wait.
@immutable
class MssqlPoolConfig {
  const MssqlPoolConfig({
    this.minimumSize = MssqlDefaults.poolMinimumSize,
    this.maximumSize = MssqlDefaults.poolMaximumSize,
    this.acquireTimeout = MssqlDefaults.poolAcquireTimeout,
    this.idleTimeout = MssqlDefaults.poolIdleTimeout,
    this.validationGracePeriod = MssqlDefaults.poolValidationGracePeriod,
  });

  /// Connections opened by `warmUp` and kept even when idle.
  final int minimumSize;

  /// The most connections this pool will own.
  ///
  /// Raising it is performance tuning that needs a measurement: the right
  /// number depends on how long the workload holds a connection and what else
  /// is connected to the same server.
  final int maximumSize;

  /// The budget for a whole `acquire`, not just for queueing.
  ///
  /// Queueing behind other borrowers, validating an idle connection and
  /// opening a new one all come out of it, retries included.
  final Duration acquireTimeout;

  /// How long a connection above [minimumSize] may sit idle before it is
  /// closed instead of reused.
  final Duration idleTimeout;

  /// Connections released more recently than this are not validated on the
  /// next `acquire`.
  ///
  /// A ping is a full round trip, so skipping it saves one per query.
  /// `Duration.zero` (the default) validates on every reuse; a non-zero value
  /// trades the round trip for a window in which a connection that died
  /// meanwhile is handed out as live, costing the borrower one failed query.
  /// Measure the workload before choosing a number.
  final Duration validationGracePeriod;

  void validate() {
    if (minimumSize < 0) throw RangeError.value(minimumSize, 'minimumSize');
    if (maximumSize < 1) throw RangeError.value(maximumSize, 'maximumSize');
    if (minimumSize > maximumSize) {
      throw ArgumentError('minimumSize cannot exceed maximumSize');
    }
    if (acquireTimeout <= Duration.zero) {
      throw ArgumentError.value(acquireTimeout, 'acquireTimeout');
    }
    if (idleTimeout <= Duration.zero) {
      throw ArgumentError.value(idleTimeout, 'idleTimeout');
    }
    // Zero means "validate every reuse"; negative would silently become zero
    // and hide a config mistake.
    if (validationGracePeriod < Duration.zero) {
      throw ArgumentError.value(
        validationGracePeriod,
        'validationGracePeriod',
        'cannot be negative; zero validates on every reuse',
      );
    }
  }
}
