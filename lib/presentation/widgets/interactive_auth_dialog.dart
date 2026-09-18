import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../domain/services/interactive_auth_prompt.dart';

/// Shows a blocking dialog that collects responses for an SSH server auth
/// challenge (a password or keyboard-interactive prompt).
///
/// Returns one response per [SshAuthChallenge.prompts] entry, in order, or
/// `null` when the user cancels.
Future<List<String>?> showInteractiveAuthDialog({
  required BuildContext context,
  required SshAuthChallenge challenge,
}) => showDialog<List<String>>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _InteractiveAuthDialog(challenge: challenge),
);

class _InteractiveAuthDialog extends StatefulWidget {
  const _InteractiveAuthDialog({required this.challenge});

  final SshAuthChallenge challenge;

  @override
  State<_InteractiveAuthDialog> createState() => _InteractiveAuthDialogState();
}

class _InteractiveAuthDialogState extends State<_InteractiveAuthDialog> {
  late final List<TextEditingController> _controllers;
  late final List<bool> _obscured;

  @override
  void initState() {
    super.initState();
    _controllers = List.generate(
      widget.challenge.prompts.length,
      (_) => TextEditingController(),
      growable: false,
    );
    _obscured = widget.challenge.prompts
        .map((prompt) => !prompt.echo)
        .toList(growable: false);
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    Navigator.of(context)
        .pop(_controllers.map((c) => c.text).toList(growable: false));
  }

  void _cancel() => Navigator.of(context).pop();

  String _resolveTitle() {
    final name = widget.challenge.name.trim();
    if (name.isNotEmpty) {
      return name;
    }
    final prompts = widget.challenge.prompts;
    final isSinglePassword = prompts.length == 1 && !prompts.first.echo;
    return isSinglePassword ? 'Password required' : 'Authentication required';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final challenge = widget.challenge;
    final instruction = challenge.instruction.trim();

    return AlertDialog(
      title: Text(
        _resolveTitle(),
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
              Text(
                'The server ${challenge.hostLabel} requested credentials to '
                'continue.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 4),
              Text(
                challenge.hostLabel,
                style: FluttyTheme.monoStyle.copyWith(
                  fontSize: 11,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              if (instruction.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(instruction, style: theme.textTheme.bodyMedium),
              ],
              const SizedBox(height: 16),
              for (var i = 0; i < challenge.prompts.length; i++)
                Padding(
                  padding: EdgeInsets.only(
                    bottom: i == challenge.prompts.length - 1 ? 0 : 12,
                  ),
                  child: _buildPromptField(i),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _cancel, child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Continue')),
      ],
    );
  }

  Widget _buildPromptField(int index) {
    final prompt = widget.challenge.prompts[index];
    final isLast = index == widget.challenge.prompts.length - 1;
    final label = prompt.prompt.trim().isEmpty ? 'Response' : prompt.prompt;
    return TextField(
      controller: _controllers[index],
      autofocus: index == 0,
      obscureText: _obscured[index],
      enableSuggestions: prompt.echo,
      autocorrect: prompt.echo,
      textInputAction: isLast ? TextInputAction.done : TextInputAction.next,
      onSubmitted: (_) {
        if (isLast) {
          _submit();
        } else {
          FocusScope.of(context).nextFocus();
        }
      },
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        suffixIcon: prompt.echo
            ? null
            : IconButton(
                icon: Icon(
                  _obscured[index]
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                tooltip: _obscured[index] ? 'Show' : 'Hide',
                onPressed: () =>
                    setState(() => _obscured[index] = !_obscured[index]),
              ),
      ),
    );
  }
}
