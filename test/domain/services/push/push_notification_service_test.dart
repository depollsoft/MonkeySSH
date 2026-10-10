import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_service.dart';
import 'package:monkeyssh/domain/services/push/push_crypto.dart';
import 'package:monkeyssh/domain/services/push/push_device_store.dart';
import 'package:monkeyssh/domain/services/push/push_event.dart';
import 'package:monkeyssh/domain/services/push/push_messaging_gateway.dart';
import 'package:monkeyssh/domain/services/push/push_notification_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

import '../../../helpers/recording_diagnostics_logger.dart';

const _token = 'fcm-token:APA91bTestTokenThatMustNeverBeLogged';
const _ticket = 'v1.k1.sealed-ticket-that-must-never-be-logged';
const _deviceId = 'pX7cQe2LrV0sNw4yJk9aTg';

class _FakeGateway implements PushMessagingGateway {
  bool permission = true;
  String? token = _token;
  Exception? registerError;
  Exception? deleteTokenError;
  Exception? autoInitError;
  final calls = <String>[];
  final registrations = <Map<String, Object?>>[];
  final tokenRefresh = StreamController<String>.broadcast();
  final messages = StreamController<PushRemoteMessage>.broadcast();
  final opened = StreamController<PushRemoteMessage>.broadcast();
  int ticketGeneration = 0;

  Future<void> close() async {
    await tokenRefresh.close();
    await messages.close();
    await opened.close();
  }

  @override
  Future<bool> requestPermission() async {
    calls.add('requestPermission');
    return permission;
  }

  @override
  Future<void> setAutoInitEnabled({required bool enabled}) async {
    calls.add('autoInit:$enabled');
    if (autoInitError case final Exception error) throw error;
  }

  @override
  Future<String?> getToken() async {
    calls.add('getToken');
    return token;
  }

  @override
  Future<void> deleteToken() async {
    calls.add('deleteToken');
    if (deleteTokenError case final Exception error) throw error;
  }

  @override
  Stream<String> get onTokenRefresh => tokenRefresh.stream;

  @override
  Stream<PushRemoteMessage> get onMessage => messages.stream;

  @override
  Stream<PushRemoteMessage> get onMessageOpenedApp => opened.stream;

  @override
  Future<PushRemoteMessage?> getInitialMessage() async => null;

  @override
  Future<PushRegistration> register({
    required String token,
    required String platform,
    String? deviceId,
  }) async {
    calls.add('register');
    registrations.add({
      'token': token,
      'platform': platform,
      'deviceId': deviceId,
    });
    if (registerError case final Exception error) throw error;
    ticketGeneration++;
    return PushRegistration(
      deviceId: deviceId ?? _deviceId,
      ticket: ticketGeneration == 1 ? _ticket : '$_ticket-$ticketGeneration',
    );
  }
}

class _MemorySecretStore implements PushSecretStore {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class _GatedRegisterGateway extends _FakeGateway {
  _GatedRegisterGateway(this.gate);

  final Completer<void> gate;

  @override
  Future<PushRegistration> register({
    required String token,
    required String platform,
    String? deviceId,
  }) async {
    calls.add('register');
    await gate.future;
    return super
        .register(token: token, platform: platform, deviceId: deviceId)
        .then((registration) {
          calls.removeLast();
          return registration;
        });
  }
}

class _ThrowingSecretStore implements PushSecretStore {
  @override
  Future<void> delete(String key) async {}

  @override
  Future<String?> read(String key) async =>
      throw Exception('keychain unavailable');

  @override
  Future<void> write(String key, String value) async {}
}

class _FakeLink implements PushHostLink {
  _FakeLink({
    required this.connectionId,
    required this.hostId,
    this.activeWindowId,
    this.sessionName = 'main',
  });

  @override
  final int connectionId;

  @override
  final int hostId;

  @override
  final String sessionName;

  @override
  String? activeWindowId;

  @override
  String get clientId => 'client-$connectionId';

  final commands = <Map<String, Object?>>[];
  bool unsupported = false;
  String testResult = 'sent';
  String? registerResult;
  Completer<void>? registerGate;

  Iterable<String> get types =>
      commands.map((command) => command['type']! as String);

  @override
  Future<MonkeyMuxPushControlResult> send(
    Map<String, Object?> command, {
    bool lowPriority = false,
  }) async {
    commands.add(command);
    if (unsupported) {
      return const MonkeyMuxPushControlResult(ok: false, unsupported: true);
    }
    if (command['type'] == 'push_register') {
      await registerGate?.future;
      final result = registerResult;
      if (result != null) {
        registerResult = null;
        return MonkeyMuxPushControlResult(ok: true, result: result);
      }
    }
    return MonkeyMuxPushControlResult(
      ok: true,
      result: command['type'] == 'push_test' ? testResult : null,
    );
  }
}

class _Harness {
  _Harness({_FakeGateway? gateway}) : gateway = gateway ?? _FakeGateway() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    settings = SettingsService(database);
  }

