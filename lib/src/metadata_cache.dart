import 'dart:collection';

import 'models/config.dart';
import 'models/types.dart';

/// Bounded cache for procedure and bulk-table metadata.
///
/// Caches completed describes and in-flight loads so concurrent callers
/// describe once. Raw SQL text is never a key: that would grow without bound
/// and pin tenant values in memory. [maxEntries] and [ttl] bound the cache;
/// [invalidate] covers schema changes the TTL has not seen.
/// Generator-supplied metadata skips this cache entirely; see
/// [MssqlMetadataDriftPolicy].
class MssqlMetadataCache {
  MssqlMetadataCache({int? maxEntries, Duration? ttl})
    : maxEntries = maxEntries ?? MssqlDefaults.metadataCacheSize,
      ttl = ttl ?? MssqlDefaults.metadataCacheTtl {
    if (this.maxEntries < 1) {
      throw ArgumentError.value(
        this.maxEntries,
        'maxEntries',
        'A metadata cache with no room cannot share a describe.',
      );
    }
    if (this.ttl < Duration.zero) {
      throw ArgumentError.value(
        this.ttl,
        'ttl',
        'A negative TTL is not a bound.',
      );
    }
  }

  /// Maximum number of entries. The oldest is evicted when a new one would
  /// exceed it. Must be at least 1.
  final int maxEntries;

  /// How long a completed entry is reused before describing again.
  ///
  /// [Duration.zero] shares only in-flight loads and keeps no completed entry,
  /// for callers that want coalescing without staleness.
  final Duration ttl;

  final LinkedHashMap<String, _MssqlMetadataEntry> _entries =
      LinkedHashMap<String, _MssqlMetadataEntry>();
  final Map<String, Future<Object?>> _inflight = <String, Future<Object?>>{};

  /// Bumped by every [invalidate] and [clear].
  ///
  /// A load records the generation it started under and discards its own
  /// result when the number has moved, so an invalidation during a describe is
  /// not undone by that describe completing.
  int _generation = 0;

  /// Server + database + object + optional generator schema version.
  ///
  /// Distinct versions are distinct entries, so a generated binding does not
  /// collide with a live describe of a drifted object.
  static String key({
    required String host,
    required int port,
    required String database,
    required String object,
    String schemaVersion = '',
  }) => '$host:$port/$database|$object|$schemaVersion';

  /// A predicate matching every entry held for one object.
  ///
  /// [quotedObject] is the quoted multipart name `MssqlMultipartIdentifier`
  /// writes. One object spans several keys: schema versions differ and
  /// procedures and tables share the namespace a caller types. [bareName]
  /// means no schema was given, so any schema matches.
  static bool Function(String key) objectMatcher({
    required String host,
    required int port,
    required String database,
    required String quotedObject,
    required bool bareName,
  }) {
    final prefix = '$host:$port/$database|';
    final exact = <String>{'proc:$quotedObject', 'table:$quotedObject'};
    return (String key) {
      if (!key.startsWith(prefix)) return false;
      final parts = key.split('|');
      if (parts.length < 2) return false;
      final object = parts[1];
      if (exact.contains(object)) return true;
      if (!bareName) return false;
      if (!object.startsWith('proc:') && !object.startsWith('table:')) {
        return false;
      }
      return object.endsWith('.$quotedObject');
    };
  }

  /// The cached value for [key], loading it once if it is missing or stale.
  Future<T> getOrLoad<T>(String key, Future<T> Function() load) async {
    final now = DateTime.now();
    final existing = _entries.remove(key);
    if (existing != null && !existing.isExpired(now, ttl)) {
      _entries[key] = existing;
      return existing.value as T;
    }
    final pending = _inflight[key];
    if (pending != null) return await pending as T;
    final future = _load<T>(key, load, _generation);
    _inflight[key] = future;
    try {
      return await future;
    } finally {
      // Identity check: a later load for the same key must not be evicted by
      // this one's cleanup.
      final current = _inflight[key];
      if (identical(current, future)) {
        // ignore: unawaited_futures
        _inflight.remove(key);
      }
    }
  }

