// Bindings for native/src/handlers.c.
//
// DB-Library stores error/message handlers as process-global function pointers.
// A Dart callback belongs to its creating isolate, but each connection has its
// own isolate. Installing Dart callbacks here can abort the VM when a second
// connection reports an error; C handlers record errors without that boundary.
// See native/include/mssql_native_handlers.h for the full reasoning.
//
// The library records; it does not decide. Classification lives in
// dblib_callbacks.dart, in Dart, where it is unit tested.
import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// The ABI this Dart code was written against.
///
/// Checked at load time so a stale native library is reported plainly instead
/// of read as though its fields were still in the same order.
const int handlersAbi = 4;

class Handlers {
  Handlers(DynamicLibrary lib)
    : _library = lib,
      abi = lib.lookupFunction<Int32 Function(), int Function()>(
        'mssql_native_handlers_abi',
      ),
      install = lib.lookupFunction<Int32 Function(), int Function()>(
        'mssql_native_handlers_install',
      ),
      hasTls = lib.lookupFunction<Int32 Function(), int Function()>(
        'mssql_native_handlers_has_tls',
      ),
      setConfigPath = lib
          .lookupFunction<
            Int32 Function(Pointer<Utf8>),
            int Function(Pointer<Utf8>)
          >('mssql_native_handlers_set_config_path'),
      reset = lib.lookupFunction<Void Function(), void Function()>(
        'mssql_native_handlers_reset',
      ),
      hasError = lib.lookupFunction<Int32 Function(), int Function()>(
        'mssql_native_handlers_has_error',
      ),
      errorCode = lib.lookupFunction<Int32 Function(), int Function()>(
        'mssql_native_handlers_error_code',
      ),
      errorSeverity = lib.lookupFunction<Int32 Function(), int Function()>(
        'mssql_native_handlers_error_severity',
      ),
      errorOs = lib.lookupFunction<Int32 Function(), int Function()>(
        'mssql_native_handlers_error_os',
      ),
      errorText = lib
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'mssql_native_handlers_error_text',
          ),
      errorOsText = lib
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'mssql_native_handlers_error_os_text',
          ),
      messageCount = lib.lookupFunction<Int32 Function(), int Function()>(
        'mssql_native_handlers_message_count',
      ),
      messageNumber = lib
          .lookupFunction<Int32 Function(Int32), int Function(int)>(
            'mssql_native_handlers_message_number',
          ),
      messageSeverity = lib
          .lookupFunction<Int32 Function(Int32), int Function(int)>(
            'mssql_native_handlers_message_severity',
          ),
      messageState = lib
          .lookupFunction<Int32 Function(Int32), int Function(int)>(
            'mssql_native_handlers_message_state',
          ),
      messageLine = lib
          .lookupFunction<Int32 Function(Int32), int Function(int)>(
            'mssql_native_handlers_message_line',
          ),
      messageText = lib
          .lookupFunction<
            Pointer<Utf8> Function(Int32),
            Pointer<Utf8> Function(int)
          >('mssql_native_handlers_message_text'),
      messageServer = lib
          .lookupFunction<
            Pointer<Utf8> Function(Int32),
            Pointer<Utf8> Function(int)
          >('mssql_native_handlers_message_server'),
      messageProcedure = lib
          .lookupFunction<
            Pointer<Utf8> Function(Int32),
            Pointer<Utf8> Function(int)
          >('mssql_native_handlers_message_procedure'),
      interruptAttach = lib
          .lookupFunction<
            Pointer<Void> Function(Pointer<Void>),
            Pointer<Void> Function(Pointer<Void>)
          >('mssql_native_interrupt_attach'),
      interruptDetach = lib
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('mssql_native_interrupt_detach'),
      interruptArm = lib
          .lookupFunction<
            Void Function(Pointer<Void>, Int64),
            void Function(Pointer<Void>, int)
          >('mssql_native_interrupt_arm'),
      interruptDisarm = lib
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('mssql_native_interrupt_disarm'),
      interruptRequest = lib
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('mssql_native_interrupt_request'),
      interruptReason = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('mssql_native_interrupt_reason');

  final DynamicLibrary _library;
  final int Function() abi;

  /// Calls `dbinit` and installs both handlers. Safe from every isolate: the
  /// installed pointers are C functions, identical in each one.
  final int Function() install;
  late final void Function() release = _library
      .lookupFunction<Void Function(), void Function()>(
        'mssql_native_handlers_release',
      );
  late final void Function() releaseAll = _library
      .lookupFunction<Void Function(), void Function()>(
        'mssql_native_handlers_release_all',
      );

  /// Whether the FreeTDS beside this library has a TLS backend. Decided when
  /// the build script configured FreeTDS; nothing at runtime can tell.
  final int Function() hasTls;

  /// Sets `FREETDSCONF` for the process, which is the only route to the
  /// certificate-trust settings.
  final int Function(Pointer<Utf8>) setConfigPath;

  /// Clears this thread's recorded state, before a DB-Library call.
  final void Function() reset;

  final int Function() hasError;
  final int Function() errorCode;
  final int Function() errorSeverity;
  final int Function() errorOs;
  final Pointer<Utf8> Function() errorText;
  final Pointer<Utf8> Function() errorOsText;

  final int Function() messageCount;
  final int Function(int) messageNumber;
  final int Function(int) messageSeverity;
  final int Function(int) messageState;
  final int Function(int) messageLine;
  final Pointer<Utf8> Function(int) messageText;
  final Pointer<Utf8> Function(int) messageServer;
  final Pointer<Utf8> Function(int) messageProcedure;

  final Pointer<Void> Function(Pointer<Void>) interruptAttach;
  final void Function(Pointer<Void>) interruptDetach;
  final void Function(Pointer<Void>, int) interruptArm;
  final void Function(Pointer<Void>) interruptDisarm;
  final void Function(Pointer<Void>) interruptRequest;
  final int Function(Pointer<Void>) interruptReason;
}
