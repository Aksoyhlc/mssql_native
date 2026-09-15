#include "mssql_native_handlers.h"

#include <stdlib.h>
#include <string.h>
#include <sybdb.h>

#if defined(_WIN32)
#include <windows.h>
static volatile LONG g_initializations = 0;
static void initialization_acquired(void) { InterlockedIncrement(&g_initializations); }
static int initialization_released(void) {
  while (1) {
    LONG current = g_initializations;
    if (current <= 0) return 0;
    if (InterlockedCompareExchange(&g_initializations, current - 1, current) == current) return 1;
  }
}
static LONG initializations_drained(void) {
  return InterlockedExchange(&g_initializations, 0);
}
#else
static int32_t g_initializations = 0;
static void initialization_acquired(void) {
  __sync_add_and_fetch(&g_initializations, 1);
}
static int initialization_released(void) {
  while (1) {
    int32_t current = __sync_add_and_fetch(&g_initializations, 0);
    if (current <= 0) return 0;
    if (__sync_bool_compare_and_swap(&g_initializations, current, current - 1)) return 1;
  }
}
static int32_t initializations_drained(void) {
  return __sync_lock_test_and_set(&g_initializations, 0);
}
#endif

#define MSSQL_NATIVE_INTERRUPT_NONE 0
#define MSSQL_NATIVE_INTERRUPT_CANCEL 1
#define MSSQL_NATIVE_INTERRUPT_TIMEOUT 2

typedef struct {
  volatile int32_t reason;
  volatile int64_t deadline_millis;
} mssql_native_interrupt_state;

