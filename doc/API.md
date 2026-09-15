# Public API guide

## Connecting

There are three ways in, and they are the same way: each one builds an
`MssqlConnectionConfig`, validates it and opens a connection. Nothing behaves
differently depending on which you used.

```dart
// 1. The four settings that have no sensible default.
final connection = await MssqlConnection.connect(
  host: 'sql.example.com',
  database: 'warehouse',
  username: 'app',
  password: password,
);

// 2. A configuration you keep, pass around and vary with copyWith.
const template = MssqlConnectionConfig(
  host: 'sql.example.com',
  database: 'warehouse',
  username: 'app',
  password: '…',
);
final reporting = await MssqlConnection.open(
  template.copyWith(
    database: 'warehouse_archive',
    defaultQueryTimeout: const Duration(minutes: 5),
  ),
);

// 3. A .NET-style connection string you already have.
final fromString = await MssqlConnection.connectString(
  'Server=tcp:sql.example.com,1433;Database=warehouse;'
  'User Id=app;Password=…',
);
```

`MssqlRuntime.instance.initialize()` is called for you by `open` if needed.
The default connection is plaintext. An explicitly encrypted connection needs
process-wide certificate trust and refuses to open without it.

### Windows authentication

Two different things, kept apart because they need different amounts of the
platform:

```dart
// A domain account and its password. NTLMv2, from any platform.
final domain = await MssqlConnection.connect(
  host: 'sql.example.com',
  database: 'warehouse',
  username: r'CONTOSO\aksoyhlc',
  password: password,
);

// The Windows account running the process. No password anywhere.
final integrated = await MssqlConnection.connectIntegrated(
  host: 'sql.example.com',
  database: 'warehouse',
);
```

The first is an ordinary configuration whose user name carries a backslash;
FreeTDS reads that as a domain login and authenticates over NTLMv2, which is
compiled into the packaged library on every platform.

The second sets `integratedSecurity` — also reachable as
`MssqlConnectionConfig.integratedSecurity(...)`, or as `Integrated
Security=true` in a connection string — and leaves the user name and password
empty, which is what asks FreeTDS to log in through SSPI as the current
Windows account. SSPI is compiled in on Windows only, so `validate()` refuses
the configuration on macOS, Linux and Android, naming the domain login as the
alternative. It refuses there rather than at login because FreeTDS answers an
empty user name off Windows with "requested GSS authentication but not
compiled in", which reaches a caller as a bare connection failure.

`copyWith` keeps the two apart as well: it refuses a user name on an
integrated configuration instead of carrying credentials that would be
ignored.

### Defaults

Every default lives in `MssqlDefaults` and nowhere else, so the answer to
"what happens if I say nothing" is one file rather than one per entry point.

| Setting | Default |
|---|---|
| `port` | 1433 (named instances are not resolved; give the port) |
| `clientCharset` | `UTF-8` |
| `tdsVersion` | `7.4` |
| `packetSize` | 0 — negotiated with the server |
| `loginTimeout` | 10 seconds |
| `defaultQueryTimeout` | 30 seconds, overridable per operation |
| `decimalMode` | `MssqlDecimalMode.exact` |
| `encryption` | `MssqlEncryption.off` |
| Certificate trust | none until `initialize(tls: ...)` says so |
| Retry | `MssqlRetryPolicy.never` |
| Pool | min 0, max 2, acquire 15s, idle 5min, grace 0 |

`decimalMode` is exact by default. Encryption is independent and defaults to
plaintext; opt into `MssqlEncryption.require` or `strict` when needed.

### Connection strings

Keys are matched the way SqlClient matches them, case and inner spaces
ignored, with the usual synonyms. Nothing is ignored:

* `Integrated Security=true` (also `=SSPI`, and `Trusted_Connection=yes`)
  builds an integrated-security configuration; see above for where it runs. A
  `User Id` or `Password` in the same string is refused rather than dropped,
  the way SqlClient drops it.
