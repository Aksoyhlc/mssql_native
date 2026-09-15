// Public header for the placeholder target. Swift Package Manager requires a C
// target to have an "include" directory, and an empty directory cannot be
// tracked in git, so the placeholder's declaration lives here.
//
// The driver's real API is the Dart FFI surface in lib/; nothing in the host
// application needs to import this.
#pragma once

void mssql_native_plugin_placeholder(void);
