import 'push_event.dart';

/// The text a push notification shows. The iOS notification service extension
/// (`ios/NotificationServiceExtension`) builds the same strings, so change
/// both together.
typedef PushNotificationText = ({String title, String body});

/// The agent names MonkeyMux reports in a payload's `agent`, as people know
/// them.
const pushAgentLabels = <String, String>{
  'claude': 'Claude Code',
  'codex': 'Codex',
  'copilot': 'Copilot',
  'opencode': 'OpenCode',
  'antigravity': 'Antigravity',
  'cursor-agent': 'Cursor Agent',
  'pi': 'Pi',
  'hermes': 'Hermes',
  'openclaw': 'OpenClaw',
  'grok': 'Grok',
  'muse': 'Muse Code',
};

/// The text for [kind] that names nothing: what the push function sends, and
/// what the phone shows when a payload does not open.
PushNotificationText genericPushNotificationText(PushEventKind kind) =>
    switch (kind) {
      PushEventKind.permission => (
        title: 'Approval needed',
        body: 'An agent is waiting for your approval.',
      ),
      PushEventKind.input => (
        title: 'Input needed',
        body: 'An agent is waiting for your answer.',
      ),
      PushEventKind.finished => (
        title: 'Agent finished',
        body: 'An agent finished its turn.',
      ),
      PushEventKind.alert => (
        title: 'Terminal alert',
        body: 'A terminal window wants your attention.',
      ),
      PushEventKind.test => (
        title: 'MonkeySSH',
        body: 'Push notifications are working.',
      ),
    };

/// The text for a decrypted [event]: the agent in the title when the payload
/// names one, and in the body the window's title, [hostLabel] when the phone
/// knows the host, and the session, each once, joined by ` · `.
PushNotificationText pushNotificationText(
  PushEvent event, {
  String? hostLabel,
}) {
  final generic = genericPushNotificationText(event.kind);
  final title = agentStatusNotificationTitle(
    event.kind,
    agentLabel: pushAgentLabels[event.agent],
  );
  if (event.kind == PushEventKind.test) return generic;
  final label = hostLabel?.trim() ?? '';
  final parts = <String>[];
  // A session is named after its host by default, so each part shows once.
  for (final part in [
    event.windowTitle?.trim() ?? '',
    label,
    if (label.isNotEmpty) event.sessionName?.trim() ?? '',
  ]) {
    if (part.isNotEmpty && !parts.contains(part)) parts.add(part);
  }
  return (title: title, body: parts.isEmpty ? generic.body : parts.join(' · '));
}

/// The title of an agent's status notification for [kind]: the agent by
/// [agentLabel] when it is known, else the generic text. Pushes and the
/// notifications a backgrounded app raises in their place share it.
String agentStatusNotificationTitle(PushEventKind kind, {String? agentLabel}) =>
    switch (kind) {
      PushEventKind.permission when agentLabel != null =>
        '$agentLabel needs approval',
      PushEventKind.input when agentLabel != null =>
        '$agentLabel has a question',
      PushEventKind.finished when agentLabel != null => '$agentLabel finished',
      _ => genericPushNotificationText(kind).title,
    };
