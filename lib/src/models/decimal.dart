import 'package:meta/meta.dart';

/// How a value is rounded when a result needs fewer decimal places than the
/// exact answer has.
///
/// There is no default: every operation that can lose digits takes one of
/// these explicitly.
enum MssqlRounding {
  /// Away from zero at a half: 2.5 → 3, −2.5 → −3.
  halfUp,

  /// Toward the even neighbour at a half: 2.5 → 2, 3.5 → 4.
  ///
  /// Banker's rounding. Keeps a long run of roundings from drifting upward.
  halfEven,

  /// Toward zero: 2.9 → 2, −2.9 → −2.
  truncate,

  /// Toward negative infinity: 2.9 → 2, −2.1 → −3.
  floor,

  /// Toward positive infinity: 2.1 → 3, −2.9 → −2.
  ceiling,

  /// Refuse: throws unless the digits being dropped are all zero.
  ///
  /// The right choice when losing a digit would be a bug rather than a
  /// rounding policy.
  exact,
}

/// An exact decimal number: an arbitrary-precision integer and a scale.
///
/// SQL Server's `DECIMAL`, `NUMERIC`, `MONEY` and `SMALLMONEY` are exact types,
/// and this class keeps them exact from the wire to Dart and back. A double
/// cannot: it loses the last digits of a large amount.
///
/// The value is [coefficient] × 10⁻ᶳᶜᵃˡᵉ. The scale is kept, so `1.50` and
/// `1.5` remain different representations, while [compareTo] and [==] compare
/// by value and treat them as equal. Keeping the scale preserves trailing
/// zeros in output and matches the column's declared scale.
///
/// Addition, subtraction and multiplication are exact. Division and [rescale]
/// can lose digits and require an explicit scale and [MssqlRounding].
/// [toDouble] is a named method so the lossy step is visible at the call site.
@immutable
final class MssqlDecimal implements Comparable<MssqlDecimal> {
  /// The value [coefficient] × 10⁻[scale].
  MssqlDecimal(this.coefficient, this.scale) {
    if (scale < 0) {
      throw ArgumentError.value(scale, 'scale', 'cannot be negative');
    }
  }

  /// Zero, at scale 0.
  static final MssqlDecimal zero = MssqlDecimal(BigInt.zero, 0);

  /// One, at scale 0.
  static final MssqlDecimal one = MssqlDecimal(BigInt.one, 0);

  /// An integer, at scale 0.
  factory MssqlDecimal.fromInt(int value) =>
      MssqlDecimal(BigInt.from(value), 0);

  /// An integer, at scale 0.
  factory MssqlDecimal.fromBigInt(BigInt value) => MssqlDecimal(value, 0);

  /// Reads invariant decimal text: `-1234.5600`, `1e-3`, `+7`.
  ///
  /// The scale comes from the text, so `parse('1.50')` keeps two decimal
  /// places. Never locale-aware: a comma is not a decimal separator.
  factory MssqlDecimal.parse(String source) {
    final value = tryParse(source);
    if (value == null) {
      throw FormatException('Not an exact decimal number', source);
    }
    return value;
  }

  /// Reads invariant decimal text, or null when [source] is not a number.
  static MssqlDecimal? tryParse(String source) {
    final text = source.trim();
    if (text.isEmpty) return null;
    final match = _syntax.firstMatch(text);
    if (match == null) return null;
    final sign = match.group(1) == '-' ? -1 : 1;
    final whole = match.group(2) ?? '';
    final fraction = match.group(3) ?? '';
    final exponent = match.group(4) == null ? 0 : int.parse(match.group(4)!);
    if (whole.isEmpty && fraction.isEmpty) return null;
    var digits = BigInt.parse('${whole.isEmpty ? '0' : whole}$fraction');
    if (sign < 0) digits = -digits;
    var scale = fraction.length - exponent;
    if (scale < 0) {
      // A positive exponent past the fraction becomes trailing zeros in the
      // coefficient.
      digits *= _pow10(-scale);
      scale = 0;
    }
    return MssqlDecimal(digits, scale);
  }

