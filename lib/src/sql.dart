/// Utilities for quoting SQL identifiers and escaping LIKE patterns.
///
/// The driver and query builder use these methods instead of interpolating raw
/// identifiers or patterns into statements.
abstract final class MssqlSql {
  /// Brackets [identifier] and doubles any `]` inside it.
  ///
  /// Rejects empty, over-long or NUL-containing identifiers.
  static String quoteIdentifier(String identifier) {
    if (identifier.isEmpty ||
        identifier.length > 128 ||
        identifier.contains('\u0000')) {
      throw ArgumentError.value(
        identifier,
        'identifier',
        'SQL identifiers must contain 1 to 128 characters.',
      );
    }
    return '[${identifier.replaceAll(']', ']]')}]';
  }

  /// Quotes each of one to four [parts] and joins them with dots.
  static String quoteMultipartIdentifier(Iterable<String> parts) {
    final values = List<String>.of(parts);
    if (values.isEmpty || values.length > 4) {
      throw ArgumentError.value(
        values,
        'parts',
        'A SQL multipart identifier requires between one and four parts.',
      );
    }
    return values.map(quoteIdentifier).join('.');
  }

  /// Escapes the LIKE wildcards `%`, `_` and `[` in [value].
  ///
  /// [escapeCharacter] must be a single non-wildcard character; it defaults to
  /// backslash.
  static String escapeLike(String value, {String escapeCharacter = r'\'}) {
    if (escapeCharacter.length != 1 ||
        escapeCharacter == '%' ||
        escapeCharacter == '_' ||
        escapeCharacter == '[') {
      throw ArgumentError.value(
        escapeCharacter,
        'escapeCharacter',
        'Use one non-wildcard character as the LIKE escape character.',
      );
    }
    return value
        .replaceAll(escapeCharacter, '$escapeCharacter$escapeCharacter')
        .replaceAll('%', '$escapeCharacter%')
        .replaceAll('_', '${escapeCharacter}_')
        .replaceAll('[', '$escapeCharacter[');
  }
}

/// A parsed SQL identifier of up to four parts, such as `dbo.Users` or
/// `[my schema].[Order Lines]`.
///
/// Public so `mssql_orm` can share the parse rather than duplicate this
/// security-relevant logic.
class MssqlMultipartIdentifier {
  MssqlMultipartIdentifier._(this.parts);

  /// The identifier's parts, unquoted, in the order they were written.
  final List<String> parts;

  /// The identifier rewritten with every part bracket-quoted.
  String get quoted => MssqlSql.quoteMultipartIdentifier(parts);

  /// Parses [input], accepting bracketed and unquoted parts.
  ///
  /// [maximumParts] defaults to 3 (`schema.table.column`); raise it for a
  /// four-part server.database.schema.table name.
  static MssqlMultipartIdentifier parse(String input, {int maximumParts = 3}) {
    if (input.trim() != input || input.isEmpty) {
      throw ArgumentError.value(input, 'identifier', 'Invalid SQL identifier.');
    }
    final parts = <String>[];
    var index = 0;
    while (index < input.length) {
      String part;
      if (input.codeUnitAt(index) == 0x5b) {
        index++;
        final out = StringBuffer();
        var closed = false;
        while (index < input.length) {
          final code = input.codeUnitAt(index++);
          if (code != 0x5d) {
            out.writeCharCode(code);
            continue;
          }
          if (index < input.length && input.codeUnitAt(index) == 0x5d) {
            out.write(']');
            index++;
            continue;
          }
          closed = true;
          break;
        }
        if (!closed) {
          throw ArgumentError.value(
            input,
            'identifier',
            'Unclosed bracketed identifier.',
          );
        }
        part = out.toString();
      } else {
        final start = index;
        while (index < input.length && input.codeUnitAt(index) != 0x2e) {
          index++;
        }
        part = input.substring(start, index);
        // A leading # or ## is a temp table, which is an ordinary destination
        // for a bulk load and for staging a table-valued parameter.
        if (!RegExp(r'^[A-Za-z_#][A-Za-z0-9_@$#]*$').hasMatch(part)) {
          throw ArgumentError.value(
            input,
            'identifier',
            'Invalid unquoted SQL identifier.',
          );
        }
      }
      MssqlSql.quoteIdentifier(part);
      parts.add(part);
      if (parts.length > maximumParts) {
        throw ArgumentError.value(
          input,
          'identifier',
          'Expected at most $maximumParts identifier parts.',
        );
      }
      if (index == input.length) break;
      if (input.codeUnitAt(index) != 0x2e || ++index == input.length) {
        throw ArgumentError.value(
          input,
          'identifier',
          'Invalid multipart SQL identifier.',
        );
      }
    }
    return MssqlMultipartIdentifier._(List<String>.unmodifiable(parts));
  }
}
