/// Sign-in method chooser for ACP agents that require authentication.
///
/// Lists the agent's advertised methods (name, description, and the method
/// type set quietly in mono), runs `agent` methods in place with a cancelable
/// progress state, and hands `terminal` methods back to the caller so they
/// run in the in-app sign-in terminal. Agent-provided text is shown to the
/// user only; it is never logged.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../domain/models/acp_authentication.dart';
import '../../domain/models/acp_protocol.dart';
import '../../domain/models/acp_provider.dart';
import '../../domain/models/acp_session_state.dart';
import '../../domain/models/monkeymux_acp_bridge.dart';
import '../../domain/services/acp_json_rpc_connection.dart';
import '../../domain/services/acp_provider_service.dart';
import '../../domain/services/monkeymux_acp_bridge_service.dart';
import '../../domain/services/ssh_service.dart';
import 'acp_sign_in_terminal.dart';
import 'cursor_block.dart';

/// What the user picked in the sign-in method sheet.
@immutable
sealed class AcpAuthMethodSelection {
  const AcpAuthMethodSelection();
}

/// A protocol choice the session manager acts on.
@immutable
final class AcpAuthMethodChosen extends AcpAuthMethodSelection {
  /// Creates a protocol choice.
  const AcpAuthMethodChosen(this.choice);

  /// The resolved choice.
  final AcpAuthenticationChoice choice;
}

/// The user preferred the provider's own command-line sign-in.
@immutable
final class AcpAuthProviderCommandChosen extends AcpAuthMethodSelection {
  /// Creates a provider-command choice.
  const AcpAuthProviderCommandChosen();
}

/// Shows the sign-in method sheet for [request].
///
/// Picking an `agent` method calls [AcpAuthenticationRequest.authenticate]
/// while the sheet shows progress; success resolves to
/// [AcpAuthenticationCompleted]. Picking a `terminal` method resolves to
/// [AcpAuthenticationInTerminal] without calling `authenticate`. When
/// [offerProviderCommand] is true, the provider's own sign-in command is
/// offered as a fallback. Dismissing or canceling resolves to `null`.
Future<AcpAuthMethodSelection?> showAcpAuthMethodSheet(
  BuildContext context, {
  required AcpAuthenticationRequest request,
  bool offerProviderCommand = false,
}) => showModalBottomSheet<AcpAuthMethodSelection>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (context) => AcpAuthMethodSheet(
    request: request,
    offerProviderCommand: offerProviderCommand,
  ),
);

/// Builds a launch-time chooser that asks with [showAcpAuthMethodSheet].
///
/// [onProviderCommand] runs after the sheet closes when the user prefers the
/// provider's own sign-in command; the launch is then declined.
AcpAuthenticationChooser acpAuthenticationChooser(
  BuildContext context, {
  bool offerProviderCommand = false,
  VoidCallback? onProviderCommand,
}) => (request) async {
  if (!context.mounted) return null;
  final selection = await showAcpAuthMethodSheet(
    context,
    request: request,
    offerProviderCommand: offerProviderCommand,
  );
  switch (selection) {
    case AcpAuthMethodChosen(:final choice):
      return choice;
    case AcpAuthProviderCommandChosen():
      onProviderCommand?.call();
      return null;
    case null:
      return null;
  }
};

/// Runs [launch] in the in-app sign-in terminal on its host's active SSH
/// connection, resolving to `true` only after a zero exit status.
Future<bool> runAcpTerminalSignIn(
  BuildContext context,
  WidgetRef ref,
  AcpTerminalAuthLaunch requested,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  var launch = requested;
  if (!launch.providerId.startsWith(acpBuiltinProviderIdPrefix)) {
    // A custom agent signs in with the command approved now, never the one
    // captured when its session started.
    final current = await currentAcpTerminalSignInLaunch(
      ref.read(acpCustomProviderLookupProvider),
      launch,
    );
    if (!context.mounted) return false;
    if (current == null) {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text(
            'Approve this agent in Settings › Custom agents before signing '
            'in.',
          ),
        ),
      );
      return false;
    }
    launch = current;
  }
  final session = ref
      .read(sshServiceProvider)
      .getSessionsForHost(launch.hostId)
      .firstOrNull;
  if (session == null) {
    messenger?.showSnackBar(
      const SnackBar(content: Text('Reconnect to this host to sign in.')),
    );
    return false;
  }
  final String command;
  try {
    command = buildAcpTerminalAuthCommand(
      launch,
      isWindows: session.remoteIsWindows,
    );
  } on MonkeyMuxAcpBridgeException {
    messenger?.showSnackBar(
      const SnackBar(
        content: Text('This sign-in method can’t run on this host.'),
      ),
    );
    return false;
  }
  if (!context.mounted) return false;
  return showAcpSignInTerminal(
    context,
    launch: launch,
    start: ({required columns, required rows}) =>
        startAcpSignInOverSsh(session, command, columns: columns, rows: rows),
  );
}

/// The sign-in method chooser surface.
class AcpAuthMethodSheet extends StatefulWidget {
  /// Creates the chooser.
  const AcpAuthMethodSheet({
    required this.request,
    this.offerProviderCommand = false,
    super.key,
  });

  /// The pending sign-in request.
  final AcpAuthenticationRequest request;

  /// Whether to offer the provider's own command-line sign-in.
  final bool offerProviderCommand;

  @override
  State<AcpAuthMethodSheet> createState() => _AcpAuthMethodSheetState();
}

