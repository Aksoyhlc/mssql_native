import 'package:mssql_native/src/native/library_paths.dart';
import 'package:test/test.dart';

void main() {
  group('macOS', () {
    const dir = '/Apps/Demo.app/Contents/MacOS';

    test('bridge is looked up inside the embedded framework bundle', () {
      final candidates = bridgeCandidates(
        os: osMacOS,
        executableDir: dir,
        separator: '/',
      );
      expect(
        candidates.first,
        '/Apps/Demo.app/Contents/MacOS/../Frameworks/MssqlNativeBridge.framework/MssqlNativeBridge',
      );
      expect(
        candidates,
        contains(
          '/Apps/Demo.app/Contents/MacOS/../Frameworks/MssqlNativeBridge.framework/Versions/A/MssqlNativeBridge',
        ),
      );
    });

    test('sybdb is looked up inside its own framework bundle', () {
      final candidates = sybdbCandidates(
        os: osMacOS,
        executableDir: dir,
        separator: '/',
      );
      expect(
        candidates.first,
        '/Apps/Demo.app/Contents/MacOS/../Frameworks/sybdb.framework/sybdb',
      );
    });

    test('no bare dylib candidate survives the framework migration', () {
      final all = <String>[
        ...bridgeCandidates(os: osMacOS, executableDir: dir, separator: '/'),
        ...sybdbCandidates(os: osMacOS, executableDir: dir, separator: '/'),
      ];
      expect(all.where((c) => c.endsWith('.dylib')), isEmpty);
    });

    test(
      'the bridge framework is never named after the pod module framework',
      () {
        final all = <String>[
          ...bridgeCandidates(os: osMacOS, executableDir: dir, separator: '/'),
          ...sybdbCandidates(os: osMacOS, executableDir: dir, separator: '/'),
        ];
        expect(all.where((c) => c.contains('mssql_native.framework')), isEmpty);
      },
    );
  });

  group('iOS', () {
    const dir = '/var/containers/Bundle/Application/ABC/Demo.app';

    test('bridge is looked up in the app bundle Frameworks directory', () {
      expect(
        bridgeCandidates(os: osIOS, executableDir: dir, separator: '/').first,
        '/var/containers/Bundle/Application/ABC/Demo.app/Frameworks/MssqlNativeBridge.framework/MssqlNativeBridge',
      );
    });

    test('sybdb is looked up in the app bundle Frameworks directory', () {
      expect(
        sybdbCandidates(os: osIOS, executableDir: dir, separator: '/').first,
        '/var/containers/Bundle/Application/ABC/Demo.app/Frameworks/sybdb.framework/sybdb',
      );
    });

    test('iOS candidates never use the macOS versioned layout', () {
      final all = <String>[
        ...bridgeCandidates(os: osIOS, executableDir: dir, separator: '/'),
        ...sybdbCandidates(os: osIOS, executableDir: dir, separator: '/'),
      ];
      expect(all.where((c) => c.contains('..')), isEmpty);
      expect(all.where((c) => c.contains('Versions')), isEmpty);
      expect(all, hasLength(2));
    });
  });

  group('other platforms are unchanged', () {
    test('windows', () {
      expect(
        bridgeCandidates(
          os: osWindows,
          executableDir: r'C:\app',
          separator: r'\',
        ),
        <String>[r'C:\app\mssql_native.dll'],
      );
      expect(
        sybdbCandidates(
          os: osWindows,
          executableDir: r'C:\app',
          separator: r'\',
        ),
        <String>[r'C:\app\sybdb.dll'],
      );
    });

    test('linux', () {
      expect(
        bridgeCandidates(
          os: osLinux,
          executableDir: '/opt/app',
          separator: '/',
        ),
        <String>[
          '/opt/app/lib/libmssql_native.so',
          '/opt/app/libmssql_native.so',
        ],
      );
      expect(
        sybdbCandidates(os: osLinux, executableDir: '/opt/app', separator: '/'),
        <String>[
          '/opt/app/lib/libsybdb.so',
          '/opt/app/lib/libsybdb.so.5',
          '/opt/app/libsybdb.so',
        ],
      );
    });

    test('an unsupported platform yields no candidates', () {
      expect(
        bridgeCandidates(os: 'fuchsia', executableDir: '/x', separator: '/'),
        isEmpty,
      );
      expect(
        sybdbCandidates(os: 'fuchsia', executableDir: '/x', separator: '/'),
        isEmpty,
      );
    });
  });

  group('android', () {
    test('the libraries are bare sonames, not paths', () {
      expect(
        sybdbCandidates(
          os: osAndroid,
          executableDir: '/data/app/x',
          separator: '/',
        ),
        <String>['libsybdb.so'],
      );
      expect(
        bridgeCandidates(
          os: osAndroid,
          executableDir: '/data/app/x',
          separator: '/',
        ),
        <String>['libmssql_native.so'],
      );
    });

    test('the executable directory is ignored entirely', () {
      for (final dir in <String>['/data/app/x', '/', '']) {
        expect(
          sybdbCandidates(os: osAndroid, executableDir: dir, separator: '/'),
          <String>['libsybdb.so'],
          reason: 'dir "$dir"',
        );
      }
    });

    test('no candidate contains a separator', () {
      for (final candidate in <String>[
        ...sybdbCandidates(os: osAndroid, executableDir: '/x', separator: '/'),
        ...bridgeCandidates(os: osAndroid, executableDir: '/x', separator: '/'),
      ]) {
        expect(candidate, isNot(contains('/')), reason: candidate);
      }
    });
  });
}

