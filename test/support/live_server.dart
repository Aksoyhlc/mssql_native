import 'dart:io';

import 'package:mssql_native/mssql_native.dart';

bool get liveEnabled => Platform.environment['MSSQL_NATIVE_LIVE'] == '1';
String? get liveSkip => liveEnabled ? null : 'Set MSSQL_NATIVE_LIVE=1 to run.';

MssqlConnectionConfig liveConfig({
  String? database,
  MssqlDecimalMode decimalMode = MssqlDecimalMode.text,
  Duration queryTimeout = const Duration(seconds: 10),
}) => MssqlConnectionConfig(
  host: Platform.environment['MSSQL_NATIVE_HOST'] ?? '127.0.0.1',
  port: int.parse(Platform.environment['MSSQL_NATIVE_PORT'] ?? '1433'),
  database:
      database ??
      Platform.environment['MSSQL_NATIVE_DB'] ??
      'mssql_native_test',
  username: Platform.environment['MSSQL_NATIVE_USER'] ?? 'sa',
  password: Platform.environment['MSSQL_NATIVE_PASSWORD'] ?? 'Mssql@Native2026',
  decimalMode: decimalMode,
  encryption: MssqlEncryption.off,
  defaultQueryTimeout: queryTimeout,
);

Future<void> initializeLive() => MssqlRuntime.instance.initialize(
  bridgePath: Platform.environment['MSSQL_NATIVE_BRIDGE'],
  sybdbPath: Platform.environment['MSSQL_NATIVE_SYBDB'],
);
