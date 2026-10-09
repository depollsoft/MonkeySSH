import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/database/database.dart';
import '../../domain/services/ssh_config_import_planner.dart';
import '../../domain/services/ssh_config_import_service.dart';
import '../../domain/services/ssh_config_parser.dart';
import '../providers/entity_list_providers.dart';

/// Largest config the importer reads, to keep a stray binary file or paste
/// from freezing the preview.
const sshConfigImportMaxBytes = 512 * 1024;

/// Configs at least this large are parsed off the UI isolate.
const _backgroundParseBytes = 32 * 1024;

SshConfigImportPlan _planFromText(String text) =>
    buildSshConfigImportPlan(parseSshConfig(text));

/// Imports hosts from an OpenSSH client config pasted or opened from a file,
/// with a preview of every host, jump host, forward, and skipped directive
/// before anything is saved.
class SshConfigImportScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const SshConfigImportScreen({super.key, this.initialText});

  /// Config text to start with, for tests and deep links.
  final String? initialText;

  @override
  ConsumerState<SshConfigImportScreen> createState() =>
      _SshConfigImportScreenState();
}

class _SshConfigImportScreenState extends ConsumerState<SshConfigImportScreen> {
  late final TextEditingController _source;
  final _defaultUsername = TextEditingController();
  SshConfigImportPlan? _plan;
  Set<String> _selected = {};
  var _importing = false;
  var _parsing = false;

  @override
  void initState() {
    super.initState();
    _source = TextEditingController(text: widget.initialText)
      ..addListener(_sourceChanged);
    _defaultUsername.addListener(_defaultUsernameChanged);
  }

  @override
  void dispose() {
    _source.dispose();
    _defaultUsername.dispose();
    super.dispose();
  }

  void _sourceChanged() => setState(() {});