  static final RegExp _syntax = RegExp(
    r'^([+-])?(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$',
  );

  /// The unscaled value: the digits, with their sign, and no decimal point.
  final BigInt coefficient;

  /// How many of [coefficient]'s digits are after the decimal point.
  final int scale;

  bool get isNegative => coefficient.isNegative;
  bool get isZero => coefficient == BigInt.zero;

  /// −1, 0 or 1.
  int get sign => coefficient.sign;

  MssqlDecimal get abs => isNegative ? -this : this;

  MssqlDecimal operator -() => MssqlDecimal(-coefficient, scale);

  /// Exact. The result's scale is the larger of the two.
  MssqlDecimal operator +(MssqlDecimal other) {
    final scale = _widerScale(other);
    return MssqlDecimal(
      _coefficientAt(scale) + other._coefficientAt(scale),
      scale,
    );
  }

  /// Exact. The result's scale is the larger of the two.
  MssqlDecimal operator -(MssqlDecimal other) {
    final scale = _widerScale(other);
    return MssqlDecimal(
      _coefficientAt(scale) - other._coefficientAt(scale),
      scale,
    );
  }

  /// Exact. The result's scale is the sum of the two, as in SQL and on paper.
  MssqlDecimal operator *(MssqlDecimal other) =>
      MssqlDecimal(coefficient * other.coefficient, scale + other.scale);

  /// Division. `1 / 3` has no exact decimal form, so [scale] and [rounding]
  /// must be stated explicitly.
  MssqlDecimal divide(
    MssqlDecimal divisor, {
    required int scale,
    MssqlRounding rounding = MssqlRounding.halfUp,
  }) {
    if (divisor.isZero) {
      throw ArgumentError.value(divisor, 'divisor', 'division by zero');
    }
    if (scale < 0) {
      throw ArgumentError.value(scale, 'scale', 'cannot be negative');
    }
    // Compute one extra digit of the quotient, then round it off. The shift is
    // (wanted scale + 1) plus the divisor's scale, minus this one's.
    final shift = scale + 1 + divisor.scale - this.scale;
    var numerator = coefficient;
    var denominator = divisor.coefficient;
    if (shift >= 0) {
      numerator *= _pow10(shift);
    } else {
      denominator *= _pow10(-shift);
    }
    final quotient = _dividedTowardZero(numerator, denominator);
    final remainder = numerator - quotient * denominator;
    return MssqlDecimal(
      quotient,
      scale + 1,
    )._rounded(scale, rounding, hasRemainder: remainder != BigInt.zero);
  }

  /// This number with exactly [scale] decimal places.
  ///
  /// Widening is exact. Narrowing applies [rounding], and
  /// [MssqlRounding.exact] refuses to drop a non-zero digit.
  MssqlDecimal rescale(
    int scale, {
    MssqlRounding rounding = MssqlRounding.exact,
  }) {
    if (scale < 0) {
      throw ArgumentError.value(scale, 'scale', 'cannot be negative');
    }
    if (scale == this.scale) return this;
    if (scale > this.scale) {
      return MssqlDecimal(coefficient * _pow10(scale - this.scale), scale);
    }
    return _rounded(scale, rounding, hasRemainder: false);
  }

  /// The nearest [double]. A named method so the lossy step is visible.
  double toDouble() => double.parse(toString());

  /// The value as an integer, or null when it has a fractional part.
  BigInt? toBigIntExact() {
    if (scale == 0) return coefficient;
    final divisor = _pow10(scale);
    final quotient = _dividedTowardZero(coefficient, divisor);
    return quotient * divisor == coefficient ? quotient : null;
  }

