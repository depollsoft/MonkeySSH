import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// Offers MonkeyMux on the first connection to a host created as a plain
/// shell. Returns whether the user chose it.
///
/// Choosing it also agrees to the helper upload the sheet describes, so the
/// separate install prompt is not shown for a fresh install.
Future<bool> showMonkeyMuxOfferSheet(
  BuildContext context, {
  required String hostLabel,
  required String sessionName,
}) async {
  final accepted = await showModalBottomSheet<bool>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) =>
        MonkeyMuxOfferSheet(hostLabel: hostLabel, sessionName: sessionName),
  );
  return accepted ?? false;
}

/// The body of [showMonkeyMuxOfferSheet]; pops true when MonkeyMux is chosen.
class MonkeyMuxOfferSheet extends StatelessWidget {
  /// Creates the sheet for the session it would open.
  const MonkeyMuxOfferSheet({
    required this.hostLabel,
    required this.sessionName,
    super.key,
  });

  /// The saved host being offered MonkeyMux.
  final String hostLabel;

  /// The MonkeyMux session the host would open.
  final String sessionName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );
    final literal = FluttyTheme.monoStyle.copyWith(
      fontSize: (muted?.fontSize ?? 12) - 0.5,
      color: colorScheme.onSurface,
    );
    return SingleChildScrollView(
      // useSafeArea guards only the top; keep the buttons clear of the home
      // indicator and gesture bar.
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        16 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Use MonkeyMux on $hostLabel?',
            style: FluttyTheme.displayMono(
              fontSize: 18,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 16),
          const _Benefit(
            icon: Icons.sync_outlined,
            text: 'Windows survive reconnects and dropped networks',
          ),
          const _Benefit(
            icon: Icons.view_carousel_outlined,
            text: 'A window switcher and native agent chats',
          ),
          const _Benefit(
            icon: Icons.notifications_active_outlined,
            text: 'Alerts when an agent needs you, even with MonkeySSH closed',
          ),
          const SizedBox(height: 8),
          Text.rich(
            TextSpan(
              style: muted,
              children: [
                const TextSpan(text: 'Uploads the MonkeyMux helper to '),
                TextSpan(text: '~/.monkeyssh', style: literal),
                const TextSpan(text: ' on the host and opens session '),
                TextSpan(text: sessionName, style: literal),
                const TextSpan(
                  text:
                      '. You can change this later in the host\'s Startup '
                      'behavior.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            key: const ValueKey('monkeymux-offer-accept'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Use MonkeyMux'),
          ),
          const SizedBox(height: 8),
          TextButton(
            key: const ValueKey('monkeymux-offer-decline'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
        ],
      ),
    );
  }
}

class _Benefit extends StatelessWidget {
  const _Benefit({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
