/// One flow that moves a password-login host to key login: pick or generate
/// a key, append it to `~/.ssh/authorized_keys` over the open session, prove
/// a key-only reconnect works, then offer to delete the saved password.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/key_repository.dart';
import '../../domain/services/authorized_key_install_service.dart';
import '../../domain/services/diagnostics_log_service.dart';
import '../../domain/services/key_service.dart';
import '../../domain/services/monkeymux_service.dart';
import '../../domain/services/ssh_service.dart';
import '../../domain/services/telemetry_service.dart';
import '../../domain/services/tmux_service.dart';
import '../providers/connection_actions.dart';
import '../providers/entity_list_providers.dart';
import 'connection_attempt_dialog.dart';
import 'public_key_share_sheet.dart';

/// Opens the key-login flow for [host].
Future<void> showKeyInstallSheet(BuildContext context, Host host) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => KeyInstallSheet(host: host),
    );

/// Stages of the install flow, in order.
enum KeyInstallStage {
  /// Creating a new key on this device.
  generate,

  /// Reusing or opening the SSH connection.
  connect,

  /// Appending the key to `authorized_keys`.
  install,

  /// Reconnecting with only the key.
  verify,
}

enum _StageState { pending, active, done, failed }

enum _Phase { choose, working, verified, failed, finished }

/// Sentinel for "generate a new key" in the key picker.
const _generateNewKey = -1;

/// The key-login flow body.
class KeyInstallSheet extends ConsumerStatefulWidget {
  /// Creates the flow for [host].
  const KeyInstallSheet({required this.host, super.key});

  /// Host that currently signs in with a password.
  final Host host;

  @override
  ConsumerState<KeyInstallSheet> createState() => _KeyInstallSheetState();
}

class _KeyInstallSheetState extends ConsumerState<KeyInstallSheet> {
  int? _selectedKeyId;
  var _phase = _Phase.choose;
  final _stages = <KeyInstallStage, _StageState>{};
  String? _error;
  SshKey? _key;
  var _passwordRemoved = false;
  var _busy = false;

  bool get _usesSavedPassword => widget.host.password?.isNotEmpty ?? false;

  List<SshKey> _usableKeys(List<SshKey> keys) {
    final repository = ref.read(keyRepositoryProvider);
    return keys
        .where(
          (key) =>
              !repository.hasUnreadablePrivateKey(key.id) &&
              !repository.hasUnreadablePassphrase(key.id) &&
              _isInstallable(key),
        )
        .toList(growable: false);
  }

  static bool _isInstallable(SshKey key) {
    try {
      buildAuthorizedKeyLine(key.publicKey);
      return true;
    } on FormatException {
      return false;
    }
  }

  void _setStage(KeyInstallStage stage, _StageState state) {
    if (!mounted) return;
    setState(() => _stages[stage] = state);
  }

  void _fail(KeyInstallStage stage, String message) {
    if (!mounted) return;
    setState(() {
      _stages[stage] = _StageState.failed;
      _error = message;
      _phase = _Phase.failed;
    });
  }