  /// Invariant decimal text, keeping [scale] decimal places.
  ///
  /// No exponent, thousands separator or locale: the format SQL Server accepts
  /// for a decimal literal.
  @override
  String toString() {
    final digits = coefficient.abs().toString();
    final sign = isNegative ? '-' : '';
    if (scale == 0) return '$sign$digits';
    final padded = digits.padLeft(scale + 1, '0');
    final cut = padded.length - scale;
    return '$sign${padded.substring(0, cut)}.${padded.substring(cut)}';
  }

  /// Compares by value, so `1.50` and `1.5` compare equal.
  @override
  int compareTo(MssqlDecimal other) {
    final scale = _widerScale(other);
    return _coefficientAt(scale).compareTo(other._coefficientAt(scale));
  }

  bool operator <(MssqlDecimal other) => compareTo(other) < 0;
  bool operator <=(MssqlDecimal other) => compareTo(other) <= 0;
  bool operator >(MssqlDecimal other) => compareTo(other) > 0;
  bool operator >=(MssqlDecimal other) => compareTo(other) >= 0;

  /// Equality by value, matching [compareTo]: `1.50 == 1.5`. Use
  /// [hasSameRepresentation] when the scale itself matters.
  @override
  bool operator ==(Object other) =>
      other is MssqlDecimal && compareTo(other) == 0;

  @override
  int get hashCode {
    // Equal values must hash equally, so trailing zeros are stripped first.
    var digits = coefficient;
    var scale = this.scale;
    final ten = BigInt.from(10);
    while (scale > 0 && digits != BigInt.zero && digits % ten == BigInt.zero) {
      digits = digits ~/ ten;
      scale--;
    }
    if (digits == BigInt.zero) return 0;
    return Object.hash(digits, scale);
  }

  /// Whether both the value and the number of decimal places match.
  bool hasSameRepresentation(MssqlDecimal other) =>
      coefficient == other.coefficient && scale == other.scale;

  int _widerScale(MssqlDecimal other) =>
      scale > other.scale ? scale : other.scale;

  BigInt _coefficientAt(int target) =>
      target == scale ? coefficient : coefficient * _pow10(target - scale);

  MssqlDecimal _rounded(
    int target,
    MssqlRounding rounding, {
    required bool hasRemainder,
  }) {
    final drop = scale - target;
    final divisor = _pow10(drop);
    final quotient = _dividedTowardZero(coefficient, divisor);
    final remainder = coefficient - quotient * divisor;
    if (remainder == BigInt.zero && !hasRemainder) {
      return MssqlDecimal(quotient, target);
    }
    if (rounding == MssqlRounding.exact) {
      throw StateError(
        'Rounding $this to $target decimal place(s) would drop a non-zero '
        'digit, and MssqlRounding.exact refuses to. Choose a rounding mode '
        'or keep the scale.',
      );
    }
    final negative = coefficient.isNegative;
    final twice = remainder.abs() * BigInt.two;
    final step = switch (rounding) {
      MssqlRounding.truncate => false,
      MssqlRounding.floor => negative,
      MssqlRounding.ceiling => !negative,
      MssqlRounding.halfUp => twice >= divisor,
      MssqlRounding.halfEven =>
        twice > divisor ||
            (twice == divisor && quotient.isOdd) ||
            // The extra digit from division: a "half" that is really more.
            (twice == divisor && hasRemainder),
      MssqlRounding.exact => false,
    };
    if (!step) return MssqlDecimal(quotient, target);
    return MssqlDecimal(
      negative ? quotient - BigInt.one : quotient + BigInt.one,
      target,
    );
  }

  /// BigInt's `~/` already truncates toward zero; named so the rounding code
  /// cannot be misread as floor division.
  static BigInt _dividedTowardZero(BigInt a, BigInt b) => a ~/ b;

  static final List<BigInt> _powers = <BigInt>[BigInt.one];

  static BigInt _pow10(int exponent) {
    if (exponent < 0) {
      throw ArgumentError.value(exponent, 'exponent', 'cannot be negative');
    }
    while (_powers.length <= exponent) {
      _powers.add(_powers.last * BigInt.from(10));
    }
    return _powers[exponent];
  }
}
