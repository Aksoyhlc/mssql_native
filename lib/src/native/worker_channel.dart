import 'dart:async';
import 'dart:isolate';

import '../exception.dart';
import '../models/types.dart';

/// Owns a worker's ports and pending RPCs. Exit/error notifications share the
/// response port, so a worker that dies cannot strand its caller's Future.
class WorkerChannel {
  WorkerChannel._(this._decodeFailure);

  final Object Function(Object) _decodeFailure;
  final ReceivePort _responses = ReceivePort();
  final Completer<List<Object?>> _ready = Completer<List<Object?>>();
  final Map<int, Completer<Object?>> _pending = {};
  Isolate? _isolate;
  SendPort? _commands;
  int _nextId = 0;
  bool _closed = false;
  Object? _terminalError;
  late final List<Object?> handshake;

  bool get isClosed => _closed;

  static Future<WorkerChannel> start(
    void Function(List<Object?>) entry,
    List<Object?> arguments, {
    required Object Function(Object) decodeFailure,
    required Duration startupTimeout,
  }) async {
    final channel = WorkerChannel._(decodeFailure);
    channel._responses.listen(channel._receive);
    final ready = channel._ready.future.timeout(
      startupTimeout,
      onTimeout: () {
        throw const MssqlException(
          type: MssqlErrorType.queryTimeout,
          message: 'The SQL worker did not complete its startup handshake.',
        );
      },
    );
    // A startup error may arrive while Isolate.spawn itself is still awaited.
    // Keep the error observed until the await below propagates it to the caller.
    ready.ignore();
    try {
      channel._isolate = await Isolate.spawn(
        entry,
        <Object?>[channel._responses.sendPort, ...arguments],
        onExit: channel._responses.sendPort,
        onError: channel._responses.sendPort,
        errorsAreFatal: true,
      );
      if (channel._closed) channel._isolate!.kill(priority: Isolate.immediate);
      channel.handshake = await ready;
      return channel;
    } catch (error, stack) {
      channel._end(error, stack);
      rethrow;
    }
  }

  Future<Object?> call(String operation, [List<Object?> arguments = const []]) {
    if (_closed) return Future<Object?>.error(_terminalError ?? _lost());
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    try {
      _commands!.send(<Object?>[id, operation, arguments]);
    } catch (error, stack) {
      _pending.remove(id);
      completer.completeError(error, stack);
    }
    return completer.future;
  }

  void _receive(Object? message) {
    if (_closed) return;
    if (message == null) {
      _end(_lost());
      return;
    }
    // Dart uncaught-error messages are [error text, stack text].
    if (message is List && message.length == 2 && message[0] is String) {
      _end(
        _lost('The SQL worker failed: ${message[0]}'),
        StackTrace.fromString('${message[1]}'),
      );
      return;
    }
    try {
      if (message is! List || message.length != 3 || message[0] is! int) {
        throw const MssqlException(
          type: MssqlErrorType.protocol,
          message: 'The SQL worker sent an invalid response.',
        );
      }
      final id = message[0] as int;
      final Object? failure = message[2];
      if (id == -1) {
        if (_ready.isCompleted) return;
        if (failure != null) {
          _end(_decodeFailure(failure));
          return;
        }
        final data = message[1];
        if (data is! List || data.isEmpty || data.first is! SendPort) {
          throw const MssqlException(
            type: MssqlErrorType.protocol,
            message: 'The SQL worker sent an invalid startup handshake.',
          );
        }
        _commands = data.first as SendPort;
        _ready.complete(data.cast<Object?>());
        return;
      }
      final completer = _pending[id];
      if (completer == null) return;
      final error = failure == null ? null : _decodeFailure(failure);
      _pending.remove(id);
      if (error != null) {
        completer.completeError(error);
      } else {
        completer.complete(message[1]);
      }
    } catch (error, stack) {
      _end(error, stack);
    }
  }

  static MssqlException _lost([
    String message = 'The SQL worker exited before the connection was closed.',
  ]) => MssqlException(
    type: MssqlErrorType.connectionLost,
    message: message,
    retryable: true,
  );

  void _end(Object error, [StackTrace? stack]) {
    if (_closed) return;
    _closed = true;
    _terminalError = error;
    if (!_ready.isCompleted) _ready.completeError(error, stack);
    for (final completer in _pending.values) {
      completer.completeError(error, stack);
    }
    _pending.clear();
    _responses.close();
    _isolate?.kill(priority: Isolate.immediate);
  }

  void dispose() => _end(_lost('The SQL worker channel was closed.'));
}
