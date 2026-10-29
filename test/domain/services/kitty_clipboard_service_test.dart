// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/kitty_clipboard_protocol.dart';
import 'package:monkeyssh/domain/services/kitty_clipboard_service.dart';

String b64(String value) => base64Encode(utf8.encode(value));

class _FakePlatform implements KittyClipboardPlatform {
  final stored = <String, Uint8List>{};
  bool failWrite = false;
  bool throwOnRead = false;
  Future<Uint8List?>? pendingRead;
  void Function()? onRead;
  final written = <List<KittyClipboardEntry>>[];

  @override
  Future<List<String>> availableTypes() async => stored.keys.toList();

  @override
  Future<Uint8List?> read(String mime) async {
    onRead?.call();
    if (throwOnRead) {
      throw PlatformException(code: 'denied');
    }
    final pending = pendingRead;
    if (pending != null) {
      pendingRead = null;
      return pending;
    }
    return stored[mime];
  }

  @override
  Future<List<String>?> write(List<KittyClipboardEntry> entries) async {
    written.add(entries);
    if (failWrite) {
      return null;
    }
    stored
      ..clear()
      ..addAll({for (final entry in entries) entry.mime: entry.data});
    return [for (final entry in entries) entry.mime];
  }

  @override
  Future<KittyClipboardPasteRead> readPasteSnapshot() async =>
      KittyClipboardPasteRead.snapshot(KittyClipboardSnapshot(stored));
}

class _RecordingLogger implements DiagnosticsLogger {
  final events = <(String, Map<String, Object?>)>[];

  void _record(String message, Map<String, Object?> fields) =>
      events.add((message, fields));

  @override
  void debug(
    String category,
    String message, {
    Map<String, Object?> fields = const {},
  }) => _record(message, fields);

  @override
  void info(
    String category,
    String message, {
    Map<String, Object?> fields = const {},
  }) => _record(message, fields);

  @override
  void warning(
    String category,
    String message, {
    Map<String, Object?> fields = const {},
  }) => _record(message, fields);

  @override
  void error(
    String category,
    String message, {
    Map<String, Object?> fields = const {},
  }) => _record(message, fields);
}

class _Harness {
  _Harness({int maxWriteBytes = kittyClipboardMaxBytes}) {
    handler = KittyClipboardHandler(
      canWrite: () => canWrite,
      canRead: () => canRead,
      sendReply: (data) {
        if (!connected) return false;
        replies.add(data);
        return true;
      },
      connectionId: () => 7,
      platform: platform,
      maxWriteBytes: maxWriteBytes,
      logger: logger,
      clock: () => now,
      random: Random(1),
    );
  }

  final platform = _FakePlatform();
  final logger = _RecordingLogger();
  final replies = <String>[];
  late final KittyClipboardHandler handler;
  bool canWrite = true;
  bool canRead = true;
  bool connected = true;
  DateTime now = DateTime(2026, 10, 28);

  /// Feeds `ESC ] 5522 ; [body] ST` as the terminal's OSC parser splits it.
  void osc(String body) => handler.handleOsc(body.split(';'));

  Future<List<String>> packets() async {
    await handler.idle;
    final packets = [
      for (final reply in replies)
        ...reply
            .split('\x1b\\')
            .where((packet) => packet.isNotEmpty)
            .map((packet) => '$packet\x1b\\'),
    ];
    replies.clear();
    return packets;
  }
}

/// A read DATA packet for [mime] carrying [payload].
String dataPacket(
  String mime,
  String payload, {
  String id = '',
  String password = '',
}) =>
    '\x1b]5522;type=read:status=DATA${id.isEmpty ? '' : ':id=$id'}'
    ':mime=${b64(mime)}${password.isEmpty ? '' : ':pw=$password'}'
    ';${b64(payload)}\x1b\\';

String status(String op, String status, {String id = ''}) =>
    '\x1b]5522;type=$op:status=$status${id.isEmpty ? '' : ':id=$id'}\x1b\\';

