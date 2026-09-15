// The real native bridge is built by scripts/build_macos.sh and shipped as the
// MssqlNativeBridge.xcframework binary target. Swift Package Manager requires
// the package to have at least one non-binary target, which this file provides.
void mssql_native_plugin_placeholder(void) {}