  void _defaultUsernameChanged() => setState(() {});

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (!mounted) return;
    if (text == null || text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The clipboard has no text.')),
      );
      return;
    }
    _source.text = text;
  }

  void _tooLarge(String what) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('That $what is too large for an ssh config.')),
  );

  Future<void> _openFile() async {
    final file = await FilePicker.pickFile();
    if (!mounted || file == null) return;
    // Reject a known-large file before reading it into memory.
    final knownLength = file.lengthSync();
    if (knownLength != null && knownLength > sshConfigImportMaxBytes) {
      _tooLarge('file');
      return;
    }
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } on Exception {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t read that file.')),
        );
      }
      return;
    }
    if (!mounted) return;
    if (bytes.length > sshConfigImportMaxBytes) {
      _tooLarge('file');
      return;
    }
    _source.text = utf8.decode(bytes, allowMalformed: true);
  }

  Future<void> _preview(List<Host> savedHosts) async {
    final text = _source.text;
    if (utf8.encode(text).length > sshConfigImportMaxBytes) {
      _tooLarge('text');
      return;
    }
    setState(() => _parsing = true);
    final SshConfigImportPlan plan;
    try {
      plan = text.length >= _backgroundParseBytes
          ? await compute(_planFromText, text)
          : _planFromText(text);
    } finally {
      if (mounted) setState(() => _parsing = false);
    }
    if (!mounted) return;
    final saved = _savedMatches(plan, savedHosts);
    setState(() {
      _plan = plan;
      _selected = {
        for (final entry in plan.entries)
          if (!entry.isJumpOnly && !saved.containsKey(entry.id)) entry.id,
      };
    });
  }

  /// The same matching the import uses, so "already saved" is accurate.
  Map<String, Host> _savedMatches(
    SshConfigImportPlan plan,
    List<Host> savedHosts,
  ) => sshConfigSavedMatches(
    plan,
    savedHosts,
    defaultUsername: _defaultUsername.text,
  );

  Future<void> _import(SshConfigImportPlan plan) async {
    final selected = {
      for (final id in _selected)
        if (sshConfigEntryBlockReason(
              plan,
              plan.entryById(id)!,
              defaultUsername: _defaultUsername.text,
            ) ==
            null)
          id,
    };
    if (selected.isEmpty) return;
    setState(() => _importing = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final result = await ref
          .read(sshConfigImportServiceProvider)
          .importEntries(
            plan,
            selectedIds: selected,
            defaultUsername: _defaultUsername.text,
          );
      final created = result.createdHostIds.length;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            created == 0
                ? 'Those hosts were already saved.'
                : 'Imported $created ${created == 1 ? 'host' : 'hosts'}.',
          ),
        ),
      );
      if (navigator.canPop()) navigator.pop();
    } on SshConfigImportBlockedException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.reason)));
    } on Exception {
      messenger.showSnackBar(
        const SnackBar(content: Text('Import failed. Nothing was saved.')),
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final savedHosts =
        ref.watch(allHostsProvider).asData?.value ?? const <Host>[];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Import ssh_config'),
        leading: plan == null
            ? null
            : IconButton(
                tooltip: 'Edit config text',
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _plan = null),
              ),
      ),
      body: plan == null
          ? _buildSource(context, savedHosts)
          : _buildPreview(context, plan, savedHosts),
    );
  }

  Widget _buildSource(BuildContext context, List<Host> savedHosts) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(FluttyTheme.spacingMd),
              children: [
                Text(
                  'Paste your ~/.ssh/config or open the file. Import only '
                  'reads it: nothing runs, and Match, Include and '
                  'ProxyCommand are skipped with a reason. You’ll see every '
                  'host before anything is saved.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: FluttyTheme.spacingMd),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _paste,
                        icon: const Icon(Icons.content_paste),
                        label: const Text('Paste'),
                      ),
                    ),
                    const SizedBox(width: FluttyTheme.spacingSm),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _openFile,
                        icon: const Icon(Icons.file_open_outlined),
                        label: const Text('Open File'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: FluttyTheme.spacingMd),
                TextField(
                  key: const ValueKey('ssh-config-source'),
                  controller: _source,
                  minLines: 10,
                  maxLines: null,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.multiline,
                  style: FluttyTheme.monoStyle,
                  decoration: InputDecoration(
                    labelText: 'Config',
                    alignLabelWithHint: true,
                    hintText:
                        'Host web\n  HostName web.example.com\n  User me\n'
                        '  ProxyJump bastion',
                    hintStyle: FluttyTheme.monoStyle.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(FluttyTheme.spacingMd),
            child: FilledButton(
              onPressed: _source.text.trim().isEmpty || _parsing
                  ? null
                  : () => unawaited(_preview(savedHosts)),
              child: Text(_parsing ? 'Reading…' : 'Preview'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview(
    BuildContext context,
    SshConfigImportPlan plan,
    List<Host> savedHosts,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hostEntries = plan.entries.where((entry) => !entry.isJumpOnly);
    final jumpEntries = plan.entries.where((entry) => entry.isJumpOnly);
    final selectable = {
      for (final id in _selected)
        if (sshConfigEntryBlockReason(
              plan,
              plan.entryById(id)!,
              defaultUsername: _defaultUsername.text,
            ) ==
            null)
          id,
    };
    final closure = sshConfigImportClosure(plan, selectable);
    final savedMatches = _savedMatches(plan, savedHosts);
    final needsUsername = plan.entries.any((entry) => entry.username == null);
    final mono = FluttyTheme.monoStyle.copyWith(
      fontSize: 12,
      color: colorScheme.onSurfaceVariant,
    );

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(
                vertical: FluttyTheme.spacingSm,
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: FluttyTheme.spacingMd,
                  ),
                  child: Text(
                    '${hostEntries.length} '
                    '${hostEntries.length == 1 ? 'host' : 'hosts'} · '
                    '${jumpEntries.length} jump-only · '
                    '${plan.skipped.length} skipped',
                    style: mono,
                  ),
                ),
                if (plan.defaultPatterns.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      FluttyTheme.spacingMd,
                      FluttyTheme.spacingXs,
                      FluttyTheme.spacingMd,
                      0,
                    ),
                    child: Text(
                      'Defaults applied from Host '
                      '${plan.defaultPatterns.join(', ')}.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (needsUsername)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      FluttyTheme.spacingMd,
                      FluttyTheme.spacingMd,
                      FluttyTheme.spacingMd,
                      0,
                    ),
                    child: TextField(
                      key: const ValueKey('ssh-config-default-username'),
                      controller: _defaultUsername,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        labelText: 'Username for hosts without User',
                        helperText: 'Used where the config sets no User.',
                      ),
                    ),
                  ),
                if (hostEntries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(FluttyTheme.spacingMd),
                    child: Text(
                      'No hosts to import. Only wildcard Host blocks were '
                      'found, and those become defaults.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                const _SectionHeader(title: 'hosts'),
                for (final entry in hostEntries)
                  _EntryTile(
                    plan: plan,
                    entry: entry,
                    selected: _selected.contains(entry.id),
                    requiredBy:
                        closure.contains(entry.id) &&
                            !_selected.contains(entry.id)
                        ? 'Needed as a jump host'
                        : null,
                    blockedReason: sshConfigEntryBlockReason(
                      plan,
                      entry,
                      defaultUsername: _defaultUsername.text,
                    ),
                    savedMatch: savedMatches[entry.id],
                    onChanged: (value) => setState(() {
                      if (value) {
                        _selected.add(entry.id);
                      } else {
                        _selected.remove(entry.id);
                      }
                    }),
                  ),
                if (jumpEntries.isNotEmpty) ...[
                  const _SectionHeader(title: 'jump hosts'),
                  for (final entry in jumpEntries)
                    _EntryTile(
                      plan: plan,
                      entry: entry,
                      selected: closure.contains(entry.id),
                      requiredBy: closure.contains(entry.id)
                          ? 'Added because a selected host jumps through it'
                          : 'Added only if a selected host needs it',
                      blockedReason: null,
                      savedMatch: savedMatches[entry.id],
                    ),
                ],
                if (plan.skipped.isNotEmpty)
                  _SkippedSection(skipped: plan.skipped),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(FluttyTheme.spacingMd),
            child: FilledButton(
              key: const ValueKey('ssh-config-import-button'),
              onPressed: _importing || selectable.isEmpty
                  ? null
                  : () => _import(plan),
              child: Text(
                closure.isEmpty
                    ? 'Select Hosts to Import'
                    : 'Import ${closure.length} '
                          '${closure.length == 1 ? 'Host' : 'Hosts'}',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      FluttyTheme.spacingMd,
      FluttyTheme.spacingLg,
      FluttyTheme.spacingMd,
      FluttyTheme.spacingXs,
    ),
    child: Semantics(
      header: true,
      child: Text(
        title,
        style: FluttyTheme.displayMono(
          fontSize: 14,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ),
  );
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.plan,
    required this.entry,
    required this.selected,
    required this.blockedReason,
    required this.savedMatch,
    this.requiredBy,
    this.onChanged,
  });

  final SshConfigImportPlan plan;
  final SshConfigImportEntry entry;
  final bool selected;
  final String? blockedReason;
  final Host? savedMatch;
  final String? requiredBy;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final mono = FluttyTheme.monoStyle.copyWith(
      fontSize: 12,
      color: colorScheme.onSurfaceVariant,
    );
    final chain = plan.jumpChain(entry);
    final user = entry.username == null ? '' : '${entry.username}@';
    final enabled = onChanged != null && blockedReason == null;
    final notes = <(IconData, String, bool)>[
      if (chain.isNotEmpty)
        (
          Icons.alt_route,
          'via ${chain.map((hop) => hop.label).join(' → ')}',
          false,
        ),
      if (entry.forwards.isNotEmpty)
        (
          Icons.swap_horiz,
          '${entry.forwards.length} '
              '${entry.forwards.length == 1 ? 'forward' : 'forwards'}: '
              '${entry.forwards.map(_forwardSummary).join(', ')}',
          false,
        ),
      if (entry.keyNeeded)
        (
          Icons.key_outlined,
          'Key needed: import ${entry.identityFiles.map(_fileName).join(', ')} '
              'in Keys, then pick it for this host.',
          false,
        ),
      if (entry.aliases.length > 1)
        (
          Icons.label_outline,
          'Also: ${entry.aliases.skip(1).join(', ')}',
          false,
        ),
      if (savedMatch != null)
        (
          Icons.bookmark_outline,
          entry.forwards.isEmpty
              ? 'Already saved as ${savedMatch!.label}.'
              : 'Already saved as ${savedMatch!.label}. Importing it adds '
                    'any forwards it doesn’t have.',
          false,
        ),
      if (requiredBy != null) (Icons.link, requiredBy!, false),
      for (final warning in entry.warnings)
        (Icons.warning_amber, warning, true),
      if (blockedReason != null) (Icons.block, blockedReason!, true),
    ];

    return MergeSemantics(
      child: InkWell(
        onTap: enabled ? () => onChanged!(!selected) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FluttyTheme.spacingSm,
            vertical: FluttyTheme.spacingXs,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 48,
                height: 48,
                child: onChanged == null
                    ? Icon(
                        selected ? Icons.link : Icons.link_off,
                        size: 20,
                        color: colorScheme.onSurfaceVariant,
                      )
                    : Checkbox(
                        value: selected && blockedReason == null,
                        onChanged: enabled
                            ? (value) => onChanged!(value ?? false)
                            : null,
                      ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 12, right: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.label,
                        style: FluttyTheme.displayMono(
                          fontSize: 15,
                          color: colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text('$user${entry.hostname}:${entry.port}', style: mono),
                      for (final (icon, text, isWarning) in notes)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                icon,
                                size: 14,
                                color: isWarning
                                    ? colorScheme.tertiary
                                    : colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  text,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: isWarning
                                        ? colorScheme.onSurface
                                        : colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _forwardSummary(SshConfigForward forward) {
    final direction = forward.type == SshConfigForwardType.local ? 'L' : 'R';
    final manual = sshConfigForwardAutoStarts(forward) ? '' : ' (manual)';
    return '$direction ${forward.bindPort}→'
        '${forward.targetHost}:${forward.targetPort}$manual';
  }

  static String _fileName(String path) {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }
}

class _SkippedSection extends StatelessWidget {
  const _SkippedSection({required this.skipped});

  final List<SshConfigSkippedDirective> skipped;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: FluttyTheme.spacingMd),
      child: ExpansionTile(
        initiallyExpanded: skipped.length <= 12,
        tilePadding: const EdgeInsets.symmetric(
          horizontal: FluttyTheme.spacingMd,
        ),
        title: Text(
          'skipped (${skipped.length})',
          style: FluttyTheme.displayMono(
            fontSize: 14,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        subtitle: Text(
          'Not imported. Nothing in the config was run.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        children: [
          for (final skip in skipped)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                FluttyTheme.spacingMd,
                FluttyTheme.spacingXs,
                FluttyTheme.spacingMd,
                FluttyTheme.spacingXs,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 56,
                    child: Text(
                      'line ${skip.lineNumber}',
                      style: FluttyTheme.monoStyle.copyWith(
                        fontSize: 11,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: skip.keyword,
                            style: FluttyTheme.monoStyle.copyWith(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurface,
                            ),
                          ),
                          TextSpan(text: '  ${skip.reason}'),
                        ],
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
