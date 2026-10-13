import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/host_notifications.dart';
import 'package:monkeyssh/domain/services/push/push_messaging_gateway.dart';
import 'package:monkeyssh/domain/services/push/push_notification_service.dart';
import 'package:monkeyssh/presentation/widgets/host_notifications_section.dart';

class _FakeController extends PushNotificationController {
  _FakeController(this.initial);

  final PushNotificationState initial;
  int enableCalls = 0;

  @override
  PushNotificationState build() => initial;

  @override
  Future<PushSetupFailure?> enable() async {
    enableCalls++;
    return initial.failure;
  }
}

Future<_FakeController> _pump(
  WidgetTester tester,
  PushNotificationState state,
) async {
  final controller = _FakeController(state);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        pushNotificationControllerProvider.overrideWith(() => controller),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              HostNotificationsSection(
                sessionKind: HostSessionKind.monkeyMux,
                sessionName: 'build-box',
                prefs: const HostNotificationPrefs(),
                onChanged: (_) {},
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return controller;
}

void main() {
  testWidgets('push that is off offers to turn it on', (tester) async {
    final controller = await _pump(
      tester,
      const PushNotificationState(available: true, loaded: true),
    );

    expect(find.text('Push is off on this device'), findsOneWidget);
    await tester.tap(find.text('Turn on'));
    await tester.pump();
    expect(controller.enableCalls, 1);
  });

  testWidgets('a failed opt-in says why and offers a retry', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final controller = await _pump(
      tester,
      const PushNotificationState(
        available: true,
        loaded: true,
        failure: PushSetupFailure.appCheckFailed,
      ),
    );

    expect(
      find.text(
        'Google Play could not verify this copy of MonkeySSH. Push works in '
        'copies installed from Google Play.',
      ),
      findsOneWidget,
    );
    expect(find.text('Turn on'), findsNothing);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(controller.enableCalls, 1);
    debugDefaultTargetPlatformOverride = null;
  });
}
