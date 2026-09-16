import 'dart:async';
import 'dart:collection';

import '../cancellation.dart';

class _OperationWaiter {
  _OperationWaiter(this.started);

  final Stopwatch started;
  final Completer<void> ready = Completer<void>();
  void Function()? unregisterCancellation;
}

class OperationLease {
  OperationLease(this.queueWait, this._release);

  final Duration queueWait;
  final void Function() _release;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

/// Serialises commands over one connection.
///
/// A connection runs one operation at a time, so a command that arrives while
/// another is in flight waits here rather than at the worker. Waiting is
/// cancellable; the gate is handed to the next waiter in arrival order.
class OperationGate {
  final Queue<_OperationWaiter> _waiters = Queue<_OperationWaiter>();
  bool _locked = false;

  Future<OperationLease> acquire(MssqlCancellationToken? token) async {
    mssqlThrowIfCancelled(token);
    final started = Stopwatch()..start();
    if (!_locked) {
      _locked = true;
      return OperationLease(started.elapsed, _release);
    }

    final waiter = _OperationWaiter(started);
    _waiters.addLast(waiter);
    if (token != null) {
      waiter.unregisterCancellation = mssqlRegisterCancellation(token, () {
        if (!_waiters.remove(waiter) || waiter.ready.isCompleted) return;
        try {
          mssqlThrowIfCancelled(token);
        } catch (error, stack) {
          waiter.ready.completeError(error, stack);
        }
      });
    }
    try {
      await waiter.ready.future;
      try {
        mssqlThrowIfCancelled(token);
      } catch (_) {
        // The waiter already owns the gate once [ready] completes. If the
        // token is cancelled between that completion and this continuation,
        // hand the gate to the next waiter instead of leaking the lock.
        _release();
        rethrow;
      }
      return OperationLease(started.elapsed, _release);
    } catch (_) {
      waiter.unregisterCancellation?.call();
      rethrow;
    }
  }

  void _release() {
    while (_waiters.isNotEmpty) {
      final next = _waiters.removeFirst();
      next.unregisterCancellation?.call();
      if (next.ready.isCompleted) continue;
      next.ready.complete();
      return;
    }
    _locked = false;
  }
}

class OperationContext {
  OperationContext(this.id, this.lease, this.unregisterCancellation);

  final int id;
  final OperationLease lease;
  final void Function()? unregisterCancellation;
}

Stream<T> withSubscriptionCancellation<T>(
  MssqlCancellationToken? externalToken,
  Stream<T> Function(MssqlCancellationToken token) create,
) {
  late StreamController<T> controller;
  StreamSubscription<T>? subscription;
  late MssqlCancellationToken operationToken;
  void Function()? unregisterExternal;
  // `await for` cancels its subscription after both early exit and failure.
  // Only an early exit should cancel the command; after failure the connection
  // may already be processing another operation.
  var ended = false;

  controller = StreamController<T>(
    sync: true,
    onListen: () {
      operationToken = MssqlCancellationToken();
      unregisterExternal = mssqlRegisterCancellation(
        externalToken,
        () => operationToken.cancel(externalToken?.reason),
      );
      subscription = create(operationToken).listen(
        controller.add,
        onError: (Object error, StackTrace stack) {
          ended = true;
          controller.addError(error, stack);
        },
        onDone: () {
          ended = true;
          unregisterExternal?.call();
          controller.close();
        },
      );
    },
    onPause: () => subscription?.pause(),
    onResume: () => subscription?.resume(),
    onCancel: () async {
      if (!ended) {
        operationToken.cancel('Stream subscription was cancelled');
      }
      unregisterExternal?.call();
      await subscription?.cancel();
    },
  );
  return controller.stream;
}
