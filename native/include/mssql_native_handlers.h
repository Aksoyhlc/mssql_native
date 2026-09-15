// The one thing DB-Library will not let Dart do.
//
// FreeTDS reports errors and server messages through two function pointers set
// by dberrhandle() and dbmsghandle(). They are process-global statics
// (src/dblib/dblib.c:168-169), while a Dart callback made with
// Pointer.fromFunction may only be invoked on the isolate that created it. Each
// connection in this driver owns an isolate, so whichever isolate installed the
// handlers last owned the global, and the next isolate to hit an error invoked
// a foreign callback and the VM aborted the process with "Cannot invoke native
// callback from a different isolate".
//
// The two handlers therefore have to be C. That is all this library is: a
// recorder. It classifies nothing, retries nothing and holds no connection
// state - the driver's logic stays in Dart, where it is unit tested.
//
// State is thread-local, not keyed by DBPROCESS, for two reasons: a login
// failure fires the handlers with a NULL DBPROCESS, and a Dart isolate cannot
// migrate threads in the middle of a synchronous FFI call, so the thread that
// provokes an error is the thread that reads it back.
#ifndef MSSQL_NATIVE_HANDLERS_H
#define MSSQL_NATIVE_HANDLERS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define MSSQL_NATIVE_EXPORT __declspec(dllexport)
#else
#define MSSQL_NATIVE_EXPORT __attribute__((visibility("default")))
#endif

// Bumped when the exported surface changes, so Dart can refuse a stale library
// instead of reading the wrong fields.
#define MSSQL_NATIVE_HANDLERS_ABI 4

MSSQL_NATIVE_EXPORT int32_t mssql_native_handlers_abi(void);

// Whether the FreeTDS this was built alongside has a TLS backend.
//
// Answered at compile time by the build script, which is the only thing that
// knows: FreeTDS exports no symbol that reveals it, and configuring
// --without-openssl produces a library that connects happily and simply never
// encrypts. Without this the driver could only report "login failed" for a
// connection that asked for encryption it could never get.
MSSQL_NATIVE_EXPORT int32_t mssql_native_handlers_has_tls(void);

// Points FreeTDS at a freetds.conf, by setting FREETDSCONF for the process.
//
// Certificate trust - `ca file`, `crl file`, `check certificate hostname` - can
// only be configured through that file. dbsetlname reaches exactly one TLS
// setting, `encryption` (dblib.c:811), and FreeTDS exports none of its internal
// tds_* functions, so there is no per-connection route to the rest.
//
// Must be called before the first connection: FreeTDS reads the file while
// building each login. Returns 1 on success.
MSSQL_NATIVE_EXPORT int32_t mssql_native_handlers_set_config_path(
    const char* path);

// Calls dbinit(), then installs both handlers. Safe to call from every isolate:
// the installed pointers are these C functions, identical in every isolate, so
// there is no isolate ownership to get wrong. Returns 1 on success.
MSSQL_NATIVE_EXPORT int32_t mssql_native_handlers_install(void);

// Balances one successful install. release_all is a final safety drain used
// only after every worker has exited.
MSSQL_NATIVE_EXPORT void mssql_native_handlers_release(void);
MSSQL_NATIVE_EXPORT void mssql_native_handlers_release_all(void);

// Clears this thread's recorded state. Call before each DB-Library operation.
MSSQL_NATIVE_EXPORT void mssql_native_handlers_reset(void);

// Installs C interrupt callbacks on one DBPROCESS and returns their opaque,
// connection-local state. Dart must never register Pointer.fromFunction here:
// FreeTDS may poll these callbacks where no owning Dart isolate is current.
MSSQL_NATIVE_EXPORT void* mssql_native_interrupt_attach(void* dbproc);
MSSQL_NATIVE_EXPORT void mssql_native_interrupt_detach(void* dbproc);

// Arms one operation. timeout_millis <= 0 means no deadline. Cancellation is
// requested from another isolate by setting an atomic flag; it never enters
// DB-Library concurrently with the worker that owns dbproc.
MSSQL_NATIVE_EXPORT void mssql_native_interrupt_arm(
    void* state, int64_t timeout_millis);
MSSQL_NATIVE_EXPORT void mssql_native_interrupt_disarm(void* state);
MSSQL_NATIVE_EXPORT void mssql_native_interrupt_request(void* state);

// 0 = none, 1 = user cancellation, 2 = deadline expired.
MSSQL_NATIVE_EXPORT int32_t mssql_native_interrupt_reason(void* state);

// The last error the error handler saw on this thread.
MSSQL_NATIVE_EXPORT int32_t mssql_native_handlers_has_error(void);
MSSQL_NATIVE_EXPORT int32_t mssql_native_handlers_error_code(void);
MSSQL_NATIVE_EXPORT int32_t mssql_native_handlers_error_severity(void);
MSSQL_NATIVE_EXPORT int32_t mssql_native_handlers_error_os(void);
MSSQL_NATIVE_EXPORT const char* mssql_native_handlers_error_text(void);
MSSQL_NATIVE_EXPORT const char* mssql_native_handlers_error_os_text(void);

// Server messages recorded on this thread, oldest first. Text pointers stay
// valid until the next reset on the same thread.
MSSQL_NATIVE_EXPORT int32_t mssql_native_handlers_message_count(void);
MSSQL_NATIVE_EXPORT int32_t mssql_native_handlers_message_number(int32_t index);
MSSQL_NATIVE_EXPORT int32_t mssql_native_handlers_message_severity(int32_t index);
MSSQL_NATIVE_EXPORT int32_t mssql_native_handlers_message_state(int32_t index);
MSSQL_NATIVE_EXPORT int32_t mssql_native_handlers_message_line(int32_t index);
MSSQL_NATIVE_EXPORT const char* mssql_native_handlers_message_text(int32_t index);
MSSQL_NATIVE_EXPORT const char* mssql_native_handlers_message_server(int32_t index);
MSSQL_NATIVE_EXPORT const char* mssql_native_handlers_message_procedure(int32_t index);

#ifdef __cplusplus
}
#endif

#endif
