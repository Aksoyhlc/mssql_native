# Examples — `mssql_native`

A cookbook for the driver, ordered from the first query you will write to the
things you only reach for once. Every example is a real call against the API
in `lib/`; nothing here is pseudo-code.

Two companion cookbooks cover the layers above this one:

- [Query builder examples](https://github.com/Aksoyhlc/mssql_orm/blob/main/doc/EXAMPLES_QUERY_BUILDER.md) — composing SQL as Dart values
- [ORM examples](https://github.com/Aksoyhlc/mssql_orm/blob/main/doc/EXAMPLES_ORM.md) — generated typed tables, relations, writes

| Level | What it covers | Read it when |
|---|---|---|
| [0 · Setup](#level-0--setup) | runtime, connect, close | first five minutes |
| [1 · Simple](#level-1--simple) | scalars, rows, parameters, `execute` | writing your first screen |
| [2 · Everyday](#level-2--everyday) | typed rows, NULL, decimals, transactions, procedures, bulk | ordinary application code |
| [3 · Advanced](#level-3--advanced) | pooling, streaming, cancellation, multiple result sets, error types | a service under load |
| [4 · Hard](#level-4--hard) | retries and idempotency, TVPs, metadata caches, code pages, session hygiene | something is subtly wrong |

Naming used throughout: `connection` is an `MssqlConnection`, `session` is any
`MssqlSession` (a connection, a transaction, or a pool's convenience session),
and `pool` is an `MssqlConnectionPool`.

---

## Level 0 · Setup

### 0.1 The whole lifecycle, once

Three things happen in this order and only this order: the runtime is
initialized, connections are opened and closed, the runtime is shut down.

```dart
import 'package:mssql_native/mssql_native.dart';

Future<void> main() async {
  await MssqlRuntime.instance.initialize();

  final connection = await MssqlConnection.connect(
    host: '192.168.1.20',
    database: 'ERP',
    username: 'report_user',
    password: const String.fromEnvironment('MSSQL_PASSWORD'),
  );

  final version = await connection.queryScalar<String>('SELECT @@VERSION');
  print(version);

  await connection.close();
  await MssqlRuntime.instance.shutdown();
}
```

`encryption` defaults to `MssqlEncryption.off`, so this connection is
plaintext. To require verified TLS, select `MssqlEncryption.require` or
`strict` and initialize the runtime with an `MssqlTlsTrust`.

### 0.2 The three ways in are one way in

```dart
// a) The four settings that have no sensible default.
final a = await MssqlConnection.connect(
  host: 'sql.example.com', database: 'warehouse',
  username: 'app', password: password,
);

// b) A configuration you keep, pass around, and vary.
const template = MssqlConnectionConfig(
  host: 'sql.example.com',
  database: 'warehouse',
  username: 'app',
  password: '…',
);
final b = await MssqlConnection.open(
  template.copyWith(
    database: 'warehouse_archive',
    defaultQueryTimeout: const Duration(minutes: 5),
  ),
);

// c) A .NET-style connection string you already have.
final c = await MssqlConnection.connectString(
  'Server=tcp:sql.example.com,1433;Database=warehouse;User Id=app;Password=…',
);
```

All three build the same `MssqlConnectionConfig`, run the same validation and
take defaults from the same place (`MssqlDefaults`). A setting behaves
identically however it arrived.

### 0.3 Logging in as a Windows account

```dart
// A domain account and its password. NTLMv2 — Windows, macOS, Linux, Android.
final domain = await MssqlConnection.connect(
  host: 'sql.example.com', database: 'warehouse',
  username: r'CONTOSO\aksoyhlc', password: password,
);

// The Windows account already running the process. No password anywhere.
final integrated = await MssqlConnection.connectIntegrated(
  host: 'sql.example.com', database: 'warehouse',
);

// The same thing from a connection string.
final fromString = await MssqlConnection.connectString(
  'Server=sql.example.com;Database=warehouse;Integrated Security=true',
);
```

The backslash in the user name is what selects the domain login, so the user
name is written as a raw string (`r'…'`) or with the backslash doubled.

Integrated security is Windows-only: it needs SSPI, which is compiled into the
packaged FreeTDS on Windows and nowhere else. On macOS, Linux and Android the
configuration is refused when it is validated, before any connection is
attempted, with the domain login named as the alternative.

### 0.4 What the defaults are

| Setting | Default | Why it matters |
|---|---|---|
| `port` | `1433` | named instances are not resolved — give the port |
| `loginTimeout` | 10 s | |
| `defaultQueryTimeout` | 30 s | overridable per call |
| `packetSize` | `0` | negotiated with the server |
| `clientCharset` | `UTF-8` | |
| `tdsVersion` | `7.4` | |
| `decimalMode` | `MssqlDecimalMode.exact` | `DECIMAL`/`MONEY` arrive as `MssqlDecimal`, not rounded `double` |
| `encryption` | `MssqlEncryption.off` | choose `require` or `strict` for encrypted sessions |
| certificate trust | none until `initialize(tls: …)` | |
| retry | `MssqlRetryPolicy.never` | |
| pool | min 0, max 2, acquire 15 s, idle 5 min | small on purpose |

---

## Level 1 · Simple

### 1.1 One value

```dart
final count = await connection.queryScalar<int>(
  'SELECT COUNT(*) FROM dbo.products',
);

final maybeName = await connection.queryScalarOrNull<String>(
  'SELECT product_name FROM dbo.products WHERE barcode = @barcode',
  parameters: {'barcode': '8690000001'},
);
```

`queryScalar<T>` treats SQL `NULL` as a conversion error unless `T` is
nullable. `queryScalarOrNull<T>` returns `null` when there is no row.

### 1.2 Rows as maps

```dart
final rows = await connection.queryRows(
  'SELECT id, name, city FROM dbo.customers WHERE is_active = @active',
  parameters: {'active': true},
);

for (final row in rows) {
  print('${row['id']}: ${row['name']} — ${row['city']}');
}
```

`rows` is `List<Map<String, Object?>>`. This is the default shape and needs no
generated code or type arguments.

### 1.3 Parameters, always parameters

Dart values are bound by name; `@` is optional in the map key.

```dart
final rows = await connection.queryRows(
  'SELECT id, name FROM dbo.products '
  'WHERE company_id = @companyId AND active = @active AND created_at >= @since',
  parameters: {
    'companyId': 12,
    'active': true,
    'since': DateTime.utc(2026, 1, 1),
  },
);
```

Inferred automatically: `bool`, signed 32/64-bit `int`, finite `double`,
`String`, `DateTime`, `Uint8List`. Everything goes through `sp_executesql`, so
the values never become part of the SQL text.

**Never do this:**

```dart
// ✗ String interpolation into SQL. One apostrophe in a product name is an
//   injection, and the plan cache gets a new entry per distinct value.
await connection.queryRows("SELECT * FROM dbo.products WHERE name = '$name'");
```

### 1.4 Exactly one row, or maybe one

```dart
// Throws MssqlNoRowsException on zero rows, MssqlMultipleRowsException on many.
final row = await connection.querySingle(
  'SELECT product_code, product_name FROM dbo.products WHERE barcode = @barcode',
  parameters: {'barcode': '8690000001'},
);

// Returns null on zero rows; still throws on many.
final maybe = await connection.querySingleOrNull(
  'SELECT id FROM dbo.customers WHERE email = @email',
  parameters: {'email': address},
);
```

The pair exists so that "no such customer" and "two customers with one email"
are different outcomes. A `.first` on a list would collapse them.

### 1.5 Writes and the affected count

```dart
final affected = await connection.execute(
  'UPDATE dbo.stock SET quantity = quantity - @amount WHERE id = @id',
  parameters: {'amount': 2, 'id': 10},
);
```

**Read this before trusting the number.** SQL Server ends each statement with
its own row-count token, and a trigger body produces tokens of its own. An
`UPDATE` of one row on a table with an audit trigger reports **two**, and
there is no token saying which statement a count belongs to. `execute` returns
the sum. When the exact count matters:

```dart
final result = await connection.query(
  'UPDATE dbo.stock SET quantity = quantity - @amount WHERE id = @id',
  parameters: {'amount': 2, 'id': 10},
);
print(result.statementRowCounts); // e.g. [1, 1] — the UPDATE, then the trigger
```

Or make the statement establish its own count with `OUTPUT`:

```dart
final changed = await connection.queryRows(
  'UPDATE dbo.stock SET quantity = quantity - @amount '
  'OUTPUT inserted.id, inserted.quantity '
  'WHERE id = @id',
  parameters: {'amount': 2, 'id': 10},
);
print(changed.length); // 1 — rows the UPDATE itself touched
```

---

## Level 2 · Everyday

### 2.1 Typed rows

`MssqlRow` is a compact view over the same values: no map is built per row,
and access can be by ordinal.

```dart
final row = await connection.queryTypedSingle(
  'SELECT id, name, balance FROM dbo.customers WHERE id = @id',
  parameters: {'id': 42},
);

final id      = row.require<int>('id');       // throws if NULL
final balance = row.get<MssqlDecimal>('balance'); // null-safe
final first   = row.at(0);                    // by ordinal
final asMap   = row.toMap();                  // when you need JSON

for (final name in row.columnNames) { /* … */ }
```

`queryTypedRows`, `queryTypedSingleOrNull` and `MssqlResultSet.typedRows` are
the same opt-in for the other shapes. Name access is exact; duplicate result
labels stay reachable by index and raise a clear ambiguity error by name.

### 2.2 NULL, exact decimals, explicit sizes

A bare `null` has no inferable SQL type. Use a name-free `MssqlValue`:

```dart
await connection.execute(
  'UPDATE dbo.products SET note = @note, price = @price WHERE id = @id',
  parameters: {
    'id': 10,
    'note': const MssqlValue.nvarchar(null, size: 200),
    'price': MssqlValue.decimal('99999999999999.9999',
        precision: 18, scale: 4),
  },
);
```

`MssqlValue` also spells out sizes so a `varchar(50)` parameter does not
arrive as a `varchar(4000)` and defeat an index seek. `MssqlValue.bit`,
`.int32`, `.int64`, `.float64`, `.varchar`, `.nvarchar`, `.char`, `.nchar`,
`.binary`, `.varbinary`, `.date`, `.time`, `.dateTime`, `.dateTime2`,
`.dateTimeOffset`, `.uniqueIdentifier`, `.xml`, `.money`, `.numeric`,
`.text` and `.raw` are all available.

Date and time columns do not come back as `DateTime`. The driver keeps the
server's exact components, because `datetime2(7)`, `time(7)` and
`datetimeoffset` carry more precision than `DateTime` can represent:

```dart
// Writing: a plain DateTime, Duration or MssqlDateTimeValue is normalized.
await connection.execute(
  'UPDATE dbo.events SET fired_at = @at WHERE id = @id',
  parameters: {'id': 1, 'at': DateTime.now().toUtc()},
);

// Reading: date, datetime, datetime2, time and datetimeoffset values are
// MssqlDateTimeValue (year..nanosecond + timezoneOffsetMinutes).
final row = await connection.querySingle(
  'SELECT fired_at FROM dbo.events WHERE id = @id',
  parameters: {'id': 1},
);
final fired = row!['fired_at'] as MssqlDateTimeValue;

// A DateTime for application logic; the offset converts wall-clock to UTC.
final asUtc = DateTime.utc(
  fired.year, fired.month, fired.day,
  fired.hour, fired.minute, fired.second,
).subtract(Duration(minutes: fired.timezoneOffsetMinutes));
```

Write an exact value back unchanged by passing the `MssqlDateTimeValue`
itself: `MssqlValue.dateTime2(fired)` keeps every component and scale,
`MssqlValue.time(...)` and `MssqlValue.dateTimeOffset(...)` work the same way.
`uniqueidentifier` and `xml` read back as `String`.

### 2.3 Working with `MssqlDecimal`

`DECIMAL`, `NUMERIC`, `MONEY` and `SMALLMONEY` arrive as `MssqlDecimal` under
the default `MssqlDecimalMode.exact`. It is an exact base-10 value — a
coefficient and a scale — not a `double`.

```dart
final price = MssqlDecimal.parse('199.90');
final qty   = MssqlDecimal.fromInt(3);

final line  = price * qty;                       // 599.70, exactly
final vat   = line * MssqlDecimal.parse('0.20');
final total = line + vat;

// Division must be told how much precision to keep and how to round.
final unit = total.divide(qty, scale: 4, rounding: MssqlRounding.halfUp);

if (total > MssqlDecimal.parse('1000')) { /* … */ }
print(total.toString()); // never scientific notation
```

`==` compares numeric value, so `1.50 == 1.5` is `true`;
`hasSameRepresentation` is the stricter test that also compares scale.

Two other modes exist and are explicit opt-ins on the config:
`MssqlDecimalMode.text` (a `String`, for pass-through and JSON) and
`MssqlDecimalMode.doublePrecision` (a `double`, which rounds — choose it only
when you know the columns are not money).

### 2.4 A connection string from the environment

```dart
final connection = await MssqlConnection.open(
  MssqlConnectionConfig.fromConnectionString(
    Platform.environment['MSSQL_CONNECTION_STRING']!,
    onUnsupportedKeys: (keys) =>
        log.warning('connection string keys ignored: ${keys.join(', ')}'),
  ),
);
```

Keys are matched the way SqlClient matches them — case and inner spaces
ignored — with the usual synonyms (`Data Source`/`Server`,
`Initial Catalog`/`Database`, `User Id`/`UID`, `Password`/`PWD`), quoted
values, and `Server=tcp:host,1433`.

Nothing is silently dropped. A key that decides how the connection is secured
but cannot be honoured is **refused** with a message naming the alternative:

| Key | Why it is refused |
|---|---|
| `User Id` together with `Integrated Security=true` | one of the two decides who logs in; SqlClient drops the credentials, this driver says so |
| `host\INSTANCE` | the driver does not resolve named instances through SQL Browser — write `Server=host,1433` |
| `np:`, `lpc:` | TDS over TCP only |
| `TrustServerCertificate=false` with encryption on | trust is process-wide, so it cannot be promised per connection |

Keys the driver simply has no use for (`Pooling`,
`MultipleActiveResultSets`, …) are also refused **unless** you pass
`onUnsupportedKeys` — which is you saying "tell me and carry on".

### 2.5 Transactions

```dart
await connection.transaction((tx) async {
  await tx.execute(
    'UPDATE dbo.stock SET quantity = quantity - @amount WHERE id = @id',
    parameters: {'amount': 2, 'id': 10},
  );
  await tx.execute(
    'INSERT INTO dbo.stock_moves (product_id, amount) VALUES (@id, @amount)',
    parameters: {'id': 10, 'amount': -2},
  );
});
```

The callback's `tx` is an `MssqlTransaction`, which is an `MssqlSession`: it
has the same `queryRows` / `querySingle` / `execute` / `stream` /
`callProcedure` / `bulkInsert` you already use. Returning normally commits;
throwing rolls back and rethrows the original error — a rollback that fails on
top of your failure is deliberately swallowed so it cannot replace the error
you have to diagnose.

Manual control, when the commit point is not the end of a callback:

```dart
final tx = await connection.beginTransaction(
  isolationLevel: MssqlIsolationLevel.snapshot,
);
try {
  // …
  await tx.commit();
} catch (_) {
  await tx.rollback();
  rethrow;
} finally {
  await tx.close();
}
```

`bool get inTransaction` on any session answers "am I already inside one?" —
the question code asks before opening one of its own.

A reversible step inside a transaction is a savepoint. The callback runs in
the transaction; when it throws, the driver rolls back to the savepoint and
rethrows, so the outer work survives:

```dart
await connection.transaction((tx) async {
  await tx.execute(
    'UPDATE dbo.accounts SET balance = balance - @amount WHERE id = @id',
    parameters: {'amount': 10, 'id': 1},
  );

  try {
    await tx.savepoint((inner) async {
      await inner.execute(
        'UPDATE dbo.accounts SET balance = balance + @amount WHERE id = @id',
        parameters: {'amount': 10, 'id': 2},
      );
      await inner.execute(
        'INSERT INTO dbo.transfers (from_id, to_id, amount) '
        'VALUES (@from, @to, @amount)',
        parameters: {'from': 1, 'to': 2, 'amount': 10},
      );
    });
  } on MssqlConstraintException {
    // Inner work rolled back; the debit on account 1 still stands and this
    // transaction can keep going — that is the point of the savepoint.
  }
});
```

Catch only when you have a real recovery decision; otherwise let the error
propagate and roll back everything. One boundary is honest: if the rollback to
the savepoint itself is refused (the failure took the whole batch down), the
transaction is marked unusable and only `tx.rollback()` remains truthful.

### 2.6 Stored procedures

```dart
final result = await connection.callProcedure(
  'dbo.create_label',
  parameters: {'company_id': 12, 'epc': 'ABC123'},
  outputParameters: const {'label_number'},
);

final label  = result.outputParameters['label_number'] as int;
final status = result.returnStatus;            // the procedure's RETURN value
final rows   = result.resultSets.first.rows;   // if it selected anything
```

Parameter types, sizes and output capability come from the procedure's own
metadata, read from SQL Server. Consequences worth knowing:

- A name in **both** `parameters` and `outputParameters` is `INPUT/OUTPUT`.
- A name **only** in `outputParameters` is output-only.
- A parameter you **omit** stays omitted, so the procedure's own `DEFAULT`
  applies. Passing `null` is not the same thing.
- Procedures are **never retried**: their body is opaque to the driver.

An explicit `MssqlParameter` list declares the whole signature yourself —
type, size and direction — instead of relying on procedure metadata:

```dart
final result = await connection.callProcedure(
  'dbo.make_label',
  parameters: [
    MssqlParameter.int32('company_id', 12),
    MssqlParameter.nvarchar('label', null,
        size: 64, direction: MssqlParameterDirection.output),
  ],
);

final label = result.outputParameters['label'] as String;
```

`outputParameters:` is for the map form only; with a list, direction lives on
each `MssqlParameter`, and an output parameter must state its `size` (there is
no metadata to borrow it from).

A procedure's streaming counterpart is `streamProcedure`, with the same
parameters, output-parameter names, and the event stream of `stream`:

```dart
final events = connection.streamProcedure(
  'dbo.export_orders',
  parameters: {'company_id': 12},
  outputParameters: const {'exported'},
);

await for (final event in events) {
  switch (event) {
    case MssqlResultSetStart(): /* set boundary */
    case MssqlRowBatch(:final rows): await writeCsv(rows);
    case MssqlResultSetEnd(): /* metrics per set */
    case MssqlExecutionComplete(): /* done; outputs are readable */
  }
}
```

### 2.7 Bulk insert

For thousands of rows, `INSERT` in a loop is the wrong tool. This is BCP:

```dart
final result = await connection.bulkInsert(
  tableName: 'dbo.label_events',
  rows: events.map((event) => {
    'reader_id': event.readerId,
    'epc': event.epc,
    'seen_at': event.seenAt,
  }),
  options: const MssqlBulkOptions(
    batchSize: 5000,
    mode: MssqlBulkMode.batched,   // commit per batch
    tableLock: true,               // faster; holds a lock on the table
  ),
  onProgress: (sent) => print('sent $sent rows'),
);

print('${result.insertedRows} of ${result.totalRows} in ${result.elapsed}');
```

- `rows` is an `Iterable`, consumed lazily and streamed in bounded chunks — a
  generator or a file reader never has to be materialized.
- The first row's keys select the columns unless `columns` is given.
- Identity, computed, hidden and `rowversion` columns are protected. To
  preserve identity values, set `keepIdentity: true` **and** name the identity
  column explicitly.
- `MssqlBulkMode.atomic` (the default) is all-or-nothing;
  `MssqlBulkMode.batched` commits each `batchSize` and reports
  `committedBatches` plus `failedRowIndex` when a batch fails.
- This is BCP, not a row-by-row `INSERT`: CHECK constraints and triggers do
  **not** fire unless you opt in, and a `null` follows BCP behavior. Every
  hint is off by default, so an ordinary copy behaves the way
  `SqlBulkCopyOptions.Default` does; the knobs are
  `MssqlBulkOptions.keepNulls`, `checkConstraints`, `fireTriggers`,
  `tableLock` (faster, and allows minimal logging, but blocks other sessions
  on that table while it runs), plus `timeout` for the whole copy.

### 2.8 Timeouts and per-call settings

Everything that shapes one execution lives in one reusable object.

```dart
const reportOptions = MssqlQueryOptions(
  timeout: Duration(minutes: 2),
  maximumRows: 100000,
  queryName: 'reports.dailyTurnover',
);

await session.queryRows(sql, options: reportOptions);

// A named argument overrides the object; one left out changes nothing.
await session.queryRows(sql, options: reportOptions, timeout: shortTimeout);

// Derived variants, for sharing one base object.
await session.queryRows(sql, options: reportOptions.named('orders.byDate'));
await session.queryRows(sql, options: reportOptions.limitedTo(500));
await session.queryRows(sql, options: reportOptions.withoutRetry);
```

`queryName` is a **label, not the SQL**. The driver never puts statement text
or parameter values into an exception or a log line — a `WHERE` clause with a
literal in it, or a password on its way into a users table, is a secret the
moment it is logged — so the label is how a failure is traced back to its
statement. The driver labels its own internal work the same way
(`mssql_native.procedureMetadata`, `mssql_native.sessionSetup`, …).

Connections, transactions and the pool take the same object under the same
argument names, so moving a call into a transaction does not change what it is
allowed to do.

---

## Level 3 · Advanced

### 3.1 Pooling — and which handle to hold

```dart
final pool = MssqlConnectionPool(
  config,
  poolConfig: const MssqlPoolConfig(
    minimumSize: 2,
    maximumSize: 8,
    acquireTimeout: Duration(seconds: 15),
    idleTimeout: Duration(minutes: 5),
    validationGracePeriod: Duration(seconds: 30),
  ),
);
await pool.warmUp();
```

Three ways to use it, and the choice is not cosmetic:

```dart
// a) One statement, no affinity to any particular connection.
final rows = await pool.session.queryRows('SELECT 1 AS n');

// b) Several statements that must land on the SAME connection.
await pool.withConnection((connection) async {
  await connection.execute('CREATE TABLE #staging (id int)');
  await connection.bulkInsert(tableName: '#staging', rows: batch);
  await connection.execute('MERGE dbo.target USING #staging …');
});

// c) A transaction: one lease held for the whole callback.
await pool.transaction((tx) async {
  await tx.execute('…');
});

await pool.close();
```

`pool.session` takes a lease **per statement**. Anything that spans
statements — a transaction, a stream, a staged temp table, a page plus its
consistent count — must hold one connection for its whole life, and asks for
that with `withConnection` or `transaction`. Handing those a fresh lease per
statement would scatter them over the pool and, for a `#temp` table, lose it
between calls.

Defaults are min 0 / max 2 on purpose: a pool is a client-side queue in front
of a shared server, and a bigger one moves contention onto SQL Server, where
it is paid in worker threads and lock waits instead of a short wait here.

`validationGracePeriod` is the one knob with a cost either way. Zero pings
every reused connection — a full round trip per acquire. A non-zero value
skips the ping for connections released more recently than that, and accepts a
window in which a connection that died meanwhile is handed out as live; the
cost is one failed query for the borrower.

A one-line health probe and a one-line health endpoint:

```dart
await pool.ping(); // one lease, one round trip — throws if no lease is live

Map<String, int> poolHealth() => {
  'created': pool.createdCount,
  'idle': pool.idleCount,
  'waiting': pool.waitingCount,
};
```

### 3.2 Streaming a result set that does not fit in memory

```dart
await for (final row in connection.streamRows(
  'SELECT id, epc, seen_at FROM dbo.label_events WHERE seen_at >= @since',
  parameters: {'since': since},
  options: const MssqlQueryOptions(batchRows: 1000),
)) {
  await sink.write(row.require<String>('epc'));
}
```

`streamRows` yields `MssqlRow`; `streamBatches` yields
`List<Map<String, Object?>>` a batch at a time, which is what you want when
the consumer is itself batched (a bulk insert into another table, a CSV
writer):

```dart
await for (final batch in connection.streamBatches(
  'SELECT id, epc FROM dbo.label_events WHERE seen_at >= @since',
  parameters: {'since': since},
  options: const MssqlQueryOptions(batchRows: 1000),
)) {
  await sink.addAll(batch); // one write per 1000 rows, not per row
}
```

For anything with more than one result set, or when you need the metrics and
the end-of-set boundaries, listen to the full event stream:

```dart
await for (final event in connection.stream(sql)) {
  switch (event) {
    case MssqlResultSetStart(:final columns):
      print('result set with ${columns.length} columns');
    case MssqlRowBatch(:final rows):
      process(rows);
    case MssqlResultSetEnd(:final metrics):
      print('set done: ${metrics.rowCount} rows');
    case MssqlExecutionComplete(:final metrics):
      print('all done in ${metrics.executionElapsed}');
  }
}
```

`MssqlStreamEvent` is a sealed class, so the `switch` is exhaustive and a new
event kind would be a compile error rather than a silently ignored branch.

### 3.3 Cancellation

```dart
final token = MssqlCancellationToken();

// Cancel when the HTTP request goes away.
request.onDisconnect.then((_) => token.cancel('client disconnected'));

try {
  final rows = await connection.queryRows(
    heavyReport,
    cancellationToken: token,
    timeout: const Duration(minutes: 5),
  );
} on MssqlCancelledException {
  return Response.clientClosedRequest();
} on MssqlQueryTimeoutException {
  return Response.gatewayTimeout();
}
```

Cancelling the token reaches the in-flight native operation; it is not a
Dart-side `Future` abandonment that leaves the server working. Cancelling a
stream subscription does the same:

```dart
final sub = connection.streamRows(sql).listen(process);
await sub.cancel(); // cancels the native operation too
```

`MssqlCancelledException` and `MssqlQueryTimeoutException` stay distinct: one
is "the caller stopped waiting on purpose", the other is "the server was given
its time and did not answer, and the work may still be running there".

### 3.4 Multiple result sets and metrics

```dart
final result = await connection.query('''
SELECT id, code FROM dbo.orders WHERE customer_id = @id;
SELECT SUM(total) AS revenue FROM dbo.orders WHERE customer_id = @id;
''', parameters: {'id': 42});

final orders  = result.resultSets[0].rows;
final revenue = result.resultSets[1].rows.single['revenue'] as MssqlDecimal;

for (final message in result.messages) {
  // Informational messages: PRINT, and RAISERROR below the error threshold.
  print('[${message.number}] ${message.message}');
}
print(result.metrics.executionElapsed);
print(result.metrics.timeToFirstRow);
```

### 3.5 `bulkInsertRaw` — skipping the metadata round trip

The high-level `bulkInsert` reads the destination schema for each call. When
that round trip matters, or when you need to decide every SQL type yourself:

```dart
await connection.bulkInsertRaw(
  tableName: 'dbo.label_events',
  columns: const [
    MssqlBulkColumn(ordinal: 1, name: 'reader_id', type: MssqlType.int32),
    MssqlBulkColumn(ordinal: 2, name: 'epc', type: MssqlType.nvarchar, size: 96),
    MssqlBulkColumn(ordinal: 3, name: 'amount', type: MssqlType.decimal,
        precision: 18, scale: 4),
  ],
  rows: events.map((e) => [e.readerId, e.epc, e.amount]),
);
```

`ordinal` is the **destination** ordinal, and rows are positional lists in
that order. The fully explicit form — rows of named `MssqlParameter` values —
remains available on `bulkInsert` itself; passing a `List<MssqlBulkColumn>`
selects it.

### 3.6 Isolation levels

```dart
await connection.transaction(
  (tx) async {
    final rows = await tx.queryRows(
      'SELECT quantity FROM dbo.stock WHERE id = @id',
      parameters: {'id': 10},
    );
    // …
  },
  isolationLevel: MssqlIsolationLevel.snapshot,
);
```

`MssqlIsolationLevel.baseline` — the default — means "leave the session where
it is", so a connection that has been set up a particular way is not silently
re-levelled. The named levels (`readUncommitted`, `readCommitted`,
`repeatableRead`, `snapshot`, `serializable`) are set on the session and
restored afterwards.

### 3.7 Dynamic identifiers and `LIKE`

Data values are always bound. Identifiers cannot be — a table name is not a
parameter — so they are quoted:

```dart
final table = MssqlSql.quoteMultipartIdentifier(['dbo', userChosenTable]);
final rows  = await connection.queryRows('SELECT TOP (10) * FROM $table');

// And a LIKE pattern whose payload is user text:
final pattern = '%${MssqlSql.escapeLike(searchTerm)}%';
final hits = await connection.queryRows(
  r"SELECT id FROM dbo.products WHERE name LIKE @pattern ESCAPE '\'",
  parameters: {'pattern': pattern},
);
```

`escapeLike` escapes `%`, `_` and `[` so a search for `50%` finds the literal
string rather than everything. `MssqlMultipartIdentifier.parse(input,
maximumParts: 3)` validates a user-supplied `schema.table` before you build
SQL from it.

### 3.8 Failures, by the decision you make about them

`MssqlException` is still the type to catch for "the database did not do
that". The ones you react to differently have their own types:

```dart
try {
  await connection.execute(sql, parameters: params);
} on MssqlConstraintException catch (e) {
  if (e.isDuplicateKey) return Conflict('already exists');   // 2601 / 2627
  return BadRequest(e.message);
} on MssqlQueryTimeoutException {
  return GatewayTimeout();                       // may still be running there
} on MssqlUnknownCommitOutcomeException {
  // The commit was sent and the answer was lost. Do NOT repeat the work.
  return await reconcileFromDatabase();
} on MssqlConnectionException catch (e) {
  return e.mayHaveRun ? Unknown() : Retryable();
} on MssqlAuthenticationException {
  return Fatal('credentials refused — retrying cannot help');
} on MssqlTlsException catch (e) {
  return Fatal('trust is a configuration problem: ${e.message}');
} on MssqlPoolTimeoutException {
  return TooBusy();                              // server was never asked
} on MssqlException catch (e) {
  log.severe('[${e.code}/${e.state}] ${e.queryName}: ${e.message}');
  rethrow;
}
```

Each carries SQL Server's message number as `code`, its state as `state`, the
server messages as `diagnostics`, `queryName` when the call had one, and a
`type` (`MssqlErrorType`) for a `switch` — `type` is also what crosses back
from the worker isolate.

---

## Level 4 · Hard

### 4.1 Retry, and why it is off

```dart
// Opt in per call, and only for something you know is a safe read. The
// idempotentRead promise says "repeat this SELECT after a lost connection".
final rows = await session.queryRows(
  'SELECT id, name FROM dbo.products WHERE company_id = @id',
  parameters: {'id': 12},
  options: const MssqlQueryOptions(
    retry: MssqlRetryPolicy.idempotentRead,
    queryName: 'products.byCompany',
  ),
);
```

`MssqlRetryPolicy.never` is the default and stays the default for arbitrary
SQL, for stored procedures, and for anything inside a transaction. **Returning
rows is not evidence that a statement is a read** — `INSERT … OUTPUT` returns
rows too, and a retried one inserts twice.

The failure that no retry policy can help with is
`MssqlUnknownCommitOutcomeException`: the commit was sent and the answer was
lost. Repeating the work may double it; the only correct move is to read the
database and find out what happened.

### 4.2 Table-valued parameters

The driver does not stream a TVP on the wire; it assembles the table
**on the server**: the rows go into a temporary
staging table by bulk copy, which is then copied into a variable of the
procedure's own table type. Scalar arguments, `OUTPUT` parameters and the
return status take the ordinary parameterised path.

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

An `Iterable<Map<String, Object?>>` is accepted for a table-typed parameter
and wrapped for you. Anything else for that parameter is an `ArgumentError`
naming it, rather than a confusing type error from deep inside the binder.

Because this needs a staging table, the call holds one connection for its
whole life — use `pool.withConnection`, not `pool.session`, if you are pooled.

### 4.3 Procedure metadata: caching, and declaring it

Every `callProcedure` needs to know the procedure's parameters. By default
that is read from SQL Server and cached.

```dart
final cache = MssqlMetadataCache(
  maxEntries: 256,
  ttl: const Duration(minutes: 10),
);
final connection = await MssqlConnection.open(config, metadataCache: cache);
// A pool shares one cache across every lease, so two sequential statements
// landing on different connections do not describe the same procedure twice.
```

When a generator already knows the shape, the describe can be skipped
entirely:

```dart
await connection.callProcedure(
  'dbo.create_label',
  parameters: {'company_id': 12},
  declared: const MssqlProcedureMetadata(
    procedure: 'dbo.create_label',
    parameters: [
      MssqlProcedureParameter(name: 'company_id', type: MssqlType.int32),
      MssqlProcedureParameter(name: 'label_number', type: MssqlType.int32,
          isOutput: true),
    ],
  ),
  driftPolicy: MssqlMetadataDriftPolicy.preferDeclared, // no catalog query
);
```

`MssqlMetadataDriftPolicy.verifyDeclared` still describes (through the cache)
and **refuses** when the declaration and the catalog disagree — which is what
you want in staging. After an `ALTER PROCEDURE`, drop the cache:
`connection.invalidateMetadata(object: 'dbo.create_label')`, or
`invalidateMetadata()` for all of it. On a pool it clears every lease's.

### 4.4 Turkish and other single-byte code pages

`clientCharset` defaults to `UTF-8` and the driver converts through its
packaged character-conversion support, so
a `varchar` column on a Turkish-collation database (code page 1254) round-trips
correctly without any per-string handling on your side. `nvarchar` columns are
UTF-16 on the wire and are unaffected.

The thing to get right is the **parameter type**, not the charset: bind a
`varchar` filter as `varchar`, so the comparison stays on the column's own
type and an index seek is still possible.

```dart
parameters: {
  'city': const MssqlValue.varchar('İstanbul', size: 50),   // matches varchar(50)
}
```

### 4.5 Switching database, and session hygiene

```dart
final selected = await connection.useDatabase('warehouse_archive');
print(connection.currentDatabase);       // follows the session, not the login
print(connection.databaseName);
```

`config.database` remains the *login* catalog; `currentDatabase` is where the
session is now. Metadata keyed by object name follows the session, which is
why `useDatabase` drops the metadata cache for you.

If you run something that changes the session in a way the driver cannot see —
`SET ANSI_NULLS`, a `SET LOCK_TIMEOUT`, a procedure that leaves an option
changed — say so, and the driver will not reuse the session as if it were
clean:

```dart
await connection.execute('EXEC dbo.legacy_setup_that_sets_options');
connection.markSessionDirty('legacy_setup changes SET options');
print(connection.isSessionDirty); // true
```

### 4.6 Server capabilities, without guessing

```dart
final info = await connection.serverInfo();
print('${info.productVersion} ${info.productLevel} — ${info.edition}');
print('engine edition: ${info.engineEdition}');   // 5 = Azure SQL Database
print('negotiated TDS: ${connection.negotiatedTdsVersion}');
```

`MssqlRuntime.instance.supportsTls` says whether the packaged native client
includes a TLS backend at all, `tlsTrust` says what this process trusts, and
`diagnostics.certificateTrust` describes it in one line — useful in a
`/healthz` payload, and much better than inferring trust from a failed
handshake.

### 4.7 Row and byte caps as a safety net

```dart
try {
  await session.queryRows(
    userSuppliedReportSql,
    options: const MssqlQueryOptions(
      maximumRows: 50000,
      maximumBytes: 64 * 1024 * 1024,
      timeout: Duration(minutes: 2),
      queryName: 'adhoc.userReport',
    ),
  );
} on MssqlException catch (e) {
  // Caps fail the operation instead of exhausting the isolate's heap.
}
```

These are guard rails for a query whose result size you do not control. They
are not paging: the operation fails when a cap is hit, rather than truncating
and returning something that looks complete.

### 4.8 Shutting down cleanly

```dart
Future<void> shutdown() async {
  await pool.close();
  await connection.close();
  await MssqlRuntime.instance.shutdown();   // unloads the native libraries
}
```

Order matters: close what holds native sessions, then the runtime. `shutdown`
closes any connection still registered, but a process that exits without it
leaves the native libraries loaded until the OS reclaims them.

---

## Where to go next

| Question | Document |
|---|---|
| Full API reference | [doc/API.md](API.md) |
| TLS: the two halves of the setting | [doc/TLS.md](TLS.md) |
| What ships, what the end user installs | [README · Deployment](../README.md#deployment) |
| Plain Dart server / CLI packaging | [doc/DART_SERVER_CLI.md](DART_SERVER_CLI.md) |
| Isolates, worker, FFI layer | [doc/ARCHITECTURE.md](ARCHITECTURE.md) |
| Platforms and gaps | [README · Platform support](../README.md#platform-support) |
| Composing SQL as Dart values | [query builder examples](https://github.com/Aksoyhlc/mssql_orm/blob/main/doc/EXAMPLES_QUERY_BUILDER.md) |
| Generated typed tables | [ORM examples](https://github.com/Aksoyhlc/mssql_orm/blob/main/doc/EXAMPLES_ORM.md) |
