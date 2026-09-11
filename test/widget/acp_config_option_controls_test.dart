// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/presentation/widgets/acp_config_option_controls.dart';

import '../support/fake_acp_session_manager.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(400, 800),
  bool wrapInMaterialApp = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    wrapInMaterialApp ? MaterialApp(home: Scaffold(body: child)) : child,
  );
}

void main() {
  testWidgets(
    'renders select + boolean and applies changes via generic setter',
    (tester) async {
      final calls = <(String, Object)>[];
      await _pump(
        tester,
        AcpConfigOptionControls(
          options: const [
            AcpSelectConfigOption(
              id: 'model',
              name: 'Model',
              category: 'model',
              currentValue: 'fast',
              options: [
                AcpConfigValue(value: 'fast', name: 'Fast'),
                AcpConfigValue(value: 'smart', name: 'Smart'),
              ],
            ),
            AcpBooleanConfigOption(
              id: 'yolo',
              name: 'Auto-approve',
              category: 'permissions',
              currentValue: false,
            ),
          ],
          onSetConfigOption: (id, value) async => calls.add((id, value)),
        ),
      );

      expect(find.widgetWithText(ListTile, 'Model'), findsOneWidget);
      expect(find.text('Auto-approve'), findsOneWidget);

      // Toggle the boolean.
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(calls, contains(('yolo', true)));

      // Change the select via the value picker.
      await tester.tap(find.widgetWithText(ListTile, 'Model'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Smart'));
      await tester.pumpAndSettle();
      expect(calls, contains(('model', 'smart')));
    },
  );

  for (final width in [400.0, 800.0]) {
    testWidgets('settings route stays live at width $width', (tester) async {
      AcpSessionManagerState state({required bool value}) =>
          AcpSessionManagerState(
            sessions: [
              fakeAcpSession(
                configOptions: [
                  AcpBooleanConfigOption(
                    id: 'flag',
                    name: 'Flag',
                    currentValue: value,
                  ),
                ],
              ),
            ],
          );
      final manager = FakeAcpSessionManager(
        sessions: state(value: false).sessions,
      );
      addTearDown(manager.dispose);
      await _pump(
        tester,
        ProviderScope(
          overrides: [acpSessionManagerProvider.overrideWithValue(manager)],
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showAcpConfigOptions(context, sessionKey: fakeAcpKey()),
                child: const Text('open'),
              ),
            ),
          ),
        ),
        size: Size(width, 800),
        wrapInMaterialApp: false,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

      for (final value in [true, false]) {
        await tester.tap(find.byType(Switch));
        await tester.pumpAndSettle();
        expect(manager.configOptionSets.last, ('flag', value));
        manager.emit(state(value: value));
        await tester.pumpAndSettle();
        expect(tester.widget<Switch>(find.byType(Switch)).value, value);
      }
      expect(manager.configOptionSets, [('flag', true), ('flag', false)]);

      manager.emit(state(value: true));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    });
  }

  testWidgets('falls back to legacy mode only when no generic option exists', (
    tester,
  ) async {
    final modeCalls = <String>[];
    await _pump(
      tester,
      AcpConfigOptionControls(
        options: const [],
        onSetConfigOption: (_, _) async {},
        modeState: const AcpSessionModeState(
          currentModeId: 'ask',
          availableModes: [
            AcpSessionMode(id: 'ask', name: 'Ask'),
            AcpSessionMode(id: 'auto', name: 'Auto'),
          ],
        ),
        onSetMode: (modeId) async => modeCalls.add(modeId),
      ),
    );

    expect(find.widgetWithText(ListTile, 'Mode'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, 'Mode'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Auto'));
    await tester.pumpAndSettle();
    expect(modeCalls, ['auto']);
  });

  testWidgets('surfaces an error when a setter fails', (tester) async {
    await _pump(
      tester,
      AcpConfigOptionControls(
        options: const [
          AcpBooleanConfigOption(id: 'flag', name: 'Flag', currentValue: false),
        ],
        onSetConfigOption: (_, _) async => throw StateError('nope'),
      ),
    );

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('Could not apply this setting.'), findsOneWidget);
  });

  testWidgets('disables controls when not enabled', (tester) async {
    await _pump(
      tester,
      AcpConfigOptionControls(
        options: const [
          AcpBooleanConfigOption(id: 'flag', name: 'Flag', currentValue: true),
        ],
        onSetConfigOption: (_, _) async {},
        enabled: false,
      ),
    );

    final switchWidget = tester.widget<Switch>(find.byType(Switch));
    expect(switchWidget.onChanged, isNull);
  });

  testWidgets('renders unknown option types as a disabled row', (tester) async {
    await _pump(
      tester,
      AcpConfigOptionControls(
        options: const [
          AcpUnknownConfigOption(
            id: 'future',
            name: 'Future Setting',
            type: 'slider',
            raw: {},
          ),
        ],
        onSetConfigOption: (_, _) async {},
      ),
    );
    expect(find.text('Unsupported setting'), findsOneWidget);
  });

  testWidgets('dismissing the value picker applies no change', (tester) async {
    final calls = <(String, Object)>[];
    await _pump(
      tester,
      AcpConfigOptionControls(
        options: const [
          AcpSelectConfigOption(
            id: 'model',
            name: 'Model',
            category: 'model',
            currentValue: 'fast',
            options: [
              AcpConfigValue(value: 'fast', name: 'Fast'),
              AcpConfigValue(value: 'smart', name: 'Smart'),
            ],
          ),
        ],
        onSetConfigOption: (id, value) async => calls.add((id, value)),
      ),
    );

    await tester.tap(find.widgetWithText(ListTile, 'Model'));
    await tester.pumpAndSettle();
    // Dismiss the value sheet without choosing (tap the scrim).
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
