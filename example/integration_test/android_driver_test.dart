// The Android acceptance run, executed on a real emulator against a real
// SQL Server.
//
// It exists because the rest of the suite cannot reach Android: `dart test`
// runs on the host VM, and nothing there loads an ARM or Android x86_64 .so.
// Only a Flutter integration test puts this driver on the platform it claims
// to support.
//
// This file is the entry point and nothing else. The suites live beside it in
// suites/, one file per subject, and are registered here so the whole run is a
// single `flutter test` invocation - one APK install and one emulator boot
// rather than eleven.
//
// What is deliberately NOT here: the pure Dart-layer unit tests
// (api_contract, parameter_binder, value_decoder, config, library_paths), which
// are platform-independent and prove nothing extra on a device; the chaos
// suite, which needs a proxy the emulator's NAT cannot reach; and certificate
// verification, which needs a server certificate whose authority the device
// holds.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mssql_native/mssql_native.dart';

import 'suites/bulk.dart';
import 'suites/connection_lifecycle.dart';
import 'suites/encoding.dart';
import 'suites/errors.dart';
import 'suites/pool.dart';
import 'suites/procedures.dart';
import 'suites/runtime.dart';
import 'suites/sql_surface.dart';
import 'suites/transactions.dart';
import 'suites/tls.dart';
import 'suites/types.dart';
import 'support/android_context.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // No paths: on Android the loader resolves bare sonames out of the APK,
    // which is the one thing about this platform the Dart layer had to learn.
    // Initialised once for the whole run - the runtime is a process-wide
    // singleton and DB-Library's globals go with it.
    // The emulator fixture uses an ephemeral self-signed certificate. This
    // suite verifies server-side encryption, not Android's certificate store,
    // so trust that fixture explicitly. Connection configs still default to
    // MssqlEncryption.off; only the TLS cases opt in with `require`.
    await MssqlRuntime.instance.initialize(
      tls: MssqlTlsTrust.insecureNoVerification(),
    );
  });

  tearDownAll(() async {
    await closeSharedConnection();
    await MssqlRuntime.instance.shutdown();
  });

  registerRuntimeTests();
  registerConnectionLifecycleTests();
  registerEncodingTests();
  registerTypeTests();
  registerSqlSurfaceTests();
  registerProcedureTests();
  registerTransactionTests();
  registerBulkTests();
  registerErrorTests();
  registerPoolTests();
  registerTlsTests();
}
