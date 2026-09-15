import 'dart:async';

import 'package:mssql_native/src/metadata_cache.dart';
import 'package:test/test.dart';

String keyFor(
  String object, {
  String schemaVersion = '',
  String database = 'shop',
}) => MssqlMetadataCache.key(
  host: 'db.internal',
  port: 1433,
  database: database,
  object: object,
  schemaVersion: schemaVersion,
);

void main() {
  group('invalidateWhere', () {
    late MssqlMetadataCache cache;

    setUp(() => cache = MssqlMetadataCache(maxEntries: 16));

    Future<void> seed(String key, Object value) =>
        cache.getOrLoad<Object>(key, () async => value);

    test('drops every entry the predicate accepts', () async {
      await seed(keyFor('proc:[dbo].[create_label]'), 1);
      await seed(keyFor('proc:[dbo].[create_label]', schemaVersion: 'v2'), 2);
      await seed(keyFor('proc:[dbo].[other]'), 3);
      expect(cache.length, 3);

      cache.invalidateWhere((k) => k.contains('create_label'));
      expect(cache.length, 1);
    });

    test(
      'a describe already in flight does not repopulate the cache',
      () async {
        final gate = Completer<int>();
        final pending = cache.getOrLoad<int>(
          keyFor('proc:[dbo].[x]'),
          () => gate.future,
        );

        cache.invalidateWhere((k) => true);
        gate.complete(7);

        expect(await pending, 7);
        expect(cache.length, 0);
      },
    );

    test('clear also stops an in-flight load from writing back', () async {
      final gate = Completer<int>();
      final pending = cache.getOrLoad<int>(
        keyFor('proc:[dbo].[x]'),
        () => gate.future,
      );
      cache.clear();
      gate.complete(7);
      expect(await pending, 7);
      expect(cache.length, 0);
    });

    test('a load that finishes with no invalidation still caches', () async {
      final gate = Completer<int>();
      final pending = cache.getOrLoad<int>(
        keyFor('proc:[dbo].[x]'),
        () => gate.future,
      );
      gate.complete(7);
      expect(await pending, 7);
      expect(cache.length, 1);
    });
  });

  group('objectMatcher', () {
    bool Function(String) matcher(String quoted, {bool bare = false}) =>
        MssqlMetadataCache.objectMatcher(
          host: 'db.internal',
          port: 1433,
          database: 'shop',
          quotedObject: quoted,
          bareName: bare,
        );

    test(
      'matches a procedure across every schema version it was cached under',
      () {
        final match = matcher('[dbo].[create_label]');
        expect(match(keyFor('proc:[dbo].[create_label]')), isTrue);
        expect(
          match(keyFor('proc:[dbo].[create_label]', schemaVersion: 'v7')),
          isTrue,
        );
      },
    );

    test('matches the table entry for the same name', () {
      final match = matcher('[dbo].[Orders]');
      expect(match(keyFor('table:[dbo].[Orders]')), isTrue);
    });

    test('leaves another object alone', () {
      final match = matcher('[dbo].[create_label]');
      expect(match(keyFor('proc:[dbo].[create_labels]')), isFalse);
      expect(match(keyFor('proc:[dbo].[other]')), isFalse);
    });

    test('leaves another database alone', () {
      final match = matcher('[dbo].[create_label]');
      expect(
        match(keyFor('proc:[dbo].[create_label]', database: 'warehouse')),
        isFalse,
      );
    });

    test(
      'a name given without a schema matches whichever schema cached it',
      () {
        final match = matcher('[create_label]', bare: true);
        expect(match(keyFor('proc:[dbo].[create_label]')), isTrue);
        expect(match(keyFor('proc:[sales].[create_label]')), isTrue);
        expect(match(keyFor('proc:[create_label]')), isTrue);
        expect(match(keyFor('proc:[dbo].[other]')), isFalse);
      },
    );

    test('a schema-qualified name does not match another schema', () {
      final match = matcher('[dbo].[create_label]');
      expect(match(keyFor('proc:[sales].[create_label]')), isFalse);
    });
  });
}

