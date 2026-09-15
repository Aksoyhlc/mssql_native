# mssql_native

Microsoft SQL Server client for Dart and Flutter.

`mssql_native` is a complete database client: connections and pooling,
transactions and savepoints, streaming results, cancellation, stored
procedures, table-valued parameters and bulk copy. It talks to SQL Server
directly, from a Flutter application, a Dart server or a command-line tool.

The native SQL Server client libraries travel inside the package. Adding the
dependency is the whole installation — on your machine, on your build server
and on the machine that eventually runs the application.

It is also the base of a three-package suite. Each layer is optional, and all
three share one session type, so a generated query, a composed query and
hand-written SQL can run inside the same transaction:

| Package | Adds |
|---|---|
| `mssql_native` | the driver |
| [`mssql_orm`](https://pub.dev/packages/mssql_orm) | a typed query builder and a database-first ORM runtime |
| [`mssql_orm_dev`](https://pub.dev/packages/mssql_orm_dev) | generates that ORM from your schema |

```dart
final orders = await connection.queryTypedRows(
  '''
  SELECT o.id, o.code, o.total, c.name AS customer
  FROM dbo.orders AS o
  JOIN dbo.customers AS c ON c.id = o.customer_id
  WHERE o.status = @status AND o.placed_at >= @since
  ORDER BY o.placed_at DESC
  ''',
  parameters: {'status': 'open', 'since': DateTime(2026, 1, 1)},
);

for (final order in orders) {
  print('${order.require<String>('code')}  '
      '${order.require<String>('customer')}  '
      '${order.require<MssqlDecimal>('total')}');
}
```

Parameters are sent separately from the statement, so a value can never become
part of the SQL text.

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Getting started](#getting-started)
- [Queries and parameters](#queries-and-parameters)
- [Transactions](#transactions)
- [Connection pooling](#connection-pooling)
- [Streaming and cancellation](#streaming-and-cancellation)
- [Stored procedures](#stored-procedures)
- [Bulk copy](#bulk-copy)
- [Encryption and certificate trust](#encryption-and-certificate-trust)
- [Execution settings](#execution-settings)
- [Error handling](#error-handling)
- [Deployment](#deployment)
- [Platform support](#platform-support)
- [Documentation](#documentation)

## Requirements

- Dart 3.10 or later; Flutter 3.38 or later for Flutter applications
- SQL Server 2008 or later, or Azure SQL
- One of the supported targets listed under [Platform support](#platform-support)

A server older than SQL Server 2016 that never received the TLS 1.2 update
needs one extra line at startup; see
[Old servers](#old-servers).

The package uses a build hook to bundle its native libraries in Dart and
Flutter applications. A standalone Dart SDK can resolve the package for a
server or CLI; Flutter applications use the same Dart API and import path.
The runtime does not import Flutter libraries.

## Install

```yaml
dependencies:
  mssql_native: ^0.0.2
```

The build hook packages the native libraries during `dart run`,
`dart build cli` and Flutter builds, including Android and iOS. There is no
separate build step and nothing to configure.

## Getting started

```dart
import 'package:mssql_native/mssql_native.dart';

Future<void> main() async {
  await MssqlRuntime.instance.initialize();

  final connection = await MssqlConnection.connect(
    host: 'sql.example.com',
    database: 'warehouse',
    username: 'app',
    password: password,
  );

  try {
    final products = await connection.queryRows(
      'SELECT id, name, price FROM dbo.products WHERE is_active = @active',
      parameters: {'active': true},
    );

    for (final product in products) {
      print('${product['name']}: ${product['price']}');
    }
  } finally {
    await connection.close();
    await MssqlRuntime.instance.shutdown();
  }
}
```

`MssqlRuntime.instance.initialize()` loads the native libraries once per
process. Call it before the first connection and shut it down when the
application ends.

In a Flutter application both calls belong in `main()`, before `runApp`, so no
widget can reach an uninitialized runtime:

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await MssqlRuntime.instance.initialize();

  final connection = await MssqlConnection.connect(
    host: 'sql.example.com',
    database: 'warehouse',
    username: 'app',
    password: await const FlutterSecureStorage().read(key: 'db_password'),
  );

  runApp(MyApp(connection: connection));
}
```

One long-lived connection serves a typical application. Open a
[pool](#connection-pooling) when several parts of it query concurrently.

### Windows authentication

A domain account logs in the same way a SQL Server login does, with the domain
in the user name. This is NTLMv2, and it works from Windows, macOS, Linux and
Android:

```dart
final connection = await MssqlConnection.connect(
  host: 'sql.example.com',
  database: 'warehouse',
  username: r'CONTOSO\aksoyhlc',
  password: password,
);
```

Integrated security logs in as the Windows account already running the
process, with no password anywhere:

```dart
final connection = await MssqlConnection.connectIntegrated(
  host: 'sql.example.com',
  database: 'warehouse',
);
```

That one is Windows-only. It goes through SSPI, which the packaged FreeTDS
carries on Windows and nowhere else, so the configuration is refused on macOS,
Linux and Android before a connection is attempted rather than failing at login
with a message that explains nothing. Use the domain account and password above
from those platforms.

### Connection strings

An existing .NET connection string works as it is:

```dart
final connection = await MssqlConnection.connectString(
  Platform.environment['MSSQL_CONNECTION_STRING']!,
);
```

Keys are matched the way SqlClient matches them: case and inner spacing are
ignored, the usual synonyms are understood, and quoted values are parsed.

`Integrated Security=true`, `Integrated Security=SSPI` and
`Trusted_Connection=yes` all ask for [Windows
authentication](#windows-authentication) and are honoured on Windows. A `User
Id` in the same string is refused rather than quietly dropped, because dropping
it is how a string that names a login connects as somebody else.

Other keys this driver cannot honour are refused with the alternative named,
rather than ignored. `host\INSTANCE` needs to be written as `host,port`.
`TrustServerCertificate` is a process-wide decision and belongs in
[`MssqlRuntime.initialize`](#encryption-and-certificate-trust). Keys with no
meaning to this driver are reported through an `onUnsupportedKeys` callback
instead of disappearing silently.

If a connection string is rejected, the exception carries it with the password
masked.

## Queries and parameters

Each result shape has its own method, so the return type matches what you
expect to get back:

```dart
final count = await connection.queryScalar<int>('SELECT COUNT(*) FROM dbo.orders');
final one   = await connection.querySingle(sql, parameters: {'id': 42});
final maybe = await connection.querySingleOrNull(sql, parameters: {'id': 42});
final rows  = await connection.queryRows(sql, parameters: {'id': 42});
final n     = await connection.execute(updateSql, parameters: {'id': 42});
```

`queryRows` returns a list of maps. The typed variants return `MssqlRow`,
which reads columns by name or ordinal without a cast:

```dart
final row     = await connection.queryTypedSingle(sql, parameters: {'id': 42});
final id      = row.require<int>('id');            // throws if the column is NULL
final balance = row.get<MssqlDecimal>('balance');  // null-safe
```

Parameters are named. The `@` is optional in the key, and types are inferred
from the Dart value for `bool`, `int`, `double`, `String`, `DateTime` and
`Uint8List`:

```dart
final customers = await connection.queryRows(
  'SELECT id, name, city FROM dbo.customers '
  'WHERE company_id = @companyId AND is_active = @active AND created_at >= @since',
  parameters: {
    'companyId': 12,
    'active': true,
    'since': DateTime(2026, 1, 1),
  },
);
```

Writes return the number of affected rows, and use the same parameter style:

```dart
final updated = await connection.execute(
  'UPDATE dbo.stock SET quantity = quantity - @amount WHERE id = @id',
  parameters: {'amount': 2, 'id': 10},
);
```

`OUTPUT` gives you the generated key in one round trip:

```dart
final newId = await connection.queryScalar<int>(
  'INSERT INTO dbo.customers (name) OUTPUT INSERTED.Id VALUES (@name)',
  parameters: {'name': 'Ada Ltd.'},
);
```

A user-typed search term needs its `LIKE` metacharacters escaped before it is
bound:

```dart
final pattern = '%${MssqlSql.escapeLike(searchTerm)}%';
final matches = await connection.queryRows(
  'SELECT id, name FROM dbo.products WHERE name LIKE @pattern',
  parameters: {'pattern': pattern},
);
```

### Naming the SQL type

Inference cannot type a bare `null`, and an inferred size may be wider than
the column, which can cost an index seek. Both are spellable:

```dart
await connection.execute(
  'UPDATE dbo.customers SET note = @note, city = @city WHERE id = @id',
  parameters: {
    'note': const MssqlValue.nvarchar(null, size: 200),
    'city': const MssqlValue.varchar('İstanbul', size: 50),
    'id': 12,
  },
);
```

`MssqlValue` has a named constructor for every SQL type: `bit`, `tinyInt`,
`smallInt`, `int32`, `int64`, `real`, `float64`, `decimal` and `numeric`,
`money` and `smallMoney`, `char`, `nchar`, `varchar` and `nvarchar`, `text`
and `ntext`, `binary`, `varbinary` and `image`, `date`, `time`,
`smallDateTime`, `dateTime`, `dateTime2`, `dateTimeOffset`,
`uniqueIdentifier` and `xml`.

`MssqlParameter` is the same idea with the direction spelled out, for the
cases where `input` is not what you want:

```dart
final result = await connection.queryRows(
  sql,
  parameters: [
    const MssqlParameter.int32('companyId', 12),
    MssqlParameter.dateTime2('since', DateTime(2026, 1, 1)),
  ],
);
```

### Types coming back

`DECIMAL`, `NUMERIC`, `MONEY` and `SMALLMONEY` are decoded as `MssqlDecimal`,
an exact base-10 value with arithmetic, comparison and explicit rounding.
`MssqlDecimalMode.text` and `MssqlDecimalMode.doublePrecision` are available
on the connection config when you would rather have a `String` or a `double`.

`datetime2(7)` and `datetimeoffset` resolve more finely than Dart's
`DateTime`, so they arrive as `MssqlDateTimeValue`, which converts with
`toDateTime()` when the extra digits do not matter.

`varchar` on a single-byte collation — Turkish, Greek, Cyrillic and the rest —
round-trips through iconv. `clientCharset` defaults to UTF-8 and nothing needs
hand-decoding.

## Transactions

```dart
await connection.transaction((tx) async {
  await tx.execute(
    'UPDATE dbo.stock SET quantity = quantity - 1 WHERE id = @id',
    parameters: {'id': 10},
  );
  await tx.execute(
    'INSERT INTO dbo.stock_moves (product_id) VALUES (@id)',
    parameters: {'id': 10},
  );
}, isolationLevel: MssqlIsolationLevel.snapshot);
```

`tx` is an `MssqlSession`, the same interface a connection and a pool expose.
Moving existing code inside a transaction changes nothing about it.

Returning from the callback commits. Throwing rolls back and rethrows your
error, not the rollback's.

A savepoint scopes part of the work, so that rolling it back leaves the
surrounding transaction open:

```dart
await connection.transaction((tx) async {
  await tx.execute('INSERT INTO dbo.orders …', parameters: {…});

  try {
    await tx.savepoint(() async {
      await tx.execute('INSERT INTO dbo.notifications …');
    });
  } on MssqlException {
    // The notification failed; the order still commits.
  }
});
```

When SQL Server aborts the batch itself the transaction is doomed and a
savepoint cannot rescue it. `tx.isDoomed` reports that state.

## Connection pooling

```dart
final pool = MssqlConnectionPool(
  config,
  poolConfig: const MssqlPoolConfig(minimumSize: 2, maximumSize: 8),
);
await pool.warmUp();

await pool.session.queryRows(sql);            // one statement, any connection
await pool.withConnection((c) async { … });   // several statements, one connection
await pool.transaction((tx) async { … });     // one lease for the whole callback
```

`pool.session` takes a lease per statement, which suits an independent query.
Anything that spans statements needs one connection for its whole life: a
transaction, an open stream, a `#temp` table, or a page and its total count.
`withConnection` and `transaction` are how you hold one.

`createdCount`, `idleCount` and `waitingCount` are available for a health
endpoint. A cancellation token covers the wait for a connection as well as the
work itself, so a cancelled request leaves the queue instead of holding its
place until the acquire timeout.

## Streaming and cancellation

`streamRows` reads a large result in bounded batches, so only the current
batch is in memory:

```dart
final sink = File('report.csv').openWrite();

await for (final row in connection.streamRows(
  'SELECT code, total FROM dbo.orders WHERE placed_at >= @since',
  parameters: {'since': DateTime(2026, 1, 1)},
  options: const MssqlQueryOptions(batchRows: 1000, queryName: 'report.export'),
)) {
  sink.writeln('${row.get<String>('code')},${row.get<MssqlDecimal>('total')}');
}

await sink.close();
```

Cancellation reaches the operation that is currently running against the
server, not only the Dart future:

```dart
final token = MssqlCancellationToken();
request.onDisconnect.then((_) => token.cancel('client left'));

await for (final row in connection.streamRows(sql, cancellationToken: token)) {
  …
}
```

A timeout and a deliberate cancellation stay distinguishable:
`MssqlQueryTimeoutException` and `MssqlCancelledException`.

A statement that returns several result sets is read through `stream`, whose
events are a sealed class:

```dart
await for (final event in connection.stream(sql)) {
  switch (event) {
    case MssqlResultSetStart(:final columns): …
    case MssqlRowBatch(:final rows): …
    case MssqlResultSetEnd(:final metrics): …
    case MssqlExecutionComplete(:final metrics): …
  }
}
```

## Stored procedures

```dart
final result = await connection.callProcedure(
  'dbo.create_label',
  parameters: {'company_id': 1},
  outputParameters: const {'label_number'},
);

print(result.outputParameters['label_number']);
print(result.returnStatus);
print(result.resultSets.length);
```

Parameter types, sizes and output capability are read from the procedure's own
metadata and cached per connection for ten minutes. After an
`ALTER PROCEDURE`, call `invalidateMetadata(object: 'dbo.create_label')`
rather than waiting for the cache to expire.

A parameter you leave out stays out, so the procedure's own `DEFAULT` applies.
Passing `null` is a different call.

Table-valued parameters are supported. The table is assembled on the server:
the rows are bulk-copied into a staging table and copied from there into a
variable of the procedure's table type.

```dart
parameters: {'moves': MssqlTableRows([{'product_id': 11, 'amount': -2}])}
```

## Bulk copy

```dart
final result = await connection.bulkInsert(
  tableName: 'dbo.label_events',
  rows: events.map((e) => {'reader_id': e.readerId, 'epc': e.epc}),
  options: const MssqlBulkOptions(
    batchSize: 5000,
    mode: MssqlBulkMode.batched,
    tableLock: true,
  ),
  onProgress: (sent) => print('sent $sent rows'),
);

print('${result.insertedRows}/${result.totalRows} in ${result.elapsed}');
```

`rows` is a lazy `Iterable` consumed in bounded chunks, so a generator or a
file reader never has to be materialized in full. `MssqlBulkMode.atomic` rolls
the whole copy back on failure; `batched` keeps the batches that already
committed.

Identity, computed, hidden and `rowversion` columns are protected unless the
options say otherwise. `bulkInsertRaw` skips the metadata lookup when you want
to declare every column's SQL type yourself.

## Encryption and certificate trust

These are two separate settings, and they are configured in two places
because SQL Server and FreeTDS treat them differently.

**Encryption is per connection.** The default is `MssqlEncryption.off`, which
is FreeTDS's own behaviour. `request`, `require` and `strict` are the
alternatives.

**Certificate trust is per process**, because FreeTDS reads it from a
configuration file located through an environment variable. Configure it once,
before the first connection:

```dart
await MssqlRuntime.instance.initialize(tls: const MssqlTlsTrust.system());

final connection = await MssqlConnection.connect(
  host: 'sql.example.com',
  database: 'warehouse',
  username: 'app',
  password: password,
  encryption: MssqlEncryption.require,
);
```

Asking for encryption without configuring trust would produce a session that
is encrypted but accepts any certificate, which is indistinguishable from a
verified one. The driver refuses to connect instead, and the error names what
to add.

`MssqlTlsTrust.system()` uses OpenSSL's default certificate paths. Those paths
are normally empty on iOS, Android and Windows, so ship a PEM bundle there:

```dart
await MssqlRuntime.instance.initialize(
  tls: const MssqlTlsTrust(certificateAuthorityFile: '/etc/ssl/corp-ca.pem'),
);

// or from an asset, on mobile:
await MssqlRuntime.instance.initialize(
  tls: await MssqlTlsTrust.installPemBundle(bytes, file: '$support/roots.pem'),
);
```

`MssqlTlsTrust.insecureNoVerification()` encrypts without verifying, for a
self-signed certificate on a private segment. It has to be written out, which
is the point.

Calling `initialize` twice with different trust is an error rather than a
silent no-op, so a second caller cannot believe it configured trust while open
connections kept the first caller's.

All supported platforms ship with TLS available. No rebuild is needed to turn
it on.

### Old servers

TDS 7.1 and later encrypt the login packet whatever `MssqlEncryption` says.
That is the protocol, not a setting, so the handshake happens even on a
connection that will otherwise be plaintext.

SQL Server 2014 and earlier that never received the TLS 1.2 update offer only
TLS 1.0 there, with a self-signed SHA-1 certificate, and both FreeTDS and
OpenSSL decline it. The result is a connection failure during login. Applying
the server's TLS 1.2 update is the real fix. Where that is not possible:

```dart
await MssqlRuntime.instance.initialize(allowLegacyTlsLogin: true);
```

This is process-wide and weakens the login handshake of every connection the
process opens, so it is a deliberate call. It changes neither session
encryption nor certificate verification. See
[doc/TLS.md](doc/TLS.md#old-servers-and-the-login-handshake).

**Statement text and parameter values never appear in an exception or a log
line.** A `WHERE` clause with a literal in it, or a password on its way into a
users table, becomes a secret the moment it is logged. Label a statement with
`MssqlQueryOptions(queryName: …)` and the label is what appears instead.

## Execution settings

Timeouts, limits, cancellation and the statement label live in one object that
every layer accepts under the same argument names:

```dart
const reportOptions = MssqlQueryOptions(
  timeout: Duration(minutes: 2),
  maximumRows: 100000,
  maximumBytes: 64 * 1024 * 1024,
  queryName: 'reports.dailyTurnover',
);

await session.queryRows(sql, options: reportOptions);
await session.queryRows(sql, options: reportOptions, timeout: shortTimeout);
await session.queryRows(sql, options: reportOptions.limitedTo(500));
```

`maximumRows` is a ceiling, not paging: a result that exceeds it fails rather
than arriving truncated.

Retry is `MssqlRetryPolicy.never` by default, and stays there for arbitrary
SQL, stored procedures and anything inside a transaction. Returning rows is
not evidence that a statement only reads — `INSERT … OUTPUT` returns rows too.
`MssqlRetryPolicy.idempotentRead` re-runs once after a lost connection, and is
an assertion you are making about the statement.

## Error handling

`MssqlException` covers everything the database refused. The failures that
call for different handling have their own types:

```dart
try {
  await connection.execute(sql, parameters: params);
} on MssqlConstraintException catch (e) {
  if (e.isDuplicateKey) return Conflict('already exists');
  return BadRequest(e.message);
} on MssqlQueryTimeoutException {
  return GatewayTimeout();                 // may still be running on the server
} on MssqlUnknownCommitOutcomeException {
  // The commit was sent and the answer was lost. Do not repeat the work.
  return await reconcileFromDatabase();
} on MssqlConnectionException catch (e) {
  return e.mayHaveRun ? Unknown() : Retryable();
} on MssqlAuthenticationException {
  return Fatal('credentials refused; retrying cannot help');
} on MssqlTlsException {
  return Fatal('certificate trust is a configuration problem');
} on MssqlPoolTimeoutException {
  return TooBusy();                        // the server was never asked
}
```

Every exception carries SQL Server's message number as `code`, its state as
`state`, the server messages as `diagnostics`, your `queryName`, and a `type`
suitable for a `switch`.

`MssqlUnknownCommitOutcomeException` is worth knowing about: it is raised when
a commit was sent and the connection dropped before the answer arrived. The
outcome is genuinely unknown, and the correct response is to read the database
rather than retry.

In a server, that mapping is usually one place:

```dart
Future<Response> createCustomer(Request request) async {
  try {
    final id = await db.customers.create(CustomerCreate(…));
    return Response.ok(jsonEncode({'id': id}));
  } on MssqlConstraintException catch (e) {
    if (e.isDuplicateKey) {
      return Response(409, body: jsonEncode({'error': 'email already registered'}));
    }
    return Response(400, body: jsonEncode({'error': 'invalid data'}));
  } on MssqlQueryTimeoutException {
    return Response(504);
  } on MssqlConnectionException {
    return Response(503);
  } on MssqlException {
    return Response(500);
  }
}
```

## Deployment

**Flutter.** Build normally. The binaries for the target are bundled into the
application.

```bash
flutter build windows
```

**Dart server or CLI.** Use `dart build cli` and distribute the whole bundle.
`dart compile exe` does not run build hooks and would produce an executable
without its native libraries.

```bash
dart build cli --target=bin/main.dart --output=build/release
# ship all of build/release/bundle/
```

**Docker.** The CLI example includes a Dockerfile. It resolves and builds in a
Dart image, then copies the bundle into a `FROM scratch` image with the
Dart runtime filesystem and glibc's gconv converters — the driver runs every
string through iconv, which loads those at runtime:

```bash
docker build --platform linux/amd64 -f example_cli/Dockerfile -t mssql-cli .
docker run --rm --env-file database.env mssql-cli
```

Serverpod and Dart Frog use the same native-asset bundling.

Runnable examples in this repository:

| | |
|---|---|
| [`example/`](example/) | Flutter application |
| [`example_cli/`](example_cli/README.md) | Dart CLI, with Docker packaging |
| [`example_dart_frog/`](example_dart_frog/README.md) | Dart Frog server |

## Platform support

| Platform | Architectures | Minimum |
|---|---|---|
| Windows | x64 | 64-bit Windows |
| Linux | x64 | glibc 2.34 |
| macOS | arm64, x86_64 | 11.0 on Apple Silicon, 10.15 on Intel |
| iOS | arm64 device, arm64 and x86_64 simulator | 13.0, or 14.0 for the arm64 simulator |
| Android | arm64-v8a, x86_64 | API 24 |

Web, 32-bit Android, ARM64 Linux and ARM64 Windows are not packaged. A build
for one of them fails at build time rather than at runtime. The bundled
FreeTDS source can be rebuilt for a different target; the build documents are
under [`doc/maintainer/`](doc/maintainer/).

A connection runs one operation at a time — SQL Server MARS is not used — so
concurrent work belongs on separate pooled connections. Named instances
(`host\INSTANCE`) are not resolved; give `host,port`.

## Documentation

| | |
|---|---|
| [Examples](doc/EXAMPLES.md) | every feature, with working code |
| [API guide](doc/API.md) | types, rows, procedures, bulk copy, streaming, transactions |
| [TLS](doc/TLS.md) | encryption and certificate trust in detail |
| [Dart server and CLI](doc/DART_SERVER_CLI.md) | bundles, Docker, Serverpod, Dart Frog |
| [Architecture](doc/ARCHITECTURE.md) | how the driver is put together |
| [Capabilities](doc/CAPABILITIES.md) | defaults and limits at a glance |
| [Third-party notices](doc/THIRD_PARTY_NOTICES.md) | bundled components and their licenses |

The package also ships `skills/mssql-native-usage/SKILL.md` for compatible AI
coding agents.

## License

MIT. See [LICENSE](LICENSE). Bundled third-party components keep their own
licenses; see [doc/THIRD_PARTY_NOTICES.md](doc/THIRD_PARTY_NOTICES.md).
