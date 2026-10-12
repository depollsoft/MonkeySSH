import 'package:flutter/foundation.dart';

import '../../data/database/database.dart';

/// What a saved host opens after connecting, as far as notifications go.
enum HostSessionKind {
  /// A MonkeyMux session: native agent chats, window alerts, shell
  /// notifications, and push while MonkeySSH is closed.
  monkeyMux,

  /// A tmux session: window alerts and shell notifications while MonkeySSH
  /// runs.
  tmux,

  /// A plain shell: shell notifications while MonkeySSH runs.
  shell,
}

/// One kind of notification a host can raise.
enum HostNotificationKind {
  /// A native agent needs approval, a file write, or an answer.
  agentAttention,

  /// A native agent finished its turn.
  agentFinished,

  /// A background multiplexer window rang the bell or showed activity.
  windowAlerts,

  /// A remote program posted a notification (OSC 9, 777 or 99).
  shellNotifications,
}

/// Which notifications a host's session can raise.
extension HostSessionKindNotifications on HostSessionKind {
  /// The kinds this session can raise, in display order.
  List<HostNotificationKind> get notificationKinds => switch (this) {
    HostSessionKind.monkeyMux => HostNotificationKind.values,
    HostSessionKind.tmux => const [
      HostNotificationKind.windowAlerts,
      HostNotificationKind.shellNotifications,
    ],
    HostSessionKind.shell => const [HostNotificationKind.shellNotifications],
  };

  /// Whether the host can push notifications while MonkeySSH is closed. Push
  /// travels through the MonkeyMux helper only.
  bool get canPushWhenClosed => this == HostSessionKind.monkeyMux;
}

/// How many push event categories exist: attention, finished, bell, notice.
const pushEventCategoryCount = 4;

/// A saved host's notification preferences. Each kind applies to every
/// notification from the host, shown by the app or pushed while it is closed.
@immutable
class HostNotificationPrefs {
  /// Creates preferences; everything is on by default.
  const HostNotificationPrefs({
    this.agentAttention = true,
    this.agentFinished = true,
    this.windowAlerts = true,
    this.shellNotifications = true,
    this.pushWhenClosed = true,
  });

  /// Reads the preferences stored on [host].
  factory HostNotificationPrefs.fromHost(Host host) => HostNotificationPrefs(
    agentAttention: host.notifyAgentAttention,
    agentFinished: host.notifyAgentFinished,
    windowAlerts: host.notifyWindowAlerts,
    shellNotifications: host.notifyShellNotifications,
    pushWhenClosed: host.pushWhenClosed,
  );

  /// Whether a native agent may notify when it needs the user.
  final bool agentAttention;

  /// Whether a native agent may notify when it finishes its turn.
  final bool agentFinished;

  /// Whether background window alerts may notify.
  final bool windowAlerts;

  /// Whether notifications posted by remote programs may show.
  final bool shellNotifications;

  /// Whether the host may push while MonkeySSH is closed.
  final bool pushWhenClosed;

  /// Whether [kind] may notify.
  bool allows(HostNotificationKind kind) => switch (kind) {
    HostNotificationKind.agentAttention => agentAttention,
    HostNotificationKind.agentFinished => agentFinished,
    HostNotificationKind.windowAlerts => windowAlerts,
    HostNotificationKind.shellNotifications => shellNotifications,
  };

  /// Returns a copy with [kind] turned on or off.
  HostNotificationPrefs withKind(
    HostNotificationKind kind, {
    required bool enabled,
  }) => HostNotificationPrefs(
    agentAttention: kind == HostNotificationKind.agentAttention
        ? enabled
        : agentAttention,
    agentFinished: kind == HostNotificationKind.agentFinished
        ? enabled
        : agentFinished,
    windowAlerts: kind == HostNotificationKind.windowAlerts
        ? enabled
        : windowAlerts,
    shellNotifications: kind == HostNotificationKind.shellNotifications
        ? enabled
        : shellNotifications,
    pushWhenClosed: pushWhenClosed,
  );

  /// Returns a copy with push while closed turned on or off.
  HostNotificationPrefs withPushWhenClosed({required bool enabled}) =>
      HostNotificationPrefs(
        agentAttention: agentAttention,
        agentFinished: agentFinished,
        windowAlerts: windowAlerts,
        shellNotifications: shellNotifications,
        pushWhenClosed: enabled,
      );

  /// The push event categories the host may send, as `push_register`'s
  /// `events` (see docs/push-notifications.md).
  List<String> get pushEvents => [
    if (agentAttention) 'attention',
    if (agentFinished) 'finished',
    if (windowAlerts) 'bell',
    if (shellNotifications) 'notice',
  ];

  @override
  bool operator ==(Object other) =>
      other is HostNotificationPrefs &&
      other.agentAttention == agentAttention &&
      other.agentFinished == agentFinished &&
      other.windowAlerts == windowAlerts &&
      other.shellNotifications == shellNotifications &&
      other.pushWhenClosed == pushWhenClosed;

  @override
  int get hashCode => Object.hash(
    agentAttention,
    agentFinished,
    windowAlerts,
    shellNotifications,
    pushWhenClosed,
  );
}
