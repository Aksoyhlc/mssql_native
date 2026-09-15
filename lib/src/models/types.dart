enum MssqlType {
  bit,
  tinyInt,
  smallInt,
  int32,
  int64,
  real,
  float64,
  decimal,
  numeric,
  money,
  smallMoney,
  char,
  varchar,
  nchar,
  nvarchar,
  text,
  ntext,
  binary,
  varbinary,
  image,
  date,
  time,
  smallDateTime,
  dateTime,
  dateTime2,
  dateTimeOffset,
  uniqueIdentifier,
  xml,
}

/// How SQL Server's exact numeric types reach Dart.
///
/// `DECIMAL`, `NUMERIC`, `MONEY` and `SMALLMONEY` are exact on the server; this
/// chooses their Dart representation, defaulting to the exact one.
enum MssqlDecimalMode {
  /// [MssqlDecimal]: the exact value, with its scale.
  ///
  /// The default. Arithmetic stays exact, an 18-digit amount keeps all 18
  /// digits, and writing the value back sends the same number that was read.
  exact,

  /// The invariant text SQL Server sent: `'1234.5600'`.
  ///
  /// For code that wants to do its own thing with the digits, or that passes
  /// the value straight to something else that parses text.
  text,

  /// A potentially lossy `double`.
  ///
  /// A `double` holds about 15.7 significant digits where `DECIMAL(18,4)`
  /// carries 18, so a large amount loses its last digits
  /// (`99999999999999.9999` becomes `100000000000000.0`) and repeated addition
  /// drifts. Use only when that precision loss is acceptable.
  doublePrecision,
}

/// Direction used by explicitly typed SQL parameters.
enum MssqlParameterDirection { input, output, inputOutput }

/// The transaction isolation levels the driver can set.
enum MssqlIsolationLevel {
  /// The driver's baseline: READ COMMITTED, set at login and restored before a
  /// pooled connection is reused, so one transaction's choice cannot become the
  /// next one's default. A database with READ_COMMITTED_SNAPSHOT on keeps its
  /// snapshot behaviour under this.
  baseline,
  readUncommitted,
  readCommitted,
  repeatableRead,
  snapshot,
  serializable,
}

/// How much of the connection is encrypted.
///
/// SQL Server always encrypts the login packet, whatever this says; these
/// levels are about the rest of the session.
enum MssqlEncryption {
  /// No encryption beyond the login packet. FreeTDS's own default.
  off,

  /// Ask the server whether encryption is supported but do not require it.
  ///
  /// Against an ordinary SQL Server this means no session encryption, the same
  /// as [off]; the session is encrypted only when the server has Force
  /// Encryption on. FreeTDS sends `TDS7_ENCRYPT_OFF` here, meaning "I can, but
  /// I am not asking" (src/tds/login.c:1306). Choose this to comply with a
  /// server that requires encryption while staying compatible with one that
  /// does not; use [require] to be sure.
  request,

  /// Refuse to connect unless the whole session is encrypted.
  require,

  /// TLS before the login packet, as SQL Server 2022 and Azure call "strict".
  /// Needs a server configured for it; older servers will refuse.
  strict,
}

/// Whether a bulk copy commits as one unit or in batches.
enum MssqlBulkMode { atomic, batched }

/// Categories used to classify driver failures.
enum MssqlErrorType {
  configuration,
  libraryLoad,
  authentication,

  /// TLS could not be established on the terms the configuration asked for.
  ///
  /// Its own type rather than [configuration] because the caller's reaction
  /// differs: a configuration error is a program to fix, while a TLS failure
  /// is usually a certificate or a trust store to fix on the machine, and the
  /// driver fails closed rather than falling back to plaintext.
  tls,
  connection,
  connectionLost,
  poolTimeout,
  querySyntax,
  constraint,
  deadlock,
  queryTimeout,
  cancelled,
  conversion,
  unsupportedType,
  procedure,
  transaction,
  bulkCopy,

  /// The commit was sent and the answer never came back.
  ///
  /// Its own type because it is the one failure where the caller cannot
  /// conclude anything: the transaction may have committed on the server, and
  /// it may not have. Reporting it as a lost connection would invite a retry
  /// that double-applies the work. Recovering means asking the database what
  /// it holds — usually through a request key the application wrote itself.
  unknownCommitOutcome,
  protocol,
  internal,
}

/// How many units of [text] a declared `(n)` length is measured against.
///
/// `nvarchar(n)` counts UTF-16 code units, which is Dart's [String.length].
/// `varchar(n)` counts bytes in the column's code page, and the code page is
/// not known at bind time — `'Ö'` is one byte under CP1254 and two under
/// UTF-8. Characters are therefore the unit here: every code page spends at
/// least one byte per character, so more characters than the declared size
/// cannot fit under any of them. A value that fits by character count may
/// still overflow a double-byte page; the server decides that.
int mssqlTextLength(String text, {required bool unicode}) =>
    unicode ? text.length : text.runes.length;

/// What a length refusal calls the unit it counted.
String mssqlTextLengthUnit({required bool unicode}) =>
    unicode ? 'UTF-16 code units' : 'characters';

/// Whether a text type's declared `(n)` is measured in UTF-16 code units.
bool mssqlTypeIsUnicodeText(MssqlType type) => switch (type) {
  MssqlType.nchar ||
  MssqlType.nvarchar ||
  MssqlType.ntext ||
  MssqlType.xml => true,
  _ => false,
};
