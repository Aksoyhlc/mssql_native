// swift-tools-version: 5.9
import PackageDescription

// The product MUST be named "mssql-native" with a hyphen. Flutter generates the
// app's target dependency as plugin.name.replaceAll('_', '-') because Swift
// Package Manager uses the library name as the CFBundleIdentifier when linking
// dynamically, and bundle identifiers cannot contain underscores. A product
// named "mssql_native" will not resolve.
//
// Each binaryTarget's name must equal its XCFramework's basename, or Xcode
// fails with "binary target ... could not be mapped to an artifact with
// expected name". A bare `swift build` tolerates a mismatch; Xcode does not.
let package = Package(
    name: "mssql_native",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13)
    ],
    products: [
        .library(name: "mssql-native", targets: ["mssql_native_plugin"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        // FreeTDS DB-Library. Dynamic on purpose: it is LGPL v2, and shipping
        // it as a dynamic framework satisfies the relink provision.
        .binaryTarget(
            name: "sybdb",
            path: "Frameworks/sybdb.xcframework"
        ),
        // The C library that owns DB-Library's global error handlers, linking
        // sybdb at @rpath/sybdb.framework/Versions/A/sybdb. Not named
        // mssql_native: CocoaPods already builds a pod module framework by
        // that name. See native/include/mssql_native_handlers.h.
        .binaryTarget(
            name: "MssqlNativeBridge",
            path: "Frameworks/MssqlNativeBridge.xcframework"
        ),
        // Swift Package Manager requires at least one regular target.
        .target(
            name: "mssql_native_plugin",
            dependencies: [
                "MssqlNativeBridge",
                "sybdb",
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            path: "Sources/mssql_native"
        )
    ]
)
