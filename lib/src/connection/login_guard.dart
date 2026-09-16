import '../exception.dart';
import '../models/config.dart';
import '../models/types.dart';
import '../runtime.dart';

/// Adds the one cause of a failed login that nothing else can report.
///
/// TDS 7.1 and later encrypt the login packet whatever `encryption` says, so
/// a server that offers only TLS 1.0 there is refused during the handshake.
/// FreeTDS reports that as an ordinary "connection failed", which sends
/// people to look at firewalls and credentials. The hint is added only when
/// the configuration could actually be hitting it.
MssqlException withLoginHandshakeHint(
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
void ensureTransportIsTrusted(
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

/// The TDS protocol version FreeTDS reports for a live connection.
String tdsVersionName(int code) => switch (code) {
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
