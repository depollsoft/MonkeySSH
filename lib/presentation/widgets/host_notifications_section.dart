import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../domain/models/host_notifications.dart';
import '../../domain/services/push/push_notification_service.dart';
import '../../domain/services/settings_service.dart';
import 'push_notification_settings_section.dart';

/// The `notifications` section of the host edit form.
///
/// It offers only the notifications the host's session can raise, as chosen
/// in Startup behavior, and reshapes as soon as that choice changes.
class HostNotificationsSection extends ConsumerWidget {
  /// Creates the section.
  const HostNotificationsSection({
    required this.sessionKind,
    required this.sessionName,
    required this.prefs,
    required this.onChanged,
    this.onUseMonkeyMux,
    super.key,
  });

  /// What the host opens after connecting.
  final HostSessionKind sessionKind;

  /// The multiplexer session name in the form, or null when empty.
  final String? sessionName;

  /// The preferences being edited.
  final HostNotificationPrefs prefs;

  /// Called with the edited preferences.
  final ValueChanged<HostNotificationPrefs> onChanged;

  /// Switches the form to MonkeyMux; null when the form cannot do that here.
  final VoidCallback? onUseMonkeyMux;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final push = ref.watch(pushNotificationControllerProvider);
    final offersPush = push.available && sessionKind.canPushWhenClosed;
    final reachesWhenClosed =
        offersPush && push.enabled && prefs.pushWhenClosed;
    final animate = !MediaQuery.disableAnimationsOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'notifications',
          style: FluttyTheme.displayMono(
            fontSize: 15,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        _ScopeLine(
          sessionKind: sessionKind,
          sessionName: sessionName,
          reachesWhenClosed: reachesWhenClosed,
        ),
        const SizedBox(height: 4),
        AnimatedSize(
          duration: animate ? const Duration(milliseconds: 150) : Duration.zero,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final kind in sessionKind.notificationKinds)
                _KindRow(
                  kind: kind,
                  sessionKind: sessionKind,
                  value: prefs.allows(kind),
                  onChanged: (enabled) =>
                      onChanged(prefs.withKind(kind, enabled: enabled)),
                ),
              if (offersPush) ...[
                const Divider(height: 17),
                _WhenClosedRow(
                  prefs: prefs,
                  push: push,
                  onChanged: (enabled) =>
                      onChanged(prefs.withPushWhenClosed(enabled: enabled)),
                ),
              ],
              if (sessionKind != HostSessionKind.monkeyMux) ...[
                const SizedBox(height: 12),
                _MonkeyMuxNote(
                  sessionKind: sessionKind,
                  onUseMonkeyMux: onUseMonkeyMux,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Where this host's notifications come from, and when they reach the user.
class _ScopeLine extends StatelessWidget {
  const _ScopeLine({
    required this.sessionKind,
    required this.sessionName,
    required this.reachesWhenClosed,
  });

  final HostSessionKind sessionKind;
  final String? sessionName;
  final bool reachesWhenClosed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final name = sessionName;
    final backend = switch (sessionKind) {
      HostSessionKind.monkeyMux => 'MonkeyMux',
      HostSessionKind.tmux => 'tmux',
      HostSessionKind.shell => null,
    };
    final when = reachesWhenClosed
        ? 'while MonkeySSH is running or closed.'
        : 'while MonkeySSH is running.';
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          if (backend == null)
            const TextSpan(text: "From this host's shell, ")
          else if (name == null)
            TextSpan(text: "From this host's $backend session, ")
          else ...[
            TextSpan(text: 'From $backend session '),
            TextSpan(
              text: name,
              style: FluttyTheme.monoStyle.copyWith(
                fontSize: (style?.fontSize ?? 12) - 0.5,
                color: theme.colorScheme.onSurface,
              ),
            ),
            const TextSpan(text: ', '),
          ],
          TextSpan(text: when),
        ],
      ),
    );
  }
}

/// One kind of notification and its switch.
class _KindRow extends ConsumerWidget {
  const _KindRow({
    required this.kind,
    required this.sessionKind,
    required this.value,
    required this.onChanged,
  });

