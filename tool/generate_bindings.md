# Bindings policy

The public C ABI is intentionally small and manually bound in Dart. If the
header changes, update `lib/src/native/native_types.dart` and `bindings.dart`
in the same commit, increment `mssql_native_get_abi_version`, then add a struct-size and
packet compatibility test. Do not expose FreeTDS structs directly to Dart.
