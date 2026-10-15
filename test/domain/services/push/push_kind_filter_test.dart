import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/domain/models/host_notifications.dart';
import 'package:monkeyssh/domain/services/host_notification_prefs_reader.dart';
import 'package:monkeyssh/domain/services/push/push_event.dart';

import '../../../helpers/mocks.dart';
import '../../../helpers/terminal_session_fixture.dart';

void main() {
  PushEvent? parse(Map<String, Object?> json) =>
      PushEvent.tryParse(utf8.encode(jsonEncode(json)));
  const base = {'v': 1, 'hostRef': 'ref', 'kind': 'alert', 'ts': 1};

  test('an alert payload names its categories', () {
    expect(
      parse({
        ...base,
        'alert': ['bell'],
      })!.alertCategories,
      {'bell'},
    );
    expect(
      parse({
        ...base,
        'alert': ['bell', 'notice', 'other'],
      })!.alertCategories,
      {'bell', 'notice'},
    );
    // Helpers before 0.1.233 do not say.
    expect(parse(base)!.alertCategories, isNull);
  });

  test('a host shows only the alert categories it allows', () {
    const bellOnly = HostNotificationPrefs(shellNotifications: false);
    bool allowed(Set<String>? categories, HostNotificationPrefs prefs) =>
        pushKindAllowedByHost(
          PushEventKind.alert,
          prefs,
          alertCategories: categories,
        );
    expect(allowed({'bell'}, bellOnly), isTrue);
    expect(allowed({'notice'}, bellOnly), isFalse);
    expect(allowed({'bell', 'notice'}, bellOnly), isTrue);
    // Without categories an alert could be either, so it needs both on.
    expect(allowed(null, bellOnly), isFalse);
    expect(allowed(null, const HostNotificationPrefs()), isTrue);
  });

  test('agent kinds follow their own switches; a test always shows', () {
    const off = HostNotificationPrefs(
      agentAttention: false,
      agentFinished: false,
      windowAlerts: false,
      shellNotifications: false,
    );
    for (final kind in [
      PushEventKind.permission,
      PushEventKind.input,
      PushEventKind.finished,
    ]) {
      expect(pushKindAllowedByHost(kind, off), isFalse, reason: '$kind');
      expect(
        pushKindAllowedByHost(kind, const HostNotificationPrefs()),
        isTrue,
        reason: '$kind',
      );
    }
    expect(pushKindAllowedByHost(PushEventKind.test, off), isTrue);
  });

  test('a failed read keeps the last good preferences', () async {
    final hosts = MockHostRepository();
    final container = ProviderContainer(
      overrides: [hostRepositoryProvider.overrideWithValue(hosts)],
    );
    addTearDown(container.dispose);
    final read = container.read(hostNotificationPrefsReaderProvider);
    when(() => hosts.getById(1)).thenAnswer(
      (_) async =>
          buildSelectionTestHost(id: 1).copyWith(notifyAgentFinished: false),
    );
    expect((await read(1)).agentFinished, isFalse);

    when(() => hosts.getById(any())).thenThrow(StateError('database'));
    expect((await read(1)).agentFinished, isFalse);
    // A host never read before still shows, rather than hiding an approval.
    expect((await read(2)).agentFinished, isTrue);
  });
}
