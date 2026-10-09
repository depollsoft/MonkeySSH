/// Settings screens for custom agents: ACP agents the user adds by the exact
/// command that starts them on a host.
///
/// Labels, commands, arguments and environment variable names are user
/// content and are never logged.
library;

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../domain/models/acp_provider.dart';
import '../../domain/services/acp_provider_service.dart';
import '../widgets/brand_empty_state.dart';

/// Opens the custom agent list on the nearest navigator.
Future<void> openAcpCustomProvidersScreen(BuildContext context) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const AcpCustomProvidersScreen()),
    );

/// Formats [argv] as one line a person can read back exactly: arguments that
/// are empty or contain spaces, quotes or shell syntax are single-quoted.
///
/// This is for display only. Launches pass each argument separately and
/// never through shell parsing.
String formatAcpArgvForDisplay(List<String> argv) => argv
    .map(
      (value) =>
          value.isNotEmpty &&
              RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$').hasMatch(value)
          ? value
          : "'${value.replaceAll("'", r"'\''")}'",
    )
    .join(' ');

/// Splits the editor's arguments field into argv elements, one per line,
/// keeping each line exactly (spaces included). Trailing empty lines are
/// ignored; an empty line between arguments is an empty argument.
List<String> parseAcpArgumentLines(String text) {
  final lines = text.replaceAll('\r\n', '\n').split('\n');
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines;
}

/// Splits a SHA-256 fingerprint into groups of four for reading aloud.
String formatAcpFingerprintForDisplay(String fingerprint) => [
  for (var index = 0; index < fingerprint.length; index += 4)
    fingerprint.substring(index, (index + 4).clamp(0, fingerprint.length)),
].join(' ');

/// Settings row that opens [AcpCustomProvidersScreen].
class AcpCustomProvidersSettingsTile extends StatelessWidget {
  /// Creates the settings row.
  const AcpCustomProvidersSettingsTile({super.key});

  @override
  Widget build(BuildContext context) => ListTile(
    key: const ValueKey('settings-acp-custom-providers'),
    leading: const Icon(Icons.smart_toy_outlined),
    title: const Text('Custom agents'),
    subtitle: const Text('Any ACP agent, started by a command you approve'),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => unawaited(openAcpCustomProvidersScreen(context)),
  );
}

enum _ListAction { import, exportAll }

