# Dart Frog native-assets acceptance fixture

This small server is built and executed by the Linux workflow against its SQL
Server service. It proves that `dart_frog build` followed by `dart build cli`
includes and resolves mssql_native without a native script or library path.

It is an acceptance fixture rather than a production architecture example: a
real service should initialize once at startup and share a connection pool.
