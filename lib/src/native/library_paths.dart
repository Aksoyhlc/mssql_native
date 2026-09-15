/// Search paths for FreeTDS and the handler library, resolved without
/// `dart:io`.
///
/// Kept pure and platform-parameterised so every platform's layout can be unit
/// tested from a single host, and so there is one place to extend when a new
/// platform is added.
library;

/// Values match `Platform.operatingSystem`.
const String osWindows = 'windows';
const String osLinux = 'linux';
const String osMacOS = 'macos';
const String osIOS = 'ios';
const String osAndroid = 'android';

/// Locator meaning "already in this process", used when the platform has no
/// separate FreeTDS file to open.
const String processLibraryLocator = '<process>';

/// Android is the one platform loaded by bare name rather than by path.
///
/// The libraries live in the APK at `lib/<abi>/`, which is not a directory on
/// the filesystem the app can compute: the loader resolves a plain soname
/// against the APK and the extracted native library directory. Building a path
/// from the executable's location, as every other platform here does, finds
/// nothing.
const String _androidSybdbName = 'libsybdb.so';
const String _androidHandlerName = 'libmssql_native.so';

const String _bridgeFrameworkName = 'MssqlNativeBridge';

/// Candidate paths for the handler library, most likely first.
///
/// Still called `bridge*` and still shipped under the old file names, so the
/// build scripts and every embedded artifact keep working; what it points at is
/// now `native/src/handlers.c` rather than the old C++ bridge.
List<String> bridgeCandidates({
  required String os,
  required String executableDir,
  required String separator,
}) {
  final s = separator;
  switch (os) {
    case osAndroid:
      return const <String>[_androidHandlerName];
    case osWindows:
      return <String>['$executableDir${s}mssql_native.dll'];
    case osLinux:
      return <String>[
        '$executableDir${s}lib${s}libmssql_native.so',
        '$executableDir${s}libmssql_native.so',
      ];
    case osMacOS:
      return _frameworkCandidates(
        frameworksDir: '$executableDir$s..${s}Frameworks',
        separator: s,
        name: _bridgeFrameworkName,
        versioned: true,
      );
    case osIOS:
      // The executable is MyApp.app/MyApp, so the frameworks sit directly
      // under its directory rather than ../Frameworks as on macOS.
      return _frameworkCandidates(
        frameworksDir: '$executableDir${s}Frameworks',
        separator: s,
        name: _bridgeFrameworkName,
        versioned: false,
      );
    default:
      return const <String>[];
  }
}

/// Candidate paths for the FreeTDS DB-Library, most likely first.
///
/// The framework is not named `mssql_native`: Flutter's macOS Podfile uses
/// `use_frameworks!`, so CocoaPods already builds a pod module framework named
/// `mssql_native.framework`, and two producers writing the same path under
/// `Contents/Frameworks` is a duplicate-output error.
List<String> sybdbCandidates({
  required String os,
  required String executableDir,
  required String separator,
}) {
  final s = separator;
  switch (os) {
    case osAndroid:
      return const <String>[_androidSybdbName];
    case osWindows:
      return <String>['$executableDir${s}sybdb.dll'];
    case osLinux:
      return <String>[
        '$executableDir${s}lib${s}libsybdb.so',
        '$executableDir${s}lib${s}libsybdb.so.5',
        '$executableDir${s}libsybdb.so',
      ];
    case osMacOS:
      return _frameworkCandidates(
        frameworksDir: '$executableDir$s..${s}Frameworks',
        separator: s,
        name: 'sybdb',
        versioned: true,
      );
    case osIOS:
      return _frameworkCandidates(
        frameworksDir: '$executableDir${s}Frameworks',
        separator: s,
        name: 'sybdb',
        versioned: false,
      );
    default:
      return const <String>[];
  }
}

/// Paths to a binary inside an embedded Apple framework bundle.
///
/// The flat `X.framework/X` form comes first: it is the bundle's top-level
/// symlink on macOS and the actual binary location on iOS, so the same entry
/// serves both. `Versions/A/X` exists only on macOS, whose bundles are
/// versioned, and only as a fallback for a lost symlink.
List<String> _frameworkCandidates({
  required String frameworksDir,
  required String separator,
  required String name,
  required bool versioned,
}) {
  final s = separator;
  return <String>[
    '$frameworksDir$s$name.framework$s$name',
    if (versioned) '$frameworksDir$s$name.framework${s}Versions${s}A$s$name',
  ];
}