/// Lists, adds, edits, approves, deletes, imports and exports custom agents.
class AcpCustomProvidersScreen extends ConsumerWidget {
  /// Creates the custom agent list screen.
  const AcpCustomProvidersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final definitionsAsync = ref.watch(acpCustomProvidersProvider);
    final definitions =
        definitionsAsync.asData?.value ?? const <AcpCustomProviderDefinition>[];
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Custom Agents'),
        actions: [
          PopupMenuButton<_ListAction>(
            tooltip: 'More actions',
            onSelected: (action) => unawaited(switch (action) {
              _ListAction.import => _import(context, ref),
              _ListAction.exportAll => _exportAll(context, ref, definitions),
            }),
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _ListAction.import,
                child: ListTile(
                  leading: Icon(Icons.download_outlined),
                  title: Text('Import'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: _ListAction.exportAll,
                enabled: definitions.isNotEmpty,
                child: const ListTile(
                  leading: Icon(Icons.copy_all_outlined),
                  title: Text('Export all'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: definitions.isEmpty
          ? null
          : FloatingActionButton(
              tooltip: 'Add custom agent',
              onPressed: () => unawaited(_openEditor(context)),
              child: const Icon(Icons.add),
            ),
      body: definitionsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) =>
            const Center(child: Text('Could not load custom agents.')),
        data: (definitions) => definitions.isEmpty
            ? Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(FluttyTheme.spacingLg),
                  child: BrandEmptyState(
                    title: 'no custom agents',
                    message: 'Speaks ACP? Then it can run here.',
                    primaryLabel: 'Add custom agent',
                    onPrimary: () => unawaited(_openEditor(context)),
                    secondaryActions: [
                      BrandEmptyAction(
                        icon: Icons.download_outlined,
                        label: 'Import',
                        onTap: () => unawaited(_import(context, ref)),
                      ),
                    ],
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      FluttyTheme.spacingMd,
                      FluttyTheme.spacingMd,
                      FluttyTheme.spacingMd,
                      FluttyTheme.spacingSm,
                    ),
                    child: Text(
                      'Approved agents appear when you start a native agent '
                      'session. MonkeySSH runs the exact command on the host '
                      'through MonkeyMux, the same way as built-in agents.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  for (final definition in definitions)
                    _AgentTile(
                      key: ValueKey('custom-agent-${definition.id}'),
                      definition: definition,
                      onTap: () => unawaited(_openEditor(context, definition)),
                      onReview: () => unawaited(
                        showAcpCustomProviderReviewSheet(context, definition),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  Future<void> _openEditor(
    BuildContext context, [
    AcpCustomProviderDefinition? definition,
  ]) => Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => AcpCustomProviderEditScreen(definition: definition),
    ),
  );

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<AcpCustomProviderImportResult>(
      context: context,
      builder: (_) => const _ImportDialog(),
    );
    if (result == null || !context.mounted) return;
    final count = result.total == 1 ? '1 agent' : '${result.total} agents';
    // Imports replace agents with the same ID, so say so.
    final replaced = result.replaced == 0
        ? ''
        : ', replacing ${result.replaced} with the same ID';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.needsApproval == 0
              ? 'Imported $count$replaced.'
              : 'Imported $count$replaced. Review each one before it can run.',
        ),
      ),
    );
  }

  Future<void> _exportAll(
    BuildContext context,
    WidgetRef ref,
    List<AcpCustomProviderDefinition> definitions,
  ) => _copyExport(context, ref, count: definitions.length);
}

Future<void> _copyExport(
  BuildContext context,
  WidgetRef ref, {
  required int count,
  Set<String>? ids,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final text = await ref
        .read(acpCustomProviderServiceProvider)
        .export(ids: ids);
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Copied ${count == 1 ? '1 agent' : '$count agents'} as JSON. '
          'Environment variables are listed by name only.',
        ),
      ),
    );
  } on Object {
    messenger.showSnackBar(
      const SnackBar(content: Text('Could not export custom agents.')),
    );
  }
}

class _AgentTile extends StatelessWidget {
  const _AgentTile({
    required this.definition,
    required this.onTap,
    required this.onReview,
    super.key,
  });

  final AcpCustomProviderDefinition definition;
  final VoidCallback onTap;
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final approved = definition.isCommandApproved;
    final muted = FluttyTheme.monoStyle.copyWith(
      fontSize: 12,
      color: theme.colorScheme.onSurfaceVariant,
    );
    return ListTile(
      onTap: onTap,
      leading: const Icon(Icons.smart_toy_outlined),
      title: Text(
        definition.label,
        style: FluttyTheme.monoStyle.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            formatAcpArgvForDisplay(definition.launchCommand.argv),
            style: muted,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: FluttyTheme.spacingXs),
          _ApprovalStatus(
            approved: approved,
            renamed: definition.renamedFromId != null,
            style: muted,
          ),
        ],
      ),
      trailing: approved
          ? const Icon(Icons.chevron_right)
          : TextButton(
              // Status already carries the amber cue; keep teal for the FAB.
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.onSurface,
              ),
              onPressed: onReview,
              child: const Text('Review'),
            ),
    );
  }
}

class _ApprovalStatus extends StatelessWidget {
  const _ApprovalStatus({
    required this.approved,
    this.renamed = false,
    this.style,
  });