* A key that decides how the connection is secured but cannot be honoured is
  refused with a message naming the alternative. `TrustServerCertificate`
  (trust is process-wide — see doc/TLS.md), `Authentication`, `Column
  Encryption Setting`, `HostNameInCertificate`.
* A key with no meaning here is also refused, unless you pass
  `onUnsupportedKeys`, which is you saying "tell me about those and carry on".
* `Encrypt` absent means `off`, matching `MssqlDefaults.encryption`. This is
  deliberately unlike modern SqlClient, which defaults it to `true`: encryption
  is opt-in here, so say `Encrypt=true` (or pass `MssqlEncryption.require`) and
  configure trust through `MssqlRuntime.initialize(tls: ...)`.
* A named instance (`Server=host\SQLEXPRESS`) is refused: the driver does not
  resolve named instances through SQL Browser. Give `Server=host,1433`.

## Parameters

Queries accept Dart values by parameter name. Names may include or omit `@`.
The driver infers `bool`, signed 32/64-bit `int`, finite `double`, `String`,
`DateTime` and `Uint8List` values.

```dart
final rows = await connection.queryRows(
  'SELECT id, name FROM dbo.products '
  'WHERE company_id = @companyId AND active = @active',
  parameters: {'companyId': 12, 'active': true},
);
```

Plain `null` has no inferable SQL type. Use a name-free `MssqlValue` for nulls,
exact decimals or explicit sizes/types:

```dart
parameters: {
  'name': const MssqlValue.nvarchar(null, size: 100),
  'price': MssqlValue.decimal(
    '99999999999999.9999',
    precision: 18,
    scale: 4,
  ),
}
```

The original explicit form remains available for full control, including
stored-procedure parameter direction:

```dart
final result = await connection.query(
  'SELECT * FROM dbo.products WHERE company_id = @company_id',
  parameters: [MssqlParameter.int32('company_id', 12)],
);
```

`query` returns every result set, affected rows, output parameters, messages,
return status and client-observed metrics. `queryRows`, `querySingle`,
`querySingleOrNull`, `queryScalar<T>` and `execute` cover common result shapes.

## Rows

`queryRows`, `querySingle`, `querySingleOrNull`, `streamBatches` and
`MssqlResultSet.rows` retain their `Map<String, Object?>` results. Callers that
want indexed and typed access can opt into `queryTypedRows`,
`queryTypedSingle`, `queryTypedSingleOrNull`, `streamRows`, or
`MssqlResultSet.typedRows`.

```dart
final row = await connection.queryTypedSingle(
  'SELECT id, name, balance FROM dbo.customers WHERE id = @id',
  parameters: {'id': 42},
);

final id = row.require<int>('id');
final nullableBalance = row.get<double>('balance');
final firstValue = row.at(0);
final mapForJson = row.toMap();
```

Name access is exact. Duplicate result labels remain available by index and
produce a clear ambiguity error when accessed by name. Map conversion retains
the established last-column-wins behavior.

## Stored procedures

Procedure metadata is read from SQL Server and cached per connection for
`MssqlDefaults.metadataCacheTtl` (10 minutes), bounded by
`MssqlDefaults.metadataCacheSize` entries. The driver uses it to determine
types, sizes and output capability. After an `ALTER PROCEDURE`, call
`invalidateMetadata(object: 'dbo.the_procedure')` rather than waiting for the
TTL; `MssqlMetadataDriftPolicy` decides what generator-declared metadata does
instead.

```dart
final result = await connection.callProcedure(
  'dbo.create_label',
  parameters: {'company_id': 12, 'epc': 'ABC123'},
  outputParameters: const {'label_number'},
);
```

A name present in both collections is input/output. A name present only in
`outputParameters` is output-only. Omitted parameters remain omitted so SQL
Server can apply procedure defaults.

Table-valued parameters are supported, but not streamed as a wire-level TVP:
the driver assembles the table on the server. The rows
go into a temporary staging table by bulk copy, which is then copied into a
variable of the procedure's own table type; the scalar arguments, the OUTPUT
parameters and the return status take the ordinary parameterised path. Pass
`MssqlTableRows`, or an `Iterable<Map<String, Object?>>` for that parameter.
Because it needs a staging table, such a call holds one connection for its
whole life — use `pool.withConnection`, not `pool.session`.