  late final AppDatabase database;
  late final SettingsService settings;
  final _FakeGateway gateway;
  final secrets = _MemorySecretStore();
  final logger = RecordingDiagnosticsLogger();
  final links = <_FakeLink>[];
  DateTime now = DateTime.utc(2026, 10, 9, 12);
  List<int> Function() hostIds = () => [1, 2, 3];
  bool localPresenceSupported = true;
  final alertListeners = <int>{};
  final bridgesByHost = <int, List<String>>{};
  ProviderContainer? _container;

  ProviderContainer get container => _container ??= ProviderContainer(
    overrides: [
      pushNotificationsAvailableProvider.overrideWithValue(true),
      pushMessagingGatewayProvider.overrideWithValue(gateway),
      pushDeviceStoreProvider.overrideWithValue(
        PushDeviceStore(secrets: secrets),
      ),
      settingsServiceProvider.overrideWithValue(settings),
      diagnosticsLoggerProvider.overrideWithValue(logger),
      pushHostLinksProvider.overrideWithValue(() => List.of(links)),
      pushHostIdsProvider.overrideWithValue(() async => hostIds()),
      pushNotificationChannelInstallerProvider.overrideWithValue(() async {}),
      pushClockProvider.overrideWithValue(() => now),
      pushLocalPresenceSupportedProvider.overrideWithValue(
        localPresenceSupported,
      ),
      pushLocalAlertListenerProvider.overrideWithValue(alertListeners.contains),
      pushLocalBridgesProvider.overrideWithValue(
        (hostId) => bridgesByHost[hostId] ?? const <String>[],
      ),
    ],
  );

  PushNotificationController get controller =>
      container.read(pushNotificationControllerProvider.notifier);

  PushNotificationState get state =>
      container.read(pushNotificationControllerProvider);

  Future<void> start() async {
    container.read(pushNotificationControllerProvider);
    await pumpEventQueue();
  }

  /// Drops the controller and builds a new one over the same storage, as an
  /// app restart would.
  Future<void> restart() async {
    _container?.dispose();
    _container = null;
    await start();
  }

  Future<void> dispose() async {
    await pumpEventQueue();
    _container?.dispose();
    await gateway.close();
    await database.close();
  }

  void expectLogsClean() {
    for (final event in logger.events) {
      expect(event.searchableText, isNot(contains(_token)));
      expect(event.searchableText, isNot(contains(_ticket)));
      expect(event.searchableText, isNot(contains(_deviceId)));
    }
  }
}