  Future<T> _load<T>(
    String key,
    Future<T> Function() load,
    int generation,
  ) async {
    final value = await load();
    // Invalidated while this describe was in flight. The caller still gets
    // the server's answer; it is not cached, so the next caller describes
    // again.
    if (generation != _generation) return value;
    _entries.remove(key);
    while (_entries.length >= maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    _entries[key] = _MssqlMetadataEntry(value, DateTime.now());
    return value;
  }

  /// Drops cached entries.
  ///
  /// [key] drops one object; [prefix] drops every key that starts with it,
  /// used when the current database changes; omitting both drops everything.
  void invalidate({String? key, String? prefix}) {
    _generation++;
    if (key != null) {
      _entries.remove(key);
      _inflight.remove(key);
      return;
    }
    if (prefix != null) {
      final keys = _entries.keys.where((k) => k.startsWith(prefix)).toList();
      for (final k in keys) {
        _entries.remove(k);
      }
      final pending = _inflight.keys
          .where((k) => k.startsWith(prefix))
          .toList();
      for (final k in pending) {
        _inflight.remove(k);
      }
      return;
    }
    clear();
  }

  /// Drops every entry whose key [test] accepts, in-flight loads included.
  ///
  /// [MssqlConnection.invalidateMetadata] builds the predicate; a caller names
  /// an object, and one object spans several keys.
  void invalidateWhere(bool Function(String key) test) {
    _generation++;
    for (final key in _entries.keys.where(test).toList()) {
      _entries.remove(key);
    }
    for (final key in _inflight.keys.where(test).toList()) {
      _inflight.remove(key);
    }
  }

  /// Drops every entry and every in-flight load.
  void clear() {
    _generation++;
    _entries.clear();
    _inflight.clear();
  }

  /// How many completed entries are held right now.
  int get length => _entries.length;
}

class _MssqlMetadataEntry {
  _MssqlMetadataEntry(this.value, this.loadedAt);

  final Object? value;
  final DateTime loadedAt;

  bool isExpired(DateTime now, Duration ttl) {
    if (ttl == Duration.zero) return true;
    return now.difference(loadedAt) >= ttl;
  }
}

/// How generator-supplied procedure metadata is used.
///
/// Declared metadata avoids a round-trip the generator already paid for.
/// Describing ignores it. Verifying describes and refuses when the two
/// disagree.
enum MssqlMetadataDriftPolicy {
  /// Use [MssqlProcedureMetadata] when the caller gave it; describe only
  /// when they did not.
  preferDeclared,

  /// Always describe (through the cache). Declared metadata is ignored.
  alwaysDescribe,

  /// Describe (through the cache) and refuse when declared metadata
  /// disagrees with what the server has now.
  verifyDeclared,
}

/// One stored-procedure parameter, as produced by the generator or a describe.
///
/// Passed to `callProcedure` so a generated binding can skip the catalog
/// query. A table-valued parameter must name its type so the driver can build
/// the staging table.
class MssqlProcedureParameter {
  const MssqlProcedureParameter({
    required this.name,
    required this.type,
    this.size = 0,
    this.precision = 0,
    this.scale = 0,
    this.isOutput = false,
    this.isReadOnly = false,
    this.tableTypeName,
    this.tableTypeSchema,
  });

  final String name;
  final MssqlType type;
  final int size;
  final int precision;
  final int scale;
  final bool isOutput;
  final bool isReadOnly;
  final String? tableTypeName;
  final String? tableTypeSchema;
}

/// Generator- or describe-supplied parameters for one procedure.
///
/// [schemaVersion] is the generator's fingerprint of the procedure. Empty
/// means no version: the cache key then shares every describe of that object
/// on that database.
class MssqlProcedureMetadata {
  const MssqlProcedureMetadata({
    required this.procedure,
    required this.parameters,
    this.schemaVersion = '',
  });

  final String procedure;
  final List<MssqlProcedureParameter> parameters;
  final String schemaVersion;
}
