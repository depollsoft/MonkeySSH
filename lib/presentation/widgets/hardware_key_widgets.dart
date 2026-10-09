import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/database/database.dart';
import '../../domain/models/hardware_key.dart';
import '../../domain/services/hardware_key_service.dart';
import 'cursor_block.dart';

/// Label for the hardware holding [key]'s private half.
String hardwareKeyBackingLabel(SshKey key) =>
    key.hardwareKeyReference?.backingLabel ?? 'secure hardware';

/// Delete confirmation copy, warning that a hardware key is unrecoverable.
String sshKeyDeleteConfirmationMessage(
  SshKey key, {
  required String softwareKeyMessage,
}) => key.isHardwareBacked
    ? 'Delete "${key.name}"? Its private key exists only in this device’s '
          '${hardwareKeyBackingLabel(key)} and can’t be recovered. Servers '
          'that trust only this key will stop accepting this device.'
    : softwareKeyMessage;

/// Compact status badge marking a key as non-exportable, naming its backing.
class HardwareKeyBadge extends StatelessWidget {
  /// Creates a [HardwareKeyBadge] for [sshKey].
  const HardwareKeyBadge({required this.sshKey, super.key});

  /// The hardware-backed key.
  final SshKey sshKey;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final backing = hardwareKeyBackingLabel(sshKey);
    return Semantics(
      label: 'Non-exportable key in $backing',
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            border: Border.all(color: colorScheme.outline.withAlpha(90)),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 12,
                  color: colorScheme.onSurface,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    'non-exportable · $backing',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: FluttyTheme.monoStyle.copyWith(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Key type line plus the non-exportable badge for hardware keys.
class SshKeyTypeLine extends StatelessWidget {
  /// Creates a [SshKeyTypeLine].
  const SshKeyTypeLine({
    required this.sshKey,
    required this.typeLabel,
    required this.style,
    super.key,
  });

  /// Key to describe.
  final SshKey sshKey;

  /// Algorithm label shown for every key.
  final String typeLabel;

  /// Style of [typeLabel].
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final type = Text(
      typeLabel,
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (!sshKey.isHardwareBacked) {
      return type;
    }
    return Wrap(
      spacing: 6,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        type,
        HardwareKeyBadge(sshKey: sshKey),
      ],
    );
  }
}

/// Details-sheet section that stands in for private key material.
class HardwareKeyPrivateKeyNotice extends StatelessWidget {
  /// Creates a [HardwareKeyPrivateKeyNotice].
  const HardwareKeyPrivateKeyNotice({required this.sshKey, super.key});

  /// The hardware-backed key.
  final SshKey sshKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final reference = sshKey.hardwareKeyReference;
    final backing = hardwareKeyBackingLabel(sshKey);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        border: Border.all(color: colorScheme.outline.withAlpha(90)),
        borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.memory, size: 18, color: colorScheme.onSurface),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'held in $backing',
                    style: FluttyTheme.monoStyle.copyWith(
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              reference == null
                  ? 'This key’s hardware reference is damaged, so it can’t '
                        'sign in. Delete it and generate a new key.'
                  : reference.isEmulated
                  ? 'Generated in this emulator’s keystore, which is '
                        'simulated in software, so it is not hardware '
                        'protected. The app still never reveals, copies, or '
                        'exports it.'
                  : 'The private key was generated inside this device’s '
                        'secure hardware and never leaves it. It can’t be '
                        'revealed, copied, exported, or moved to another '
                        'device.',
              style: theme.textTheme.bodySmall,
            ),
            if (reference != null) ...[
              const SizedBox(height: 8),
              if (reference.requiresUserPresence)
                const _Note(
                  icon: Icons.fingerprint,
                  text:
                      'Asks for biometrics or the passcode at every sign-in, '
                      'so auto-connect and background reconnect can’t use it.',
                )
              else
                const _Note(
                  icon: Icons.bolt_outlined,
                  text:
                      'Signs without a prompt, so background reconnects keep '
                      'working.',
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Generate-tab options for a key in secure hardware.
class HardwareKeyGeneratePanel extends ConsumerWidget {
  /// Creates a [HardwareKeyGeneratePanel].
  const HardwareKeyGeneratePanel({
    required this.requireUserPresence,
    required this.onRequireUserPresenceChanged,
    super.key,
  });

  /// Whether per-use confirmation is selected.
  final bool requireUserPresence;

  /// Called when per-use confirmation is toggled.
  final ValueChanged<bool> onRequireUserPresenceChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final capabilities = ref.watch(hardwareKeyCapabilitiesProvider);
    return capabilities.when(
      loading: () => _StatusRow(
        // The brand loading mark; static when reduced motion is on.
        icon: CursorBlock(
          size: 14,
          color: Theme.of(context).colorScheme.onSurface,
        ),
        label: 'checking secure hardware…',
      ),
      error: (_, _) => _UnavailableNotice(
        message: HardwareKeyUnavailableReason.checkFailed.message,
        onRetry: () => ref.invalidate(hardwareKeyCapabilitiesProvider),
      ),
      data: (capabilities) {
        final backing = capabilities.backing;
        if (backing == null) {
          final reason =
              capabilities.unavailableReason ??
              HardwareKeyUnavailableReason.checkFailed;
          return _UnavailableNotice(
            message: reason.message,
            onRetry: reason == HardwareKeyUnavailableReason.checkFailed
                ? () => ref.invalidate(hardwareKeyCapabilitiesProvider)
                : null,
          );
        }
        return _AvailablePanel(
          capabilities: capabilities,
          backing: backing,
          requireUserPresence: requireUserPresence,
          onRequireUserPresenceChanged: onRequireUserPresenceChanged,
        );
      },
    );
  }
}

class _AvailablePanel extends StatelessWidget {
  const _AvailablePanel({
    required this.capabilities,
    required this.backing,
    required this.requireUserPresence,
    required this.onRequireUserPresenceChanged,
  });

  final HardwareKeyCapabilities capabilities;
  final HardwareKeyBacking backing;
  final bool requireUserPresence;
  final ValueChanged<bool> onRequireUserPresenceChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final mutedStyle = theme.textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatusRow(
          icon: Icon(Icons.memory, size: 18, color: colorScheme.onSurface),
          label: capabilities.isEmulator
              ? '${backing.label} (emulator)'
              : backing.label,
        ),
        const SizedBox(height: 8),
        Text(
          capabilities.isEmulator
              ? 'Creates an ECDSA P-256 key in this emulator’s simulated '
                    '${backing.label}. The app never exports or copies it. '
                    'Servers see a standard ecdsa-sha2-nistp256 key.'
              : 'Creates an ECDSA P-256 key inside the ${backing.label}. The '
                    'private key never leaves it: it can’t be exported, '
                    'copied, or moved to another device. Servers see a '
                    'standard ecdsa-sha2-nistp256 key.',
          style: mutedStyle,
        ),
        if (capabilities.isEmulator) ...[
          const SizedBox(height: 8),
          const _Note(
            icon: Icons.info_outline,
            text:
                'Emulator: this keystore is simulated in software. Use a '
                'physical device for real hardware protection.',
          ),
        ] else if (backing == HardwareKeyBacking.tee &&
            !capabilities.strongBoxAvailable) ...[
          const SizedBox(height: 8),
          const _Note(
            icon: Icons.info_outline,
            text:
                'This device has no StrongBox, so the key lives in the TEE, '
                'the processor’s isolated secure area.',
          ),
        ],
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: requireUserPresence && capabilities.userPresenceAvailable,
          onChanged: capabilities.userPresenceAvailable
              ? onRequireUserPresenceChanged
              : null,
          title: const Text('Confirm each use'),
          subtitle: Text(switch ((
            capabilities.userPresenceAvailable,
            capabilities.userPresenceAllowsPasscode,
          )) {
            (true, true) =>
              'Biometric or passcode confirmation before every sign-in.',
            (true, false) =>
              'Fingerprint or face confirmation before every sign-in. '
                  'Enrolling new biometrics deletes the key.',
            (false, true) => 'Set up a screen lock to turn this on.',
            (false, false) =>
              'Set up a screen lock and enroll a fingerprint or face to turn '
                  'this on.',
          }),
        ),
        if (requireUserPresence && capabilities.userPresenceAvailable)
          _Note(
            icon: Icons.warning_amber_rounded,
            iconColor: colorScheme.tertiary,
            text:
                'Auto-connect and background reconnect will fail for hosts '
                'that use this key, because nothing can answer the prompt.',
          ),
      ],
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.icon, required this.label});

  final Widget icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      icon,
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          label,
          style: FluttyTheme.monoStyle.copyWith(
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    ],
  );
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text, this.iconColor});

  final IconData icon;
  final String text;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: iconColor ?? theme.colorScheme.onSurface),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
      ],
    );
  }
}

class _UnavailableNotice extends StatelessWidget {
  const _UnavailableNotice({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StatusRow(
          icon: Icon(Icons.block, size: 18, color: colorScheme.error),
          label: 'secure hardware unavailable',
        ),
        const SizedBox(height: 8),
        Text(message, style: Theme.of(context).textTheme.bodySmall),
        if (onRetry != null) ...[
          const SizedBox(height: 4),
          TextButton(onPressed: onRetry, child: const Text('Check again')),
        ],
      ],
    );
  }
}
