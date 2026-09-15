import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'asset_ids.dart';

// These anchors let Dart resolve code assets in both `dart run` and relocated
// AOT/Flutter bundles. No path into .dart_tool or the pub cache is hardcoded.
// The driver still uses its existing DynamicLibrary bindings in each worker.
@Native<Pointer<Utf8> Function()>(assetId: sybdbAsset, symbol: 'dbversion')
external Pointer<Utf8> _dbVersion();

@Native<Int32 Function()>(
  assetId: handlersAsset,
  symbol: 'mssql_native_handlers_abi',
)
external int _handlersAbi();

({String sybdb, String handlers}) desktopCodeAssetPaths() {
  // Load FreeTDS before the handler that depends on it. Keep its SONAME
  // resident so native dependency lookup and Dart workers use the same copy.
  final sybdb = _modulePath(
    Native.addressOf<NativeFunction<Pointer<Utf8> Function()>>(
      _dbVersion,
    ).cast(),
  );
  DynamicLibrary.open(sybdb);
  final handlers = _modulePath(
    Native.addressOf<NativeFunction<Int32 Function()>>(_handlersAbi).cast(),
  );
  return (sybdb: sybdb, handlers: handlers);
}

String _modulePath(Pointer<Void> symbol) =>
    Platform.isWindows ? _windowsModulePath(symbol) : _posixModulePath(symbol);

final class _DlInfo extends Struct {
  external Pointer<Utf8> filename;
  external Pointer<Void> base;
  external Pointer<Utf8> symbolName;
  external Pointer<Void> symbolAddress;
}

String _posixModulePath(Pointer<Void> symbol) {
  final dladdr = DynamicLibrary.process()
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<_DlInfo>),
        int Function(Pointer<Void>, Pointer<_DlInfo>)
      >('dladdr');
  final info = calloc<_DlInfo>();
  try {
    if (dladdr(symbol, info) == 0 || info.ref.filename == nullptr) {
      throw StateError('Could not locate the loaded mssql_native code asset.');
    }
    return File(info.ref.filename.toDartString()).absolute.path;
  } finally {
    calloc.free(info);
  }
}

String _windowsModulePath(Pointer<Void> symbol) {
  final kernel = DynamicLibrary.open('kernel32.dll');
  final getModule = kernel
      .lookupFunction<
        Int32 Function(Uint32, Pointer<Void>, Pointer<Pointer<Void>>),
        int Function(int, Pointer<Void>, Pointer<Pointer<Void>>)
      >('GetModuleHandleExW');
  final getFilename = kernel
      .lookupFunction<
        Uint32 Function(Pointer<Void>, Pointer<Utf16>, Uint32),
        int Function(Pointer<Void>, Pointer<Utf16>, int)
      >('GetModuleFileNameW');
  final module = calloc<Pointer<Void>>();
  const capacity = 32768;
  final filename = calloc<Uint16>(capacity).cast<Utf16>();
  try {
    // FROM_ADDRESS | UNCHANGED_REFCOUNT; the address is not a UTF-16 string.
    if (getModule(0x00000004 | 0x00000002, symbol, module) == 0) {
      throw StateError('Could not locate the loaded mssql_native DLL.');
    }
    final length = getFilename(module.value, filename, capacity);
    if (length == 0 || length >= capacity) {
      throw StateError('Could not read the mssql_native DLL path.');
    }
    return filename.toDartString(length: length);
  } finally {
    calloc.free(filename);
    calloc.free(module);
  }
}