```dart
final result = await connection.callProcedure(
  'dbo.apply_stock_moves',
  parameters: {
    'company_id': 12,
    'moves': MssqlTableRows([
      {'product_id': 11, 'amount': -2},
      {'product_id': 12, 'amount': -1},
    ]),
  },
  outputParameters: const {'applied'},
);
```

## Bulk insert

The common bulk API reads destination metadata and streams the input iterator
to BCP in bounded chunks:

```dart
await connection.bulkInsert(
  tableName: 'dbo.label_events',
  rows: events.map((event) => {
    'reader_id': event.readerId,
    'epc': event.epc,
  }),
);
```

The first row's keys select columns unless `columns` is supplied. Binding uses
destination ordinal order. Identity, computed, hidden and rowversion columns
are protected; set `keepIdentity` and explicitly select an identity column when
preserving identity values.

Use `bulkInsertRaw` to skip the metadata round trip and define the physical
destination columns yourself:

```dart
await connection.bulkInsertRaw(
  tableName: 'dbo.label_events',
  columns: const [
    MssqlBulkColumn(ordinal: 1, name: 'reader_id', type: MssqlType.int32),
    MssqlBulkColumn(
      ordinal: 2,
      name: 'epc',
      type: MssqlType.nvarchar,
      size: 96,
    ),
  ],
  rows: events.map((event) => [event.readerId, event.epc]),
);
```

The original detailed `bulkInsert` form is also retained. Passing
`List<MssqlBulkColumn>` selects it, and its rows may continue to contain named
`MssqlParameter` values:

```dart
await connection.bulkInsert(
  tableName: 'dbo.label_events',
  columns: const [
    MssqlBulkColumn(ordinal: 1, name: 'reader_id', type: MssqlType.int32),
    MssqlBulkColumn(
      ordinal: 2,
      name: 'epc',
      type: MssqlType.nvarchar,
      size: 96,
    ),
  ],
  rows: events.map((event) => [
    MssqlParameter.int32('reader_id', event.readerId),
    MssqlParameter.nvarchar('epc', event.epc, size: 96),
  ]),
);
```

## Streaming and cancellation

`stream` emits result-set start, row-batch, result-set end and final execution
events, so it supports any number of result sets. `streamRows` and
`streamBatches` are simpler single-result helpers.

```dart
final token = MssqlCancellationToken();
final subscription = connection
    .streamRows('SELECT * FROM dbo.large_table', cancellationToken: token)
    .listen(processRow);

token.cancel('request ended');
await subscription.cancel();
```

Cancelling the token or stream subscription reaches the in-flight native
operation. Timeouts remain distinguishable from explicit cancellation.

## Transactions, metadata and SQL helpers

Connection and transaction objects expose the same query conveniences:

```dart
await pool.transaction((transaction) async {
  await transaction.execute(
    'UPDATE dbo.stock SET quantity = quantity - @amount WHERE id = @id',
    parameters: {'amount': 2, 'id': 10},
  );
});
```

`databaseName` and `negotiatedTdsVersion` are available without a query.
`useDatabase(name)` switches the session's current database directly, and
`serverInfo()` reads current SQL Server product metadata. Use
`MssqlSql.quoteIdentifier`, `quoteMultipartIdentifier` and `escapeLike` for
dynamic identifiers and LIKE patterns; continue binding all data values.

## Execution settings

Timeouts, cancellation, row and byte caps, retry and a name for the statement
all live in one reusable object, `MssqlQueryOptions`. Connections,
transactions and the pool take the same one under the same argument names, so
moving a call into a transaction does not change what it is allowed to do.

