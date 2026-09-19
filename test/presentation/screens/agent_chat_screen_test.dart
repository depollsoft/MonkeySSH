import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/presentation/screens/acp_quick_selectors.dart';

import '../../support/fake_acp_session_manager.dart';

void main() {
  late List<(String, Object)> selected;
  setUp(() => selected = []);
  List<AcpQuickSelectorData> selectors(
    AcpSessionState session, {
    List<String>? scope,
  }) => buildAcpQuickSelectors(
    session,
    providerId: session.key.providerId,
    piEnabledModelPatterns: scope,
    setConfigOption: (id, value) async => selected.add((id, value)),
    setModel: (value) async => selected.add(('model', value)),
    setMode: (value) async => selected.add(('mode', value)),
    setAutoApprovePermissions: ({required enabled}) async =>
        selected.add(('autoApprove', enabled)),
  );

  test('empty sessions expose the fallback permission choices', () async {
    final result = selectors(fakeAcpSession());
    expect(result.map((item) => item.label), ['Permission']);
    expect(result.single.currentValue, 'false');
    expect(
      result.single.choices.map((choice) => (choice.value, choice.label)),
      [('false', 'Ask'), ('true', 'YOLO')],
    );
    await result.single.onSelected('true');
    expect(selected, [('autoApprove', true)]);
  });

  test(
    'legacy effort retains the mode callback and exact identifiers',
    () async {
      final result = selectors(
        fakeAcpSession(
          modeState: const AcpSessionModeState(
            currentModeId: 'medium',
            availableModes: [
              AcpSessionMode(id: 'low', name: 'Low'),
              AcpSessionMode(id: 'medium', name: 'Medium'),
              AcpSessionMode(id: 'high', name: 'High'),
            ],
          ),
        ),
      );
      expect(result.map((item) => item.label), ['Effort', 'Permission']);
      expect(result.first.currentValue, 'medium');
      expect(result.first.choices.map((choice) => choice.label), [
        'Low',
        'Medium',
        'High',
      ]);
      await result.first.onSelected('high');
      expect(selected, [('mode', 'high')]);
    },
  );

  test(
    'generic effort and provider permission options keep their callbacks',
    () async {
      final result = selectors(
        fakeAcpSession(
          configOptions: const [
            AcpSelectConfigOption(
              id: 'session-mode',
              name: 'Mode',
              category: 'mode',
              currentValue: 'medium',
              options: [
                AcpConfigValue(value: 'low', name: 'Low'),
                AcpConfigValue(value: 'medium', name: 'Medium'),
                AcpConfigValue(value: 'high', name: 'High'),
              ],
            ),
            AcpSelectConfigOption(
              id: 'approval-mode',
              name: 'Permission',
              currentValue: 'yolo',
              options: [
                AcpConfigValue(value: 'yolo', name: 'YOLO'),
                AcpConfigValue(value: 'plan', name: 'Plan only'),
              ],
            ),
            AcpSelectConfigOption(
              id: 'fast',
              name: 'Fast mode',
              category: 'model_config',
              currentValue: 'off',
              options: [
                AcpConfigValue(value: 'off', name: 'Off'),
                AcpConfigValue(value: 'on', name: 'On'),
              ],
            ),
          ],
        ),
      );
      expect(result.map((item) => item.label), [
        'Effort',
        'Permission',
        'Fast mode',
      ]);
      expect(result[1].choices.map((choice) => choice.label), [
        'YOLO',
        'Plan only',
      ]);
      await result[0].onSelected('high');
      await result[1].onSelected('plan');
      await result[2].onSelected('on');
      expect(selected, [
        ('session-mode', 'high'),
        ('approval-mode', 'plan'),
        ('fast', 'on'),
      ]);
    },
  );

  test(
    'Pi scope retains the current model and partitions other choices in order',
    () {
      final session = fakeAcpSession(
        key: fakeAcpKey(providerId: AcpBuiltinProviderIds.pi),
        configOptions: const [
          AcpSelectConfigOption(
            id: 'model',
            name: 'Model',
            category: 'model',
            currentValue: 'openai/gpt-5',
            options: [
              AcpConfigValue(
                value: 'anthropic/claude-sonnet',
                name: 'anthropic/Claude Sonnet',
              ),
              AcpConfigValue(value: 'openai/gpt-5', name: 'openai/GPT-5'),
              AcpConfigValue(
                value: 'google/gemini-pro',
                name: 'google/Gemini Pro',
              ),
            ],
          ),
        ],
      );
      final model = selectors(session, scope: ['anthropic/*:high']).first;
      expect(model.choices.map((choice) => choice.value), [
        'openai/gpt-5',
        'anthropic/claude-sonnet',
      ]);
      expect(model.hiddenChoices.map((choice) => choice.value), [
        'google/gemini-pro',
      ]);
      expect(selectors(session).first.choices, hasLength(3));
    },
  );
}
