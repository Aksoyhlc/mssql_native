import 'package:mssql_native/src/models/types.dart';
import 'package:mssql_native/src/platform_hints.dart';
import 'package:test/test.dart';

void main() {
  const original = 'Connection timed out after 15000 ms';

  test('iOS connection failures mention the local network permission', () {
    final message = describeConnectionFailure(
      os: 'ios',
      type: MssqlErrorType.connection,
      message: original,
    );
    expect(message, startsWith(original));
    expect(message, contains('NSLocalNetworkUsageDescription'));
  });

  test('other error types on iOS are left alone', () {
    expect(
      describeConnectionFailure(
        os: 'ios',
        type: MssqlErrorType.querySyntax,
        message: original,
      ),
      original,
    );
  });

  test('other platforms are left alone', () {
    for (final os in <String>['macos', 'windows', 'linux']) {
      expect(
        describeConnectionFailure(
          os: os,
          type: MssqlErrorType.connection,
          message: original,
        ),
        original,
        reason: 'the hint must not muddy diagnosis on $os',
      );
    }
  });
}
