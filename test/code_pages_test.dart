import 'dart:convert';

import 'package:mssql_native/src/native/code_pages.dart';
import 'package:test/test.dart';

void main() {
  group('encodeForCodePage', () {
    test('ASCII passes through whatever the code page is', () {
      for (final codePage in <int>[0, 1252, 1254, 932, 65001]) {
        expect(
          encodeForCodePage('DSK-LMP-001', codePage, 'sku'),
          utf8.encode('DSK-LMP-001'),
          reason: 'code page $codePage',
        );
      }
    });

    test('CP1254 encodes the Turkish letters to their own bytes', () {
      expect(encodeForCodePage('ÖZEL ÜRÜN ŞİŞLİ', 1254, 'narrow'), <int>[
        0xD6, 0x5A, 0x45, 0x4C, 0x20,
        0xDC, 0x52, 0xDC, 0x4E, 0x20,
        0xDE, 0xDD, 0xDE, 0x4C, 0xDD,
      ]);
    });

    test('CP1254 encodes the lower-case Turkish letters', () {
      expect(encodeForCodePage('çğıöşü', 1254, 'narrow'), <int>[
        0xE7,
        0xF0,
        0xFD,
        0xF6,
        0xFE,
        0xFC,
      ]);
    });

    test('the dotless ı and the dotted İ are distinct bytes', () {
      expect(encodeForCodePage('ı', 1254, 'c'), <int>[0xFD]);
      expect(encodeForCodePage('İ', 1254, 'c'), <int>[0xDD]);
      expect(encodeForCodePage('i', 1254, 'c'), <int>[0x69]);
      expect(encodeForCodePage('I', 1254, 'c'), <int>[0x49]);
    });

    test('CP1254 and CP1252 differ exactly where they should', () {
      expect(encodeForCodePage('Ð', 1252, 'c'), <int>[0xD0]);
      expect(encodeForCodePage('Ğ', 1254, 'c'), <int>[0xD0]);
      expect(encodeForCodePage('Ý', 1252, 'c'), <int>[0xDD]);
      expect(encodeForCodePage('Þ', 1252, 'c'), <int>[0xDE]);
      expect(
        () => encodeForCodePage('Ğ', 1252, 'c'),
        throwsA(isA<CodePageError>()),
      );
      expect(
        () => encodeForCodePage('Ý', 1254, 'c'),
        throwsA(isA<CodePageError>()),
      );
      expect(
        () => encodeForCodePage('Ž', 1254, 'c'),
        throwsA(isA<CodePageError>()),
      );
      expect(encodeForCodePage('Ž', 1252, 'c'), <int>[0x8E]);
    });

    test('the shared upper half is Latin-1', () {
      expect(encodeForCodePage('äöüßé', 1254, 'c'), <int>[
        0xE4,
        0xF6,
        0xFC,
        0xDF,
        0xE9,
      ]);
      expect(encodeForCodePage('äöüßé', 1252, 'c'), <int>[
        0xE4,
        0xF6,
        0xFC,
        0xDF,
        0xE9,
      ]);
    });

    test('the CP1252 punctuation block is reachable in both', () {
      expect(encodeForCodePage('€', 1254, 'c'), <int>[0x80]);
      expect(encodeForCodePage('“”–—…', 1254, 'c'), <int>[
        0x93,
        0x94,
        0x96,
        0x97,
        0x85,
      ]);
    });

    test(
      'a character the code page cannot hold is refused, not approximated',
      () {
        expect(
          () => encodeForCodePage('Москва', 1254, 'narrow'),
          throwsA(
            isA<CodePageError>()
                .having((e) => e.message, 'message', contains('narrow'))
                .having((e) => e.message, 'message', contains('NVARCHAR')),
          ),
        );
      },
    );

    test('an emoji is refused rather than silently mangled', () {
      expect(
        () => encodeForCodePage('kayıt 🧿', 1254, 'label'),
        throwsA(isA<CodePageError>()),
      );
    });

    test('an unsupported code page is refused for non-ASCII', () {
      expect(
        () => encodeForCodePage('İstanbul', 1256, 'narrow'),
        throwsA(
          isA<CodePageError>()
              .having((e) => e.message, 'message', contains('1256'))
              .having((e) => e.message, 'message', contains('narrow')),
        ),
      );
    });

    test('an unknown code page says so rather than printing zero', () {
      expect(
        () => encodeForCodePage('İstanbul', 0, 'narrow'),
        throwsA(
          isA<CodePageError>().having(
            (e) => e.message,
            'message',
            contains('unknown'),
          ),
        ),
      );
    });

    test('an empty string encodes to no bytes', () {
      expect(encodeForCodePage('', 1254, 'c'), isEmpty);
    });

    test('the supported set is what it says it is', () {
      expect(isSupportedCodePage(1254), isTrue);
      expect(isSupportedCodePage(1252), isTrue);
      expect(isSupportedCodePage(1256), isFalse);
      expect(isSupportedCodePage(0), isFalse);
    });
  });
}