  Future<void> _start(List<SshKey> usableKeys) async {
    final generate =
        usableKeys.isEmpty || (_selectedKeyId ?? _generateNewKey) < 0;
    setState(() {
      _phase = _Phase.working;
      _error = null;
      _stages
        ..clear()
        ..addAll({
          if (generate) KeyInstallStage.generate: _StageState.pending,
          KeyInstallStage.connect: _StageState.pending,
          KeyInstallStage.install: _StageState.pending,
          KeyInstallStage.verify: _StageState.pending,
        });
    });

    final hostId = widget.host.id;
    final service = ref.read(authorizedKeyInstallServiceProvider);
    final sshService = ref.read(sshServiceProvider);
    final tmuxService = ref.read(tmuxServiceProvider);
    final monkeyMuxService = ref.read(monkeyMuxServiceProvider);
    final sessions = ref.read(activeSessionsProvider.notifier);
    int? openedConnectionId;

    DiagnosticsLogService.instance.info(
      'onboarding.key',
      'flow_started',
      fields: {'hostId': hostId, 'generatesKey': generate},
    );
    try {
      SshKey? key;
      if (generate) {
        _setStage(KeyInstallStage.generate, _StageState.active);
        try {
          key = await ref
              .read(keyServiceProvider)
              .generateKey(
                name: _generatedKeyName(widget.host.label),
                keyType: SshKeyType.ed25519,
              );
        } on Exception {
          key = null;
        }
        if (key == null) {
          _fail(KeyInstallStage.generate, 'Couldn’t generate a key.');
          return;
        }
        unawaited(
          ref.read(telemetryServiceProvider).logKeyAdded(method: 'generated'),
        );
        _setStage(KeyInstallStage.generate, _StageState.done);
      } else {
        key = usableKeys.firstWhere(
          (candidate) => candidate.id == _selectedKeyId,
        );
      }
      _key = key;
      if (!mounted) return;

      _setStage(KeyInstallStage.connect, _StageState.active);
      // Install and verify against the host as it is saved now. An open
      // session from before the host was edited may be logged in to another
      // account or through other jump hosts, so only a matching one is
      // reused.
      final savedHost = await ref.read(hostRepositoryProvider).getById(hostId);
      if (savedHost == null) {
        _fail(KeyInstallStage.connect, 'This saved host no longer exists.');
        return;
      }
      var session = await service.reusableSessionFor(
        savedHost,
        sshService.getSessionsForHost(hostId),
      );
      if (session == null) {
        if (!mounted) return;
        final connection = await connectToHostWithProgressDialog(
          context,
          ref,
          savedHost,
        );
        final connectionId = connection.connectionId;
        if (!connection.success || connectionId == null) {
          _fail(
            KeyInstallStage.connect,
            connection.error ?? 'Couldn’t connect with the saved login.',
          );
          return;
        }
        openedConnectionId = connectionId;
        session = sshService.getSession(connectionId);
        if (session == null) {
          _fail(KeyInstallStage.connect, 'The connection closed.');
          return;
        }
      }
      _setStage(KeyInstallStage.connect, _StageState.done);

      _setStage(KeyInstallStage.install, _StageState.active);
      final AuthorizedKeyInstallOutcome outcome;
      try {
        outcome = await service.installKey(session, key);
      } on Exception catch (error) {
        DiagnosticsLogService.instance.warning(
          'onboarding.key',
          'install_failed',
          fields: {'hostId': hostId, 'errorType': error.runtimeType},
        );
        _fail(
          KeyInstallStage.install,
          'Couldn’t run the install command on the server.',
        );
        return;
      }
      if (!authorizedKeyInstallSucceeded(outcome)) {
        _fail(
          KeyInstallStage.install,
          describeAuthorizedKeyInstallOutcome(outcome),
        );
        return;
      }
      _setStage(KeyInstallStage.install, _StageState.done);

      _setStage(KeyInstallStage.verify, _StageState.active);
      final verification = await service.verifyKeyOnlyLogin(
        session,
        key,
        savedHost: savedHost,
      );
      if (!verification.success) {
        _fail(
          KeyInstallStage.verify,
          'The server didn’t accept the key on its own, so the host still '
                  'uses the password. ${verification.error ?? ''}'
              .trim(),
        );
        return;
      }
      _setStage(KeyInstallStage.verify, _StageState.done);
      await service.switchHostToKey(hostId, key.id, removePassword: false);
      if (!mounted) return;
      setState(
        () => _phase = _usesSavedPassword ? _Phase.verified : _Phase.finished,
      );
    } finally {
      if (openedConnectionId != null) {
        unawaited(
          disconnectAndClearMuxCaches(
            openedConnectionId,
            tmuxService: tmuxService,
            monkeyMuxService: monkeyMuxService,
            sessions: sessions,
          ),
        );
      }
    }
  }

