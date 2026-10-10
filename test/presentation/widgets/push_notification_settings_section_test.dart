import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/services/push/push_messaging_gateway.dart';
import 'package:monkeyssh/domain/services/push/push_notification_service.dart';
import 'package:monkeyssh/presentation/providers/entity_list_providers.dart';
import 'package:monkeyssh/presentation/widgets/push_notification_settings_section.dart';

class _FakeController extends PushNotificationController {
  _FakeController(this.initial);

  final PushNotificationState initial;
  final calls = <String>[];
  PushTestOutcome testOutcome = PushTestOutcome.sent;
  Completer<void>? testGate;

  @override
  PushNotificationState build() => initial;

  @override
  Future<PushSetupFailure?> enable() async {
    calls.add('enable');
    state = state.copyWith(enabled: true);
    return null;
  }

  @override
  Future<void> disable() async {
    calls.add('disable');
    state = state.copyWith(enabled: false);
  }

  @override
  Future<void> setHostEnabled(int hostId, {required bool enabled}) async {
    calls.add('host:$hostId:$enabled');
    final disabled = {...state.disabledHostIds};
    enabled ? disabled.remove(hostId) : disabled.add(hostId);
    state = state.copyWith(disabledHostIds: disabled);
  }

  @override
  Future<PushTestOutcome> sendTest() async {
    calls.add('test');
    await testGate?.future;
    return testOutcome;
  }
}

Host _host(int id, String label) => Host(
  id: id,
  label: label,
  hostname: '$label.example.com',
  port: 22,
  username: 'root',
  isFavorite: false,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  autoConnectRequiresConfirmation: false,
  autoForwardPorts: false,
  sortOrder: 0,
);

Future<_FakeController> _pump(
  WidgetTester tester, {
  required bool available,
  PushNotificationState state = const PushNotificationState(
    available: true,
    loaded: true,
  ),
}) async {
  final controller = _FakeController(state);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        pushNotificationsAvailableProvider.overrideWithValue(available),
        pushNotificationControllerProvider.overrideWith(() => controller),
        allHostsProvider.overrideWith(
          (ref) => Stream.value([_host(1, 'build-box'), _host(2, 'gpu-rig')]),
        ),
      ],
      child: MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: ListView(children: const [PushNotificationSettingsSection()]),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets('builds without push support render nothing', (tester) async {
    await _pump(tester, available: false);
    expect(find.text('Notify me when the app is closed'), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
  });

  testWidgets('the opt-in switch starts off and turns push on', (tester) async {
    final controller = await _pump(tester, available: true);
    final optIn = find.byKey(const ValueKey('push-settings-enabled'));
    expect(tester.widget<SwitchListTile>(optIn).value, isFalse);
    expect(find.textContaining('Prompts, output, paths'), findsOneWidget);
    expect(find.byKey(const ValueKey('push-settings-test')), findsNothing);

    await tester.tap(optIn);
    await tester.pumpAndSettle();

    expect(controller.calls, ['enable']);
    expect(tester.widget<SwitchListTile>(optIn).value, isTrue);
    expect(find.text('build-box'), findsOneWidget);
    expect(find.byKey(const ValueKey('push-settings-test')), findsOneWidget);
  });

  testWidgets('the switch is disabled until settings load', (tester) async {
    await _pump(
      tester,
      available: true,
      state: const PushNotificationState(available: true),
    );
    final optIn = find.byKey(const ValueKey('push-settings-enabled'));
    expect(tester.widget<SwitchListTile>(optIn).onChanged, isNull);
  });

  testWidgets('the switch is disabled while busy', (tester) async {
    await _pump(
      tester,
      available: true,
      state: const PushNotificationState(
        available: true,
        loaded: true,
        busy: true,
      ),
    );
    final optIn = find.byKey(const ValueKey('push-settings-enabled'));
    expect(tester.widget<SwitchListTile>(optIn).onChanged, isNull);
    expect(find.text('Updating…'), findsOneWidget);
  });

  testWidgets('a failed opt-in explains itself with text and an icon', (
    tester,
  ) async {
    await _pump(
      tester,
      available: true,
      state: const PushNotificationState(
        available: true,
        loaded: true,
        failure: PushSetupFailure.permissionDenied,
      ),
    );
    expect(
      find.textContaining('Allow them in system settings'),
      findsOneWidget,
    );
    final icon = tester.widget<Icon>(find.byIcon(Icons.error_outline));
    expect(icon.semanticLabel, 'Error');
  });

  testWidgets('hosts can be turned off one by one', (tester) async {
    final controller = await _pump(
      tester,
      available: true,
      state: const PushNotificationState(
        available: true,
        loaded: true,
        enabled: true,
        disabledHostIds: {2},
        registeredHostIds: {1},
      ),
    );
    final first = find.byKey(const ValueKey('push-settings-host-1'));
    final second = find.byKey(const ValueKey('push-settings-host-2'));
    expect(tester.widget<SwitchListTile>(first).value, isTrue);
    expect(tester.widget<SwitchListTile>(second).value, isFalse);
    // State is spelled out, not only shown by the switch.
    expect(
      find.descendant(of: second, matching: find.text('Off')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: first, matching: find.text('On')),
      findsOneWidget,
    );

    await tester.tap(first);
    await tester.pumpAndSettle();
    expect(controller.calls, ['host:1:false']);
    expect(tester.widget<SwitchListTile>(first).value, isFalse);
  });

  testWidgets('send test notification reports the outcome', (tester) async {
    final controller = await _pump(
      tester,
      available: true,
      state: const PushNotificationState(
        available: true,
        loaded: true,
        enabled: true,
      ),
    );
    controller.testOutcome = PushTestOutcome.noConnectedHost;
    await tester.tap(find.byKey(const ValueKey('push-settings-test')));
    await tester.pumpAndSettle();

    expect(controller.calls, ['test']);
    expect(
      find.text(pushTestOutcomeMessage(PushTestOutcome.noConnectedHost)),
      findsOneWidget,
    );
  });

  testWidgets('send test cannot be tapped again while one is on its way', (
    tester,
  ) async {
    final controller = await _pump(
      tester,
      available: true,
      state: const PushNotificationState(
        available: true,
        loaded: true,
        enabled: true,
      ),
    );
    controller.testGate = Completer<void>();
    final tile = find.byKey(const ValueKey('push-settings-test'));
    await tester.tap(tile);
    await tester.pump();
    expect(tester.widget<ListTile>(tile).enabled, isFalse);
    await tester.tap(tile, warnIfMissed: false);
    expect(controller.calls, ['test']);
    controller.testGate!.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(tile).enabled, isTrue);
  });

  testWidgets('targets are large enough and labelled', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      available: true,
      state: const PushNotificationState(
        available: true,
        loaded: true,
        enabled: true,
      ),
    );
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    semantics.dispose();
  });

  test('host status says when a host has not registered yet', () {
    const state = PushNotificationState(
      enabled: true,
      disabledHostIds: {3},
      registeredHostIds: {1, 3},
    );
    expect(pushHostStatus(state, 1), 'On');
    expect(
      pushHostStatus(state, 2),
      'On once you connect to it with MonkeyMux',
    );
    expect(pushHostStatus(state, 3), 'Off');
  });

  test('every outcome and failure has a message', () {
    for (final outcome in PushTestOutcome.values) {
      expect(pushTestOutcomeMessage(outcome), isNotEmpty);
    }
    for (final failure in PushSetupFailure.values) {
      expect(pushSetupFailureMessage(failure), isNotEmpty);
    }
  });
}
