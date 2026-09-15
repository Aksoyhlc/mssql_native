# Architecture

```text
Public Dart API (MssqlSession)
  -> per-connection operation gate
  -> SendPort / ReceivePort
  -> one worker isolate per MssqlConnection
  -> dart:ffi
  -> packaged native client
  -> Microsoft SQL Server
```

Most of the driver is Dart. Below the `dart:ffi` boundary the packaged native
client library, its layout, and its rebuild steps live with the source in
`native/` and `hook/`; maintainer documentation is under `doc/maintainer/`.

## Public boundary

`lib/mssql_native.dart` is the public barrel. `MssqlSession` in
`lib/src/session.dart` defines the common primitive operations:

- `query`
- `callProcedure`
- `stream`
- `ping`
- `bulkInsert`

Convenience terminals such as `queryRows`, `querySingle`, `execute`, and
`streamRows` are derived once on that contract. `MssqlConnection`,
`MssqlTransaction`, the pool's per-operation session, and the ORM's observed
session use the same surface.

There is no MethodChannel or platform host adapter; the same `dart:ffi` path
serves Flutter and plain Dart.

## One isolate per connection

Native calls block, and one native connection cannot safely serve concurrent
commands. Each `MssqlConnection` therefore owns a worker isolate and a single
native connection for its lifetime. The operation gate in
`lib/src/connection.dart` queues commands before they reach that worker.

Consequences:

- Operations on one connection are serialized.
- Independent concurrency requires multiple pooled connections.
- A stream holds its connection until it completes or is cancelled.
- Reconnection replaces the worker and native connection; it does not attempt
  to repair a dead native handle in place.
- Transactions lease the connection until commit/rollback and close complete.

## Cancellation and deadlines

A worker blocked in a native read cannot read another Dart port message.
Cancellation therefore marks atomic native state associated with the
connection; the packaged native client observes it through the interrupt
callback running in the blocked operation. The Dart side never calls into the
native client for cancellation from the main isolate.

Deadlines are stored per connection. The implementation does not use a
process-global native timeout as the public timeout model, because one
connection's setting would leak into other isolates.

## Loading model

`hook/build.dart` stages the packaged native libraries for each supported
OS/architecture. Flutter places Android hook outputs in the APK and iOS hook
outputs in application frameworks.

The runtime resolves `@Native` anchor symbols through Dart code assets and
recovers the loaded module paths. It does not derive native-library locations
from the pub cache, script directory, or current working directory.

See [README · Deployment](../README.md#deployment).

## Pool and transaction ownership

`MssqlConnectionPool` owns the connections it opens.

- `pool.session` leases for one operation.
- `withConnection` holds one lease for a multi-statement callback.
- `pool.transaction` holds one lease for the complete transaction.
- `release` restores the session baseline or discards an unsafe connection.
- `close` drains tracked work and closes owned connections.

`MssqlTransaction` implements `MssqlSession` against its leased connection.
Nested work uses savepoints. A connection loss while waiting for `COMMIT`
raises `MssqlUnknownCommitOutcomeException`; the transaction is not retried.

## TLS configuration

Encryption is a connection setting; certificate trust is process-wide and is
configured once through `MssqlRuntime.initialize` before connections open. A
conflicting later configuration is refused.

`MssqlEncryption.require` and `strict` fail before login when no trust
decision exists. Verified and explicitly unverified TLS remain distinct
choices. See [TLS](TLS.md).

## Values and character conversion

Exact numeric families are decoded to invariant base-10 form and become
`MssqlDecimal` by default. Text and double modes are explicit alternatives.

Normal character conversion uses the packaged character-conversion support
with a UTF-8 client character set. Unicode bulk values are encoded as
UTF-16LE. Single-byte bulk conversion uses the implemented CP1252/CP1254
paths and rejects values that cannot be represented.

## Execution and recovery

`MssqlConnection.query` and `callProcedure` normalize options and
parameters, acquire the operation gate, execute on the worker, and classify
recorded diagnostics before returning. SQL text and parameter values are not
placed in errors; `MssqlQueryOptions.queryName` is the safe diagnostic label.

A dead process may be replaced so that a later command can use the connection.
That repair is separate from retry. Arbitrary SQL is not repeated. An explicit
`MssqlRetryPolicy.idempotentRead` allows one reconnect-and-repeat only outside
transactions and only when the caller has declared the statement safe.

## Authoritative code map

| Concern | Source |
|---|---|
| Public exports | `lib/mssql_native.dart` |
| Session contract | `lib/src/session.dart` |
| Connection lifecycle and gate | `lib/src/connection.dart` |
| Pool leasing | `lib/src/connection_pool.dart` |
| Transactions and savepoints | `lib/src/transaction.dart` |
| Runtime and TLS setup | `lib/src/runtime.dart`, `lib/src/models/config.dart` |
| Worker protocol | `lib/src/native/worker.dart` |
| Native callback recording | `native/src/handlers.c` |
| Code-asset staging | `hook/build.dart`, `hook/src/desktop.dart` |
