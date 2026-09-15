import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mssql_native/mssql_native.dart';

import '../support/android_context.dart';

/// What the application bundle actually carries, before any question of SQL.
void registerRuntimeTests() {
  group('the bundled runtime', () {
    testWidgets('the libraries load at all', (_) async {
      // Android resolves the bare soname from jniLibs. Apple resolves the
      // executable inside the embedded framework bundle.
      expect(MssqlRuntime.instance.isInitialized, isTrue);
      final path = MssqlRuntime.instance.sybdbPath;
      if (Platform.isAndroid) {
        expect(path, 'libsybdb.so');
      } else if (Platform.isIOS) {
        expect(path, endsWith('/Frameworks/sybdb.framework/sybdb'));
      } else {
        fail('This acceptance suite expects Android or iOS, got $path.');
      }
    });

    testWidgets('this build can encrypt', (_) async {
      // Both mobile payloads link OpenSSL statically, so this is an assertion
      // rather than a question.
      expect(MssqlRuntime.instance.supportsTls, isTrue);
    });

    testWidgets('connects and runs a query', (_) async {
      final conn = await sharedConnection();
      final row = await conn.querySingle('SELECT 42 AS answer');
      expect(row['answer'], 42);
    });
  });
}