void main() {
  late _Harness h;

  setUp(() => h = _Harness());
  tearDown(() => h.dispose());

  test('nothing contacts FCM or hosts before opt-in', () async {
    final link = _FakeLink(connectionId: 10, hostId: 1);
    h.links.add(link);
    await h.start();
    await h.controller.syncNow();
    h.controller.reportVisibility(foreground: true, viewedHostId: 1);
    await pumpEventQueue();

    expect(h.state.loaded, isTrue);
    expect(h.state.enabled, isFalse);
    expect(h.gateway.calls, isEmpty);
    expect(link.commands, isEmpty);
    expect(h.secrets.values, isEmpty);
  });

  test(
    'opting in registers the device and hands the ticket to live hosts',
    () async {
      final link = _FakeLink(connectionId: 10, hostId: 2);
      h.links.add(link);
      await h.start();

      expect(await h.controller.enable(), isNull);
      await h.controller.syncNow();

      expect(h.state.enabled, isTrue);
      expect(h.gateway.calls, [
        'requestPermission',
        'autoInit:true',
        'getToken',
        'register',
      ]);
      expect(h.gateway.registrations.single['token'], _token);
      final stored = await PushDeviceStore(secrets: h.secrets).load();
      expect(stored!.deviceId, _deviceId);
      expect(stored.ticket, _ticket);

      expect(h.state.registeredHostIds, {2});
      final register = link.commands.firstWhere(
        (command) => command['type'] == 'push_register',
      );
      final push = register['push']! as Map<String, Object?>;
      expect(push['deviceId'], _deviceId);
      expect(push['ticket'], _ticket);
      expect(push['publicKey'], stored.keyPair.encodedPublicKey);
      expect(
        push['hostRef'],
        await derivePushHostRef(hostRefKey: stored.hostRefKey, hostId: 2),
      );
      expect(push.toString(), isNot(contains(_token)));
      final presence = link.commands.lastWhere(
        (command) => command['type'] == 'push_presence',
      );
      expect(presence['clientId'], 'client-10');
      expect((presence['push']! as Map)['foreground'], isFalse);

      // An idle device says so once; a watching device heartbeats.
      link.commands.clear();
      await h.controller.syncNow();
      expect(link.commands, isEmpty);
      h.controller.reportVisibility(foreground: true, viewedHostId: 2);
      await h.controller.syncNow();
      await h.controller.syncNow();
      expect(link.types.length, greaterThanOrEqualTo(2));
      for (final command in link.commands) {
        expect(command['type'], 'push_presence');
        expect((command['push']! as Map)['foreground'], isTrue);
      }
      h.expectLogsClean();
    },
  );

  test('declined permission leaves no token, key or registration', () async {
    h.gateway.permission = false;
    await h.start();

    expect(await h.controller.enable(), PushSetupFailure.permissionDenied);

    expect(h.state.enabled, isFalse);
    expect(h.state.failure, PushSetupFailure.permissionDenied);
    expect(h.gateway.calls, isNot(contains('getToken')));
    expect(h.secrets.values, isEmpty);
    expect(await h.settings.getBool('push_notifications_enabled'), isFalse);
  });

  test('a failed registration deletes the token and the new key', () async {
    h.gateway.registerError = const PushSetupException(
      PushSetupFailure.appCheckFailed,
    );
    await h.start();

    expect(await h.controller.enable(), PushSetupFailure.appCheckFailed);

    expect(h.gateway.calls, containsAllInOrder(['autoInit:false']));
    expect(h.gateway.calls, contains('deleteToken'));
    expect(h.secrets.values, isEmpty);
    expect(h.state.enabled, isFalse);
  });

  test('a missing token is reported and cleaned up', () async {
    h.gateway.token = null;
    await h.start();

    expect(await h.controller.enable(), PushSetupFailure.tokenUnavailable);
    expect(h.gateway.calls, isNot(contains('register')));
    expect(h.secrets.values, isEmpty);
  });

  test('opting out unregisters reachable hosts, remembers the rest and '
      'deletes the key', () async {
    final online = _FakeLink(connectionId: 10, hostId: 1);
    final offline = _FakeLink(connectionId: 11, hostId: 2);
    h.links.addAll([online, offline]);
    await h.start();
    await h.controller.enable();
    await h.controller.syncNow();
    expect(offline.types, contains('push_register'));

    h.links.remove(offline);
    await h.controller.disable();

    expect(h.state.enabled, isFalse);
    expect(h.state.registeredHostIds, isEmpty);
    expect(online.types.last, 'push_unregister');
    expect((online.commands.last['push']! as Map)['deviceId'], _deviceId);
    expect(
      h.gateway.calls,
      containsAllInOrder(['autoInit:false', 'deleteToken']),
    );
    expect(h.secrets.values, isEmpty);
    expect(await h.settings.getBool('push_notifications_enabled'), isFalse);

    // After a restart the unreachable host is cleaned up on its next attach,
    // even though push is now off.
    await h.restart();
    offline.commands.clear();
    h.links.add(offline);
    await h.controller.syncNow();
    expect(offline.types, ['push_unregister']);
    expect((offline.commands.single['push']! as Map)['deviceId'], _deviceId);

    offline.commands.clear();
    await h.controller.syncNow();
    expect(offline.commands, isEmpty);
    h.expectLogsClean();
  });

  test('turning a host off unregisters it and stops registering', () async {
    final first = _FakeLink(connectionId: 10, hostId: 1);
    final second = _FakeLink(connectionId: 11, hostId: 2);
    h.links.addAll([first, second]);
    await h.start();
    await h.controller.enable();
    await h.controller.syncNow();

    await h.controller.setHostEnabled(2, enabled: false);
    expect(h.state.disabledHostIds, {2});
    expect(second.types.last, 'push_unregister');

    second.commands.clear();
    first.commands.clear();
    await h.controller.syncNow();
    expect(second.commands, isEmpty);
    expect(first.commands, isEmpty);

    await h.controller.setHostEnabled(2, enabled: true);
    await h.controller.syncNow();
    expect(second.types, contains('push_register'));

    // The choice survives a restart.
    await h.controller.setHostEnabled(1, enabled: false);
    await h.restart();
    expect(h.state.disabledHostIds, {1});
    expect(h.state.enabled, isTrue);
  });

  test(
    'a refreshed FCM token is registered again and resent to hosts',
    () async {
      final link = _FakeLink(connectionId: 10, hostId: 1);
      h.links.add(link);
      await h.start();
      await h.controller.enable();
      await h.controller.syncNow();
      link.commands.clear();

      h.gateway
        ..token = 'fcm-token:refreshed'
        ..tokenRefresh.add('fcm-token:refreshed');
      await pumpEventQueue();
      await h.controller.syncNow();

      expect(h.gateway.registrations.last['token'], 'fcm-token:refreshed');
      expect(h.gateway.registrations.last['deviceId'], _deviceId);
      final register = link.commands.firstWhere(
        (command) => command['type'] == 'push_register',
      );
      expect((register['push']! as Map)['ticket'], '$_ticket-2');
    },
  );

  test('a helper without push support is not asked again', () async {
    final link = _FakeLink(connectionId: 10, hostId: 1)..unsupported = true;
    h.links.add(link);
    await h.start();
    await h.controller.enable();
    await h.controller.syncNow();
    expect(link.types, ['push_register']);

    await h.controller.syncNow();
    expect(link.types, ['push_register']);
    expect(await h.controller.sendTest(), PushTestOutcome.hostNeedsUpdate);
  });

  test('presence says foreground only for the host on screen', () async {
    final first = _FakeLink(connectionId: 10, hostId: 1);
    final second = _FakeLink(connectionId: 11, hostId: 2);
    h.links.addAll([first, second]);
    h.alertListeners.add(11);
    await h.start();
    await h.controller.enable();
    h.controller.reportVisibility(foreground: true, viewedHostId: 2);
    await h.controller.syncNow();

    bool foregroundOf(_FakeLink link) =>
        (link.commands.lastWhere(
                  (command) => command['type'] == 'push_presence',
                )['push']!
                as Map)['foreground']!
            as bool;
    expect(foregroundOf(first), isFalse);
    expect(foregroundOf(second), isTrue);

    h.controller.reportVisibility(foreground: false);
    await pumpEventQueue();
    await h.controller.syncNow();
    expect(foregroundOf(second), isFalse);
    // In the background the app says it raises its own notifications, and
    // keeps saying so while it is alive.
    final local = second.commands.lastWhere(
      (command) => command['type'] == 'push_presence',
    );
    expect((local['push']! as Map)['local'], isTrue);
    second.commands.clear();
    await h.controller.syncNow();
    expect(second.types, ['push_presence']);
  });

  test('sendTest reports what happened', () async {
    await h.start();
    await h.controller.enable();
    expect(await h.controller.sendTest(), PushTestOutcome.noConnectedHost);

    final link = _FakeLink(connectionId: 10, hostId: 1);
    h.links.add(link);
    expect(await h.controller.sendTest(), PushTestOutcome.sent);
    expect(
      (link.commands.lastWhere(
            (command) => command['type'] == 'push_test',
          )['push']!
          as Map)['deviceId'],
      _deviceId,
    );
    link.testResult = 'rate_limited';
    expect(await h.controller.sendTest(), PushTestOutcome.rateLimited);
    link.testResult = 'unregistered';
    expect(await h.controller.sendTest(), PushTestOutcome.registrationRejected);
  });

  group('review round 1', () {
    test('an offline opt-out still turns auto-init off and retries the '
        'token deletion', () async {
      final link = _FakeLink(connectionId: 10, hostId: 1);
      h.links.add(link);
      await h.start();
      await h.controller.enable();
      h.gateway.deleteTokenError = Exception('offline');
      h.gateway.calls.clear();

      await h.controller.disable();

      expect(h.gateway.calls, ['autoInit:false', 'deleteToken']);
      expect(
        await h.settings.getBool('push_notifications_token_delete_pending'),
        isTrue,
      );
      expect(h.secrets.values, isEmpty);

      // Later, with the network back, a sync deletes the token.
      h.gateway
        ..deleteTokenError = null
        ..calls.clear();
      h.now = h.now.add(pushRegistrationRetryInterval);
      await h.controller.syncNow();
      await pumpEventQueue();
      expect(h.gateway.calls, ['autoInit:false', 'deleteToken']);
      expect(
        await h.settings.getBool('push_notifications_token_delete_pending'),
        isFalse,
      );

      // The pending deletion survives a restart.
      h.gateway.deleteTokenError = Exception('offline');
      await h.settings.setBool(
        'push_notifications_token_delete_pending',
        value: true,
      );
      await h.restart();
      await pumpEventQueue();
      // The first attempt at start fails (still offline); a later one works.
      expect(h.gateway.calls, contains('deleteToken'));
      h.gateway
        ..deleteTokenError = null
        ..calls.clear();
      h.now = h.now.add(pushRegistrationRetryInterval);
      await h.controller.syncNow();
      await pumpEventQueue();
      expect(h.gateway.calls, ['autoInit:false', 'deleteToken']);
    });

    test(
      'a failed opt-in still deletes the token when auto-init fails',
      () async {
        h.gateway.registerError = const PushSetupException(
          PushSetupFailure.registrationFailed,
        );
        await h.start();
        expect(
          await h.controller.enable(),
          PushSetupFailure.registrationFailed,
        );
        expect(h.gateway.calls, contains('deleteToken'));
        expect(h.gateway.calls, contains('autoInit:false'));
      },
    );

    test('turning a host off waits for a registration in flight', () async {
      final link = _FakeLink(connectionId: 10, hostId: 2);
      h.links.add(link);
      await h.start();
      await h.controller.enable();
      await h.controller.syncNow();
      // A refreshed ticket makes the next sync register again, slowly.
      link
        ..commands.clear()
        ..registerGate = Completer<void>();
      h.gateway
        ..token = 'fcm-token:rotated'
        ..tokenRefresh.add('fcm-token:rotated');
      await pumpEventQueue();
      expect(link.types, ['push_register']);
      final sync = h.controller.syncNow();

      final hostOff = h.controller.setHostEnabled(2, enabled: false);
      await pumpEventQueue();
      expect(link.types, ['push_register'], reason: 'unregister overtook it');
      link.registerGate!.complete();
      await Future.wait([sync, hostOff]);

      expect(link.types.last, 'push_unregister');
      final unregister = link.commands.last['push']! as Map;
      expect(unregister['deviceId'], _deviceId);
      expect(unregister['hostRef'], isNotNull);
      link.commands.clear();
      await h.controller.syncNow();
      expect(link.commands, isEmpty);
    });

    test('a token that rotated while the app was closed is registered at '
        'start', () async {
      final link = _FakeLink(connectionId: 10, hostId: 1);
      h.links.add(link);
      await h.start();
      await h.controller.enable();
      await h.controller.syncNow();

      h.gateway.token = 'fcm-token:rotated-while-closed';
      await h.restart();
      await pumpEventQueue();
      await h.controller.syncNow();

      expect(
        h.gateway.registrations.last['token'],
        'fcm-token:rotated-while-closed',
      );
      final registers = link.commands.where(
        (command) => command['type'] == 'push_register',
      );
      expect((registers.last['push']! as Map)['ticket'], '$_ticket-2');
    });

    test('a failed re-registration is retried', () async {
      final link = _FakeLink(connectionId: 10, hostId: 1);
      h.links.add(link);
      await h.start();
      await h.controller.enable();
      await h.controller.syncNow();

      h.gateway
        ..registerError = const PushSetupException(
          PushSetupFailure.appCheckFailed,
        )
        ..token = 'fcm-token:rotated'
        ..tokenRefresh.add('fcm-token:rotated');
      await pumpEventQueue();
      expect(h.gateway.registrations.last['token'], 'fcm-token:rotated');
      final failures = h.gateway.registrations.length;

      // Too soon: not retried yet.
      h.gateway.registerError = null;
      await h.controller.syncNow();
      await pumpEventQueue();
      expect(h.gateway.registrations, hasLength(failures));

      h.now = h.now.add(pushRegistrationRetryInterval);
      await h.controller.syncNow();
      await pumpEventQueue();
      await h.controller.syncNow();
      expect(h.gateway.registrations, hasLength(failures + 1));
      final registers = link.commands.where(
        (command) => command['type'] == 'push_register',
      );
      expect((registers.last['push']! as Map)['ticket'], '$_ticket-2');
    });

    test('tickets are renewed weekly when the app comes back', () async {
      final link = _FakeLink(connectionId: 10, hostId: 1);
      h.links.add(link);
      await h.start();
      await h.controller.enable();
      final registrations = h.gateway.registrations.length;
      h.controller.reportVisibility(foreground: false);
      h.now = h.now.add(pushTicketRefreshAge);
      h.controller.reportVisibility(foreground: true);
      await pumpEventQueue();
      await h.controller.syncNow();
      expect(h.gateway.registrations, hasLength(registrations + 1));
    });

    test('a host that refused the ticket gets a new one', () async {
      for (final (result, deletesToken) in [
        ('stale_ticket', false),
        ('token_unregistered', true),
      ]) {
        final harness = _Harness();
        addTearDown(harness.dispose);
        final link = _FakeLink(connectionId: 10, hostId: 1)
          ..registerResult = result;
        harness.links.add(link);
        await harness.start();
        await harness.controller.enable();
        harness.gateway.calls.clear();
        await harness.controller.syncNow();
        await pumpEventQueue();
        await harness.controller.syncNow();

        expect(harness.gateway.calls, contains('register'), reason: result);
        expect(
          harness.gateway.calls.contains('deleteToken'),
          deletesToken,
          reason: result,
        );
        final registers = link.commands
            .where((command) => command['type'] == 'push_register')
            .toList();
        expect(registers, hasLength(2), reason: result);
        expect(
          (registers.last['push']! as Map)['ticket'],
          '$_ticket-2',
          reason: result,
        );
      }
    });

    test('presence follows the connection on screen, not the host', () async {
      final first = _FakeLink(
        connectionId: 10,
        hostId: 1,
        sessionName: 'build',
      );
      final second = _FakeLink(
        connectionId: 11,
        hostId: 1,
        sessionName: 'review',
      );
      h.links.addAll([first, second]);
      await h.start();
      await h.controller.enable();

      bool? viewing(_FakeLink link) {
        final presence = link.commands.where(
          (command) => command['type'] == 'push_presence',
        );
        return presence.isEmpty
            ? null
            : (presence.last['push']! as Map)['foreground'] as bool;
      }

      h.controller.reportVisibility(
        foreground: true,
        viewedHostId: 1,
        viewedConnectionId: 11,
      );
      await h.controller.syncNow();
      expect(viewing(first), isFalse);
      expect(viewing(second), isTrue);

      // Without the connection id, two connections to one host are
      // ambiguous: neither suppresses pushes.
      h.controller.reportVisibility(foreground: true, viewedHostId: 1);
      await h.controller.syncNow();
      expect(viewing(first), isFalse);
      expect(viewing(second), isFalse);
    });

    test(
      'foreground alerts are kept unless that session is on screen',
      () async {
        final link = _FakeLink(
          connectionId: 10,
          hostId: 2,
          activeWindowId: '@4',
        );
        h.links.add(link);
        await h.start();
        await h.controller.enable();
        const alert = PushNavigationTarget(
          hostId: 2,
          kind: PushEventKind.alert,
          sessionName: 'main',
          windowId: '@5',
        );
        // Connected, but on Home: no window bar is raising this alert.
        h.controller.reportVisibility(foreground: true);
        expect(h.controller.shouldSuppressInForeground(alert), isFalse);
        h.controller.reportVisibility(foreground: true, viewedHostId: 2);
        expect(h.controller.shouldSuppressInForeground(alert), isTrue);
        const otherSession = PushNavigationTarget(
          hostId: 2,
          kind: PushEventKind.alert,
          sessionName: 'other',
          windowId: '@5',
        );
        expect(h.controller.shouldSuppressInForeground(otherSession), isFalse);
      },
    );

    test('a secure storage failure leaves settings usable', () async {
      final failing = _ThrowingSecretStore();
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.settings.setBool('push_notifications_enabled', value: true);
      final container = ProviderContainer(
        overrides: [
          pushNotificationsAvailableProvider.overrideWithValue(true),
          pushMessagingGatewayProvider.overrideWithValue(harness.gateway),
          pushDeviceStoreProvider.overrideWithValue(
            PushDeviceStore(secrets: failing),
          ),
          settingsServiceProvider.overrideWithValue(harness.settings),
          diagnosticsLoggerProvider.overrideWithValue(harness.logger),
          pushHostLinksProvider.overrideWithValue(() => const []),
          pushHostIdsProvider.overrideWithValue(() async => [1]),
          pushLocalBridgesProvider.overrideWithValue((_) => const []),
          pushNotificationChannelInstallerProvider.overrideWithValue(
            () async {},
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(pushNotificationControllerProvider);
      await pumpEventQueue();
      final state = container.read(pushNotificationControllerProvider);
      expect(state.loaded, isTrue);
      expect(state.enabled, isFalse);
      final target = await container
          .read(pushNotificationControllerProvider.notifier)
          .resolve(const PushRemoteMessage(data: {'v': '1', 'p': 'AAAA'}));
      expect(target, isNull);
    });

    test('a helper that lacked push is asked again later', () async {
      final link = _FakeLink(connectionId: 10, hostId: 1)..unsupported = true;
      h.links.add(link);
      await h.start();
      await h.controller.enable();
      await h.controller.syncNow();
      link
        ..unsupported = false
        ..commands.clear();
      await h.controller.syncNow();
      expect(link.commands, isEmpty);
      h.now = h.now.add(pushUnsupportedRetryInterval);
      await h.controller.syncNow();
      expect(link.types, contains('push_register'));
    });

    test('send test tells apart no hosts and hosts turned off', () async {
      final link = _FakeLink(connectionId: 10, hostId: 1);
      await h.start();
      await h.controller.enable();
      expect(await h.controller.sendTest(), PushTestOutcome.noConnectedHost);
      h.links.add(link);
      await h.controller.setHostEnabled(1, enabled: false);
      expect(await h.controller.sendTest(), PushTestOutcome.noEnabledHost);
    });
  });

  group('review round 2', () {
    Map<String, Object?> lastPresence(_FakeLink link) =>
        link.commands.lastWhere(
              (command) => command['type'] == 'push_presence',
            )['push']!
            as Map<String, Object?>;

    test('background presence claims only what the app will raise', () async {
      final mounted = _FakeLink(connectionId: 10, hostId: 1);
      final unmounted = _FakeLink(connectionId: 11, hostId: 2);
      h.links.addAll([mounted, unmounted]);
      h.alertListeners.add(10);
      h.bridgesByHost[2] = ['0123456789abcdef0123456789abcdef'];
      await h.start();
      await h.controller.enable();
      h.controller.reportVisibility(foreground: false);
      await pumpEventQueue();
      await h.controller.syncNow();

      expect(lastPresence(mounted)['local'], isTrue);
      expect(lastPresence(mounted)['alerts'], isTrue);
      expect(lastPresence(mounted)['bridges'], isEmpty);
      expect(lastPresence(unmounted)['local'], isTrue);
      expect(lastPresence(unmounted)['alerts'], isFalse);
      expect(lastPresence(unmounted)['bridges'], [
        '0123456789abcdef0123456789abcdef',
      ]);

      // A connection with neither is idle, said once.
      h.alertListeners.clear();
      h.bridgesByHost.clear();
      await h.controller.syncNow();
      expect(lastPresence(mounted)['local'], isFalse);
      mounted.commands.clear();
      await h.controller.syncNow();
      expect(mounted.commands, isEmpty);
    });

    test('a backgrounded iOS app reports idle', () async {
      h.localPresenceSupported = false;
      final link = _FakeLink(connectionId: 10, hostId: 1);
      h.links.add(link);
      h.alertListeners.add(10);
      await h.start();
      await h.controller.enable();
      h.controller.reportVisibility(foreground: false);
      await pumpEventQueue();
      await h.controller.syncNow();
      expect(lastPresence(link)['local'], isFalse);
    });

    test(
      'an opt-in that never got a token does not schedule a deletion',
      () async {
        for (final setup in <void Function(_FakeGateway)>[
          (gateway) => gateway.permission = false,
          (gateway) => gateway.token = null,
        ]) {
          final harness = _Harness();
          addTearDown(harness.dispose);
          setup(harness.gateway);
          await harness.start();
          await harness.controller.enable();
          expect(harness.gateway.calls, isNot(contains('deleteToken')));
          expect(
            await harness.settings.getBool(
              'push_notifications_token_delete_pending',
            ),
            isFalse,
          );
        }
      },
    );

    test(
      'a pending deletion never removes the token a new opt-in registers',
      () async {
        await h.settings.setBool(
          'push_notifications_token_delete_pending',
          value: true,
        );
        final gate = Completer<void>();
        final gateway = _GatedRegisterGateway(gate);
        final harness = _Harness(gateway: gateway);
        addTearDown(harness.dispose);
        await harness.settings.setBool(
          'push_notifications_token_delete_pending',
          value: true,
        );
        await harness.start();
        gateway.calls.clear();
        final enabling = harness.controller.enable();
        await pumpEventQueue();
        expect(gateway.calls, contains('register'));
        // A heartbeat during the opt-in.
        harness.now = harness.now.add(pushRegistrationRetryMax);
        await harness.controller.syncNow();
        await pumpEventQueue();
        gate.complete();
        await enabling;
        await harness.controller.syncNow();
        await pumpEventQueue();
        expect(gateway.calls, isNot(contains('deleteToken')));
        expect(
          await harness.settings.getBool(
            'push_notifications_token_delete_pending',
          ),
          isFalse,
        );
        expect(harness.state.enabled, isTrue);
      },
    );

    test(
      'a dead token is not re-registered when it cannot be deleted',
      () async {
        final link = _FakeLink(connectionId: 10, hostId: 1)
          ..registerResult = 'token_unregistered';
        h.links.add(link);
        await h.start();
        h.gateway.deleteTokenError = Exception('offline');
        await h.controller.enable();
        final registrations = h.gateway.registrations.length;
        await h.controller.syncNow();
        await pumpEventQueue();
        expect(h.gateway.registrations, hasLength(registrations));
      },
    );

    test('ticket renewal retries back off', () async {
      final link = _FakeLink(connectionId: 10, hostId: 1);
      h.links.add(link);
      await h.start();
      await h.controller.enable();
      h.gateway
        ..registerError = const PushSetupException(
          PushSetupFailure.appCheckFailed,
        )
        ..token = 'fcm-token:rotated'
        ..tokenRefresh.add('fcm-token:rotated');
      await pumpEventQueue();
      int attempts() => h.gateway.registrations
          .where((entry) => entry['token'] == 'fcm-token:rotated')
          .length;
      expect(attempts(), 1);
      Future<void> after(Duration delay) async {
        h.now = h.now.add(delay);
        await h.controller.syncNow();
        await pumpEventQueue();
      }

      await after(pushRegistrationRetryInterval);
      expect(attempts(), 2);
      // The next wait is twice as long.
      await after(pushRegistrationRetryInterval);
      expect(attempts(), 2);
      await after(pushRegistrationRetryInterval);
      expect(attempts(), 3);
    });

    test('a reconnected terminal still counts as viewed', () async {
      final link = _FakeLink(connectionId: 12, hostId: 1);
      h.links.add(link);
      await h.start();
      await h.controller.enable();
      // The route still names the connection from before the reconnect.
      h.controller.reportVisibility(
        foreground: true,
        viewedHostId: 1,
        viewedConnectionId: 7,
      );
      await h.controller.syncNow();
      expect(lastPresence(link)['foreground'], isTrue);
    });

    test('deleted hosts are dropped from the bookkeeping', () async {
      final link = _FakeLink(connectionId: 10, hostId: 3);
      h.links.add(link);
      await h.start();
      await h.controller.enable();
      await h.controller.syncNow();
      expect(h.state.registeredHostIds, {3});
      await h.controller.setHostEnabled(3, enabled: false);
      expect(h.state.disabledHostIds, {3});

      h.links.clear();
      h.hostIds = () => [1, 2];
      await h.restart();
      expect(h.state.registeredHostIds, isEmpty);
      expect(h.state.disabledHostIds, isEmpty);
      await h.controller.disable();
      expect(
        await h.settings.getString('push_notifications_pending_unregister'),
        '{}',
      );
    });

    test('a short host-reference key is rejected', () async {
      final store = PushDeviceStore(secrets: h.secrets);
      final created = await store.loadOrCreate();
      final raw = jsonDecode(h.secrets.values.values.single) as Map;
      raw['hostRefKey'] = encodePushBase64([1, 2, 3]);
      h.secrets.values[h.secrets.values.keys.single] = jsonEncode(raw);
      expect(await store.load(), isNull);
      final regenerated = await store.loadOrCreate();
      expect(regenerated.hostRefKey, hasLength(32));
      expect(regenerated.hostRefKey, isNot(created.hostRefKey));
    });
  });

  group('review round 2 follow-up', () {
    test('a failed auto-init disable is persisted and retried', () async {
      await h.start();
      await h.controller.enable();
      h.gateway.autoInitError = Exception('plugin');
      await h.controller.disable();
      expect(
        await h.settings.getBool(
          'push_notifications_auto_init_disable_pending',
        ),
        isTrue,
      );
      h.gateway
        ..autoInitError = null
        ..calls.clear();
      h.now = h.now.add(pushRegistrationRetryInterval);
      await h.controller.syncNow();
      await pumpEventQueue();
      expect(h.gateway.calls, contains('autoInit:false'));
      expect(
        await h.settings.getBool(
          'push_notifications_auto_init_disable_pending',
        ),
        isFalse,
      );
    });

    test(
      'an opt-out interrupted by the app being killed finishes at start',
      () async {
        final link = _FakeLink(connectionId: 10, hostId: 1);
        h.links.add(link);
        await h.start();
        await h.controller.enable();
        await h.controller.syncNow();
        // What a kill right after the opt-out began leaves behind.
        await h.settings.setBool('push_notifications_enabled', value: false);
        await h.settings.setBool(
          'push_notifications_opt_out_pending',
          value: true,
        );
        h.links.clear();
        h.gateway.calls.clear();
        await h.restart();

        expect(h.state.enabled, isFalse);
        expect(h.secrets.values, isEmpty);
        expect(
          h.gateway.calls,
          containsAllInOrder(['autoInit:false', 'deleteToken']),
        );
        expect(
          await h.settings.getBool('push_notifications_opt_out_pending'),
          isFalse,
        );
        // The host that held the registration is unregistered when it attaches.
        h.links.add(link);
        link.commands.clear();
        await h.controller.syncNow();
        expect(link.types, ['push_unregister']);
        expect((link.commands.single['push']! as Map)['deviceId'], _deviceId);
      },
    );
  });

  group('messages', () {
    Future<PushRemoteMessage> sealedMessage({
      required int hostId,
      required String kind,
      String window = '@4',
      String session = 'main',
    }) async {
      final stored = (await PushDeviceStore(secrets: h.secrets).load())!;
      final hostRef = await derivePushHostRef(
        hostRefKey: stored.hostRefKey,
        hostId: hostId,
      );
      final payload = await sealPushPayloadForTesting(
        devicePublicKey: stored.keyPair.publicKey,
        plaintext: utf8.encode(
          jsonEncode({
            'v': 1,
            'hostRef': hostRef,
            'window': window,
            'sessionId': session,
            'kind': kind,
            'ts': 1760000000,
          }),
        ),
        ephemeralSeed: List<int>.generate(32, (index) => index + 1),
        nonce: List<int>.filled(12, 9),
      );
      return PushRemoteMessage(data: {'v': '1', 'p': payload});
    }

    test('a tap resolves to the host, session and window', () async {
      final link = _FakeLink(connectionId: 10, hostId: 2);
      h.links.add(link);
      await h.start();
      await h.controller.enable();

      final target = await h.controller.resolve(
        await sealedMessage(hostId: 2, kind: 'permission'),
      );
      expect(
        target,
        const PushNavigationTarget(
          hostId: 2,
          kind: PushEventKind.permission,
          sessionName: 'main',
          windowId: '@4',
          connectionId: 10,
        ),
      );
    });

    test(
      'unknown hosts, foreign payloads and a deleted key resolve to null',
      () async {
        await h.start();
        await h.controller.enable();
        expect(
          await h.controller.resolve(
            await sealedMessage(hostId: 99, kind: 'alert'),
          ),
          isNull,
        );
        expect(
          await h.controller.resolve(
            const PushRemoteMessage(data: {'v': '1', 'p': 'AAAA'}),
          ),
          isNull,
        );
        expect(
          await h.controller.resolve(const PushRemoteMessage(data: {})),
          isNull,
        );

        final message = await sealedMessage(hostId: 1, kind: 'finished');
        await h.controller.disable();
        expect(await h.controller.resolve(message), isNull);
      },
    );

    test('foreground pushes for the window on screen are dropped', () async {
      final link = _FakeLink(connectionId: 10, hostId: 2, activeWindowId: '@4');
      h.links.add(link);
      await h.start();
      await h.controller.enable();
      h.controller.reportVisibility(foreground: true, viewedHostId: 2);

      const onScreen = PushNavigationTarget(
        hostId: 2,
        kind: PushEventKind.permission,
        sessionName: 'main',
        windowId: '@4',
      );
      expect(h.controller.shouldSuppressInForeground(onScreen), isTrue);
      const otherWindow = PushNavigationTarget(
        hostId: 2,
        kind: PushEventKind.permission,
        sessionName: 'main',
        windowId: '@5',
      );
      expect(h.controller.shouldSuppressInForeground(otherWindow), isFalse);
      // The window bar already alerts for a live connection.
      const alert = PushNavigationTarget(
        hostId: 2,
        kind: PushEventKind.alert,
        sessionName: 'main',
        windowId: '@5',
      );
      expect(h.controller.shouldSuppressInForeground(alert), isTrue);
      const otherHost = PushNavigationTarget(
        hostId: 3,
        kind: PushEventKind.alert,
        sessionName: 'main',
        windowId: '@5',
      );
      expect(h.controller.shouldSuppressInForeground(otherHost), isFalse);
      const test = PushNavigationTarget(hostId: 2, kind: PushEventKind.test);
      expect(h.controller.shouldSuppressInForeground(test), isFalse);
    });
  });
}