void main() {
  group('writes', () {
    test(
      'a committed write reaches the clipboard and is answered DONE',
      () async {
        final harness = _Harness();
        final data = b64('hello clipboard');
        harness
          ..osc('type=write:id=w1')
          ..osc('type=wdata:mime=${b64('text/plain')};${data.substring(0, 5)}')
          ..osc('type=wdata:mime=${b64('text/plain')};${data.substring(5)}')
          ..osc('type=walias:mime=${b64('text/plain')};${b64('UTF8_STRING')}')
          ..osc('type=wdata');

        expect(await harness.packets(), [status('write', 'DONE', id: 'w1')]);
        expect(
          utf8.decode(harness.platform.stored['text/plain']!),
          'hello clipboard',
        );
        expect(harness.platform.stored.keys, ['text/plain', 'UTF8_STRING']);
      },
    );

    test('follows the remote clipboard update setting', () async {
      final harness = _Harness()
        ..canWrite = false
        ..osc('type=write:id=x')
        ..osc('type=wdata:mime=${b64('text/plain')};${b64('hi')}')
        ..osc('type=wdata');

      expect(await harness.packets(), [status('write', 'EPERM', id: 'x')]);
      expect(harness.platform.written, isEmpty);
    });

    test(
      'aborts on invalid data and ignores the rest until a new write',
      () async {
        final harness = _Harness()
          ..osc('type=write:id=a')
          ..osc('type=wdata:mime=${b64('text/plain')};not base64!')
          ..osc('type=wdata:mime=${b64('text/plain')};${b64('later')}')
          ..osc('type=wdata')
          ..osc('type=write:id=b')
          ..osc('type=wdata:mime=!!;x')
          ..osc('type=write:id=c')
          ..osc('type=walias;${b64('TEXT')}')
          ..osc('type=write:id=d')
          ..osc('type=wdata:mime=${b64('text/plain')};YWJ')
          ..osc('type=wdata');

        expect(await harness.packets(), [
          status('write', 'EINVAL', id: 'a'),
          status('write', 'EINVAL', id: 'b'),
          status('write', 'EINVAL', id: 'c'),
          status('write', 'EINVAL', id: 'd'),
        ]);
        expect(harness.platform.written, isEmpty);
      },
    );

    test('answer noncanonical base64 padding with EINVAL', () async {
      final harness = _Harness()
        ..osc('type=write:id=a')
        ..osc('type=wdata:mime=${b64('text/plain')};AB==')
        ..osc('type=write:id=b')
        ..osc('type=wdata:mime=AB==;${b64('x')}')
        ..osc('type=write:id=c')
        ..osc('type=walias:mime=${b64('text/plain')};AB==')
        // A read has no error status; it is ignored.
        ..osc('type=read:id=r;AB==')
        ..osc('type=read:id=s:pw=AB==:name=${b64('x')};${b64('.')}');

      expect(await harness.packets(), [
        status('write', 'EINVAL', id: 'a'),
        status('write', 'EINVAL', id: 'b'),
        status('write', 'EINVAL', id: 'c'),
      ]);
    });

    test('refuses a write over the size limit with EFBIG', () async {
      final harness = _Harness(maxWriteBytes: 4)
        ..osc('type=write')
        ..osc('type=wdata:mime=${b64('text/plain')};${b64('hello')}');

      expect(await harness.packets(), [status('write', 'EFBIG')]);
    });

    test('reports EIO when the platform keeps nothing', () async {
      final harness = _Harness();
      harness.platform.failWrite = true;
      harness
        ..osc('type=write')
        ..osc('type=wdata:mime=${b64('application/x-thing')};${b64('x')}')
        ..osc('type=wdata');

      expect(await harness.packets(), [status('write', 'EIO')]);
    });

    test('answers ENOSYS for the primary selection', () async {
      final harness = _Harness()
        ..osc('type=write:loc=primary:id=p')
        ..osc('type=read:loc=primary:id=q;${b64('text/plain')}');

      expect(await harness.packets(), [
        status('write', 'ENOSYS', id: 'p'),
        status('read', 'ENOSYS', id: 'q'),
      ]);
    });

    test('a new write silently replaces an open one', () async {
      final harness = _Harness()
        ..osc('type=write:id=old')
        ..osc('type=wdata:mime=${b64('text/plain')};${b64('old')}')
        ..osc('type=write:id=new')
        ..osc('type=wdata:mime=${b64('text/plain')};${b64('new')}')
        ..osc('type=wdata');

      expect(await harness.packets(), [status('write', 'DONE', id: 'new')]);
      expect(utf8.decode(harness.platform.stored['text/plain']!), 'new');
    });

    test('refuses writes queued past the size limit with EFBIG', () async {
      final harness = _Harness(maxWriteBytes: 8);
      final blockedRead = Completer<Uint8List?>();
      harness.platform.pendingRead = blockedRead.future;
      harness.osc('type=read:id=r;${b64('text/plain')}');

      // Each write fits on its own, but they wait behind the read together.
      for (final (id, text) in [('a', 'abcde'), ('b', 'fgh'), ('c', 'ijk')]) {
        harness
          ..osc('type=write:id=$id')
          ..osc('type=wdata:mime=${b64('text/plain')};${b64(text)}')
          ..osc('type=wdata');
      }
      blockedRead.complete(utf8.encode('read'));

      final packets = await harness.packets();
      expect(packets.skip(3), [
        status('write', 'DONE', id: 'a'),
        status('write', 'DONE', id: 'b'),
        status('write', 'EFBIG', id: 'c'),
      ]);
      expect(harness.platform.written, hasLength(2));

      // Written, they no longer count against the next one.
      harness
        ..osc('type=write:id=d')
        ..osc('type=wdata:mime=${b64('text/plain')};${b64('lmnopqrs')}')
        ..osc('type=wdata');
      expect(await harness.packets(), [status('write', 'DONE', id: 'd')]);
    });

    test('a write queued before disposal leaves the clipboard alone', () async {
      final harness = _Harness();
      final blockedRead = Completer<Uint8List?>();
      var reads = 0;
      harness.platform
        ..pendingRead = blockedRead.future
        ..onRead = () => reads++;
      harness
        ..osc('type=read:id=r;${b64('text/plain image/png')}')
        ..osc('type=write:id=w')
        ..osc('type=wdata:mime=${b64('text/plain')};${b64('late')}')
        ..osc('type=wdata');
      await pumpEventQueue();

      // The session disconnects while the read waits on the platform.
      harness.handler.dispose();
      blockedRead.complete(utf8.encode('read'));

      expect(await harness.packets(), isEmpty);
      expect(harness.platform.written, isEmpty);
      // The read stops at the type it was waiting for.
      expect(reads, 1);
    });

    test('drops a write left idle', () {
      fakeAsync((async) {
        final harness = _Harness()
          ..osc('type=write:id=idle')
          ..osc('type=wdata:mime=${b64('text/plain')};${b64('x')}');
        async.elapse(
          kittyClipboardWriteIdleTimeout + const Duration(seconds: 1),
        );
        harness.osc('type=wdata');
        async.flushMicrotasks();
        expect(harness.replies, isEmpty);
        expect(harness.platform.written, isEmpty);
      });
    });
  });

  group('reads', () {
    test('follow the remote clipboard read setting', () async {
      final harness = _Harness()
        ..canRead = false
        ..osc('type=read:id=r;${b64('text/plain')}')
        ..osc('type=read;${b64('.')}');

      expect(await harness.packets(), [
        status('read', 'EPERM', id: 'r'),
        status('read', 'EPERM'),
      ]);
    });

    test('list types and serve the ones available, in order', () async {
      final harness = _Harness();
      harness.platform.stored['text/plain'] = utf8.encode('hello');
      harness.osc('type=read:id=r;${b64('. text/plain image/png')}');

      expect(await harness.packets(), [
        status('read', 'OK', id: 'r'),
        dataPacket('.', 'text/plain\n', id: 'r'),
        dataPacket('text/plain', 'hello', id: 'r'),
        status('read', 'DONE', id: 'r'),
      ]);
    });

    test('ignore a request that is not base64 UTF-8', () async {
      final harness = _Harness()
        ..osc('type=read;text/plain')
        ..osc('type=read;${base64Encode([0xff])}');

      expect(await harness.packets(), isEmpty);
    });

    test('see a write committed before them', () async {
      final harness = _Harness()
        ..osc('type=write')
        ..osc('type=wdata:mime=${b64('text/plain')};${b64('fresh')}')
        ..osc('type=wdata')
        ..osc('type=read;${b64('text/plain')}');

      final packets = await harness.packets();
      expect(packets.first, status('write', 'DONE'));
      expect(packets, contains(contains(b64('fresh'))));
    });

    test('serve what was read before a platform failure', () async {
      final harness = _Harness();
      harness.platform.throwOnRead = true;
      harness.osc('type=read;${b64('text/plain')}');

      expect(await harness.packets(), [
        status('read', 'OK'),
        status('read', 'DONE'),
      ]);
    });
  });

  group('paste events', () {
    Future<String> sendPasteEvent(_Harness harness) async {
      final snapshot = KittyClipboardSnapshot({
        'image/png': Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]),
        'text/plain': utf8.encode('pasted'),
      });
      expect(
        await harness.handler.sendPasteEvent(snapshot),
        KittyClipboardPasteEventResult.sent,
      );
      final packets = await harness.packets();
      expect(packets, hasLength(3));
      final password = RegExp(':pw=([A-Za-z0-9+/=]+)')
          .firstMatch(packets.first)!
          .group(1)!;
      final pw = utf8.decode(base64Decode(password));
      expect(pw, hasLength(22));
      expect(packets, [
        '\x1b]5522;type=read:status=OK:pw=$password\x1b\\',
        dataPacket('.', 'image/png text/plain\n', password: password),
        '\x1b]5522;type=read:status=DONE:pw=$password\x1b\\',
      ]);
      return password;
    }

    test(
      'list the pasted types and serve them once to their password',
      () async {
        // Reading the clipboard is off, but the user pasted.
        final harness = _Harness()..canRead = false;
        final password = await sendPasteEvent(harness);
        final name = b64(kittyClipboardPasteEventName);

        // A listing does not use the password up.
        harness.osc('type=read:pw=$password:name=$name;${b64('.')}');
        expect(
          (await harness.packets())[1],
          contains(b64('image/png text/plain\n')),
        );

        harness.osc('type=read:pw=$password:name=$name;${b64('UTF8_STRING')}');
        expect(await harness.packets(), [
          status('read', 'OK'),
          dataPacket('UTF8_STRING', 'pasted'),
          status('read', 'DONE'),
        ]);

        harness.osc('type=read:pw=$password:name=$name;${b64('text/plain')}');
        expect(await harness.packets(), [status('read', 'EPERM')]);
      },
    );

    test('ignore a password without a name, or one that expired', () async {
      final harness = _Harness()..canRead = false;
      final password = await sendPasteEvent(harness);
      harness.osc('type=read:pw=$password;${b64('text/plain')}');
      expect(await harness.packets(), [status('read', 'EPERM')]);

      harness
        ..now = harness.now.add(kittyClipboardPasteGrantLifetime)
        ..osc('type=read:pw=$password:name=${b64('x')};${b64('text/plain')}');
      expect(await harness.packets(), [status('read', 'EPERM')]);
    });

    test('keep an answer from the snapshot within the read budget', () async {
      final harness = _Harness()..canRead = false;
      final text = Uint8List(kittyClipboardMaxReadBytes ~/ 2 + 1);
      final snapshot = KittyClipboardSnapshot({'text/plain': text});
      expect(
        await harness.handler.sendPasteEvent(snapshot),
        KittyClipboardPasteEventResult.sent,
      );
      final event = await harness.packets();
      final password = RegExp(':pw=([A-Za-z0-9+/=]+)')
          .firstMatch(event.first)!
          .group(1)!;

      // Both names resolve to the same text; only the first fits.
      harness.osc(
        'type=read:pw=$password:name=${b64(kittyClipboardPasteEventName)}'
        ';${b64('text/plain UTF8_STRING')}',
      );
      final packets = await harness.packets();
      final mimes = {
        for (final packet in packets)
          ?RegExp(':mime=([A-Za-z0-9+/=]+)').firstMatch(packet)?.group(1),
      };
      expect(mimes, {b64('text/plain')});
      expect(packets.last, status('read', 'DONE'));
    });

    test('report a closed connection', () async {
      final harness = _Harness()..connected = false;
      expect(
        await harness.handler.sendPasteEvent(
          KittyClipboardSnapshot({'text/plain': utf8.encode('x')}),
        ),
        KittyClipboardPasteEventResult.failed,
      );
    });

    test('recheck their target once earlier requests are answered', () async {
      final harness = _Harness();
      final blockedRead = Completer<Uint8List?>();
      harness.platform.pendingRead = blockedRead.future;
      harness.osc('type=read;${b64('text/plain')}');

      // The paste waits behind the read; the user moves to another window
      // before the read is answered.
      var targeted = true;
      final result = harness.handler.sendPasteEvent(
        KittyClipboardSnapshot({'text/plain': utf8.encode('pasted')}),
        stillTargeted: () => targeted,
      );
      targeted = false;
      blockedRead.complete(utf8.encode('read'));

      expect(await result, KittyClipboardPasteEventResult.skipped);
      final packets = await harness.packets();
      expect(packets, hasLength(3));
      expect(packets.join(), isNot(contains(':pw=')));
    });
  });

  group('a replaced shell channel', () {
    test('gets no reply still owed to the one before', () async {
      final harness = _Harness();
      final blockedRead = Completer<Uint8List?>();
      var reads = 0;
      harness.platform
        ..pendingRead = blockedRead.future
        ..onRead = () => reads++;
      harness
        ..osc('type=read:id=r;${b64('text/plain text/html')}')
        ..osc('type=write:id=w')
        ..osc('type=wdata:mime=${b64('text/plain')};${b64('copied')}')
        ..osc('type=wdata');
      final paste = harness.handler.sendPasteEvent(
        KittyClipboardSnapshot({'text/plain': utf8.encode('pasted')}),
      );
      await pumpEventQueue();
      expect(reads, 1);

      // The command ends and a login shell takes its place.
      harness.handler.abandonChannel();
      blockedRead.complete(utf8.encode('read'));

      expect(await paste, KittyClipboardPasteEventResult.skipped);
      expect(await harness.packets(), isEmpty);
      // The read stops at the type it was waiting for.
      expect(reads, 1);
      // The program's write still reaches the clipboard.
      expect(utf8.decode(harness.platform.stored['text/plain']!), 'copied');

      // The new channel's requests are answered.
      harness.osc('type=read:id=n;${b64('text/plain')}');
      expect(await harness.packets(), [
        status('read', 'OK', id: 'n'),
        dataPacket('text/plain', 'copied', id: 'n'),
        status('read', 'DONE', id: 'n'),
      ]);
    });

    test('ends the open write and the paste grants', () async {
      final harness = _Harness();
      harness.platform.stored['text/plain'] = utf8.encode('secret');
      final paste = harness.handler.sendPasteEvent(
        KittyClipboardSnapshot({'text/plain': utf8.encode('pasted')}),
      );
      expect(await paste, KittyClipboardPasteEventResult.sent);
      final password = RegExp(':pw=([A-Za-z0-9+/=]+)')
          .firstMatch((await harness.packets()).first)!
          .group(1)!;
      harness
        ..canRead = false
        ..osc('type=write:id=w')
        ..osc('type=wdata:mime=${b64('text/plain')};${b64('half')}')
        ..handler.abandonChannel()
        ..osc('type=wdata')
        ..osc(
          'type=read:id=r:pw=$password'
          ':name=${b64(kittyClipboardPasteEventName)};${b64('text/plain')}',
        );

      expect(await harness.packets(), [status('read', 'EPERM', id: 'r')]);
      expect(harness.platform.written, isEmpty);
    });
  });

  test('diagnostics carry no clipboard content or MIME types', () async {
    final harness = _Harness();
    harness.platform.stored['text/plain'] = utf8.encode('secret text');
    harness
      ..osc('type=write:id=w')
      ..osc('type=wdata:mime=${b64('text/x-secret')};${b64('secret text')}')
      ..osc('type=wdata')
      ..osc('type=read:id=r;${b64('. text/x-secret')}');
    await harness.handler.sendPasteEvent(
      KittyClipboardSnapshot({'text/plain': utf8.encode('secret text')}),
    );
    await harness.packets();

    expect(harness.logger.events, isNotEmpty);
    for (final (_, fields) in harness.logger.events) {
      for (final value in fields.values) {
        expect(value, anyOf(isNull, isA<num>(), isA<bool>(), isA<String>()));
        if (value is String) {
          expect(value, isNot(contains('secret')));
          expect(value, isNot(contains('/')));
        }
      }
    }
  });

  group('SystemKittyClipboardPlatform', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const pasteboard = MethodChannel('pasteboard');
    final png = Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, //
    ]);
    late List<String> calls;
    late Map<String, Object?> pasteboardResults;
    String? clipboardText;

    setUp(() {
      calls = [];
      pasteboardResults = {};
      clipboardText = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        ..setMockMethodCallHandler(pasteboard, (call) async {
          calls.add('pasteboard.${call.method}');
          return pasteboardResults[call.method];
        })
        ..setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'Clipboard.getData':
              return clipboardText == null ? null : {'text': clipboardText};
            case 'Clipboard.hasStrings':
              return {'value': clipboardText != null};
            case 'Clipboard.setData':
              clipboardText = (call.arguments as Map)['text'] as String?;
              return null;
          }
          return null;
        });
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        ..setMockMethodCallHandler(pasteboard, null)
        ..setMockMethodCallHandler(SystemChannels.platform, null);
    });

    test('a paste snapshot holds the image and text', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      pasteboardResults = {'files': <String>[], 'image': png};
      clipboardText = 'caption';

      final read = await const SystemKittyClipboardPlatform()
          .readPasteSnapshot();

      expect(read.useAttachmentFlow, isFalse);
      expect(read.snapshot!.mimeTypes, ['image/png', 'text/plain']);
      expect(read.snapshot!.representations['image/png'], png);
    });

    test('files and unknown images keep the upload flow', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      pasteboardResults = {
        'files': ['/tmp/a.txt'],
      };
      expect(
        (await const SystemKittyClipboardPlatform().readPasteSnapshot())
            .useAttachmentFlow,
        isTrue,
      );

      pasteboardResults = {
        'files': <String>[],
        'image': Uint8List.fromList([1, 2, 3]),
      };
      expect(
        (await const SystemKittyClipboardPlatform().readPasteSnapshot())
            .useAttachmentFlow,
        isTrue,
      );
    });

    test('Android reads the image before files, like the paste flow', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      pasteboardResults = {
        'image': png,
        'files': ['content://clipboard/image'],
      };

      final read = await const SystemKittyClipboardPlatform()
          .readPasteSnapshot();

      expect(read.snapshot!.mimeTypes, ['image/png']);
      expect(calls, isNot(contains('pasteboard.files')));
    });

    test('iOS lists types without reading the image', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      pasteboardResults = {'image': png};
      clipboardText = 'text';

      expect(await const SystemKittyClipboardPlatform().availableTypes(), [
        'text/plain',
      ]);
      expect(calls, isNot(contains('pasteboard.image')));
    });

    test('a write keeps text first, otherwise an image', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      const platform = SystemKittyClipboardPlatform();

      expect(
        await platform.write([
          (mime: 'image/png', data: png),
          (mime: 'text/plain', data: utf8.encode('words')),
        ]),
        ['text/plain'],
      );
      expect(clipboardText, 'words');
      expect(calls, isNot(contains('pasteboard.writeImage')));

      // The plugin picks its write path from the host it runs on, so only
      // the result is checked here.
      expect(await platform.write([(mime: 'image/png', data: png)]), [
        'image/png',
      ]);

      expect(
        await platform.write([(mime: 'text/html', data: utf8.encode('<b>'))]),
        isNull,
      );
      expect(await platform.write(const []), isEmpty);
      expect(clipboardText, isEmpty);
    });

    test('Linux cannot write images', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(
        await const SystemKittyClipboardPlatform().write([
          (mime: 'image/png', data: png),
        ]),
        isNull,
      );
    });
  });
}
