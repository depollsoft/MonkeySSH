/// Host-edit fields for a preset's git worktree and native initial prompt.
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../domain/models/agent_launch_preset.dart';
import '../../domain/models/agent_worktree.dart';

/// Editable text and toggle state behind [AgentPresetWorkspaceFields].
class AgentPresetWorkspaceFormState {
  /// Repository path; empty uses the preset's working directory.
  final repository = TextEditingController();

  /// Base ref; empty means `HEAD`.
  final baseRef = TextEditingController();

  /// Branch name template; empty uses the default.
  final branchTemplate = TextEditingController();

  /// Worktree path template; empty uses the default.
  final pathTemplate = TextEditingController();

  /// Prompt sent once when a native session starts.
  final initialPrompt = TextEditingController();

  final _focusNodes = {
    for (final field in AgentWorktreeField.values) field: FocusNode(),
  };
  final _locationKeys = {
    for (final field in AgentWorktreeField.values) field: GlobalKey(),
  };

  /// Focus target for a validation problem in [field].
  FocusNode focusNodeFor(AgentWorktreeField field) => _focusNodes[field]!;

  /// Scroll target for a validation problem in [field].
  GlobalKey locationKeyFor(AgentWorktreeField field) => _locationKeys[field]!;

  /// The field holding the first problem for [workingDirectory], so a failed
  /// save takes the user to the field they must fix.
  AgentWorktreeField problemField(String workingDirectory) =>
      worktree?.problem(workingDirectory: workingDirectory)?.field ??
      AgentWorktreeField.branchTemplate;

  /// Whether launches create a new worktree.
  bool worktreeEnabled = false;

  /// Every text controller, for dirty-state listeners.
  List<TextEditingController> get controllers => [
    repository,
    baseRef,
    branchTemplate,
    pathTemplate,
    initialPrompt,
  ];

  /// Worktree options for the current text, or null when disabled.
  AgentWorktreeLaunchOptions? get worktree => worktreeEnabled
      ? AgentWorktreeLaunchOptions(
          repositoryPath: repository.text.trim(),
          baseRef: baseRef.text.trim(),
          branchTemplate: branchTemplate.text.trim(),
          pathTemplate: pathTemplate.text.trim(),
        )
      : null;

  /// Loads the fields from a saved [preset].
  void load(AgentLaunchPreset? preset) {
    final options = preset?.worktree;
    worktreeEnabled = options != null;
    repository.text = options?.repositoryPath ?? '';
    baseRef.text = options?.baseRef ?? '';
    branchTemplate.text = options?.branchTemplate ?? '';
    pathTemplate.text = options?.pathTemplate ?? '';
    initialPrompt.text = preset?.initialPrompt ?? '';
  }

  /// Releases the controllers.
  void dispose() {
    for (final controller in controllers) {
      controller.dispose();
    }
    for (final node in _focusNodes.values) {
      node.dispose();
    }
  }
}

/// Worktree toggle, worktree settings and the native initial prompt for an
/// agent launch preset.
class AgentPresetWorkspaceFields extends StatelessWidget {
  /// Creates the fields.
  const AgentPresetWorkspaceFields({
    required this.state,
    required this.enabled,
    required this.tool,
    required this.workingDirectory,
    required this.onChanged,
    super.key,
  });

  /// Form state owned by the screen.
  final AgentPresetWorkspaceFormState state;

  /// Whether the user can edit presets (Pro).
  final bool enabled;

  /// Agent the preset launches, used in the name preview.
  final AgentLaunchTool tool;

  /// The preset's working directory field, the repository fallback.
  final TextEditingController workingDirectory;

