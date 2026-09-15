import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:mssql_native/src/native/asset_ids.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

import 'macos.dart';

const _anchors = [sybdbAsset, handlersAsset];

void registerUnusedAnchors(
  BuildInput input,
  BuildOutputBuilder output, {
  Iterable<String> assets = _anchors,
}) {
  for (final asset in assets) {
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: asset.split('/').last,
        linkMode: LookupInProcess(),
      ),
    );
  }
}

Future<void> prepareDesktop(BuildInput input, BuildOutputBuilder output) async {
  final os = input.config.code.targetOS;
  final architecture = input.config.code.targetArchitecture;
  if (os == OS.macOS &&
      (architecture == Architecture.arm64 ||
          architecture == Architecture.x64)) {
    await prepareMacOS(input, output);
    registerUnusedAnchors(input, output, assets: const []);
    return;
  }
  if ((os != OS.linux && os != OS.windows) ||
      architecture != Architecture.x64) {
    throw UnsupportedError(
      'mssql_native has no bundled desktop library for '
      '${os.name}/${architecture.name}. Supported: Linux x64 (glibc 2.34+), '
      'Windows x64, macOS arm64/x64.',
    );
  }

  await Directory.fromUri(input.outputDirectory).create(recursive: true);
  final platform = os == OS.windows ? 'windows' : 'linux';
  final vendor = input.packageRoot.resolve('$platform/vendor/freetds/');
  final features = vendor.resolve('freetds_features.cmake');
  output.dependencies.add(features);
  final metadata = await File.fromUri(features).readAsString();
  final match = RegExp(
    r'set\(MSSQL_NATIVE_HAS_TLS\s+(ON|OFF)\)',
  ).firstMatch(metadata);
  if (match == null) {
    throw FormatException('Missing TLS capability in $features');
  }

  Future<void> stage(String source, String filename, String asset) async {
    final sourceUri = vendor.resolve(source);
    output.dependencies.add(sourceUri);
    final file = await File.fromUri(
      sourceUri,
    ).copy(input.outputDirectory.resolve(filename).toFilePath());
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: asset.split('/').last,
        linkMode: DynamicLoadingBundled(),
        file: file.uri,
      ),
    );
  }

  if (os == OS.linux) {
    // Preserve the ELF SONAME required by the handler's DT_NEEDED entry.
    // Copy the real file, not a symlink back into the package cache.
    await stage('lib/libsybdb.so.5.1.0', 'libsybdb.so.5', sybdbAsset);
    registerUnusedAnchors(input, output, assets: const []);
  } else {
    // OpenSSL, iconv and the MSVC runtime are linked statically into sybdb.dll.
    // Keeping the Windows payload to two DLLs avoids loader-order traps and a
    // machine-wide Visual C++ Redistributable prerequisite.
    await stage('bin/sybdb.dll', 'sybdb.dll', sybdbAsset);
    output.dependencies.add(vendor.resolve('lib/sybdb.lib'));
  }

  // The handler ships built, like the Apple and Android binaries do, so that
  // using this package needs no C toolchain. It is only compiled here when
  // there is no prebuilt file to use, or when the staged FreeTDS is a
  // maintainer's own build whose TLS capability the shipped handler would
  // misreport.
  final prebuilt = input.packageRoot.resolve(
    os == OS.windows
        ? 'windows/bin/mssql_native.dll'
        : 'linux/lib/libmssql_native.so',
  );
  final prebuiltFile = File.fromUri(prebuilt);
  if (match.group(1) == 'ON' && await prebuiltFile.exists()) {
    output.dependencies.add(prebuilt);
    final filename = os == OS.windows
        ? 'mssql_native.dll'
        : 'libmssql_native.so';
    final staged = await prebuiltFile.copy(
      input.outputDirectory.resolve(filename).toFilePath(),
    );
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: handlersAsset.split('/').last,
        linkMode: DynamicLoadingBundled(),
        file: staged.uri,
      ),
    );
    return;
  }

  // CBuilder discovers the platform compiler; consumers never invoke CMake
  // or rebuild FreeTDS/OpenSSL. Its Linux rpath is $ORIGIN for relocation.
  final builder = CBuilder.library(
    name: 'mssql_native',
    assetName: 'handlers',
    sources: ['native/src/handlers.c'],
    includes: ['native/include', '$platform/vendor/freetds/include'],
    defines: {if (match.group(1) == 'ON') 'MSSQL_NATIVE_HAS_TLS': '1'},
    libraries: [os == OS.windows ? 'sybdb' : ':libsybdb.so.5'],
    libraryDirectories: [
      if (os == OS.windows) vendor.resolve('lib/').toFilePath(),
      input.outputDirectory.toFilePath(),
    ],
    linkModePreference: LinkModePreference.dynamic,
  );
  // Include every staged header, including the generated platform header.
  await for (final file in Directory.fromUri(
    vendor.resolve('include/'),
  ).list(recursive: true)) {
    if (file is File) output.dependencies.add(file.uri);
  }
  output.dependencies.add(
    input.packageRoot.resolve('native/include/mssql_native_handlers.h'),
  );
  await builder.run(input: input, output: output);
}
