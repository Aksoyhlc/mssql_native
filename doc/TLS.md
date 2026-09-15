# Encrypted connections

The driver separates two decisions:

1. `MssqlConnectionConfig.encryption` chooses how much of a connection must be
   encrypted.
2. `MssqlRuntime.initialize(tls: ...)` chooses how the process trusts server
   certificates.

Certificate trust is process-wide: it is configured once per process and
cannot be changed independently for each connection.

## Encryption modes

| Mode | Behavior |
|---|---|
| `MssqlEncryption.off` | Only SQL Server's login packet protection; the session is otherwise plaintext; package default |
| `MssqlEncryption.request` | Accept server-forced encryption but do not require an encrypted session |
| `MssqlEncryption.require` | Require the complete session to be encrypted |
| `MssqlEncryption.strict` | Establish TLS before the login packet; requires SQL Server 2022/Azure strict support |

`request` does not mean “encrypt when possible.” Against a server that does
not force encryption, it produces an unencrypted session. Use `require` when
encryption is required.

No TLS initialization is needed for the default `off` mode. Trust becomes
required only after an application explicitly selects `require` or
`strict`.

## Trust choices

### Verify against a PEM bundle

```dart
await MssqlRuntime.instance.initialize(
  tls: MssqlTlsTrust(
    certificateAuthorityFile: '/app/certificates/company-ca.pem',
  ),
);
```

The file must exist and be non-empty. Initialization stops rather than letting
a missing CA file be interpreted as no verification.

Use `expectedHostname` when the network address differs from the certificate
name:

```dart
await MssqlRuntime.instance.initialize(
  tls: MssqlTlsTrust(
    certificateAuthorityFile: '/app/certificates/company-ca.pem',
    expectedHostname: 'sql.internal.example',
  ),
);
```

### Use system default trust paths

```dart
await MssqlRuntime.instance.initialize(
  tls: const MssqlTlsTrust.system(),
);
```

This asks the native client to use its default CA paths. It does not bridge to
Apple Keychain, Android's native trust store, or the Windows certificate store.
Servers and configured desktop environments may have usable default trust
paths; mobile and Windows application bundles commonly need an explicit PEM
bundle.

### Encrypt without verification

```dart
await MssqlRuntime.instance.initialize(
  tls: const MssqlTlsTrust.insecureNoVerification(),
);
```

This prevents passive wire reading but accepts any certificate. The explicit
name exists so this weaker choice cannot happen accidentally. Do not present it
as certificate authentication.

### Install bytes as a PEM file

Assets and downloaded bundles are bytes, while certificate trust is configured
by file path:

```dart
final trust = await MssqlTlsTrust.installPemBundle(
  pemBytes,
  file: '/application-support/sql-ca.pem',
);

await MssqlRuntime.instance.initialize(tls: trust);
```

The application chooses a persistent, readable location. The helper rejects an
empty payload or content without a PEM certificate header.

## Fail-closed encrypted modes

`MssqlEncryption.require` and `strict` are refused before login if runtime
trust has not been configured. A native build without a TLS backend also
rejects trust configuration and encrypted modes.

A second call to `MssqlRuntime.initialize` may repeat the same trust setting.
A conflicting setting is rejected because trust is process-wide in the driver.

Initialize once at startup, before opening a connection or pool.

## Connection strings

`MssqlConnectionConfig.fromConnectionString` understands `Encrypt`, but
rejects `TrustServerCertificate`. Certificate trust is not a per-connection
setting in this driver. Remove that key and express the decision through
`MssqlRuntime.initialize`.

Unsupported security keys are not silently discarded. Pass
`onUnsupportedKeys` only when the application deliberately handles
non-security keys that have no driver equivalent.

## Platform notes

| Platform | TLS | Trust source |
|---|---|---|
| Windows x64 | Included | Explicit PEM or system default paths |
| Linux x64 | Included | Explicit PEM or system default paths |
| macOS | Included | Explicit PEM or system default paths |
| iOS | Included | Normally an application-installed PEM |
| Android | Included | Normally an application-installed PEM |

The native backend is included; certificate trust is still an application
configuration decision.

## Old servers and the login handshake

TDS 7.1 and later encrypt the login packet whatever `MssqlEncryption` says.
That is part of the protocol, not a setting, so the login handshake happens
even on a connection that will otherwise be plaintext.

SQL Server 2014 and earlier that never received the TLS 1.2 update offer only
TLS 1.0 for that handshake, with a self-signed SHA-1 certificate. FreeTDS
disables TLS 1.0 by default, and OpenSSL 3 rejects the certificate at its
default security level, so the connection fails during login with FreeTDS
error 20002 — an ordinary "connection failed", which is why the driver adds a
line naming this cause.

Two ways forward, in order of preference:

1. Apply the server's TLS 1.2 update. For SQL Server 2014 that is SP3 plus
   KB3135244. This is the real fix and leaves every client's security intact.
2. Permit the old handshake for this process:

```dart
await MssqlRuntime.instance.initialize(allowLegacyTlsLogin: true);
```

That writes two FreeTDS settings: `enable tls v1`, which clears FreeTDS's own
refusal, and `openssl ciphers = DEFAULT@SECLEVEL=0`, which lowers OpenSSL's
security level enough to accept the certificate. Both are needed; neither
works alone.

It is process-wide and it weakens the login handshake of every connection the
process opens, including those to modern servers. It does not change session
encryption, which `MssqlEncryption` still decides, and it does not relax
certificate *verification*, which `MssqlTlsTrust` still decides.

`tdsVersion: '7.0'` is a third option and is not recommended. TDS 7.0 predates
login encryption, so it sidesteps the handshake entirely, but it also predates
`date`, `time`, `datetime2`, `datetimeoffset` and the `max` types, and the
server will convert or refuse accordingly.

## Multiple private authorities

One process that connects to servers signed by different private authorities
needs one PEM bundle containing every authority it intends to trust. Trust
cannot be replaced while other connections remain open.

## Diagnosing failures

- `MssqlTlsException.configuration` reports a program or deployment setting
  detected before transport, such as a missing CA file or conflicting runtime
  initialization.
- `MssqlTlsException` with `MssqlErrorType.tls` reports a connect-time trust
  or encryption failure.
- Authentication failures remain `MssqlAuthenticationException`; changing TLS
  settings does not fix invalid SQL credentials.

The runtime diagnostics report whether the packaged native client supports
TLS and which trust decision was applied. They do not expose credentials.

To confirm the server's view from an established session, query
`sys.dm_exec_connections.encrypt_option` under permissions appropriate for
the application account.