  final HostNotificationKind kind;
  final HostSessionKind sessionKind;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (icon, title) = switch (kind) {
      HostNotificationKind.agentAttention => (
        Icons.pan_tool_outlined,
        'Agent needs you',
      ),
      HostNotificationKind.agentFinished => (
        Icons.task_alt_outlined,
        'Agent finished',
      ),
      HostNotificationKind.windowAlerts => (
        Icons.notifications_outlined,
        'Window alerts',
      ),
      HostNotificationKind.shellNotifications => (
        Icons.terminal_outlined,
        'Shell notifications',
      ),
    };
    final Widget subtitle = switch (kind) {
      HostNotificationKind.agentAttention => const Text(
        'Approvals, file writes, and questions from native agent chats',
      ),
      HostNotificationKind.agentFinished => const Text(
        'A native agent chat finished its turn',
      ),
      HostNotificationKind.windowAlerts => Text(
        sessionKind == HostSessionKind.tmux
            ? 'A background window rang the bell or showed activity'
            : 'A background window rang the bell',
      ),
      HostNotificationKind.shellNotifications => _ShellNotificationsSubtitle(
        appWideOff: !ref.watch(terminalNotificationsNotifierProvider),
      ),
    };
    return SwitchListTile(
      key: ValueKey('host-notify-${kind.name}'),
      contentPadding: EdgeInsets.zero,
      secondary: Icon(icon),
      title: Text(title),
      subtitle: subtitle,
      value: value,
      onChanged: onChanged,
    );
  }
}

/// What a shell notification is, with the escape codes set as literals, and
/// a note when the app-wide switch in Settings keeps them off everywhere.
class _ShellNotificationsSubtitle extends StatelessWidget {
  const _ShellNotificationsSubtitle({required this.appWideOff});

  final bool appWideOff;

  @override
  Widget build(BuildContext context) {
    // The list tile's subtitle style, so this row matches the others.
    final style = DefaultTextStyle.of(context).style;
    final code = FluttyTheme.monoStyle.copyWith(
      fontSize: (style.fontSize ?? 14) - 1,
      color: style.color,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            style: style,
            children: [
              const TextSpan(text: 'Posted by remote programs '),
              // One unit, so the codes never leave a fragment on a line of
              // their own.
              TextSpan(text: '(OSC\u00A09,\u00A0777,\u00A099)', style: code),
            ],
          ),
        ),
        if (appWideOff)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(Icons.info_outline, size: 16, color: style.color),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Off for every host: Desktop notifications is off in '
                    'Settings',
                    style: style,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Push while MonkeySSH is closed: a switch once this device has push on,
/// otherwise a way to turn push on for the device.
class _WhenClosedRow extends ConsumerWidget {
  const _WhenClosedRow({
    required this.prefs,
    required this.push,
    required this.onChanged,
  });

  final HostNotificationPrefs prefs;
  final PushNotificationState push;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const icon = Icon(Icons.phonelink_lock_outlined);
    const title = Text('When MonkeySSH is closed');
    if (push.enabled) {
      final nothingToSend = prefs.pushEvents.isEmpty;
      return SwitchListTile(
        key: const ValueKey('host-notify-push'),
        contentPadding: EdgeInsets.zero,
        secondary: icon,
        title: title,
        subtitle: Text(
          nothingToSend && prefs.pushWhenClosed
              ? 'Nothing to send: every kind above is off'
              : 'Encrypted push through the MonkeySSH relay',
        ),
        value: prefs.pushWhenClosed,
        onChanged: onChanged,
      );
    }
    final controller = ref.read(pushNotificationControllerProvider.notifier);
    final failure = push.failure;
    return ListTile(
      key: const ValueKey('host-notify-push-setup'),
      contentPadding: EdgeInsets.zero,
      leading: icon,
      title: title,
      subtitle: Text(
        push.busy
            ? 'Turning on…'
            : failure != null
            ? pushSetupFailureMessage(failure)
            : 'Push is off on this device',
      ),
      trailing: TextButton(
        onPressed: !push.loaded || push.busy
            ? null
            : () => unawaited(controller.enable()),
        child: Text(failure == null ? 'Turn on' : 'Try again'),
      ),
    );
  }
}

/// What MonkeyMux would add on a tmux or plain-shell host, with a one-tap
/// switch to it.
class _MonkeyMuxNote extends StatelessWidget {
  const _MonkeyMuxNote({
    required this.sessionKind,
    required this.onUseMonkeyMux,
  });

  final HostSessionKind sessionKind;
  final VoidCallback? onUseMonkeyMux;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final body = sessionKind == HostSessionKind.tmux
        ? 'MonkeyMux adds alerts when an agent needs you or finishes, and '
              'reaches you when MonkeySSH is closed.'
        : 'MonkeyMux adds window and agent alerts, and reaches you when '
              'MonkeySSH is closed.';
    final onUse = onUseMonkeyMux;
    return DecoratedBox(
      key: const ValueKey('host-notify-monkeymux-note'),
      decoration: BoxDecoration(
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 8, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                Icons.view_carousel_outlined,
                size: 20,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 8),
                    child: Text(
                      body,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                  if (onUse != null)
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: TextButton(
                        key: const ValueKey('host-notify-use-monkeymux'),
                        onPressed: onUse,
                        child: const Text('Use MonkeyMux'),
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 8),
                      child: Text(
                        'Choose MonkeyMux as the terminal window backend '
                        'above.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
