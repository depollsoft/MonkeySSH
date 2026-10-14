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
/// names one, and [hostLabel] with the session in the body when the phone
/// knows the host.
PushNotificationText pushNotificationText(
  PushEvent event, {
  String? hostLabel,
}) {
  final generic = genericPushNotificationText(event.kind);
  final agent = pushAgentLabels[event.agent];
  final title = switch (event.kind) {
    PushEventKind.permission when agent != null => '$agent needs approval',
    PushEventKind.input when agent != null => '$agent has a question',
    PushEventKind.finished when agent != null => '$agent finished',
    _ => generic.title,
  };
  if (event.kind == PushEventKind.test) return generic;
  final label = hostLabel?.trim();
  if (label == null || label.isEmpty) return (title: title, body: generic.body);
  // A session named after its host (the default) would repeat the label.
  final session = event.sessionName?.trim();
  return (
    title: title,
    body: session == null || session.isEmpty || session == label
        ? label
        : '$label · $session',
  );
}