#if defined(_WIN32)
static int64_t monotonic_millis(void) { return (int64_t)GetTickCount64(); }
static int32_t atomic_load_i32(volatile int32_t* value) {
  return (int32_t)InterlockedCompareExchange((volatile LONG*)value, 0, 0);
}
static void atomic_store_i32(volatile int32_t* value, int32_t next) {
  InterlockedExchange((volatile LONG*)value, (LONG)next);
}
static int32_t atomic_compare_exchange_i32(volatile int32_t* value,
                                           int32_t expected, int32_t next) {
  return InterlockedCompareExchange((volatile LONG*)value, (LONG)next,
                                    (LONG)expected) == expected;
}
static int64_t atomic_load_i64(volatile int64_t* value) {
  return (int64_t)InterlockedCompareExchange64((volatile LONG64*)value, 0, 0);
}
static void atomic_store_i64(volatile int64_t* value, int64_t next) {
  InterlockedExchange64((volatile LONG64*)value, (LONG64)next);
}
#else
#include <time.h>
static int64_t monotonic_millis(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}
static int32_t atomic_load_i32(volatile int32_t* value) {
  return __atomic_load_n(value, __ATOMIC_ACQUIRE);
}
static void atomic_store_i32(volatile int32_t* value, int32_t next) {
  __atomic_store_n(value, next, __ATOMIC_RELEASE);
}
static int32_t atomic_compare_exchange_i32(volatile int32_t* value,
                                           int32_t expected, int32_t next) {
  return __atomic_compare_exchange_n(value, &expected, next, 0,
                                     __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
}
static int64_t atomic_load_i64(volatile int64_t* value) {
  return __atomic_load_n(value, __ATOMIC_ACQUIRE);
}
static void atomic_store_i64(volatile int64_t* value, int64_t next) {
  __atomic_store_n(value, next, __ATOMIC_RELEASE);
}
#endif

static int interrupt_check(void* raw_dbproc) {
  DBPROCESS* dbproc = (DBPROCESS*)raw_dbproc;
  mssql_native_interrupt_state* state =
      (mssql_native_interrupt_state*)dbgetuserdata(dbproc);
  if (state == NULL) return 0;
  if (atomic_load_i32(&state->reason) != MSSQL_NATIVE_INTERRUPT_NONE) return 1;
  int64_t deadline = atomic_load_i64(&state->deadline_millis);
  if (deadline <= 0 || monotonic_millis() < deadline) return 0;
  atomic_compare_exchange_i32(&state->reason, MSSQL_NATIVE_INTERRUPT_NONE,
                              MSSQL_NATIVE_INTERRUPT_TIMEOUT);
  return 1;
}

static int interrupt_handle(void* raw_dbproc) {
  (void)raw_dbproc;
  return INT_CANCEL;
}

#if defined(_MSC_VER)
#define MSSQL_NATIVE_THREAD_LOCAL __declspec(thread)
#else
#define MSSQL_NATIVE_THREAD_LOCAL __thread
#endif

#define MSSQL_NATIVE_TEXT 1024
#define MSSQL_NATIVE_NAME 128

// Capped rather than grown: a runaway RAISERROR loop must not be able to make
// this library allocate without bound, and a caller that needs more than
// thirty-two messages from one statement is not reading them anyway.
#define MSSQL_NATIVE_MAX_MESSAGES 32

typedef struct {
  int32_t number;
  int32_t severity;
  int32_t state;
  int32_t line;
  char text[MSSQL_NATIVE_TEXT];
  char server[MSSQL_NATIVE_NAME];
  char procedure[MSSQL_NATIVE_NAME];
} mssql_native_message;

typedef struct {
  int32_t has_error;
  int32_t code;
  int32_t severity;
  int32_t os_error;
  char text[MSSQL_NATIVE_TEXT];
  char os_text[MSSQL_NATIVE_NAME];
  int32_t message_count;
  mssql_native_message messages[MSSQL_NATIVE_MAX_MESSAGES];
} mssql_native_state;

static MSSQL_NATIVE_THREAD_LOCAL mssql_native_state g_state;

// strncpy would leave the buffer unterminated on truncation, which is how a
// recorder like this turns a database error into a crash.
static void copy_text(char* destination, size_t size, const char* source) {
  if (size == 0) return;
  if (source == NULL) {
    destination[0] = '\0';
    return;
  }
  size_t length = strlen(source);
  if (length >= size) {
    length = size - 1;
    // Server text is UTF-8. Cutting at a byte offset can leave half a
    // character behind, which turns a database error into a decode failure on
    // the Dart side, so back off to the start of the truncated character.
    while (length > 0 && (source[length] & 0xC0) == 0x80) length--;
  }
  memcpy(destination, source, length);
  destination[length] = '\0';
}

static int error_handler(DBPROCESS* dbproc, int severity, int dberr, int oserr,
                        char* dberrstr, char* oserrstr) {
  (void)dbproc;
  g_state.has_error = 1;
  g_state.code = dberr;
  g_state.severity = severity;
  g_state.os_error = oserr;
  copy_text(g_state.text, sizeof(g_state.text), dberrstr);
  // Kept separate rather than folded into text: Dart renders it as "(OS 32:
  // Broken pipe)", and losing it loses the only clue for a socket-level
  // failure that FreeTDS describes only generically.
  copy_text(g_state.os_text, sizeof(g_state.os_text), oserrstr);
  // INT_CANCEL, not the default INT_EXIT: INT_EXIT terminates the process.
  return INT_CANCEL;
}

static int message_handler(DBPROCESS* dbproc, DBINT msgno, int msgstate,
                          int severity, char* msgtext, char* srvname,
                          char* procname, int line) {
  (void)dbproc;
  if (g_state.message_count >= MSSQL_NATIVE_MAX_MESSAGES) return 0;
  mssql_native_message* message = &g_state.messages[g_state.message_count++];
  message->number = (int32_t)msgno;
  message->severity = severity;
  message->state = msgstate;
  message->line = line;
  copy_text(message->text, sizeof(message->text), msgtext);
  copy_text(message->server, sizeof(message->server), srvname);
  copy_text(message->procedure, sizeof(message->procedure), procname);
  return 0;
}

int32_t mssql_native_handlers_abi(void) { return MSSQL_NATIVE_HANDLERS_ABI; }

int32_t mssql_native_handlers_has_tls(void) {
#ifdef MSSQL_NATIVE_HAS_TLS
  return 1;
#else
  return 0;
#endif
}

int32_t mssql_native_handlers_set_config_path(const char* path) {
  if (path == NULL || path[0] == '\0') return 0;
#if defined(_WIN32)
  // _putenv_s rather than setenv, which MSVC does not provide.
  return _putenv_s("FREETDSCONF", path) == 0 ? 1 : 0;
#else
  return setenv("FREETDSCONF", path, 1) == 0 ? 1 : 0;
#endif
}

int32_t mssql_native_handlers_install(void) {
  if (dbinit() != SUCCEED) return 0;
  initialization_acquired();
  dberrhandle(error_handler);
  dbmsghandle(message_handler);
  return 1;
}

void mssql_native_handlers_release(void) {
  if (initialization_released()) dbexit();
}

void mssql_native_handlers_release_all(void) {
  int32_t count = (int32_t)initializations_drained();
  while (count-- > 0) dbexit();
}

void mssql_native_handlers_reset(void) {
  g_state.has_error = 0;
  g_state.code = 0;
  g_state.severity = 0;
  g_state.os_error = 0;
  g_state.text[0] = '\0';
  g_state.os_text[0] = '\0';
  // Only the count is cleared. The message bodies are overwritten as they are
  // recorded, and zeroing 32 KB before every statement would be the most
  // expensive thing this library does.
  g_state.message_count = 0;
}

void* mssql_native_interrupt_attach(void* raw_dbproc) {
  DBPROCESS* dbproc = (DBPROCESS*)raw_dbproc;
  if (dbproc == NULL) return NULL;
  mssql_native_interrupt_state* state =
      (mssql_native_interrupt_state*)calloc(1, sizeof(*state));
  if (state == NULL) return NULL;
  dbsetuserdata(dbproc, (BYTE*)state);
  dbsetinterrupt(dbproc, interrupt_check, interrupt_handle);
  return state;
}

void mssql_native_interrupt_detach(void* raw_dbproc) {
  DBPROCESS* dbproc = (DBPROCESS*)raw_dbproc;
  if (dbproc == NULL) return;
  mssql_native_interrupt_state* state =
      (mssql_native_interrupt_state*)dbgetuserdata(dbproc);
  dbsetinterrupt(dbproc, NULL, NULL);
  dbsetuserdata(dbproc, NULL);
  free(state);
}

void mssql_native_interrupt_arm(void* raw_state, int64_t timeout_millis) {
  mssql_native_interrupt_state* state =
      (mssql_native_interrupt_state*)raw_state;
  if (state == NULL) return;
  int64_t deadline = timeout_millis > 0
      ? monotonic_millis() + timeout_millis
      : 0;
  atomic_store_i64(&state->deadline_millis, deadline);
}

void mssql_native_interrupt_disarm(void* raw_state) {
  mssql_native_interrupt_state* state =
      (mssql_native_interrupt_state*)raw_state;
  if (state == NULL) return;
  atomic_store_i64(&state->deadline_millis, 0);
  atomic_store_i32(&state->reason, MSSQL_NATIVE_INTERRUPT_NONE);
}

void mssql_native_interrupt_request(void* raw_state) {
  mssql_native_interrupt_state* state =
      (mssql_native_interrupt_state*)raw_state;
  if (state == NULL) return;
  atomic_compare_exchange_i32(&state->reason, MSSQL_NATIVE_INTERRUPT_NONE,
                              MSSQL_NATIVE_INTERRUPT_CANCEL);
}

int32_t mssql_native_interrupt_reason(void* raw_state) {
  mssql_native_interrupt_state* state =
      (mssql_native_interrupt_state*)raw_state;
  return state == NULL ? MSSQL_NATIVE_INTERRUPT_NONE
                       : atomic_load_i32(&state->reason);
}

int32_t mssql_native_handlers_has_error(void) { return g_state.has_error; }
int32_t mssql_native_handlers_error_code(void) { return g_state.code; }
int32_t mssql_native_handlers_error_severity(void) { return g_state.severity; }
int32_t mssql_native_handlers_error_os(void) { return g_state.os_error; }
const char* mssql_native_handlers_error_text(void) { return g_state.text; }
const char* mssql_native_handlers_error_os_text(void) {
  return g_state.os_text;
}

int32_t mssql_native_handlers_message_count(void) {
  return g_state.message_count;
}

static int in_range(int32_t index) {
  return index >= 0 && index < g_state.message_count;
}

int32_t mssql_native_handlers_message_number(int32_t index) {
  return in_range(index) ? g_state.messages[index].number : 0;
}
int32_t mssql_native_handlers_message_severity(int32_t index) {
  return in_range(index) ? g_state.messages[index].severity : 0;
}
int32_t mssql_native_handlers_message_state(int32_t index) {
  return in_range(index) ? g_state.messages[index].state : 0;
}
int32_t mssql_native_handlers_message_line(int32_t index) {
  return in_range(index) ? g_state.messages[index].line : 0;
}
const char* mssql_native_handlers_message_text(int32_t index) {
  return in_range(index) ? g_state.messages[index].text : "";
}
const char* mssql_native_handlers_message_server(int32_t index) {
  return in_range(index) ? g_state.messages[index].server : "";
}
const char* mssql_native_handlers_message_procedure(int32_t index) {
  return in_range(index) ? g_state.messages[index].procedure : "";
}
