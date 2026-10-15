import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/push/push_background_message.dart';
import 'package:monkeyssh/domain/services/push/push_crypto.dart';
import 'package:monkeyssh/domain/services/push/push_event.dart';
import 'package:monkeyssh/domain/services/push/push_notification_context.dart';
import 'package:monkeyssh/domain/services/push/push_notification_text.dart';
import 'package:monkeyssh/domain/services/push/push_tap_payload.dart';

class _MemoryContextStore implements PushNotificationContextStore {
  _MemoryContextStore([this.stored]);

  String? stored;

  @override
  Future<void> write(String encoded) async => stored = encoded;

  @override
  Future<String?> read() async => stored;

  @override
  Future<void> delete() async => stored = null;
}

void main() {
  final seed = List<int>.generate(32, (index) => index + 1);
  late PushDeviceKeyPair device;

  setUpAll(() async {
    device = await pushDeviceKeyPairFromSeed(seed);
  });

  Future<String> seal(Map<String, Object?> event) => sealPushPayloadForTesting(
    devicePublicKey: device.publicKey,
    plaintext: utf8.encode(jsonEncode(event)),
    ephemeralSeed: List<int>.filled(32, 9),
    nonce: List<int>.filled(12, 4),
  );

  Future<List<PushNotificationPost>> show(
    Map<String, dynamic> data, {
    String? context,
  }) async {
    final posts = <PushNotificationPost>[];
    await showPushNotificationFromData(
      data,
      store: _MemoryContextStore(context),
      post: (post) async => posts.add(post),
    );
    return posts;
  }

  String context(Map<String, String> hosts) =>
      PushNotificationContext(seed: device.seed, hosts: hosts).encode();

  test('a push the phone can open names the agent, host and session', () async {
    final payload = await seal({
      'v': 1,
      'hostRef': 'ref-build-box',
      'window': '@3',
      'sessionId': 'MonkeySSH',
      'kind': 'finished',
      'agent': 'claude',
      'ts': 1760000000,
    });
    final posts = await show({
      'v': '1',
      'p': payload,
      'k': 'finished',
      'c': 'collapse-1',
    }, context: context({'ref-build-box': 'build-box'}));
    final post = posts.single;
    expect(post.title, 'Claude Code finished');
    expect(post.body, 'build-box · MonkeySSH');
    expect(post.kind, PushEventKind.finished);
    expect(post.id, pushNotificationIdFor('collapse-1'));
    expect(decodePushTapPayload(post.tapPayload), payload);
    expect(post.timestamp!.millisecondsSinceEpoch, 1760000000 * 1000);
  });

  test(
    'without a context or with another key it shows the generic text',
    () async {
      final payload = await seal({
        'v': 1,
        'hostRef': 'ref',
        'kind': 'permission',
        'ts': 1,
      });
      final data = {'v': '1', 'p': payload, 'k': 'permission', 'c': 'c'};
      for (final stored in [
        null,
        'not json',
        PushNotificationContext(
          seed: Uint8List.fromList(List<int>.filled(32, 77)),
          hosts: const {},
        ).encode(),
      ]) {
        final post = (await show(data, context: stored)).single;
        expect(post.title, 'Approval needed');
        expect(post.body, 'An agent is waiting for your approval.');
        expect(decodePushTapPayload(post.tapPayload), payload);
      }
    },
  );

  test('a kind the host no longer allows does not show', () async {
    Future<String> event(String kind, {List<String>? alert}) => seal({
      'v': 1,
      'hostRef': 'ref',
      'kind': kind,
      'alert': ?alert,
      'ts': 1,
    });
    // Agent finished and window alerts were turned off while the host was
    // out of reach, so its registration still asks for them.
    final stored = PushNotificationContext(
      seed: device.seed,
      hosts: const {'ref': 'build-box'},
      allowed: const {
        'ref': {'attention', 'notice'},
      },
    ).encode();
    Future<int> posts(String kind, {List<String>? alert}) async => (await show({
      'v': '1',
      'p': await event(kind, alert: alert),
      'k': kind,
      'c': 'c',
    }, context: stored)).length;
    expect(await posts('permission'), 1);
    expect(await posts('finished'), 0);
    expect(await posts('alert', alert: ['bell']), 0);
    expect(await posts('alert', alert: ['notice']), 1);
    // An older helper's alert does not say which; it needs both.
    expect(await posts('alert'), 0);
    expect(await posts('test'), 1);
    // A host the context does not filter shows everything.
    final unfiltered = context({'ref': 'build-box'});
    expect(
      (await show({
        'v': '1',
        'p': await event('finished'),
        'k': 'finished',
        'c': 'c',
      }, context: unfiltered)).length,
      1,
    );
  });

  test('other data messages are ignored', () async {
    expect(await show({'v': '1', 'k': 'finished'}), isEmpty);
    expect(await show({'v': '2', 'p': 'x', 'k': 'finished'}), isEmpty);
    expect(await show({'v': '1', 'p': 'x', 'k': 'nonsense'}), isEmpty);
    expect(await show({'hello': 'world'}), isEmpty);
  });

  test('notification ids are stable and non-negative', () {
    expect(pushNotificationIdFor('a'), pushNotificationIdFor('a'));
    expect(pushNotificationIdFor('a'), isNot(pushNotificationIdFor('b')));
    for (final key in ['', 'a', 'x' * 200]) {
      expect(pushNotificationIdFor(key), inInclusiveRange(0, 0x7fffffff));
    }
  });

  test('tap payloads round-trip and other payloads are not mistaken', () {
    expect(decodePushTapPayload(pushTapPayload('abc')), 'abc');
    expect(decodePushTapPayload(null), isNull);
    expect(decodePushTapPayload('{"hostId":1}'), isNull);
    expect(decodePushTapPayload('not json'), isNull);
  });

  group('notification text', () {
    PushEvent event(
      PushEventKind kind, {
      String? agent,
      String? session,
      String? window,
    }) => PushEvent(
      hostRef: 'ref',
      kind: kind,
      timestamp: DateTime.utc(2026),
      sessionName: session,
      agent: agent,
      windowTitle: window,
    );

    test('names the agent in the title', () {
      String title(PushEventKind kind) =>
          pushNotificationText(event(kind, agent: 'cursor-agent')).title;
      expect(title(PushEventKind.permission), 'Cursor Agent needs approval');
      expect(title(PushEventKind.input), 'Cursor Agent has a question');
      expect(title(PushEventKind.finished), 'Cursor Agent finished');
      expect(title(PushEventKind.alert), 'Terminal alert');
      expect(title(PushEventKind.test), 'MonkeySSH');
    });

    test('an unknown or missing agent keeps the generic title', () {
      for (final agent in [null, 'something-new']) {
        expect(
          pushNotificationText(event(PushEventKind.finished, agent: agent))
              .title,
          'Agent finished',
        );
      }
    });

    test(
      'the body names the host and session when the phone knows the host',
      () {
        expect(
          pushNotificationText(
            event(PushEventKind.alert, session: 'main'),
            hostLabel: 'build-box',
          ).body,
          'build-box · main',
        );
        expect(
          pushNotificationText(
            event(PushEventKind.alert),
            hostLabel: 'build-box',
          ).body,
          'build-box',
        );
        expect(
          pushNotificationText(event(PushEventKind.alert, session: 'main'))
              .body,
          'A terminal window wants your attention.',
        );
        // The default session is named after the host; it is not repeated.
        expect(
          pushNotificationText(
            event(PushEventKind.alert, session: 'build-box'),
            hostLabel: 'build-box',
          ).body,
          'build-box',
        );
        expect(
          pushNotificationText(
            event(PushEventKind.test, session: 'main'),
            hostLabel: 'build-box',
          ).body,
          'Push notifications are working.',
        );
      },
    );

    test('the body leads with the window title', () {
      String body(String? window, {String? session, String? label}) =>
          pushNotificationText(
            event(PushEventKind.finished, session: session, window: window),
            hostLabel: label,
          ).body;
      expect(
        body('Fix login bug', session: 'main', label: 'build-box'),
        'Fix login bug · build-box · main',
      );
      expect(
        body('Fix login bug', session: 'build-box', label: 'build-box'),
        'Fix login bug · build-box',
      );
      // A host the phone does not know still shows the title.
      expect(body('Fix login bug', session: 'main'), 'Fix login bug');
      expect(body('build-box', label: 'build-box'), 'build-box');
    });
  });

  test('the text matches the vectors the iOS extension checks', () {
    final vectors = jsonDecode(
      File('docs/push-notification-vectors.json').readAsStringSync(),
    ) as Map<String, Object?>;
    final text = vectors['text']! as Map<String, Object?>;
    final generic = text['genericBodies']! as Map<String, Object?>;
    for (final MapEntry(:key, :value) in generic.entries) {
      expect(
        genericPushNotificationText(PushEventKind.tryParse(key)!).body,
        value,
      );
    }
    for (final raw in text['cases']! as List<Object?>) {
      final vector = raw! as Map<String, Object?>;
      final got = pushNotificationText(
        PushEvent(
          hostRef: 'ref',
          kind: PushEventKind.tryParse(vector['kind'])!,
          timestamp: DateTime.utc(2026),
          sessionName: vector['session'] as String?,
          agent: vector['agent'] as String?,
          windowTitle: vector['windowTitle'] as String?,
        ),
        hostLabel: vector['hostLabel'] as String?,
      );
      expect(
        (got.title, got.body),
        (vector['title'], vector['body']),
        reason: jsonEncode(vector),
      );
    }
  });

  test('a payload title is cleaned and bounded', () {
    PushEvent? parse(Object? title) => PushEvent.tryParse(
      utf8.encode(
        jsonEncode({
          'v': 1,
          'hostRef': 'ref',
          'kind': 'finished',
          'ts': 1,
          'title': ?title,
        }),
      ),
    );
    expect(parse('Fix login bug')!.windowTitle, 'Fix login bug');
    expect(parse(' deploy\n\u001b prod ')!.windowTitle, 'deploy prod');
    expect(parse(null)!.windowTitle, isNull);
    expect(parse('  ')!.windowTitle, isNull);
    expect(parse(7)!.windowTitle, isNull);
    expect(parse('a' * 65)!.windowTitle, isNull);
  });

  test('a payload version or time written with a fraction is refused', () {
    PushEvent? parse(Object v, Object ts) => PushEvent.tryParse(
      utf8.encode(
        jsonEncode({'v': v, 'hostRef': 'ref', 'kind': 'finished', 'ts': ts}),
      ),
    );
    expect(parse(1, 1), isNotNull);
    expect(parse(1.0, 1), isNull);
    expect(parse(1, 1.0), isNull);
  });

  test('a payload names its agent only with a short lowercase id', () {
    PushEvent? parse(Object? agent) => PushEvent.tryParse(
      utf8.encode(
        jsonEncode({
          'v': 1,
          'hostRef': 'ref',
          'kind': 'finished',
          'ts': 1,
          'agent': ?agent,
        }),
      ),
    );
    expect(parse('claude')!.agent, 'claude');
    expect(parse(null)!.agent, isNull);
    expect(parse('Claude Code')!.agent, isNull);
    expect(parse(7)!.agent, isNull);
    expect(parse('a' * 33)!.agent, isNull);
  });

  test('the context round-trips and rejects a short key', () {
    final encoded = context({'ref': 'build-box'});
    final decoded = PushNotificationContext.decode(encoded)!;
    expect(decoded.seed, device.seed);
    expect(decoded.hosts, {'ref': 'build-box'});
    expect(decoded.allowed, isEmpty);
    expect(
      PushNotificationContext.decode(
        PushNotificationContext(
          seed: device.seed,
          hosts: const {'ref': 'build-box'},
          allowed: const {
            'ref': {'finished', 'attention'},
            'off': {},
          },
        ).encode(),
      )!.allowed,
      {
        'ref': {'attention', 'finished'},
        'off': <String>{},
      },
    );
    expect(PushNotificationContext.decode(null), isNull);
    expect(
      PushNotificationContext.decode(
        jsonEncode({
          'v': 1,
          'seed': encodePushBase64([1, 2]),
          'hosts': {},
        }),
      ),
      isNull,
    );
  });
}
