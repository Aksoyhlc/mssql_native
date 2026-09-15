import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

void main() {
  late Directory fixture;

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('mssql-path-policy-');
  });

  tearDown(() async {
    await fixture.delete(recursive: true);
  });

  Future<ProcessResult> verify() {
    return Process.run('python3', <String>[
      '${Directory.current.path}/tool/verify_binary_paths.py',
      fixture.path,
    ]);
  }

  test('accepts documented runtime certificate paths', () async {
    final binary = File('${fixture.path}/libsybdb.so');
    await binary.writeAsBytes(
      Uint8List.fromList(<int>[
        ...'/etc/ssl/cert.pem'.codeUnits,
        0,
        ...'/tmp/freetds.log.%d'.codeUnits,
        0,
        ...r'C:\Program Files\Common Files\SSL'.codeUnits,
        0,
        ...r'q:\random-binary-data'.codeUnits,
      ]),
    );

    final result = await verify();

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });

  test('rejects workstation, CI, and producer build paths', () async {
    final binary = File('${fixture.path}/libsybdb.dylib');
    await binary.writeAsBytes(
      Uint8List.fromList(<int>[
        ...'/Users/alice/work/mssql_native/.native-build/openssl'.codeUnits,
        0,
        ...r'D:\a\mssql_native\mssql_native\native\source.c'.codeUnits,
        0,
        ...r'D:\CFILES\Projects\WinSSL\temp\crypto.c'.codeUnits,
      ]),
    );

    final result = await verify();
    final output = '${result.stdout}\n${result.stderr}';

    expect(result.exitCode, 1, reason: output);
    expect(output, contains('libsybdb.dylib'));
    expect(output, contains('/Users/alice/work/mssql_native'));
    expect(output, contains(r'D:\a\mssql_native'));
    expect(output, contains(r'D:\CFILES\Projects\WinSSL'));
  });

  test('scans shipped payload directories but ignores build inputs', () async {
    final shipped = File('${fixture.path}/linux/lib/libsybdb.so');
    await shipped.parent.create(recursive: true);
    await shipped.writeAsBytes('/etc/ssl/cert.pem'.codeUnits);

    final buildInput = File(
      '${fixture.path}/native/vendor/dependency/libproducer.so',
    );
    await buildInput.parent.create(recursive: true);
    await buildInput.writeAsBytes('/Users/vendor/build/source.c'.codeUnits);

    final result = await verify();

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
}
