import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/database/database.dart';
import '../../domain/models/monetization.dart';
import '../../domain/services/host_agent_forwarding_service.dart';
import '../../domain/services/monetization_service.dart';
import '../providers/entity_list_providers.dart';
import 'premium_access.dart';
import 'premium_badge.dart';

/// Host editor section for per-host SSH agent forwarding.
///
/// Changes save immediately, like port forwards, and also apply to a
/// connection that is already open. A host that has not been saved yet
/// cannot opt in. Only the keys chosen here are offered to the host; turning
/// forwarding on starts with the host's own key.
class HostAgentForwardingSection extends ConsumerStatefulWidget {
  /// Creates a [HostAgentForwardingSection].
  const HostAgentForwardingSection({
    required this.hostId,
    this.hostKeyId,
    super.key,
  });

  /// The saved host, or null while adding a new one.
  final int? hostId;

  /// The key the host signs in with, chosen first when forwarding is turned
  /// on.
  final int? hostKeyId;

  @override
  ConsumerState<HostAgentForwardingSection> createState() =>
      _HostAgentForwardingSectionState();
}

class _HostAgentForwardingSectionState
    extends ConsumerState<HostAgentForwardingSection> {
  HostAgentForwardingSettings? _pending;
  bool _saving = false;

  Future<void> _setEnabled(
    HostAgentForwardingSettings current, {
    required bool enabled,
  }) async {
    if (enabled) {
      final allowed = await requireMonetizationFeatureAccess(
        context: context,
        ref: ref,
        feature: MonetizationFeature.agentForwarding,
      );
      if (!allowed || !mounted) {
        return;
      }
    }
    final hostKeyId = widget.hostKeyId;
    await _save(
      current.copyWith(
        enabled: enabled,
        keyIds: enabled && current.keyIds.isEmpty && hostKeyId != null
            ? [hostKeyId]
            : null,
      ),
    );
  }

  Future<void> _setKeySelected(
    HostAgentForwardingSettings current,
    List<SshKey> keys,
    SshKey key, {
    required bool selected,
  }) {
    final chosen = {...current.keyIds};
    if (selected) {
      chosen.add(key.id);
    } else {
      chosen.remove(key.id);
    }
    // Offer keys in the order the app lists them.
    return _save(
      current.copyWith(
        keyIds: [
          for (final candidate in keys)
            if (chosen.contains(candidate.id)) candidate.id,
        ],
      ),
    );
  }

  Future<void> _save(HostAgentForwardingSettings next) async {
    final hostId = widget.hostId;
    if (hostId == null) {
      return;
    }
    // Read before the await: the editor can close while the save runs, and a
    // closed widget's ref throws.
    final service = ref.read(hostAgentForwardingServiceProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() {
      _pending = next;
      _saving = true;
    });
    try {
      await service.setForHost(hostId, next);
      if (mounted) {
        ref.invalidate(hostAgentForwardingSettingsProvider(hostId));
      }
    } on Exception {
      if (mounted) {
        setState(() => _pending = null);
      }
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Could not save agent forwarding. Try again.'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hostId = widget.hostId;
    final access =
        ref.watch(monetizationStateProvider).asData?.value ??
        ref.watch(monetizationServiceProvider).currentState;
    final hasAccess = access.allowsFeature(MonetizationFeature.agentForwarding);
    final saved = hostId == null
        ? null
        : ref.watch(hostAgentForwardingSettingsProvider(hostId));
    // While a save (or a change made elsewhere) reloads, show what was just
    // chosen; otherwise show what is stored.
    final pending = _pending;
    final settings = pending != null && (saved?.isLoading ?? false)
        ? pending
        : saved?.value ?? pending ?? const HostAgentForwardingSettings();
    final canEdit = hostId != null && !_saving && (saved?.hasValue ?? false);
    final signingKeys = [
      for (final key
          in ref.watch(allKeysProvider).asData?.value ?? const <SshKey>[])
        if (key.privateKey.trim().isNotEmpty) key,
    ];
    final chosenKeys = {
      for (final key in signingKeys)
        if (settings.keyIds.contains(key.id)) key.id,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.key_rounded, size: 20, color: colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              'agent forwarding',
              style: FluttyTheme.displayMono(
                fontSize: 15,
                color: colorScheme.onSurface,
              ),
            ),
            if (!hasAccess) ...[const SizedBox(width: 8), const PremiumBadge()],
          ],
        ),
        const SizedBox(height: 8),
        SwitchListTile.adaptive(
          key: const Key('host-agent-forwarding-switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Forward SSH agent'),
          subtitle: const Text(
            'Lets this host use the keys you choose to sign in elsewhere, for '
            'example to git push. Applies to open connections too.',
          ),
          value: settings.enabled,
          onChanged: canEdit
              ? (enabled) => unawaited(_setEnabled(settings, enabled: enabled))
              : null,
        ),
        if (settings.enabled) ...[
          SwitchListTile.adaptive(
            key: const Key('host-agent-forwarding-confirm-switch'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Confirm each signature'),
            subtitle: const Text(
              'Ask before every use and name the key. Refused while '
              'MonkeySSH is in the background or locked.',
            ),
            value: settings.confirmEachSignature,
            onChanged: canEdit
                ? (confirm) => unawaited(
                    _save(settings.copyWith(confirmEachSignature: confirm)),
                  )
                : null,
          ),
          const SizedBox(height: 8),
          Text('Keys this host can use', style: theme.textTheme.labelLarge),
          for (final key in signingKeys)
            CheckboxListTile(
              key: Key('host-agent-forwarding-key-${key.id}'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: chosenKeys.contains(key.id),
              title: Text(
                key.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: FluttyTheme.monoStyle.copyWith(
                  color: colorScheme.onSurface,
                ),
              ),
              subtitle: key.id == widget.hostKeyId
                  ? const Text('This host’s sign-in key')
                  : null,
              onChanged: canEdit
                  ? (selected) => unawaited(
                      _setKeySelected(
                        settings,
                        signingKeys,
                        key,
                        selected: selected ?? false,
                      ),
                    )
                  : null,
            ),
          if (chosenKeys.isEmpty) ...[
            const SizedBox(height: 4),
            _AgentForwardingNote(
              icon: Icons.info_outline,
              iconColor: colorScheme.onSurfaceVariant,
              text: signingKeys.isEmpty
                  ? 'Add a key with its private key to forward it.'
                  : 'Choose at least one key. Until then the host sees no '
                        'keys.',
            ),
          ],
        ],
        const SizedBox(height: 8),
        _AgentForwardingNote(
          icon: Icons.warning_amber_rounded,
          iconColor: colorScheme.tertiary,
          text:
              'Anything running on this host can use the chosen keys while '
              'MonkeySSH stays connected, including a coding agent in YOLO '
              'mode. That includes time in the background, and on Android '
              'with the screen off. Forwarding ends when the connection '
              'closes, so a push from the host fails then.',
        ),
        if (hostId == null) ...[
          const SizedBox(height: 8),
          _AgentForwardingNote(
            icon: Icons.info_outline,
            iconColor: colorScheme.onSurfaceVariant,
            text: 'Save the host first to turn on agent forwarding.',
          ),
        ],
      ],
    );
  }
}

class _AgentForwardingNote extends StatelessWidget {
  const _AgentForwardingNote({
    required this.icon,
    required this.iconColor,
    required this.text,
  });

  final IconData icon;
  final Color iconColor;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: iconColor),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
