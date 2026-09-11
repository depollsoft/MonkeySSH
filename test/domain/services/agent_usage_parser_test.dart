import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_usage.dart';
import 'package:monkeyssh/domain/services/agent_usage_parser.dart';

void main() {
  final now = DateTime.utc(2026, 9, 10);
  String record(Map<String, Object?> values) =>
      '__monkeyssh_usage__=${jsonEncode(values)}';

  test(
    'keeps quota windows, unlimited status, reset time, and earned resets',
    () {
      final result = parseAgentUsageOutput(
        record({
          'id': 'codex',
          'status': 'available',
          'resetCredits': 2,
          'windows': [
            {
              'label': '5 hours',
              'usedPercent': 100,
              'resetsAt': '2026-09-10T13:00:00Z',
            },
            {'label': 'Weekly', 'usedPercent': 42.5},
            {'label': 'Chat', 'unlimited': true},
          ],
        }),
        checkedAt: now,
      )['codex']!;
      expect(result.windows, hasLength(3));
      expect(result.windows.first.resetsAt, DateTime.utc(2026, 9, 10, 13));
      expect(result.windows.last.unlimited, isTrue);
      expect(result.windows.last.usedPercent, isNull);
      expect(result.resetCredits, 2);
      expect(result.checkedAt, now);
    },
  );

  test('malformed records and unknown fields do not leak into usage', () {
    final result = parseAgentUsageOutput(
      [
        'raw credentials and errors are ignored',
        '__monkeyssh_usage__=broken',
        record({
          'id': 'claude',
          'status': 'available',
          'windows': [
            {'label': 'Bad', 'usedPercent': -5},
            {'label': 'Bad', 'usedPercent': '10'},
            {'label': 'Missing'},
          ],
        }),
        record({'id': 'copilot', 'status': 'rateLimited', 'error': 'secret'}),
      ].join('\n'),
      checkedAt: now,
    );
    expect(result['claude']!.status, AgentUsageStatus.unavailable);
    expect(result['claude']!.windows, isEmpty);
    expect(result['copilot']!.status, AgentUsageStatus.rateLimited);
  });
  test('accepts every supported agent and partial provider status', () {
    for (final id in [
      'claude',
      'codex',
      'copilot',
      'opencode',
      'antigravity',
      'cursor',
      'pi',
      'hermes',
      'openclaw',
      'grok',
    ]) {
      final result = parseAgentUsageOutput(
        record({
          'id': id,
          'status': 'available',
          'windows': [
            {
              'label': 'Account limit',
              'restricted': false,
              'resetsAt': '2026-10-01T00:00:00Z',
            },
            {'label': 'Balance', 'remaining': 12.34, 'unit': 'USD'},
          ],
          'notices': [
            {'provider': 'Anthropic', 'status': 'signInRequired'},
          ],
        }),
        checkedAt: now,
      )[id]!;
      expect(result.windows, hasLength(2));
      expect(result.windows.first.usedPercent, isNull);
      expect(result.windows.first.restricted, isFalse);
      expect(result.windows.last.remaining, 12.34);
      expect(result.windows.last.unit, 'USD');
      expect(result.notices.single.status, AgentUsageStatus.signInRequired);
    }
  });
}
