import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../domain/services/ssh_agent_forwarding.dart';

/// Shows the per-signature confirmation for SSH agent forwarding.
///
/// Resolves [SshAgentSignatureDecision.approved] only when the user taps
/// Allow, and [SshAgentSignatureDecision.stopForwarding] when they turn
/// forwarding off for the host. The dialog closes itself and resolves
/// [SshAgentSignatureDecision.declined] when [timeout] passes, the app goes to
/// the background, or the connection that asked closes.
Future<SshAgentSignatureDecision> showAgentSignatureDialog({
  required BuildContext context,
  required SshAgentSignatureRequest request,
  required Duration timeout,
}) async {
  final decision = await showDialog<SshAgentSignatureDecision>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AgentSignatureDialog(request: request, timeout: timeout),
  );
  return decision ?? SshAgentSignatureDecision.declined;
}

/// Asks whether a host may sign with one of the app's keys.
class AgentSignatureDialog extends StatefulWidget {
  /// Creates an [AgentSignatureDialog].
  const AgentSignatureDialog({
    required this.request,
    required this.timeout,
    super.key,
  });

  /// The signature being asked for.
  final SshAgentSignatureRequest request;

  /// How long the dialog waits before refusing on its own.
  final Duration timeout;

  @override
  State<AgentSignatureDialog> createState() => _AgentSignatureDialogState();
}

class _AgentSignatureDialogState extends State<AgentSignatureDialog> {
  static const _maxUsernameLength = 64;

  // The answers stay disabled this long after the prompt appears, so a tap
  // meant for the terminal (the host sees every keystroke and can time a
  // request to land under one) cannot answer it.
  static const _armDelay = Duration(milliseconds: 500);

  Timer? _timeoutTimer;
  Timer? _armTimer;
  AppLifecycleListener? _lifecycleListener;
  bool _armed = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _armTimer = Timer(_armDelay, () {
      if (mounted) {
        setState(() => _armed = true);
      }
    });
    _timeoutTimer = Timer(
      widget.timeout,
      () => _close(SshAgentSignatureDecision.declined),
    );
    _lifecycleListener = AppLifecycleListener(
      onStateChange: (state) {
        // Inactive counts too: the app switcher and the lock screen pass
        // through it, and the app treats it as backgrounded elsewhere.
        if (state != AppLifecycleState.resumed) {
          _close(SshAgentSignatureDecision.declined);
        }
      },
    );
    // The listener only reports later changes. The app may have left the
    // foreground between the foreground check that allowed this prompt and
    // this frame, so refuse right away rather than wait for a change that
    // already happened. An unknown state (null) has not been reported yet
    // and is left to the listener.
    final currentState = WidgetsBinding.instance.lifecycleState;
    if (currentState != null && currentState != AppLifecycleState.resumed) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _close(SshAgentSignatureDecision.declined),
      );
    }
    unawaited(
      widget.request.connectionClosed.then(
        (_) => _close(SshAgentSignatureDecision.declined),
      ),
    );
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    _armTimer?.cancel();
    _lifecycleListener?.dispose();
    super.dispose();
  }

  /// The button callback for [decision]: null, so the button shows as
  /// disabled, until the prompt is armed.
  VoidCallback? _answer(SshAgentSignatureDecision decision) =>
      _armed ? () => _close(decision) : null;

  void _close(SshAgentSignatureDecision decision) {
    if (_closed || !mounted) {
      return;
    }
    _closed = true;
    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    if (route == null || route.isCurrent) {
      navigator.pop(decision);
    } else {
      // Something opened above the dialog; remove only the dialog.
      navigator.removeRoute(route);
    }
  }

  String get _username =>
      sanitizeAgentSignatureUsername(widget.request.username);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final request = widget.request;
    final seconds = widget.timeout.inSeconds;

    return AlertDialog(
      title: Text(
        'Allow key use?',
        style: FluttyTheme.displayMono(
          fontSize: 18,
          color: colorScheme.onSurface,
        ),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: request.hostLabel,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const TextSpan(text: ' wants to sign in as '),
                    TextSpan(text: _username, style: FluttyTheme.monoStyle),
                    const TextSpan(text: ' with your key:'),
                  ],
                ),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  border: Border.all(color: colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.key_rounded,
                      size: 18,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        request.keyLabel,
                        key: const Key('agent-signature-key-label'),
                        style: FluttyTheme.monoStyle.copyWith(
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Allow only if you started this, for example a git push. '
                'MonkeySSH refuses on its own after $seconds seconds.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              // A third way out, kept apart from the Deny/Allow pair so the
              // two everyday answers stay side by side.
              TextButton.icon(
                key: const Key('agent-signature-stop'),
                style: TextButton.styleFrom(
                  foregroundColor: colorScheme.onSurface,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  alignment: AlignmentDirectional.centerStart,
                  minimumSize: const Size.fromHeight(44),
                ),
                onPressed: _answer(SshAgentSignatureDecision.stopForwarding),
                icon: const Icon(Icons.key_off_outlined, size: 18),
                label: const Text('Deny and turn off forwarding'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('agent-signature-deny'),
          onPressed: _answer(SshAgentSignatureDecision.declined),
          child: const Text('Deny'),
        ),
        FilledButton(
          key: const Key('agent-signature-allow'),
          onPressed: _answer(SshAgentSignatureDecision.approved),
          child: const Text('Allow'),
        ),
      ],
    );
  }
}

// Controls, format characters (bidi overrides and isolates, zero-width
// joiners and spaces) and line separators: anything that could hide or
// reorder text in the prompt.
final _invisibleCharacters = RegExp(
  r'[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]',
  unicode: true,
);

/// The user name from a signature request as it is safe to show: invisible
/// and reordering characters removed, and at most 64 characters kept without
/// splitting one.
@visibleForTesting
String sanitizeAgentSignatureUsername(String username) {
  final cleaned = username.replaceAll(_invisibleCharacters, '');
  final characters = cleaned.characters;
  return characters.length > _AgentSignatureDialogState._maxUsernameLength
      ? '${characters.take(_AgentSignatureDialogState._maxUsernameLength)}…'
      : cleaned;
}
