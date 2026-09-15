import 'package:flutter/material.dart';
import 'package:mssql_native/mssql_native.dart';

void main() {
  runApp(const DriverExample());
}

class DriverExample extends StatefulWidget {
  const DriverExample({super.key});

  @override
  State<DriverExample> createState() => _DriverExampleState();
}

class _DriverExampleState extends State<DriverExample> {
  String _status = 'Ready';

  Future<void> _test() async {
    setState(() => _status = 'Connecting...');
    MssqlConnection? connection;
    try {
      connection = await MssqlConnection.connect(
        host: '127.0.0.1',
        database: 'mssql_native_test',
        username: 'sa',
        password: 'CHANGE_ME',
      );
      final row = await connection.querySingle(
        'SELECT @value AS value, N\'İstanbul\' AS city',
        parameters: const {'value': 123},
      );
      setState(
        () => _status =
            '${row['value'] as int} / '
            '${row['city'] as String}',
      );
    } catch (error) {
      setState(() => _status = error.toString());
    } finally {
      await connection?.close();
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('mssql_native example')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FilledButton(
              onPressed: _test,
              child: const Text('Run connection test'),
            ),
            const SizedBox(height: 20),
            SelectableText(_status),
          ],
        ),
      ),
    ),
  );
}
