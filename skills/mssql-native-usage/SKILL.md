---
name: mssql-native-usage
description: Use when writing, reviewing, or debugging Dart or Flutter code that connects directly to Microsoft SQL Server with mssql_native, including pooling, transactions, parameters, procedures, streaming, cancellation, TLS, and driver failures.
---

# Use mssql_native

Use the package's public session API for direct SQL Server access. Choose
`mssql_orm` when the task needs composable queries or generated database-first
models; `mssql_orm_dev` belongs only in generation workflows.

## Establish the actual API

Read [README](../../README.md) for the supported path and
[API](../../doc/API.md) for signatures. Consult
[architecture](../../doc/ARCHITECTURE.md) for ownership or concurrency and
[capabilities](../../doc/CAPABILITIES.md) before making platform, type, or
retry claims. Confirm exports in `lib/mssql_native.dart`; do not use a
private `lib/src` symbol or invent an API from older documentation.

## Baseline pattern

```dart
import 'package:mssql_native/mssql_native.dart';

Future<List<MssqlRow>> activeProducts() async {
  final connection = await MssqlConnection.connect(
    host: 'sql.example.com',
    database: 'warehouse',
    username: 'app_user',
    password: 'read-from-a-secret-store',
  );
  try {
    return await connection.queryTypedRows(
      'SELECT id, name FROM dbo.products WHERE active = @active',
      parameters: {'active': true},
      queryName: 'products.active',
    );
  } finally {
    await connection.close();
  }
}
```

Bind data through `parameters`. Use `MssqlSql.quoteIdentifier` only when an
identifier itself must be dynamic; it does not replace value binding. Keep
credentials, SQL literals, and parameter values out of logs and use
`queryName` for diagnostics.

## Choose ownership deliberately

- Use one `MssqlConnection` for session-affine work. It serializes operations,
  and an open stream holds the connection.
- Use `pool.session` for independent operations, `withConnection` for session
  affinity, and `pool.transaction` for transactional work.
- Close resources created by the application. Shut down `MssqlRuntime` only
  after every owned connection and pool is closed.

## Preserve driver invariants

- Plaintext is the default. Before opening a connection with `require` or
  `strict`, initialize one process-wide `MssqlTlsTrust`; missing trust fails
  closed.
- Use `MssqlValue` or `MssqlParameter` for typed nulls, sizes, precision,
  direction, or other explicit SQL metadata.
- Treat `mayHaveRun` as part of connection-failure handling. When it is true,
  confirm application state before retrying a non-idempotent operation.
- Arbitrary SQL, procedures, writes, and transaction statements are not
  retryable by default. After `MssqlUnknownCommitOutcomeException`, read
  application state before deciding what to do; never repeat the write blindly.
- Cancel a long operation through its token or stream subscription. Do not
  start dependent work on the same connection while its stream remains open.
