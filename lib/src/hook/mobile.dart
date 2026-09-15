import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

import '../native/asset_ids.dart';
import 'desktop.dart';

Future<void> prepareMobile(BuildInput input, BuildOutputBuilder output) async {
  final config = input.config.code;
  if (config.targetOS == OS.android) {
    await _prepareAndroid(input, output);
    return;
  }
  if (config.targetOS == OS.iOS) {
    await _prepareIOS(input, output);
    return;
  }
  throw UnsupportedError('No mobile library for ${config.targetOS.name}.');
}

Future<void> _prepareAndroid(
  BuildInput input,
  BuildOutputBuilder output,
) async {
  final architecture = input.config.code.targetArchitecture;
  // Flutter may build an arm32 slice by default. This package has never
  // shipped arm32 binaries; leave that slice without libraries, as the old
  // Gradle ABI filter did, while keeping the other slices buildable.
  if (architecture == Architecture.arm) {
    registerUnusedAnchors(input, output);
    return;
  }
  final abi = switch (architecture) {
    Architecture.arm64 => 'arm64-v8a',
    Architecture.x64 => 'x86_64',
    _ => throw UnsupportedError(
      'mssql_native has Android binaries for arm64 and x64, '
      'not ${architecture.name}.',
    ),
  };
  await _copyAndroidAsset(input, output, abi, 'libsybdb.so', sybdbAsset);
  await _copyAndroidAsset(
    input,
    output,
    abi,
    'libmssql_native.so',
    handlersAsset,
  );
}

Future<void> _copyAndroidAsset(
  BuildInput input,
  BuildOutputBuilder output,
  String abi,
  String filename,
  String assetId,
) async {
  final source = input.packageRoot.resolve(
    'android/src/main/jniLibs/$abi/$filename',
  );
  output.dependencies.add(source);
  await Directory.fromUri(input.outputDirectory).create(recursive: true);
  final file = await File.fromUri(
    source,
  ).copy(input.outputDirectory.resolve(filename).toFilePath());
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: assetId.split('/').last,
      linkMode: DynamicLoadingBundled(),
      file: file.uri,
    ),
  );
}

Future<void> _prepareIOS(BuildInput input, BuildOutputBuilder output) async {
  final config = input.config.code;
  final architecture = config.targetArchitecture;
  final sdk = config.iOS.targetSdk;
  if (sdk == IOSSdk.iPhoneOS && architecture != Architecture.arm64) {
    throw UnsupportedError('iOS devices require arm64.');
  }
  if (sdk == IOSSdk.iPhoneSimulator &&
      architecture != Architecture.arm64 &&
      architecture != Architecture.x64) {
    throw UnsupportedError('iOS simulators require arm64 or x64.');
  }
  final slice = sdk == IOSSdk.iPhoneOS
      ? 'ios-arm64'
      : 'ios-arm64_x86_64-simulator';
  final thinArchitecture = architecture == Architecture.arm64
      ? 'arm64'
      : 'x86_64';
  await Directory.fromUri(input.outputDirectory).create(recursive: true);

  for (final entry in [
    (framework: 'sybdb', filename: 'libsybdb.dylib', assetId: sybdbAsset),
    (
      framework: 'MssqlNativeBridge',
      filename: 'libMssqlNativeBridge.dylib',
      assetId: handlersAsset,
    ),
  ]) {
    final source = input.packageRoot.resolve(
      'darwin/mssql_native/Frameworks/'
      '${entry.framework}.xcframework/$slice/'
      '${entry.framework}.framework/${entry.framework}',
    );
    output.dependencies.add(source);
    final target = input.outputDirectory.resolve(entry.filename);
    if (sdk == IOSSdk.iPhoneOS) {
      await File.fromUri(source).copy(target.toFilePath());
    } else {
      final result = await Process.run('lipo', [
        source.toFilePath(),
        '-thin',
        thinArchitecture,
        '-output',
        target.toFilePath(),
      ]);
      if (result.exitCode != 0) {
        throw StateError(
          'Could not extract ${entry.framework} for '
          '$slice/$thinArchitecture: ${result.stderr}',
        );
      }
    }
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: entry.assetId.split('/').last,
        linkMode: DynamicLoadingBundled(),
        file: target,
      ),
    );
  }
}