class _AcpAuthMethodSheetState extends State<AcpAuthMethodSheet> {
  AcpAuthMethod? _authenticating;
  AcpSessionError? _error;
  var _generation = 0;
  AcpRequestCancellation? _pendingSignIn;

  @override
  void dispose() {
    // Dismissing the sheet mid sign-in abandons it, like Cancel does.
    _pendingSignIn?.cancel();
    super.dispose();
  }

  Future<void> _choose(AcpAuthMethod method) async {
    if (method.isTerminal) {
      Navigator.of(context)
          .pop(AcpAuthMethodChosen(AcpAuthenticationInTerminal(method)));
      return;
    }
    final generation = ++_generation;
    setState(() {
      _authenticating = method;
      _error = null;
    });
    final cancellation = _pendingSignIn = AcpRequestCancellation();
    final error = await widget.request.authenticate(
      method,
      cancellation: cancellation,
    );
    if (identical(_pendingSignIn, cancellation)) _pendingSignIn = null;
    if (!mounted || generation != _generation) return;
    if (error == null) {
      Navigator.of(context)
          .pop(const AcpAuthMethodChosen(AcpAuthenticationCompleted()));
      return;
    }
    setState(() {
      _authenticating = null;
      _error = error;
    });
  }

  void _cancel() {
    // Stop waiting and tell the agent to stop its login flow; the launch then
    // gives up and releases the agent connection.
    _pendingSignIn?.cancel();
    _pendingSignIn = null;
    _generation++;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final authenticating = _authenticating;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FluttyTheme.spacingLg,
        0,
        FluttyTheme.spacingLg,
        FluttyTheme.spacingLg,
      ),
      child: SingleChildScrollView(
        child: AnimatedSize(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'sign in to ${widget.request.providerLabel}',
                style: FluttyTheme.displayMono(
                  fontSize: 18,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: FluttyTheme.spacingSm),
              if (authenticating == null)
                ..._buildChooser(context)
              else
                ..._buildProgress(context, authenticating),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildChooser(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final error = _error;
    return [
      Text(
        '${widget.request.providerLabel} needs you to sign in before it can '
        'start. MonkeySSH never stores third-party credentials.',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      if (error != null) ...[
        const SizedBox(height: FluttyTheme.spacingMd),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, size: 18, color: scheme.error),
            const SizedBox(width: FluttyTheme.spacingSm),
            Expanded(
              child: Text(
                error.message,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ),
          ],
        ),
      ],
      const SizedBox(height: FluttyTheme.spacingMd),
      for (final method in widget.request.methods) ...[
        _AuthMethodTile(
          key: ValueKey('acp-auth-method-${method.id}'),
          method: method,
          onTap: () => unawaited(_choose(method)),
        ),
        const SizedBox(height: FluttyTheme.spacingSm),
      ],
      const SizedBox(height: FluttyTheme.spacingSm),
      if (widget.offerProviderCommand) ...[
        OutlinedButton.icon(
          onPressed: () =>
              Navigator.of(context).pop(const AcpAuthProviderCommandChosen()),
          icon: const Icon(Icons.terminal),
          label: const Text('Copy CLI sign-in command'),
        ),
        const SizedBox(height: FluttyTheme.spacingSm),
      ],
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Not now'),
      ),
    ];
  }

  List<Widget> _buildProgress(BuildContext context, AcpAuthMethod method) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final description = method.description?.trim();
    return [
      Semantics(
        liveRegion: true,
        label:
            'Waiting for ${widget.request.providerLabel} to finish signing in',
        child: Row(
          children: [
            Text(
              'waiting for the agent',
              style: FluttyTheme.monoStyle.copyWith(
                color: scheme.onSurface,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: FluttyTheme.spacingSm),
            CursorBlock(color: scheme.primary, size: 10),
          ],
        ),
      ),
      const SizedBox(height: FluttyTheme.spacingMd),
      Text(
        _methodTitle(method),
        style: theme.textTheme.titleSmall?.copyWith(color: scheme.onSurface),
      ),
      if (description != null && description.isNotEmpty) ...[
        const SizedBox(height: FluttyTheme.spacingXs),
        Text(
          description,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
      const SizedBox(height: FluttyTheme.spacingMd),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: FluttyTheme.spacingSm),
          Expanded(
            child: Text(
              'The agent runs this on the remote host. A browser it opens '
              'appears there, not on this device.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: FluttyTheme.spacingLg),
      OutlinedButton(onPressed: _cancel, child: const Text('Cancel sign-in')),
    ];
  }
}

String _methodTitle(AcpAuthMethod method) {
  final name = method.name.trim();
  return name.isEmpty ? method.id : name;
}

/// One advertised method: name, the agent's description, and its type.
class _AuthMethodTile extends StatelessWidget {
  const _AuthMethodTile({required this.method, required this.onTap, super.key});

  final AcpAuthMethod method;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final description = method.description?.trim();
    final terminal = method.isTerminal;
    return Material(
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FluttyTheme.radiusMd),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FluttyTheme.spacingMd,
              vertical: 12,
            ),
            child: Row(
              children: [
                Icon(
                  terminal ? Icons.terminal : Icons.login,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: FluttyTheme.spacingMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _methodTitle(method),
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: scheme.onSurface,
                        ),
                      ),
                      if (description != null && description.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          description,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: FluttyTheme.spacingSm),
                Text(
                  terminal ? 'terminal' : 'agent',
                  style: FluttyTheme.monoStyle.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontSize: 11,
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
