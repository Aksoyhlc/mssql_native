Pod::Spec.new do |s|
  s.name             = 'mssql_native'
  s.version          = '0.0.1'
  s.summary          = 'FreeTDS DB-Library and error handlers for the mssql_native Dart driver.'
  s.description      = <<-DESC
Ships FreeTDS DB-Library and a small C library that owns its global error handlers. The SQL Server driver itself is Dart, calling both through dart:ffi.
                       DESC
  # No public repository URL is recorded for this package yet. `publish_to` is
  # none in pubspec.yaml, and this pod is consumed from the local path above,
  # so the field is a placeholder rather than a location: keep it obviously
  # unresolvable instead of naming a repository that does not exist.
  s.homepage         = 'https://localhost/mssql_native'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Aksoyhlc' => 'aksoyhlc@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'mssql_native/Sources/mssql_native/**/*'
  s.osx.dependency 'FlutterMacOS'
  s.ios.dependency 'Flutter'
  s.osx.deployment_target = '10.15'
  s.ios.deployment_target = '13.0'
  # The same XCFrameworks the Swift package consumes, so CocoaPods and SPM
  # never ship differing binaries. The handler framework is MssqlNativeBridge,
  # not mssql_native: use_frameworks! already builds a pod module framework by
  # the pod's own name and the two would collide on one output path.
  s.vendored_frameworks = 'mssql_native/Frameworks/MssqlNativeBridge.xcframework',
                          'mssql_native/Frameworks/sybdb.xcframework'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'MACOSX_DEPLOYMENT_TARGET' => '10.15',
    'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks'
  }
end
