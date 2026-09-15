import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mssql_native/mssql_native.dart';

String _required(String name) {
  final value = Platform.environment[name];
  if (value == null || value.isEmpty) {
    throw StateError('$name is required.');
  }
  return value;
}

Future<Response> onRequest(RequestContext context) async {
  await MssqlRuntime.instance.initialize();
  final connection = await MssqlConnection.open(
    MssqlConnectionConfig(
      host: _required('MSSQL_HOST'),
      port: int.parse(Platform.environment['MSSQL_PORT'] ?? '1433'),
      database: _required('MSSQL_DATABASE'),
      username: _required('MSSQL_USERNAME'),
      password: _required('MSSQL_PASSWORD'),
      encryption: MssqlEncryption.off,
    ),
  );
  try {
    final row = await connection.querySingle(
      'SELECT @@VERSION AS version, encrypt_option '
      'FROM sys.dm_exec_connections WHERE session_id = @@SPID',
    );
    return Response.json(body: row);
  } finally {
    await connection.close();
  }
}