  Future<void> _finish({required bool removePassword}) async {
    final key = _key;
    if (key == null) return;
    setState(() => _busy = true);
    try {
      if (removePassword) {
        await ref
            .read(authorizedKeyInstallServiceProvider)
            .switchHostToKey(widget.host.id, key.id, removePassword: true);
      }
      if (!mounted) return;
      setState(() {
        _passwordRemoved = removePassword;
        _phase = _Phase.finished;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _generatedKeyName(String hostLabel) {
    final name = 'MonkeySSH key for $hostLabel';
    return name.length <= 255 ? name : name.substring(0, 255);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final keys = _usableKeys(
      ref.watch(allKeysProvider).asData?.value ?? const <SshKey>[],
    );
    if (_selectedKeyId == null && keys.isNotEmpty) {
      // Default to the newest key; people usually reuse the one they just made.
      _selectedKeyId = keys
          .reduce((a, b) => b.createdAt.isAfter(a.createdAt) ? b : a)
          .id;
    }

    final body = switch (_phase) {
      _Phase.choose => _buildChoose(context, keys),
      _Phase.working || _Phase.failed => _buildProgress(context),
      _Phase.verified => _buildVerified(context),
      _Phase.finished => _buildFinished(context),
    };

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          FluttyTheme.spacingMd,
          0,
          FluttyTheme.spacingMd,
          FluttyTheme.spacingMd,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Key Login',
              style: FluttyTheme.displayMono(color: colorScheme.onSurface),
            ),
            const SizedBox(height: FluttyTheme.spacingXs),
            Text(
              widget.host.label,
              style: FluttyTheme.monoStyle.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: FluttyTheme.spacingMd),
            ...body,
          ],
        ),
      ),
    );
  }

  List<Widget> _buildChoose(BuildContext context, List<SshKey> keys) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return [
      Text.rich(
        TextSpan(
          children: [
            const TextSpan(text: 'MonkeySSH adds a public key to '),
            TextSpan(
              text: '~/.ssh/authorized_keys',
              style: FluttyTheme.monoStyle.copyWith(
                fontSize: 13,
                color: colorScheme.onSurface,
              ),
            ),
            const TextSpan(
              text:
                  ' on this host, then reconnects with only the key to check '
                  'it works. The saved password stays until you choose to '
                  'remove it.',
            ),
          ],
        ),
        style: theme.textTheme.bodyMedium?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: FluttyTheme.spacingMd),
      Text('Key', style: theme.textTheme.titleSmall),
      const SizedBox(height: FluttyTheme.spacingXs),
      RadioGroup<int>(
        groupValue: keys.isEmpty ? _generateNewKey : _selectedKeyId,
        onChanged: (value) => setState(() => _selectedKeyId = value),
        child: Column(
          children: [
            for (final key in keys.reversed)
              RadioListTile<int>(
                value: key.id,
                contentPadding: EdgeInsets.zero,
                title: Text(key.name, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  key.keyType.toUpperCase(),
                  style: FluttyTheme.monoStyle.copyWith(
                    fontSize: 11,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            RadioListTile<int>(
              value: _generateNewKey,
              contentPadding: EdgeInsets.zero,
              title: const Text('Generate a new Ed25519 key'),
              subtitle: Text(
                'Stored on this device only.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: FluttyTheme.spacingMd),
      FilledButton.icon(
        onPressed: () => unawaited(_start(keys)),
        icon: const Icon(Icons.vpn_key_outlined),
        label: const Text('Install Key'),
      ),
    ];
  }

  List<Widget> _buildProgress(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final error = _error;
    final key = _key;
    return [
      for (final entry in _stages.entries)
        _StageRow(stage: entry.key, state: entry.value),
      if (error != null) ...[
        const SizedBox(height: FluttyTheme.spacingSm),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, size: 20, color: colorScheme.error),
            const SizedBox(width: FluttyTheme.spacingSm),
            Expanded(child: Text(error, style: theme.textTheme.bodyMedium)),
          ],
        ),
        const SizedBox(height: FluttyTheme.spacingMd),
        if (key != null)
          OutlinedButton.icon(
            onPressed: () => showPublicKeyShareSheet(context, key),
            icon: const Icon(Icons.qr_code_2),
            label: const Text('Add the Key by Hand'),
          ),
        const SizedBox(height: FluttyTheme.spacingSm),
        FilledButton(
          onPressed: () => setState(() => _phase = _Phase.choose),
          child: const Text('Try Again'),
        ),
      ],
    ];
  }

  List<Widget> _buildVerified(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return [
      for (final entry in _stages.entries)
        _StageRow(stage: entry.key, state: entry.value),
      const SizedBox(height: FluttyTheme.spacingMd),
      Text('Remove the saved password?', style: theme.textTheme.titleMedium),
      const SizedBox(height: FluttyTheme.spacingXs),
      Text(
        'Key login works. Without the saved password, MonkeySSH signs in to '
        'this host with ${_key?.name ?? 'the key'} only.',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: FluttyTheme.spacingMd),
      FilledButton(
        onPressed: _busy ? null : () => _finish(removePassword: true),
        child: const Text('Remove Password'),
      ),
      const SizedBox(height: FluttyTheme.spacingSm),
      OutlinedButton(
        onPressed: _busy ? null : () => _finish(removePassword: false),
        child: const Text('Keep Password'),
      ),
    ];
  }

  List<Widget> _buildFinished(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return [
      Row(
        children: [
          Icon(Icons.check_circle, color: colorScheme.onSurface),
          const SizedBox(width: FluttyTheme.spacingSm),
          Expanded(
            child: Text(
              'This host now signs in with ${_key?.name ?? 'the key'}.',
              style: theme.textTheme.titleMedium,
            ),
          ),
        ],
      ),
      const SizedBox(height: FluttyTheme.spacingXs),
      Text(
        _passwordRemoved || !_usesSavedPassword
            ? 'No password is saved for it.'
            : 'The saved password is kept as a fallback.',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: FluttyTheme.spacingMd),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Done'),
      ),
    ];
  }
}

class _StageRow extends StatelessWidget {
  const _StageRow({required this.stage, required this.state});

  final KeyInstallStage stage;
  final _StageState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final (icon, color, status) = switch (state) {
      _StageState.pending => (
        Icons.radio_button_unchecked,
        colorScheme.onSurfaceVariant,
        'waiting',
      ),
      _StageState.active => (
        Icons.more_horiz,
        colorScheme.onSurface,
        'working',
      ),
      _StageState.done => (
        Icons.check_circle,
        colorScheme.onSurfaceVariant,
        'done',
      ),
      _StageState.failed => (Icons.error, colorScheme.error, 'failed'),
    };
    final label = switch (stage) {
      KeyInstallStage.generate => 'Generate an Ed25519 key',
      KeyInstallStage.connect => 'Connect with the saved login',
      KeyInstallStage.install => 'Add the key to authorized_keys',
      KeyInstallStage.verify => 'Reconnect with only the key',
    };
    return Semantics(
      label: '$label, $status',
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: FluttyTheme.spacingSm),
            Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
            Text(
              status,
              style: FluttyTheme.monoStyle.copyWith(
                fontSize: 12,
                color: state == _StageState.failed
                    ? colorScheme.error
                    : colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
