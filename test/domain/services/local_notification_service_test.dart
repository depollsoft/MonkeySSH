import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/domain/services/local_notification_service.dart';
import 'package:monkeyssh/domain/services/terminal_notification.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Unit tests do not run the native plugin registrant.
  AndroidFlutterLocalNotificationsPlugin.registerWith();

  test(
    'terminal dispatch preserves sound, permission, and missing-plugin results',
    () async {
      const channel = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      const payload = TerminalNotificationPayload(hostId: 7, connectionId: 21);
      final previousPlatform = FlutterLocalNotificationsPlatform.instance;
      FlutterLocalNotificationsPlatform.instance =
          IOSFlutterLocalNotificationsPlugin();
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final service = LocalNotificationService();
      final calls = <MethodCall>[];
      var permitted = true;
      var missingPlugin = false;
      var sound = TerminalNotificationSound.silent;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            ..setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              if (call.method == 'getNotificationAppLaunchDetails') return null;
              if (call.method == 'requestPermissions') {
                expect(
                  (call.arguments as Map)['sound'],
                  sound == TerminalNotificationSound.system,
                );
              }
              if (call.method == 'show') {
                if (missingPlugin) throw MissingPluginException();
                expect(
                  call.arguments,
                  containsPair('payload', payload.encode()),
                );
                expect(call.arguments, containsPair('id', 42));
              }
              return permitted;
            });
      addTearDown(() {
        service.dispose();
        messenger.setMockMethodCallHandler(channel, null);
        FlutterLocalNotificationsPlatform.instance = previousPlatform;
        debugDefaultTargetPlatformOverride = null;
      });
      for (sound in TerminalNotificationSound.values) {
        for (final scenario in [(true, false), (false, false), (true, true)]) {
          (permitted, missingPlugin) = scenario;
          calls.clear();
          expect(
            await service.showTerminalNotification(
              notificationId: 42,
              title: 'Ready',
              body: 'Done',
              payload: payload,
              sound: sound,
            ),
            permitted && !missingPlugin,
          );
          expect(
            calls.where((call) => call.method == 'requestPermissions'),
            hasLength(1),
          );
          expect(
            calls.where((call) => call.method == 'show'),
            hasLength(permitted ? 1 : 0),
          );
        }
      }
      calls.clear();
      await service.clearTmuxAlert(42);
      await service.clearTerminalNotification(43);
      expect(calls.map((call) => (call.method, call.arguments)), [
        ('cancel', 42),
        ('cancel', 43),
      ]);
    },
  );

  for (final delayedMethod in ['requestPermissions', 'show']) {
    test(
      'tmux cancellation waits for delayed $delayedMethod and retires its queue',
      () async {
        const channel = MethodChannel(
          'dexterous.com/flutter/local_notifications',
        );
        final previousPlatform = FlutterLocalNotificationsPlatform.instance;
        FlutterLocalNotificationsPlatform.instance =
            IOSFlutterLocalNotificationsPlugin();
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final service = LocalNotificationService();
        final pending = Completer<bool>();
        final started = Completer<void>();
        final delivered = <int>{};
        final operations = <String>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              ..setMockMethodCallHandler(channel, (call) async {
                if (call.method == 'getNotificationAppLaunchDetails') {
                  return null;
                }
                if (call.method == delayedMethod && !started.isCompleted) {
                  started.complete();
                  await pending.future;
                }
                if (call.method == 'show') {
                  final id = (call.arguments as Map)['id'] as int;
                  delivered.add(id);
                  operations.add('show $id');
                } else if (call.method == 'cancel') {
                  final id = call.arguments as int;
                  delivered.remove(id);
                  operations.add('cancel $id');
                }
                return true;
              });
        addTearDown(() {
          service.dispose();
          messenger.setMockMethodCallHandler(channel, null);
          FlutterLocalNotificationsPlatform.instance = previousPlatform;
          debugDefaultTargetPlatformOverride = null;
        });
        Future<void> show(int id) => service.showTmuxAlert(
          notificationId: id,
          title: 'Ready',
          body: 'Done',
          payload: const TmuxAlertNotificationPayload(
            hostId: 7,
            connectionId: 21,
            tmuxSessionName: 'main',
            windowIndex: 1,
          ),
        );

        final showing = show(42);
        await started.future;
        final clearing = service.clearTmuxAlert(42);
        // A pending permission dialog or platform show must not block other IDs.
        await show(43);
        expect(delivered, {43});
        expect(operations, ['show 43']);
        pending.complete(true);
        await Future.wait([showing, clearing]);
        expect(operations, ['show 43', 'show 42', 'cancel 42']);
        expect(delivered, {43});
        expect(service.pendingNotificationOperationCount, 0);

        // The same ID can be used again after its previous queue was removed.
        await show(42);
        expect(delivered, {42, 43});
        await service.clearTmuxAlert(42);
        expect(delivered, {43});
        expect(service.pendingNotificationOperationCount, 0);
      },
    );
  }

  test('a failed tmux show does not prevent queued cancellation', () async {
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final previousPlatform = FlutterLocalNotificationsPlatform.instance;
    FlutterLocalNotificationsPlatform.instance =
        IOSFlutterLocalNotificationsPlugin();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final service = LocalNotificationService();
    final cancelled = <int>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          ..setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getNotificationAppLaunchDetails') return null;
            if (call.method == 'show') throw PlatformException(code: 'failed');
            if (call.method == 'cancel') cancelled.add(call.arguments as int);
            return true;
          });
    addTearDown(() {
      service.dispose();
      messenger.setMockMethodCallHandler(channel, null);
      FlutterLocalNotificationsPlatform.instance = previousPlatform;
      debugDefaultTargetPlatformOverride = null;
    });
    final showing = service.showTmuxAlert(
      notificationId: 42,
      title: 'Ready',
      body: 'Done',
      payload: const TmuxAlertNotificationPayload(
        hostId: 7,
        connectionId: 21,
        tmuxSessionName: 'main',
        windowIndex: 1,
      ),
    );
    final expectedError = expectLater(
      showing,
      throwsA(isA<PlatformException>()),
    );
    final clearing = service.clearTmuxAlert(42);
    await expectedError;
    await clearing;
    expect(cancelled, [42]);
    expect(service.pendingNotificationOperationCount, 0);
  });

  group('TmuxAlertNotificationPayload', () {
    test('round-trips tmux alert routing fields', () {
      const payload = TmuxAlertNotificationPayload(
        hostId: 12,
        connectionId: 34,
        tmuxSessionName: 'work',
        windowIndex: 5,
        windowId: '@9',
      );

      expect(TmuxAlertNotificationPayload.decode(payload.encode()), payload);
    });

    test('ignores malformed and unrelated payloads', () {
      expect(TmuxAlertNotificationPayload.decode(null), isNull);
      expect(TmuxAlertNotificationPayload.decode('not json'), isNull);
      expect(TmuxAlertNotificationPayload.decode('{"type":"other"}'), isNull);
      expect(
        TmuxAlertNotificationPayload.decode(
          '{"type":"tmux-alert","version":1,"hostId":12}',
        ),
        isNull,
      );
      expect(
        TmuxAlertNotificationPayload.decode(
          '{"type":"tmux-alert","version":1,"hostId":12,'
          '"connectionId":34,"tmuxSessionName":"work","windowIndex":5,'
          '"windowId":"not-a-window-id"}',
        ),
        isNull,
      );
    });
  });

  test('buildTmuxAlertTerminalLocation targets the source connection window', () {
    final location = buildTmuxAlertTerminalLocation(
      const TmuxAlertNotificationPayload(
        hostId: 12,
        connectionId: 34,
        tmuxSessionName: 'project main',
        windowIndex: 5,
        windowId: '@9',
      ),
    );

    expect(
      location,
      '/terminal/12?connectionId=34&tmuxSession=project+main&tmuxWindow=5&tmuxWindowId=%409',
    );
  });

  group('TerminalNotificationPayload', () {
    test('round-trips terminal notification routing fields', () {
      const payload = TerminalNotificationPayload(
        hostId: 7,
        connectionId: 21,
        platformNotificationId: 4321,
        notificationIdentifier: 'build',
        reportsActivation: true,
        focusOnActivation: false,
      );

      expect(TerminalNotificationPayload.decode(payload.encode()), payload);
    });

    test('decodes legacy navigation-only payloads', () {
      expect(
        TerminalNotificationPayload.decode(
          '{"type":"terminal-notification","version":1,'
          '"hostId":7,"connectionId":21}',
        ),
        const TerminalNotificationPayload(hostId: 7, connectionId: 21),
      );
    });

    test('ignores malformed and unrelated payloads', () {
      expect(TerminalNotificationPayload.decode(null), isNull);
      expect(TerminalNotificationPayload.decode('not json'), isNull);
      expect(
        TerminalNotificationPayload.decode('{"type":"tmux-alert"}'),
        isNull,
      );
      expect(
        TerminalNotificationPayload.decode(
          '{"type":"terminal-notification","version":1,"hostId":7}',
        ),
        isNull,
      );
    });

    test('does not decode as a tmux alert and vice versa', () {
      const terminal = TerminalNotificationPayload(hostId: 7, connectionId: 21);
      expect(TmuxAlertNotificationPayload.decode(terminal.encode()), isNull);
    });
  });

  test('Kitty urgency and sound map to native notification details', () {
    final quiet = buildTerminalNotificationDetails(
      urgency: TerminalNotificationUrgency.low,
      sound: TerminalNotificationSound.silent,
      timeout: const Duration(milliseconds: 1250),
    );
    expect(quiet.android?.channelId, terminalNotificationLowSilentChannelId);
    expect(quiet.android?.importance, Importance.low);
    expect(quiet.android?.priority, Priority.low);
    expect(quiet.android?.playSound, isFalse);
    expect(quiet.android?.silent, isTrue);
    expect(quiet.android?.timeoutAfter, 1250);
    expect(quiet.iOS?.presentSound, isFalse);
    expect(quiet.iOS?.interruptionLevel, InterruptionLevel.passive);

    final critical = buildTerminalNotificationDetails(
      urgency: TerminalNotificationUrgency.critical,
      sound: TerminalNotificationSound.system,
    );
    expect(critical.android?.channelId, terminalNotificationCriticalChannelId);
    expect(critical.android?.importance, Importance.max);
    expect(critical.android?.priority, Priority.max);
    expect(critical.android?.playSound, isTrue);
    expect(critical.iOS?.presentSound, isTrue);
    expect(critical.iOS?.interruptionLevel, InterruptionLevel.active);

    final channels = LocalNotificationService.debugTerminalNotificationChannels;
    for (final channelId in <String>{
      terminalNotificationLowSilentChannelId,
      terminalNotificationSilentChannelId,
      terminalNotificationCriticalSilentChannelId,
    }) {
      expect(
        channels.singleWhere((channel) => channel.id == channelId).playSound,
        isFalse,
      );
    }
  });

  test('Kitty identifiers replace within a connection without collisions', () {
    expect(
      buildTerminalNotificationId(21, identifier: 'build'),
      buildTerminalNotificationId(21, identifier: 'build'),
    );
    expect(
      buildTerminalNotificationId(21, identifier: 'build'),
      isNot(buildTerminalNotificationId(21, identifier: 'deploy')),
    );
    expect(
      buildTerminalNotificationId(21, identifier: 'build'),
      isNot(buildTerminalNotificationId(22, identifier: 'build')),
    );
    expect(
      buildTerminalNotificationId(21, identifier: 'build/a'),
      isNot(buildTerminalNotificationId(21, identifier: 'build+a')),
    );
  });

  test('buildTerminalNotificationLocation targets the source connection', () {
    final location = buildTerminalNotificationLocation(
      const TerminalNotificationPayload(hostId: 7, connectionId: 21),
    );

    expect(location, '/terminal/7?connectionId=21');
  });

  group('AcpNotificationPayload', () {
    test('round-trips completion, permission, and write fields', () {
      const completion = AcpNotificationPayload(
        kind: AcpNotificationKind.completion,
        hostId: 3,
        providerId: 'builtin:copilot-cli',
        bridgeId: 'bridge-1',
        acpSessionId: 'session-1',
      );
      const permission = AcpNotificationPayload(
        kind: AcpNotificationKind.permission,
        hostId: 3,
        providerId: 'builtin:opencode',
        bridgeId: 'bridge-2',
        acpSessionId: 'session-2',
      );

      const write = AcpNotificationPayload(
        kind: AcpNotificationKind.writeApproval,
        hostId: 3,
        providerId: 'builtin:opencode',
        bridgeId: 'bridge-2',
        acpSessionId: 'session-2',
      );

      expect(AcpNotificationPayload.decode(completion.encode()), completion);
      expect(AcpNotificationPayload.decode(permission.encode()), permission);
      expect(AcpNotificationPayload.decode(write.encode()), write);
      expect(
        acpNotificationIdFor(permission),
        acpNotificationIdFor(permission),
      );
      expect(
        acpNotificationIdFor(write),
        isNot(acpNotificationIdFor(permission)),
      );
      expect(
        acpNotificationIdFor(write),
        inInclusiveRange(0x40000000, 0x7fffffff),
      );
      expect(
        buildTerminalNotificationId(3, identifier: 'session-2'),
        inInclusiveRange(0, 0x3fffffff),
      );
    });

    test('ignores malformed and unrelated payloads', () {
      expect(AcpNotificationPayload.decode(null), isNull);
      expect(AcpNotificationPayload.decode('not json'), isNull);
      expect(AcpNotificationPayload.decode('{"type":"tmux-alert"}'), isNull);
      expect(
        AcpNotificationPayload.decode(
          '{"type":"acp-notification","version":1,"kind":"completion"}',
        ),
        isNull,
      );
      expect(
        AcpNotificationPayload.decode(
          '{"type":"acp-notification","version":1,"kind":"unknown-kind",'
          '"hostId":3,"providerId":"builtin:copilot-cli",'
          '"bridgeId":"bridge-1","acpSessionId":"session-1"}',
        ),
        isNull,
      );
    });

    test('does not decode as a tmux alert or terminal notification', () {
      const payload = AcpNotificationPayload(
        kind: AcpNotificationKind.completion,
        hostId: 3,
        providerId: 'builtin:copilot-cli',
        bridgeId: 'bridge-1',
        acpSessionId: 'session-1',
      );
      expect(TmuxAlertNotificationPayload.decode(payload.encode()), isNull);
      expect(TerminalNotificationPayload.decode(payload.encode()), isNull);
    });

    test('encode never includes prompt/tool/path/content fields', () {
      const payload = AcpNotificationPayload(
        kind: AcpNotificationKind.permission,
        hostId: 3,
        providerId: 'builtin:copilot-cli',
        bridgeId: 'bridge-1',
        acpSessionId: 'session-1',
      );
      final encoded = payload.encode();
      for (final forbidden in ['prompt', 'tool', 'path', 'content', 'title']) {
        expect(encoded.toLowerCase(), isNot(contains(forbidden)));
      }
    });
  });

  test('buildAcpNotificationLocation deep-links to the specific chat', () {
    final location = buildAcpNotificationLocation(
      const AcpNotificationPayload(
        kind: AcpNotificationKind.completion,
        hostId: 3,
        providerId: 'builtin:copilot-cli',
        bridgeId: 'bridge-1',
        acpSessionId: 'session-1',
      ),
    );

    final uri = Uri.parse(location);
    expect(uri.path, acpAgentChatRoutePath);
    expect(uri.queryParameters[acpAgentChatHostQueryKey], '3');
    expect(uri.queryParameters[acpAgentChatSessionQueryKey], 'session-1');
    // Must not target the nonexistent /home route.
    expect(location.startsWith('/home'), isFalse);
  });
}
