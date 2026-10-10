import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/database/database.dart';
import '../../domain/services/push/push_messaging_gateway.dart';
import '../../domain/services/push/push_notification_service.dart';
import '../providers/entity_list_providers.dart';

/// Settings for closed-app agent notifications.
///
/// Self-contained so it can move into the Notifications section planned in
/// #934. Renders nothing in builds without Firebase or on other platforms.
class PushNotificationSettingsSection extends ConsumerWidget {
  /// Creates the section.
  const PushNotificationSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(pushNotificationsAvailableProvider)) {
      return const SizedBox.shrink();
    }
    final state = ref.watch(pushNotificationControllerProvider);
    final controller = ref.read(pushNotificationControllerProvider.notifier);
    final theme = Theme.of(context);
    final hosts = state.enabled
        ? ref.watch(allHostsProvider).asData?.value ?? const <Host>[]
        : const <Host>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 28, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'push',
                style: FluttyTheme.displayMono(
                  fontSize: 13,
                  color: theme.colorScheme.onSurface,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Agent alerts while MonkeySSH is closed',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        SwitchListTile(
          key: const ValueKey('push-settings-enabled'),
          secondary: const Icon(Icons.notifications_active_outlined),
          title: const Text('Notify me when the app is closed'),
          subtitle: Text(_subtitle(state)),
          value: state.enabled,
          onChanged: !state.loaded || state.busy
              ? null
              : (value) => unawaited(
                  value ? controller.enable() : controller.disable(),
                ),
        ),
        if (state.failure case final failure? when !state.enabled)
          _FailureNote(failure: failure),
        if (state.enabled) ...[
          for (final host in hosts)
            SwitchListTile(
              key: ValueKey('push-settings-host-${host.id}'),
              contentPadding: const EdgeInsetsDirectional.only(
                start: 72,
                end: 16,
              ),
              title: Text(
                host.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: FluttyTheme.displayMono(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              subtitle: Text(pushHostStatus(state, host.id)),
              value: !state.disabledHostIds.contains(host.id),
              onChanged: state.busy
                  ? null
                  : (value) => unawaited(
                      controller.setHostEnabled(host.id, enabled: value),
                    ),
            ),
          _SendTestTile(enabled: !state.busy, controller: controller),
        ],
      ],
    );
  }

  static String _subtitle(PushNotificationState state) {
    if (state.busy) return 'Updating…';
    if (state.enabled) {
      return 'Alerts are encrypted to this device. Only the event type, such '
          'as "approval needed", is readable on the way.';
    }
    return 'Relayed by a MonkeySSH Firebase service. Prompts, output, paths '
        'and names stay on your hosts.';
  }
}

/// "Send test notification", disabled while a test is on its way.
class _SendTestTile extends StatefulWidget {
  const _SendTestTile({required this.enabled, required this.controller});

  final bool enabled;
  final PushNotificationController controller;

  @override
  State<_SendTestTile> createState() => _SendTestTileState();
}

class _SendTestTileState extends State<_SendTestTile> {
  bool _sending = false;

  Future<void> _send() async {
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context)
      ..showSnackBar(
        const SnackBar(content: Text('Sending test notification…')),
      );
    final PushTestOutcome outcome;
    try {
      outcome = await widget.controller.sendTest();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(pushTestOutcomeMessage(outcome))));
  }

  @override
  Widget build(BuildContext context) => ListTile(
    key: const ValueKey('push-settings-test'),
    leading: const Icon(Icons.send_outlined),
    title: const Text('Send test notification'),
    subtitle: Text(
      _sending
          ? 'Sending…'
          : 'Goes through a connected host and back to this device',
    ),
    enabled: widget.enabled && !_sending,
    onTap: () => unawaited(_send()),
  );
}

/// Status line for one host: whether it will alert this device yet.
String pushHostStatus(PushNotificationState state, int hostId) {
  if (state.disabledHostIds.contains(hostId)) return 'Off';
  if (state.registeredHostIds.contains(hostId)) return 'On';
  return 'On once you connect to it with MonkeyMux';
}

/// User-facing text for a test notification outcome.
String pushTestOutcomeMessage(PushTestOutcome outcome) => switch (outcome) {
  PushTestOutcome.sent =>
    'Test sent. Lock your phone or switch apps to see it arrive.',
  PushTestOutcome.noConnectedHost =>
    'Connect to a host that uses MonkeyMux, then try again.',
  PushTestOutcome.noEnabledHost =>
    'Push is off for every connected host. Turn one on, then try again.',
  PushTestOutcome.hostNeedsUpdate =>
    "This host's MonkeyMux is too old for push. Update it, then try again.",
  PushTestOutcome.rateLimited =>
    'Too many notifications recently. Try again in a few minutes.',
  PushTestOutcome.registrationRejected =>
    'The host had an expired registration. It is being renewed; try again '
        'in a minute.',
  PushTestOutcome.failed => 'The test notification could not be sent.',
};

/// User-facing text for an opt-in failure.
String pushSetupFailureMessage(PushSetupFailure failure) => switch (failure) {
  PushSetupFailure.permissionDenied =>
    'Notifications are not allowed for MonkeySSH. Allow them in system '
        'settings, then try again.',
  PushSetupFailure.tokenUnavailable =>
    'This device did not get a push token. Check the network and try again.',
  PushSetupFailure.appCheckFailed =>
    'This copy of the app could not be verified, so push is unavailable.',
  PushSetupFailure.registrationFailed =>
    'Push registration failed. Try again later.',
};

class _FailureNote extends StatelessWidget {
  const _FailureNote({required this.failure});

  final PushSetupFailure failure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(72, 0, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              Icons.error_outline,
              size: 18,
              color: theme.colorScheme.error,
              semanticLabel: 'Error',
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              pushSetupFailureMessage(failure),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
