import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

/// Copies the ready-made dylibs, when the package carries them.
///
/// They are staged by scripts/build_darwin.sh with install names, an
/// @loader_path rpath and an ad-hoc signature already applied, so nothing runs
/// here. The fallback below needs Xcode command-line tools, which `dart run`
/// should not require.
Future<bool> _stagePrebuiltMacOS(
  BuildInput input,
  BuildOutputBuilder output,
) async {
  final directory = input.outputDirectory;
  final sources = <({String filename, String asset})>[
    (filename: 'libsybdb.dylib', asset: 'sybdb'),
    (filename: 'libmssql_native.dylib', asset: 'handlers'),
  ];
  final architecture =
      input.config.code.targetArchitecture == Architecture.arm64
      ? 'arm64'
      : 'x64';
  final files = <Uri>[
    for (final entry in sources)
      input.packageRoot.resolve('darwin/lib/$architecture/${entry.filename}'),
  ];
  for (final file in files) {
    if (!await File.fromUri(file).exists()) return false;
  }
  for (var i = 0; i < sources.length; i++) {
    output.dependencies.add(files[i]);
    final staged = await File.fromUri(files[i]).copy(
      directory.resolve(sources[i].filename).toFilePath(),
    );
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: sources[i].asset,
        file: staged.uri,
        linkMode: DynamicLoadingBundled(),
      ),
    );
  }
  return true;
}

Future<void> prepareMacOS(BuildInput input, BuildOutputBuilder output) async {
  await Directory.fromUri(input.outputDirectory).create(recursive: true);
  if (await _stagePrebuiltMacOS(input, output)) return;

  if (!Platform.isMacOS) {
    throw UnsupportedError(
      'Build macOS applications on macOS with Xcode '
      'command-line tools available.',
    );
  }
  final architecture =
      input.config.code.targetArchitecture == Architecture.arm64
      ? 'arm64'
      : 'x86_64';
  final directory = input.outputDirectory;

  Future<void> tool(String name, List<String> arguments) async {
    final result = await Process.run('xcrun', [name, ...arguments]);
    if (result.exitCode != 0) {
      throw StateError(
        '$name failed (${result.exitCode}): '
        '${result.stderr}\n${result.stdout}',
      );
    }
  }

  for (final entry in [
    (framework: 'sybdb', filename: 'libsybdb.dylib', asset: 'sybdb'),
    (
      framework: 'MssqlNativeBridge',
      filename: 'libmssql_native.dylib',
      asset: 'handlers',
    ),
  ]) {
    final source = input.packageRoot.resolve(
      'darwin/mssql_native/Frameworks/'
      '${entry.framework}.xcframework/macos-arm64_x86_64/'
      '${entry.framework}.framework/Versions/A/${entry.framework}',
    );
    output.dependencies.add(source);
    final target = directory.resolve(entry.filename).toFilePath();
    await tool('lipo', [
      source.toFilePath(),
      '-thin',
      architecture,
      '-output',
      target,
    ]);
    await tool('install_name_tool', [
      '-id',
      '@rpath/${entry.filename}',
      if (entry.asset == 'handlers') ...[
        '-change',
        '@rpath/sybdb.framework/Versions/A/sybdb',
        '@rpath/libsybdb.dylib',
        '-add_rpath',
        '@loader_path',
      ],
      target,
    ]);
    // Relocation invalidates the original signature. Re-sign hook output only;
    // Flutter will apply the application's signing identity when packaging it.
    final signing = await Process.run('codesign', [
      '--force',
      '--sign',
      '-',
      target,
    ]);
    if (signing.exitCode != 0) {
      throw StateError('Could not sign ${entry.filename}: ${signing.stderr}');
    }
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: entry.asset,
        file: Uri.file(target),
        linkMode: DynamicLoadingBundled(),
      ),
    );
  }
}
