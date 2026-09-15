import 'dart:async';
import 'dart:isolate';

import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_native/src/native/worker_channel.dart';
import 'package:test/test.dart';

void _entry(List<Object?> args) {
  final replies = args[0] as SendPort;
  final mode = args[1] as String;
  if (mode == 'startup-exit') Isolate.exit();
  if (mode == 'startup-error') throw StateError('startup exploded');
  final commands = ReceivePort();
  if (mode == 'silent') return;
  if (mode == 'invalid-handshake') {
    replies.send(<Object?>[
      -1,
      <Object?>['not a port'],
      null,
    ]);
    return;
  }
  if (mode == 'startup-failure') {
    replies.send(<Object?>[-1, null, 'login rejected']);
    return;
  }
  replies.send(<Object?>[
    -1,
    <Object?>[commands.sendPort, 42],
    null,
  ]);
  commands.listen((message) {
    final request = message as List<Object?>;
    final id = request[0] as int;
    switch (request[1]) {
      case 'exit':
        Isolate.exit();
      case 'error':
        throw StateError('operation exploded');
      case 'hold':
        return;
      case 'failure':
        replies.send(<Object?>[id, null, 'query rejected']);
      case 'malformed':
        replies.send('broken response');
      case 'duplicate':
        replies.send(<Object?>[id, 7, null]);
        replies.send(<Object?>[id, 8, null]);
      case 'unknown':
        replies.send(<Object?>[99999, null, null]);
        replies.send(<Object?>[id, 9, null]);
      case 'close':
        replies.send(<Object?>[id, null, null]);
        commands.close();
      default:
        replies.send(<Object?>[id, request[2], null]);
    }
  });
}

Object _failure(Object error) =>
    MssqlException(type: MssqlErrorType.querySyntax, message: error.toString());

Future<WorkerChannel> _open([String mode = 'normal']) => WorkerChannel.start(
  _entry,
  <Object?>[mode],
  decodeFailure: _failure,
  startupTimeout: const Duration(seconds: 2),
);

final _lost = isA<MssqlException>().having(
  (error) => error.type,
  'type',
  MssqlErrorType.connectionLost,
);

void main() {
  test('exit before handshake fails instead of hanging', () async {
    await expectLater(_open('startup-exit'), throwsA(_lost));
  });
  test('uncaught startup error preserves diagnostic text', () async {
    await expectLater(
      _open('startup-error'),
      throwsA(
        isA<MssqlException>().having(
          (e) => e.message,
          'message',
          contains('startup exploded'),
        ),
      ),
    );
  });
  test('startup protocol failure preserves the reported error', () async {
    await expectLater(
      _open('startup-failure'),
      throwsA(
        isA<MssqlException>().having(
          (e) => e.message,
          'message',
          'login rejected',
        ),
      ),
    );
  });
  test('silent startup has a deadline', () async {
    await expectLater(
      WorkerChannel.start(
        _entry,
        <Object?>['silent'],
        decodeFailure: _failure,
        startupTimeout: const Duration(milliseconds: 50),
      ),
      throwsA(
        isA<MssqlException>().having(
          (e) => e.type,
          'type',
          MssqlErrorType.queryTimeout,
        ),
      ),
    );
  });
  test('malformed handshake fails immediately', () async {
    await expectLater(
      _open('invalid-handshake'),
      throwsA(isA<MssqlException>()),
    );
  });
  test('handshake metadata and request payload survive transport', () async {
    final channel = await _open();
    addTearDown(channel.dispose);
    expect(channel.handshake[1], 42);
    expect(await channel.call('echo', <Object?>[1, 'İstek', null]), <Object?>[
      1,
      'İstek',
      null,
    ]);
  });
  test('concurrent replies are matched by request id', () async {
    final channel = await _open();
    addTearDown(channel.dispose);
    expect(
      await Future.wait([
        channel.call('echo', <Object?>[1]),
        channel.call('echo', <Object?>[2]),
      ]),
      <Object?>[
        <Object?>[1],
        <Object?>[2],
      ],
    );
  });
  test('operation failure does not kill a healthy channel', () async {
    final channel = await _open();
    addTearDown(channel.dispose);
    await expectLater(
      channel.call('failure'),
      throwsA(
        isA<MssqlException>().having(
          (e) => e.message,
          'message',
          'query rejected',
        ),
      ),
    );
    expect(await channel.call('echo', <Object?>[3]), <Object?>[3]);
  });
  test(
    'exit settles every pending request and rejects future requests',
    () async {
      final channel = await _open();
      addTearDown(channel.dispose);
      final waiting = expectLater(channel.call('hold'), throwsA(_lost));
      await expectLater(channel.call('exit'), throwsA(_lost));
      await waiting;
      expect(channel.isClosed, isTrue);
      await expectLater(channel.call('echo'), throwsA(_lost));
    },
  );
  test('uncaught operation error settles a pending call', () async {
    final channel = await _open();
    addTearDown(channel.dispose);
    await expectLater(
      channel.call('error'),
      throwsA(
        isA<MssqlException>().having(
          (e) => e.message,
          'message',
          contains('operation exploded'),
        ),
      ),
    );
  });
  test('duplicate reply cannot complete the next request', () async {
    final channel = await _open();
    addTearDown(channel.dispose);
    expect(await channel.call('duplicate'), 7);
    expect(await channel.call('echo', <Object?>[4]), <Object?>[4]);
  });
  test('unknown request id is ignored without losing valid replies', () async {
    final channel = await _open();
    addTearDown(channel.dispose);
    expect(await channel.call('unknown'), 9);
  });
  test('malformed response fails the pending call', () async {
    final channel = await _open();
    addTearDown(channel.dispose);
    await expectLater(
      channel.call('malformed'),
      throwsA(isA<MssqlException>()),
    );
  });
  test('disposing twice is safe and settles pending work', () async {
    final channel = await _open();
    final waiting = expectLater(channel.call('hold'), throwsA(_lost));
    channel.dispose();
    channel.dispose();
    await waiting;
    expect(channel.isClosed, isTrue);
  });
  test('graceful close receives its reply before exit handling', () async {
    final channel = await _open();
    addTearDown(channel.dispose);
    await expectLater(channel.call('close'), completes);
  });
}