  /// Called after the toggle changes so the screen can rebuild and update
  /// its unsaved-changes state.
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final helperStyle = Theme.of(context).textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        KeyedSubtree(
          key: const Key('host-agent-worktree-switch-location'),
          child: SwitchListTile(
            key: const Key('host-agent-worktree-switch'),
            value: state.worktreeEnabled,
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.account_tree_outlined),
            title: const Text('Start in a new git worktree'),
            subtitle: const Text(
              'Each launch adds a branch and folder, so parallel agents '
              'don’t share a checkout.',
            ),
            onChanged: enabled
                ? (value) {
                    state.worktreeEnabled = value;
                    onChanged();
                  }
                : null,
          ),
        ),
        if (state.worktreeEnabled) ...[
          const SizedBox(height: 8),
          _field(
            field: AgentWorktreeField.repository,
            key: const Key('host-agent-worktree-repository-field'),
            controller: state.repository,
            label: 'Repository (optional)',
            hint: 'Same as working directory',
            icon: Icons.source_outlined,
            validator: (value) {
              final text = value?.trim() ?? '';
              if (text.isEmpty) {
                return workingDirectory.text.trim().isEmpty
                    ? 'Set a repository or a working directory.'
                    : null;
              }
              return validateAgentWorktreeRemotePath(text, label: 'Repository');
            },
          ),
          const SizedBox(height: 12),
          _field(
            field: AgentWorktreeField.baseRef,
            key: const Key('host-agent-worktree-base-field'),
            controller: state.baseRef,
            label: 'Base branch or ref (optional)',
            hint: defaultAgentWorktreeBaseRef,
            icon: Icons.commit_outlined,
            validator: (value) {
              final text = value?.trim() ?? '';
              return text.isEmpty ? null : validateAgentWorktreeBaseRef(text);
            },
          ),
          const SizedBox(height: 12),
          _field(
            field: AgentWorktreeField.branchTemplate,
            key: const Key('host-agent-worktree-branch-field'),
            controller: state.branchTemplate,
            label: 'New branch name',
            hint: defaultAgentWorktreeBranchTemplate,
            icon: Icons.call_split,
            helper: 'Use {tool}, {date}, {time} and {id}.',
            validator: (value) => _templateError(
              AgentWorktreeLaunchOptions(branchTemplate: value?.trim()),
            ),
          ),
          const SizedBox(height: 12),
          _field(
            field: AgentWorktreeField.pathTemplate,
            key: const Key('host-agent-worktree-path-field'),
            controller: state.pathTemplate,
            label: 'Worktree folder',
            hint: defaultAgentWorktreePathTemplate,
            icon: Icons.create_new_folder_outlined,
            helper:
                'Start with {repo} for the repository folder. {name} is the '
                'branch with / replaced by -.',
            validator: (value) => _templateError(
              AgentWorktreeLaunchOptions(pathTemplate: value?.trim()),
            ),
          ),
          const SizedBox(height: 12),
          ListenableBuilder(
            listenable: Listenable.merge([
              ...state.controllers,
              workingDirectory,
            ]),
            builder: (context, _) => _WorktreePreview(
              options: state.worktree!,
              tool: tool,
              workingDirectory: workingDirectory.text,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Needs a MonkeyMux or tmux session, set below, so reconnecting '
            'returns to the same worktree. Closing the agent’s window offers '
            'to remove a clean worktree.',
            style: helperStyle,
          ),
        ],
        const SizedBox(height: 12),
        TextFormField(
          key: const Key('host-agent-initial-prompt-field'),
          controller: state.initialPrompt,
          readOnly: !enabled,
          minLines: 1,
          maxLines: 5,
          keyboardType: TextInputType.multiline,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Initial prompt for native chat (optional)',
            hintText: 'Read AGENTS.md and list the open tasks.',
            prefixIcon: Icon(Icons.chat_bubble_outline),
            helperText:
                'Sent once when a native chat starts from this host. Never '
                'sent when resuming or reconnecting.',
            helperMaxLines: 3,
          ),
        ),
      ],
    );
  }

  Widget _field({
    required AgentWorktreeField field,
    required Key key,
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    required FormFieldValidator<String> validator,
    String? helper,
  }) => KeyedSubtree(
    key: state.locationKeyFor(field),
    child: TextFormField(
      key: key,
      controller: controller,
      focusNode: state.focusNodeFor(field),
      readOnly: !enabled,
      autocorrect: false,
      enableSuggestions: false,
      style: FluttyTheme.monoStyle,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        helperText: helper,
        helperMaxLines: 3,
      ),
    ),
  );

  static String? _templateError(AgentWorktreeLaunchOptions options) {
    try {
      renderAgentWorktreeTarget(options, AgentWorktreeTemplateValues.sample);
      return null;
    } on FormatException catch (error) {
      return error.message;
    }
  }
}

class _WorktreePreview extends StatelessWidget {
  const _WorktreePreview({
    required this.options,
    required this.tool,
    required this.workingDirectory,
  });

  final AgentWorktreeLaunchOptions options;
  final AgentLaunchTool tool;
  final String workingDirectory;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final problem = options.validate(workingDirectory: workingDirectory);
    if (problem != null) {
      return Row(
        key: const Key('host-agent-worktree-preview-error'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              problem,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colorScheme.error),
            ),
          ),
        ],
      );
    }
    final target = renderAgentWorktreeTarget(
      options,
      AgentWorktreeTemplateValues.sample.withTool(tool.commandName),
    );
    final repository = options.resolveRepositoryPath(workingDirectory)!;
    final location = target.pathIsRepositoryRelative
        ? '${repository.endsWith('/') && repository.length > 1 ? repository.substring(0, repository.length - 1) : repository}${target.path}'
        : target.path;
    final mono = FluttyTheme.monoStyle.copyWith(
      fontSize: 12,
      color: colorScheme.onSurfaceVariant,
    );
    return Semantics(
      label:
          'Example: branch ${target.branch} in $location, '
          'from ${options.effectiveBaseRef}',
      excludeSemantics: true,
      child: Column(
        key: const Key('host-agent-worktree-preview'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Example', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text('${options.effectiveBaseRef} → ${target.branch}', style: mono),
          Text(location, style: mono),
        ],
      ),
    );
  }
}
