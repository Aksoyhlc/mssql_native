import 'package:mssql_native/src/models/config.dart';
import 'package:test/test.dart';

void main() {
  group('the generated FreeTDS settings', () {
    test('a CA file becomes a ca file line', () {
      const trust = MssqlTlsTrust(certificateAuthorityFile: '/etc/ssl/ca.pem');
      expect(trust.configSettings(), contains('ca file = /etc/ssl/ca.pem'));
      expect(trust.toConfig(), startsWith('[global]\n'));
    });

    test('hostname validation is written either way', () {
      expect(
        const MssqlTlsTrust(
          certificateAuthorityFile: '/ca.pem',
        ).configSettings(),
        contains('check certificate hostname = yes'),
      );
      expect(
        const MssqlTlsTrust(
          certificateAuthorityFile: '/ca.pem',
          validateHostname: false,
        ).configSettings(),
        contains('check certificate hostname = no'),
      );
    });

    test('an expected hostname overrides the host being connected to', () {
      expect(
        const MssqlTlsTrust(
          certificateAuthorityFile: '/ca.pem',
          expectedHostname: 'sql.internal',
        ).configSettings(),
        contains('certificate hostname = sql.internal'),
      );
    });

    test('settings carry no section header of their own', () {
      expect(
        const MssqlTlsTrust(
          certificateAuthorityFile: '/ca.pem',
        ).configSettings(),
        isNot(contains('[global]')),
      );
    });

    test('insecure trust needs no configuration file', () {
      expect(
        const MssqlTlsTrust.insecureNoVerification().requiresConfigurationFile,
        isFalse,
      );
    });
  });
}

