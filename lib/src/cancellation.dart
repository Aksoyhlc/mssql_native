import 'dart:async';

import 'exception.dart';

/// A cancellation signal shared by one or more operations.
///
/// Cancellation is permanent and [cancel] is idempotent. Listeners registered
/// after cancellation run immediately. Use a new token for later, unrelated
/// work.
class MssqlCancellationToken {
  bool _cancelled = false;
  String? _reason;
  final Set<void Function()> _listeners = <void Function()>{};

  bool get isCancelled => _cancelled;
  String? get reason => _reason;

  void cancel([String? reason]) {
    if (_cancelled) return;
    _cancelled = true;
    _reason = reason;
    final listeners = List<void Function()>.of(_listeners);
    _listeners.clear();
    // A token may be shared, so one listener's failure must not stop the
    // others from being told. The first error is reported out of band rather
    // than thrown from cancel(), which has no single caller to hand it to.
    Object? firstError;
    StackTrace? firstStack;
    for (final listener in listeners) {
      try {
        listener();
      } catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    if (firstError != null) {
      Zone.current.handleUncaughtError(firstError, firstStack!);
    }
  }

  void Function() _register(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// Throws [MssqlCancelledException] once this token has been cancelled.
  ///
  /// The subclass, not the base type: `on MssqlCancelledException` is what the
  /// documentation tells a caller to write, and a base `MssqlException` here
  /// would slip past it and land in whichever broader handler came next.
  void _throwIfCancelled() {
    if (!_cancelled) return;
    throw MssqlCancelledException(
      message: _reason == null || _reason!.isEmpty
          ? 'The SQL operation was cancelled.'
          : 'The SQL operation was cancelled: $_reason',
    );
  }
}

void mssqlThrowIfCancelled(MssqlCancellationToken? token) =>
    token?._throwIfCancelled();

void Function()? mssqlRegisterCancellation(
  MssqlCancellationToken? token,
  void Function() listener,
) => token?._register(listener);
