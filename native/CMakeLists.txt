cmake_minimum_required(VERSION 3.13)
if(POLICY CMP0091)
  cmake_policy(SET CMP0091 NEW)
endif()
# C, not C++: this library is a hundred lines of recorder, and plain C keeps it
# free of a C++ runtime dependency on every platform it has to ship to.
project(mssql_native_handlers LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_VISIBILITY_PRESET hidden)
if(MSVC)
  set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

if(NOT DEFINED FREETDS_INCLUDE_DIR OR NOT DEFINED FREETDS_LIBRARY)
  message(FATAL_ERROR "FREETDS_INCLUDE_DIR and FREETDS_LIBRARY must be set.")
endif()

# The target keeps the name mssql_native so the shipped file names
# (mssql_native.dll, libmssql_native.so, MssqlNativeBridge.framework) and the
# paths in lib/src/native/library_paths.dart stay as they were.
add_library(mssql_native SHARED src/handlers.c)
target_include_directories(mssql_native PRIVATE include "${FREETDS_INCLUDE_DIR}")
target_link_libraries(mssql_native PRIVATE "${FREETDS_LIBRARY}")

# The build script knows whether FreeTDS was configured with a TLS backend and
# nothing else does: FreeTDS exports no symbol that reveals it, and a build
# without one connects happily and simply never encrypts.
option(MSSQL_NATIVE_HAS_TLS "FreeTDS was built with a TLS backend" OFF)
if(MSSQL_NATIVE_HAS_TLS)
  target_compile_definitions(mssql_native PRIVATE MSSQL_NATIVE_HAS_TLS=1)
endif()

if(APPLE)
  # Resolved next to this library once both are embedded as frameworks; the
  # exact rpath is added by scripts/build_darwin.sh, which knows the layout.
  set_target_properties(mssql_native PROPERTIES
    BUILD_WITH_INSTALL_RPATH FALSE)
elseif(UNIX)
  # BUILD_WITH_INSTALL_RPATH matters here: the build-tree binary is copied
  # straight into linux/lib rather than installed, so it must already carry its
  # final runpath. Without it, cmake adds the directory of the linked library -
  # the build machine's absolute path - to the build-tree rpath, and the shipped
  # libmssql_native.so ended up with
  # "$ORIGIN:/src/linux/vendor/freetds/lib" baked into it.
  set_target_properties(mssql_native PROPERTIES
    BUILD_WITH_INSTALL_RPATH TRUE
    INSTALL_RPATH "$ORIGIN")
endif()
