// Shared setup for the Android acceptance suites.
//
// The host's SQL Server is 10.0.2.2 from inside the emulator - the address the
// Android emulator maps to its host loopback. Everything else is overridable
// with --dart-define so the same suite can be pointed at another server.
import 'package:mssql_native/mssql_native.dart';

const androidHost = String.fromEnvironment(
  'MSSQL_HOST',
  defaultValue: '10.0.2.2',
);
const androidPort = int.fromEnvironment('MSSQL_PORT', defaultValue: 1433);
const androidDatabase = String.fromEnvironment(
  'MSSQL_DB',
  defaultValue: 'mssql_native_test',
);
const androidUser = String.fromEnvironment('MSSQL_USER', defaultValue: 'sa');
const androidPassword = String.fromEnvironment('MSSQL_PASSWORD');

/// The connection settings every suite starts from.
///
/// The timeouts are longer than the desktop suites use. An emulator on a
/// two-core runner is slow enough that a 10-second login is a coin toss, and a
/// timeout that fires because the machine is slow tests the machine.
MssqlConnectionConfig androidConfig({
  MssqlEncryption encryption = MssqlEncryption.off,
  MssqlDecimalMode decimalMode = MssqlDecimalMode.doublePrecision,
  String? host,
  int? port,
  String? database,
  String? username,
  String? password,
  Duration loginTimeout = const Duration(seconds: 20),
  Duration queryTimeout = const Duration(seconds: 60),
}) => MssqlConnectionConfig(
  host: host ?? androidHost,
  port: port ?? androidPort,
  database: database ?? androidDatabase,
  username: username ?? androidUser,
  password: password ?? androidPassword,
  encryption: encryption,
  decimalMode: decimalMode,
  loginTimeout: loginTimeout,
  defaultQueryTimeout: queryTimeout,
);

MssqlConnection? _shared;

/// One connection for every suite that only reads and writes ordinary data.
///
/// Opened once rather than per test: a login is a full round trip to the host
/// through the emulator's NAT, and sixty of them is minutes of wall clock that
/// prove nothing the first one did not. Suites that are *about* connecting,
/// closing, encrypting or killing a session open their own.
Future<MssqlConnection> sharedConnection() async =>
    _shared ??= await MssqlConnection.open(androidConfig());

Future<void> closeSharedConnection() async {
  final conn = _shared;
  _shared = null;
  if (conn != null && !conn.isClosed) await conn.close();
}

/// What SQL Server says about the session it is currently holding.
///
/// The only honest check for encryption: a driver can set every flag correctly
/// and still end up in the clear, so the question goes to the server.
Future<String> encryptOption(MssqlConnection conn) async {
  final row = await conn.querySingle(
    'SELECT CAST(encrypt_option AS NVARCHAR(10)) AS e '
    'FROM sys.dm_exec_connections WHERE session_id = @@SPID',
  );
  return (row['e'] as String).toUpperCase();
}

Future<void> dropTable(MssqlConnection conn, String name) =>
    conn.execute("IF OBJECT_ID('$name','U') IS NOT NULL DROP TABLE $name;");
