import 'dart:io';

import 'package:mssql_native/mssql_native.dart';

String requiredEnvironment(String name) {
  final value = Platform.environment[name];
  if (value == null || value.isEmpty) {
    throw ArgumentError('Set $name before starting the application.');
  }
  return value;
}

Future<void> main() async {
  // Trust is process-wide and is configured before anything connects.
  final ca = Platform.environment['MSSQL_CA_FILE'];
  final config = MssqlConnectionConfig(
    host: requiredEnvironment('MSSQL_HOST'),
    port: int.parse(Platform.environment['MSSQL_PORT'] ?? '1433'),
    database: requiredEnvironment('MSSQL_DATABASE'),
    username: requiredEnvironment('MSSQL_USERNAME'),
    password: requiredEnvironment('MSSQL_PASSWORD'),
    // Encryption is required only when a CA was given: the driver fails
    // closed, so asking for it with no trust configured would refuse to
    // connect rather than fall back.
    encryption: ca == null ? MssqlEncryption.off : MssqlEncryption.require,
  );
  // No bridgePath, sybdbPath, pub-cache path or native build script.
  await MssqlRuntime.instance.initialize(
    tls: ca == null ? null : MssqlTlsTrust(certificateAuthorityFile: ca),
  );
  if (ca == null) {
    stderr.writeln(
      'MSSQL_CA_FILE is not set: connecting without encryption. Set it to a '
      'trusted PEM CA to encrypt the session.',
    );
  }
  MssqlConnection? connection;
  try {
    connection = await MssqlConnection.open(config);
    final row = await connection.querySingle('SELECT @@VERSION AS version');
    stdout.writeln(row);
  } finally {
    await connection?.close();
    await MssqlRuntime.instance.shutdown();
  }
}