  final bool approved;
  final bool renamed;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          approved ? Icons.verified_user_outlined : Icons.gpp_maybe_outlined,
          size: 14,
          color: approved ? colorScheme.primary : colorScheme.tertiary,
        ),
        const SizedBox(width: FluttyTheme.spacingXs),
        Flexible(
          child: Text(
            approved
                ? 'approved'
                : renamed
                ? 'id changed · needs approval'
                : 'needs approval',
            style: style,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// Adds or edits one custom agent definition.
class AcpCustomProviderEditScreen extends ConsumerStatefulWidget {
  /// Creates the editor. [definition] is `null` when adding.
  const AcpCustomProviderEditScreen({this.definition, super.key});

  /// The definition being edited, or `null` for a new one.
  final AcpCustomProviderDefinition? definition;

  @override
  ConsumerState<AcpCustomProviderEditScreen> createState() =>
      _AcpCustomProviderEditScreenState();
}

class _AcpCustomProviderEditScreenState
    extends ConsumerState<AcpCustomProviderEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _label;
  late final TextEditingController _command;
  late final TextEditingController _arguments;
  late final TextEditingController _environment;
  late AcpCustomProviderCwdPolicy _cwdPolicy;
  var _dirty = false;
  var _saving = false;
  var _allowPop = false;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    final definition = widget.definition;
    _label = TextEditingController(text: definition?.label ?? '');
    _command = TextEditingController(
      text: definition?.launchCommand.executable ?? '',
    );
    _arguments = TextEditingController(
      text: definition?.launchCommand.arguments.join('\n') ?? '',
    );
    _environment = TextEditingController(
      text: definition?.environmentVariableNames.join('\n') ?? '',
    );
    _cwdPolicy =
        definition?.cwdPolicy ?? AcpCustomProviderCwdPolicy.chosenDirectory;
  }

  @override
  void dispose() {
    _label.dispose();
    _command.dispose();
    _arguments.dispose();
    _environment.dispose();
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  AcpLaunchCommand _buildCommand() {
    final original = widget.definition?.launchCommand;
    final executable = _command.text.trim();
    // An untouched field keeps the stored argv exactly, including empty
    // arguments a text field cannot show unambiguously.
    if (original != null &&
        executable == original.executable &&
        _arguments.text == original.arguments.join('\n')) {
      return original;
    }
    return AcpLaunchCommand(
      executable: executable,
      arguments: parseAcpArgumentLines(_arguments.text),
    );
  }

  List<String> _environmentNames() => [
    for (final name in _environment.text.split(RegExp(r'[\s,]+')))
      if (name.isNotEmpty) name,
  ];

  static String? _validate(void Function() check) {
    try {
      check();
      return null;
    } on FormatException catch (error) {
      return error.message;
    }
  }

  Future<void> _save() async {
    setState(() => _saveError = null);
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final commandError = _validate(
      () => validateAcpLaunchCommand(_buildCommand()),
    );
    if (commandError != null) {
      setState(() => _saveError = commandError);
      return;
    }
    setState(() => _saving = true);
    final service = ref.read(acpCustomProviderServiceProvider);
    final existing = widget.definition;
    try {
      final saved = existing == null
          ? await service.create(
              label: _label.text,
              launchCommand: _buildCommand(),
              environmentVariableNames: _environmentNames(),
              cwdPolicy: _cwdPolicy,
            )
          : await service.update(
              existing.id,
              label: _label.text,
              launchCommand: _buildCommand(),
              environmentVariableNames: _environmentNames(),
              cwdPolicy: _cwdPolicy,
            );
      if (!mounted) return;
      setState(() {
        _allowPop = true;
        _saving = false;
      });
      final navigator = Navigator.of(context);
      if (!saved.isCommandApproved) {
        await showAcpCustomProviderReviewSheet(context, saved);
      }
      if (mounted) navigator.pop();
    } on AcpCustomProviderException catch (error) {
      if (mounted) setState(() => _saveError = error.message);
    } on Object {
      if (mounted) {
        setState(() => _saveError = 'Could not save this custom agent.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final definition = widget.definition;
    if (definition == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete custom agent?'),
        content: const Text(
          'It will no longer appear in new sessions. Sessions already '
          'running keep going until they end.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false) || !mounted) return;
    await ref.read(acpCustomProviderServiceProvider).delete(definition.id);
    if (!mounted) return;
    setState(() => _allowPop = true);
    Navigator.of(context).pop();
  }

  Future<void> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your edits to this custom agent will be lost.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (!(discard ?? false) || !mounted) return;
    setState(() => _allowPop = true);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final definition = widget.definition;
    final isEditing = definition != null;
    return PopScope<Object?>(
      canPop: _allowPop || !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmDiscard());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(isEditing ? 'Edit Custom Agent' : 'Add Custom Agent'),
          actions: [
            if (definition != null) ...[
              IconButton(
                tooltip: 'Copy as JSON',
                icon: const Icon(Icons.copy_all_outlined),
                onPressed: () => unawaited(
                  _copyExport(context, ref, count: 1, ids: {definition.id}),
                ),
              ),
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: _saving ? null : () => unawaited(_delete()),
              ),
            ],
          ],
        ),
        body: Form(
          key: _formKey,
          onChanged: _markDirty,
          child: ListView(
            padding: const EdgeInsets.all(FluttyTheme.spacingMd),
            children: [
              if (definition != null) ...[
                _EditorApprovalBanner(initial: definition),
                const SizedBox(height: FluttyTheme.spacingMd),
              ],
              TextFormField(
                key: const ValueKey('custom-agent-label'),
                controller: _label,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Goose',
                ),
                validator: (value) =>
                    _validate(() => validateAcpProviderLabel(value ?? '')),
              ),
              if (definition != null) ...[
                const SizedBox(height: FluttyTheme.spacingXs),
                Text(
                  'id: ${definition.id}',
                  style: FluttyTheme.monoStyle.copyWith(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: FluttyTheme.spacingMd),
              TextFormField(
                key: const ValueKey('custom-agent-command'),
                controller: _command,
                autocorrect: false,
                enableSuggestions: false,
                style: FluttyTheme.monoStyle,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Command',
                  hintText: 'goose',
                  helperText:
                      'Looked up on the host’s PATH after your shell profile '
                      'loads. An absolute path is most reliable.',
                  helperMaxLines: 3,
                ),
                validator: (value) => (value ?? '').trim().isEmpty
                    ? 'Command must not be blank.'
                    : null,
              ),
              const SizedBox(height: FluttyTheme.spacingMd),
              TextFormField(
                key: const ValueKey('custom-agent-arguments'),
                controller: _arguments,
                autocorrect: false,
                enableSuggestions: false,
                minLines: 2,
                maxLines: 6,
                style: FluttyTheme.monoStyle,
                decoration: const InputDecoration(
                  labelText: 'Arguments',
                  hintText: 'acp',
                  helperText:
                      'One per line, exactly as written, spaces included. An '
                      'empty line between arguments passes an empty one; '
                      'empty lines at the end are ignored. No shell quoting, '
                      r'~ or $VARIABLE expansion.',
                  helperMaxLines: 3,
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: FluttyTheme.spacingMd),
              TextFormField(
                key: const ValueKey('custom-agent-environment'),
                controller: _environment,
                autocorrect: false,
                enableSuggestions: false,
                minLines: 1,
                maxLines: 4,
                style: FluttyTheme.monoStyle,
                decoration: const InputDecoration(
                  labelText: 'Required environment variables',
                  hintText: 'OPENAI_API_KEY',
                  helperText:
                      'Names only. MonkeySSH checks they are set on the host '
                      'before starting the agent and never stores their '
                      'values.',
                  helperMaxLines: 3,
                  alignLabelWithHint: true,
                ),
                validator: (_) => _validate(
                  () =>
                      validateAcpEnvironmentVariableNames(_environmentNames()),
                ),
              ),
              const SizedBox(height: FluttyTheme.spacingLg),
              Text('Starts in', style: theme.textTheme.labelLarge),
              const SizedBox(height: FluttyTheme.spacingSm),
              SegmentedButton<AcpCustomProviderCwdPolicy>(
                key: const ValueKey('custom-agent-cwd-policy'),
                segments: const [
                  ButtonSegment(
                    value: AcpCustomProviderCwdPolicy.chosenDirectory,
                    label: Text('Chosen folder'),
                  ),
                  ButtonSegment(
                    value: AcpCustomProviderCwdPolicy.homeDirectory,
                    label: Text('Home folder'),
                  ),
                ],
                selected: {_cwdPolicy},
                showSelectedIcon: false,
                onSelectionChanged: (selection) => setState(() {
                  _cwdPolicy = selection.single;
                  _dirty = true;
                }),
              ),
              const SizedBox(height: FluttyTheme.spacingSm),
              Text(switch (_cwdPolicy) {
                AcpCustomProviderCwdPolicy.chosenDirectory =>
                  'The agent starts in the folder you pick for each session.',
                AcpCustomProviderCwdPolicy.homeDirectory =>
                  'The agent always starts in your home folder on the host, '
                      'for agents that are not tied to one project.',
              }, style: muted),
              if (_saveError != null) ...[
                const SizedBox(height: FluttyTheme.spacingMd),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 18,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: FluttyTheme.spacingSm),
                    Expanded(
                      child: Text(
                        _saveError!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: FluttyTheme.spacingLg),
              FilledButton.icon(
                key: const ValueKey('custom-agent-save'),
                onPressed: _saving ? null : () => unawaited(_save()),
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save),
                label: Text(isEditing ? 'Save Changes' : 'Save and Review'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EditorApprovalBanner extends ConsumerWidget {
  const _EditorApprovalBanner({required this.initial});

  /// The definition the editor opened with; the banner follows the stored
  /// one, so approving from here updates it at once.
  final AcpCustomProviderDefinition initial;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final definition =
        ref
            .watch(acpCustomProvidersProvider)
            .asData
            ?.value
            .firstWhereOrNull((candidate) => candidate.id == initial.id) ??
        initial;
    final theme = Theme.of(context);
    final approved = definition.isCommandApproved;
    final renamedFrom = definition.renamedFromId;
    final colorScheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(
          color: approved ? colorScheme.outlineVariant : colorScheme.tertiary,
        ),
        borderRadius: BorderRadius.circular(FluttyTheme.radiusMd),
      ),
      child: Padding(
        padding: const EdgeInsets.all(FluttyTheme.spacingSm),
        child: Row(
          children: [
            Icon(
              approved
                  ? Icons.verified_user_outlined
                  : Icons.gpp_maybe_outlined,
              color: approved ? colorScheme.primary : colorScheme.tertiary,
            ),
            const SizedBox(width: FluttyTheme.spacingSm),
            Expanded(
              child: Text(
                approved
                    ? 'Approved. Any change, including the name, needs '
                          'approval again.'
                    : renamedFrom != null
                    ? 'A built-in agent now uses the ID "$renamedFrom", so '
                          'this agent moved to "${definition.id}". Review it '
                          'to run it again.'
                    : 'Needs approval before it can run.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            if (!approved)
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: colorScheme.onSurface,
                ),
                onPressed: () => unawaited(
                  showAcpCustomProviderReviewSheet(context, definition),
                ),
                child: const Text('Review'),
              ),
          ],
        ),
      ),
    );
  }
}

/// Shows the exact launch of [definition] with its fingerprint and asks the
/// user to approve it. Completes with `true` once approved.
Future<bool> showAcpCustomProviderReviewSheet(
  BuildContext context,
  AcpCustomProviderDefinition definition,
) async =>
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _ReviewSheet(definition: definition),
    ) ??
    false;

class _ReviewSheet extends ConsumerStatefulWidget {
  const _ReviewSheet({required this.definition});

  final AcpCustomProviderDefinition definition;

  @override
  ConsumerState<_ReviewSheet> createState() => _ReviewSheetState();
}

class _ReviewSheetState extends ConsumerState<_ReviewSheet> {
  var _approving = false;
  String? _error;

  Future<void> _approve() async {
    setState(() {
      _approving = true;
      _error = null;
    });
    try {
      await ref
          .read(acpCustomProviderServiceProvider)
          .approve(
            widget.definition.id,
            reviewedFingerprint: widget.definition.fingerprint,
          );
      if (mounted) Navigator.of(context).pop(true);
    } on AcpCustomProviderException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Object {
      if (mounted) setState(() => _error = 'Could not approve this agent.');
    } finally {
      if (mounted) setState(() => _approving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final definition = widget.definition;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );
    final changedSinceApproval =
        definition.approval != null && !definition.isCommandApproved;
    Widget section(String title, Widget child) => Padding(
      padding: const EdgeInsets.only(top: FluttyTheme.spacingMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: theme.textTheme.labelLarge),
          const SizedBox(height: FluttyTheme.spacingXs),
          child,
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FluttyTheme.spacingLg,
        0,
        FluttyTheme.spacingLg,
        FluttyTheme.spacingLg,
      ),
      // The decision stays in thumb reach however long the command is.
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'approve agent',
                    style: FluttyTheme.displayMono(
                      fontSize: 18,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: FluttyTheme.spacingSm),
                  Text(
                    definition.label,
                    style: FluttyTheme.monoStyle.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: FluttyTheme.spacingSm),
                  Text(
                    'MonkeySSH will run this exact command on the host each time '
                    'you start a session with this agent. It runs with your '
                    'account’s permissions there.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  if (changedSinceApproval) ...[
                    const SizedBox(height: FluttyTheme.spacingSm),
                    Row(
                      children: [
                        Icon(
                          Icons.history,
                          size: 18,
                          color: colorScheme.tertiary,
                        ),
                        const SizedBox(width: FluttyTheme.spacingSm),
                        Expanded(
                          child: Text(
                            'This agent changed since you last approved it.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ],
                  section(
                    'Command',
                    _CodeBlock(
                      key: const ValueKey('custom-agent-review-command'),
                      text: formatAcpArgvForDisplay(
                        definition.launchCommand.argv,
                      ),
                    ),
                  ),
                  section(
                    'Required environment variables',
                    Text(
                      definition.environmentVariableNames.isEmpty
                          ? 'None'
                          : definition.environmentVariableNames.join('  '),
                      style: FluttyTheme.monoStyle,
                    ),
                  ),
                  section(
                    'Starts in',
                    Text(switch (definition.cwdPolicy) {
                      AcpCustomProviderCwdPolicy.chosenDirectory =>
                        'The folder chosen for each session',
                      AcpCustomProviderCwdPolicy.homeDirectory =>
                        'Your home folder',
                    }, style: theme.textTheme.bodyMedium),
                  ),
                  section(
                    'Fingerprint',
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SelectableText(
                          formatAcpFingerprintForDisplay(
                            definition.fingerprint,
                          ),
                          key: const ValueKey(
                            'custom-agent-review-fingerprint',
                          ),
                          style: FluttyTheme.monoStyle.copyWith(fontSize: 12),
                        ),
                        const SizedBox(height: FluttyTheme.spacingXs),
                        Text(
                          'SHA-256 of the name, command, variable names and '
                          'starting folder. Any change needs approval again.',
                          style: muted,
                        ),
                      ],
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: FluttyTheme.spacingMd),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 18,
                          color: colorScheme.error,
                        ),
                        const SizedBox(width: FluttyTheme.spacingSm),
                        Expanded(
                          child: Text(
                            _error!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: FluttyTheme.spacingLg),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _approving
                      ? null
                      : () => Navigator.of(context).pop(false),
                  child: const Text('Not now'),
                ),
              ),
              const SizedBox(width: FluttyTheme.spacingSm),
              Expanded(
                child: FilledButton(
                  key: const ValueKey('custom-agent-approve'),
                  onPressed: _approving ? null : () => unawaited(_approve()),
                  child: const Text('Approve'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(FluttyTheme.radiusMd),
      ),
      child: Padding(
        padding: const EdgeInsets.all(FluttyTheme.spacingSm),
        child: SelectableText(text, style: FluttyTheme.monoStyle),
      ),
    );
  }
}

class _ImportDialog extends ConsumerStatefulWidget {
  const _ImportDialog();

  @override
  ConsumerState<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends ConsumerState<_ImportDialog> {
  final _text = TextEditingController();
  var _importing = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (!mounted || text == null) return;
    setState(() {
      _text.text = text;
      _error = null;
    });
  }

  Future<void> _import() async {
    setState(() {
      _importing = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(acpCustomProviderServiceProvider)
          .import(_text.text);
      if (mounted) Navigator.of(context).pop(result);
    } on AcpCustomProviderException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Object {
      if (mounted) setState(() => _error = 'Could not import these agents.');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Import custom agents'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Paste JSON exported from MonkeySSH. Imported agents run '
              'commands on your hosts, so each one waits for your approval.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: FluttyTheme.spacingSm),
            TextField(
              key: const ValueKey('custom-agent-import-text'),
              controller: _text,
              autocorrect: false,
              enableSuggestions: false,
              minLines: 4,
              maxLines: 10,
              style: FluttyTheme.monoStyle.copyWith(fontSize: 12),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              decoration: InputDecoration(
                hintText: '{"format": "$acpCustomProviderExportFormat", …}',
                errorText: _error,
                errorMaxLines: 4,
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.onSurfaceVariant,
                ),
                onPressed: _importing ? null : () => unawaited(_paste()),
                icon: const Icon(Icons.content_paste_outlined, size: 18),
                label: const Text('Paste'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _importing ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('custom-agent-import'),
          onPressed: _importing ? null : () => unawaited(_import()),
          child: const Text('Import'),
        ),
      ],
    );
  }
}
