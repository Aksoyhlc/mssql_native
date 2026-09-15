import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

import 'src/desktop.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    if (os != OS.android &&
        os != OS.iOS &&
        os != OS.linux &&
        os != OS.windows &&
        os != OS.macOS) {
      throw UnsupportedError(
        'mssql_native has no bundled library for ${os.name}. '
        'Supported: Windows x64, Linux x64 (glibc 2.34+), macOS arm64/x64, '
        'iOS device/simulator, Android arm64/x64. Web is not packaged — '
        'this package imports dart:ffi and dart:io.',
      );
    }
    if (os == OS.android || os == OS.iOS) {
      // Gradle/CocoaPods/SPM still own the mobile files. Native anchors in
      // the desktop loader are never called on these platforms.
      registerUnusedAnchors(input, output);
      return;
    }
    await prepareDesktop(input, output);
  });
}