```dart
const reportOptions = MssqlQueryOptions(
  timeout: Duration(minutes: 2),
  maximumRows: 100000,
  queryName: 'reports.dailyTurnover',
);

await session.queryRows(sql, options: reportOptions);

// The common settings stay easy: an argument given here overrides the object,
// and one left out changes nothing about it.
await session.queryRows(sql, options: reportOptions, timeout: shortTimeout);
await session.queryRows(sql, cancellationToken: token);
```

`options.named('orders.byDate')` relabels a shared options object,
`options.withoutRetry` forces retry off, and `options.limitedTo(n)` caps rows.

Retry defaults to `MssqlRetryPolicy.never` and stays there for arbitrary SQL,
for stored procedures and for anything inside a transaction. Returning rows is
not evidence that a statement is a read: `INSERT … OUTPUT` returns rows too.

`queryName` is a label, not the SQL. The driver never puts statement text or
parameter values in an exception or a log line — a `WHERE` clause with a
literal in it, or the password being written to a users table, is a secret the
moment it is logged — so the label is how a failure is traced back to its
statement. The driver labels its own internal statements the same way, as
`mssql_native.procedureMetadata`, `mssql_native.sessionSetup` and so on.

## Failures

`MssqlException` is still the type to catch for "the database did not do
that". The failures a caller reacts to differently have their own types:

| Type | What it means |
|---|---|
| `MssqlConnectionException` | Not reachable, or stopped being reachable. `mayHaveRun` says whether the statement was in flight. |
| `MssqlAuthenticationException` | Credentials refused. Retrying cannot help. |
| `MssqlTlsException` | The session could not be encrypted or could not be trusted. The fix is configuration. |
| `MssqlQueryTimeoutException` | The server was given its time and did not answer. The work may still be running there. |
| `MssqlCancelledException` | The caller stopped waiting on purpose. |
| `MssqlPoolTimeoutException` | No pooled connection came free in the acquire budget. The server was never asked anything. |
| `MssqlConstraintException` | A unique index, foreign key or check rejected the write. `isDuplicateKey` covers 2601 and 2627. |
| `MssqlConversionException` | A value did not fit, in either direction. `MssqlBulkRowException` is this one, with the row and column. |
| `MssqlUnknownCommitOutcomeException` | The commit was sent and the answer was lost. Do not repeat the work; read the database. |

Each carries SQL Server's message number as `code`, its error state as
`state`, the server messages as `diagnostics`, and `queryName` when the call
had one. `type` remains for a switch, and is what crosses from the worker
isolate.

## Pool sizing

Defaults are min 0, max 2, a 15-second budget for a whole `acquire`, a
5-minute idle timeout and a validation grace period of zero. They are small on
purpose: a pool is a client-side queue in front of a shared server, and a
bigger one moves contention onto SQL Server, where it is paid in worker
threads and lock waits instead of a short wait here.

`validationGracePeriod` is the one knob with a measurable cost either way.
Zero pings every reused connection, which is a full round trip per acquire; a
non-zero value skips the ping for connections released more recently than
that, and accepts a window in which a connection that died meanwhile is handed
out as live — the cost being one failed query for the borrower. Raising it, or
`maximumSize`, is performance tuning against a workload you have measured. No
number here was chosen from a benchmark, and none is offered as one.

## Runtime lifecycle

Call `MssqlRuntime.instance.initialize(tls: ...)` once, before the first
connection: certificate trust is process-wide, and a second call asking for
different trust is an error rather than a silent no-op. `supportsTls` says
whether the packaged native client includes a TLS backend at all, `tlsTrust`
says what this process trusts, and `diagnostics.certificateTrust` describes it
in one line. At process shutdown, close pools and connections and call
`MssqlRuntime.instance.shutdown()`.

`initialize(allowLegacyTlsLogin: true)` permits the TLS 1.0 login handshake
that SQL Server 2014 and earlier offer when they never received the TLS 1.2
update. It is process-wide and weakens every connection's login, so it is a
deliberate call rather than a fallback the driver takes on its own;
`allowLegacyTlsLogin` reports what was applied. See
[TLS.md](TLS.md#old-servers-and-the-login-handshake).
