import 'package:mssql_native/mssql_native.dart';

Future<void> main() async {
  await MssqlRuntime.instance.initialize();

  final connection = await MssqlConnection.connect(
    host: 'sql.example.com',
    database: 'warehouse',
    username: 'app_user',
    password: 'read-from-a-secret-store',
  );

  try {
    final rows = await connection.queryRows(
      'SELECT id, name FROM dbo.products WHERE is_active = @active',
      parameters: const {'active': true},
    );

    for (final row in rows) {
      print('${row['id']}: ${row['name']}');
    }
  } finally {
    await connection.close();
    await MssqlRuntime.instance.shutdown();
  }
}
