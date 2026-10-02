/// Settings screens for the MCP servers native agent sessions can use.
///
/// Server names, commands, URLs, and secret values are never logged.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../domain/models/acp_mcp_server.dart';
import '../../domain/services/acp_mcp_server_service.dart';
import '../widgets/brand_empty_state.dart';

/// Opens the MCP server list on the nearest navigator.
Future<void> openAcpMcpServersScreen(BuildContext context) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const AcpMcpServersScreen()),
    );

/// Settings row that opens [AcpMcpServersScreen].
///
/// It deliberately does not watch the server list: the row stays cheap and
/// never decrypts stored secrets just to render Settings.
class AcpMcpServersSettingsTile extends StatelessWidget {
  /// Creates the settings row.
  const AcpMcpServersSettingsTile({super.key});

  @override
  Widget build(BuildContext context) => ListTile(
    key: const ValueKey('settings-acp-mcp-servers'),
    leading: const Icon(Icons.extension_outlined),
    title: const Text('MCP servers'),
    subtitle: const Text(
      'Tools agents can use, on by default or chosen per session',
    ),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => unawaited(openAcpMcpServersScreen(context)),
  );
}

/// Lists, adds, edits, and deletes user-defined MCP servers.
class AcpMcpServersScreen extends ConsumerWidget {
  /// Creates the MCP server list screen.
  const AcpMcpServersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serversAsync = ref.watch(acpMcpServersProvider);
    final servers = serversAsync.asData?.value ?? const <AcpMcpServerConfig>[];
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('MCP Servers')),
      floatingActionButton: servers.isEmpty
          ? null
          : FloatingActionButton(
              tooltip: 'Add MCP server',
              onPressed: () => unawaited(_openEditor(context, servers)),
              child: const Icon(Icons.add),
            ),
      body: serversAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) =>
            const Center(child: Text('Could not load MCP servers.')),
        data: (servers) => servers.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(FluttyTheme.spacingLg),
                  child: BrandEmptyState(
                    title: 'no mcp servers',
                    message: 'Agents only know the tools you hand them.',
                    primaryLabel: 'Add MCP server',
                    onPrimary: () => unawaited(_openEditor(context, servers)),
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
                      'Switched-on servers attach to new native agent '
                      'sessions; adjust the set per session when you start '
                      'it. The agent launches stdio servers on the remote '
                      'host.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  for (final server in servers)
                    _ServerTile(
                      key: ValueKey('mcp-server-${server.id}'),
                      server: server,
                      onTap: () =>
                          unawaited(_openEditor(context, servers, server)),
                      onDefaultChanged: (enabled) => unawaited(
                        ref
                            .read(acpMcpServerServiceProvider)
                            .setUseByDefault(server.id, enabled: enabled),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  Future<void> _openEditor(
    BuildContext context,
    List<AcpMcpServerConfig> servers, [
    AcpMcpServerConfig? server,
  ]) => Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => AcpMcpServerEditScreen(
        server: server,
        otherNames: [
          for (final other in servers)
            if (other.id != server?.id) other.name,
        ],
      ),
    ),
  );
}

class _ServerTile extends StatelessWidget {
  const _ServerTile({
    required this.server,
    required this.onTap,
    required this.onDefaultChanged,
    super.key,
  });

  final AcpMcpServerConfig server;
  final VoidCallback onTap;
  final ValueChanged<bool> onDefaultChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final target = server.transport.isRemote
        ? (Uri.tryParse(server.url)?.host ?? server.url)
        : server.command;
    return ListTile(
      onTap: onTap,
      leading: Icon(
        server.transport.isRemote ? Icons.cloud_outlined : Icons.terminal,
      ),
      title: Text(
        server.name,
        style: FluttyTheme.monoStyle.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Row(
        children: [
          if (server.hasUnreadableSecrets) ...[
            Icon(
              Icons.warning_amber_rounded,
              size: 14,
              color: theme.colorScheme.error,
            ),
            const SizedBox(width: FluttyTheme.spacingXs),
          ],
          Expanded(
            child: Text(
              server.hasUnreadableSecrets
                  ? 'secrets need re-entering'
                  : '${server.transport.label} · $target',
              style: FluttyTheme.monoStyle.copyWith(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      trailing: Tooltip(
        message: 'Use by default for new sessions',
        child: Switch(value: server.useByDefault, onChanged: onDefaultChanged),
      ),
    );
  }
}

class _PairDraft {
  _PairDraft({String name = '', String value = ''})
    : name = TextEditingController(text: name),
      value = TextEditingController(text: value);

  final TextEditingController name;
  final TextEditingController value;
  bool revealed = false;

  void dispose() {
    name.dispose();
    value.dispose();
  }
}

/// Adds or edits one MCP server definition.
class AcpMcpServerEditScreen extends ConsumerStatefulWidget {
  /// Creates the editor. [server] is `null` when adding.
  const AcpMcpServerEditScreen({
    this.server,
    this.otherNames = const <String>[],
    super.key,
  });

  /// The server being edited, or `null` for a new server.
  final AcpMcpServerConfig? server;

  /// Names of the other configured servers, for uniqueness validation.
  final List<String> otherNames;

  @override
  ConsumerState<AcpMcpServerEditScreen> createState() =>
      _AcpMcpServerEditScreenState();
}

class _AcpMcpServerEditScreenState
    extends ConsumerState<AcpMcpServerEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _command;
  late final TextEditingController _args;
  late final TextEditingController _url;
  late AcpMcpServerTransport _transport;
  late bool _useByDefault;
  final List<_PairDraft> _env = <_PairDraft>[];
  final List<_PairDraft> _headers = <_PairDraft>[];
  var _dirty = false;
  var _saving = false;
  var _allowPop = false;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    final server = widget.server;
    _name = TextEditingController(text: server?.name ?? '');
    _command = TextEditingController(text: server?.command ?? '');
    _args = TextEditingController(text: server?.args.join('\n') ?? '');
    _url = TextEditingController(text: server?.url ?? '');
    _transport = server?.transport ?? AcpMcpServerTransport.stdio;
    _useByDefault = server?.useByDefault ?? true;
    for (final variable in server?.env ?? const <AcpMcpNameValue>[]) {
      _env.add(_PairDraft(name: variable.name, value: variable.value));
    }
    for (final header in server?.headers ?? const <AcpMcpNameValue>[]) {
      _headers.add(_PairDraft(name: header.name, value: header.value));
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    _args.dispose();
    _url.dispose();
    for (final draft in [..._env, ..._headers]) {
      draft.dispose();
    }
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  AcpMcpServerConfig _buildServer() {
    List<AcpMcpNameValue> pairs(List<_PairDraft> drafts) => [
      for (final draft in drafts)
        if (draft.name.text.trim().isNotEmpty || draft.value.text.isNotEmpty)
          AcpMcpNameValue(
            name: draft.name.text.trim(),
            value: draft.value.text,
          ),
    ];
    final service = ref.read(acpMcpServerServiceProvider);
    return AcpMcpServerConfig(
      id: widget.server?.id ?? service.newServerId(),
      name: _name.text.trim(),
      transport: _transport,
      command: _command.text.trim(),
      args: [
        for (final line in _args.text.split('\n'))
          if (line.trim().isNotEmpty) line.trim(),
      ],
      env: pairs(_env),
      url: _url.text.trim(),
      headers: pairs(_headers),
      useByDefault: _useByDefault,
    );
  }

  Future<void> _save() async {
    setState(() => _saveError = null);
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      await ref.read(acpMcpServerServiceProvider).saveServer(_buildServer());
      if (!mounted) return;
      setState(() => _allowPop = true);
      Navigator.of(context).pop();
    } on AcpMcpServerValidationException catch (error) {
      if (mounted) setState(() => _saveError = error.message);
    } on Object {
      if (mounted) {
        setState(() => _saveError = 'Could not save this MCP server.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final server = widget.server;
    if (server == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete MCP server?'),
        content: const Text(
          'New sessions will no longer use it. Sessions already running keep '
          'it until they reconnect.',
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
    await ref.read(acpMcpServerServiceProvider).deleteServer(server.id);
    if (!mounted) return;
    setState(() => _allowPop = true);
    Navigator.of(context).pop();
  }

  Future<void> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your edits to this MCP server will be lost.'),
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
    final isEditing = widget.server != null;
    return PopScope<Object?>(
      canPop: _allowPop || !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmDiscard());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(isEditing ? 'Edit MCP Server' : 'Add MCP Server'),
          actions: [
            if (isEditing)
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: _saving ? null : () => unawaited(_delete()),
              ),
          ],
        ),
        body: Form(
          key: _formKey,
          onChanged: _markDirty,
          child: ListView(
            padding: const EdgeInsets.all(FluttyTheme.spacingMd),
            children: [
              if (widget.server?.hasUnreadableSecrets ?? false) ...[
                _UnreadableSecretsBanner(textStyle: muted),
                const SizedBox(height: FluttyTheme.spacingMd),
              ],
              TextFormField(
                key: const ValueKey('mcp-server-name'),
                controller: _name,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'github',
                ),
                validator: (value) => AcpMcpServerValidation.name(
                  value ?? '',
                  otherNames: widget.otherNames,
                ),
              ),
              const SizedBox(height: FluttyTheme.spacingMd),
              SegmentedButton<AcpMcpServerTransport>(
                segments: [
                  for (final transport in AcpMcpServerTransport.values)
                    ButtonSegment<AcpMcpServerTransport>(
                      value: transport,
                      label: Text(transport.label),
                    ),
                ],
                selected: {_transport},
                showSelectedIcon: false,
                onSelectionChanged: (selection) => setState(() {
                  _transport = selection.single;
                  _dirty = true;
                }),
              ),
              const SizedBox(height: FluttyTheme.spacingSm),
              Text(switch (_transport) {
                AcpMcpServerTransport.stdio =>
                  'The agent starts this server as a process on the remote '
                      'host, so the command must be installed there. Every '
                      'agent supports stdio.',
                AcpMcpServerTransport.http =>
                  'The agent connects to this URL from the remote host. '
                      'Agents that do not support HTTP MCP servers skip it.',
                AcpMcpServerTransport.sse =>
                  'SSE is deprecated by MCP; prefer HTTP when the server '
                      'offers it. Agents that do not support SSE skip it.',
              }, style: muted),
              const SizedBox(height: FluttyTheme.spacingMd),
              if (_transport == AcpMcpServerTransport.stdio) ...[
                TextFormField(
                  key: const ValueKey('mcp-server-command'),
                  controller: _command,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: FluttyTheme.monoStyle,
                  decoration: const InputDecoration(
                    labelText: 'Command',
                    hintText: '/usr/local/bin/mcp-server',
                    helperText: 'An absolute path is most reliable.',
                  ),
                  validator: (value) =>
                      AcpMcpServerValidation.command(value ?? ''),
                ),
                const SizedBox(height: FluttyTheme.spacingMd),
                TextFormField(
                  key: const ValueKey('mcp-server-args'),
                  controller: _args,
                  autocorrect: false,
                  enableSuggestions: false,
                  minLines: 2,
                  maxLines: 6,
                  style: FluttyTheme.monoStyle,
                  decoration: const InputDecoration(
                    labelText: 'Arguments',
                    hintText: '--stdio',
                    helperText: 'One argument per line. No shell quoting.',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: FluttyTheme.spacingLg),
                _PairsEditor(
                  title: 'Environment variables',
                  addLabel: 'Add variable',
                  namePlaceholder: 'API_KEY',
                  drafts: _env,
                  isHeader: false,
                  onChanged: () => setState(() => _dirty = true),
                ),
              ] else ...[
                TextFormField(
                  key: const ValueKey('mcp-server-url'),
                  controller: _url,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.url,
                  style: FluttyTheme.monoStyle,
                  decoration: const InputDecoration(
                    labelText: 'URL',
                    hintText: 'https://mcp.example.com/mcp',
                  ),
                  validator: (value) => AcpMcpServerValidation.url(value ?? ''),
                ),
                const SizedBox(height: FluttyTheme.spacingLg),
                _PairsEditor(
                  title: 'Headers',
                  addLabel: 'Add header',
                  namePlaceholder: 'Authorization',
                  drafts: _headers,
                  isHeader: true,
                  onChanged: () => setState(() => _dirty = true),
                ),
              ],
              const SizedBox(height: FluttyTheme.spacingSm),
              Text(
                'Values are encrypted on this device and only sent to the '
                'agent when a session starts.',
                style: muted,
              ),
              const SizedBox(height: FluttyTheme.spacingMd),
              SwitchListTile(
                key: const ValueKey('mcp-server-default'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Use by default'),
                subtitle: const Text('Preselect for new agent sessions'),
                value: _useByDefault,
                onChanged: (value) => setState(() {
                  _useByDefault = value;
                  _dirty = true;
                }),
              ),
              if (_saveError != null) ...[
                const SizedBox(height: FluttyTheme.spacingSm),
                Text(
                  _saveError!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: FluttyTheme.spacingLg),
              FilledButton.icon(
                onPressed: _saving ? null : () => unawaited(_save()),
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save),
                label: Text(isEditing ? 'Save Changes' : 'Add Server'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UnreadableSecretsBanner extends StatelessWidget {
  const _UnreadableSecretsBanner({required this.textStyle});

  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colorScheme.error),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(FluttyTheme.spacingSm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, color: colorScheme.error),
            const SizedBox(width: FluttyTheme.spacingSm),
            Expanded(
              child: Text(
                'Saved values could not be decrypted on this device. '
                'Re-enter them and save; until then, sessions skip this '
                'server.',
                style: textStyle,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PairsEditor extends StatelessWidget {
  const _PairsEditor({
    required this.title,
    required this.addLabel,
    required this.namePlaceholder,
    required this.drafts,
    required this.isHeader,
    required this.onChanged,
  });

  final String title;
  final String addLabel;
  final String namePlaceholder;
  final List<_PairDraft> drafts;
  final bool isHeader;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.labelLarge),
          ),
          TextButton.icon(
            // The screen's one teal signal is Save; utility actions stay quiet.
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
            onPressed: drafts.length >= kAcpMcpServerMaxEntries
                ? null
                : () {
                    drafts.add(_PairDraft());
                    onChanged();
                  },
            icon: const Icon(Icons.add, size: 18),
            label: Text(addLabel),
          ),
        ],
      ),
      for (final (index, draft) in drafts.indexed)
        Padding(
          key: ObjectKey(draft),
          padding: const EdgeInsets.only(top: FluttyTheme.spacingSm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 2,
                child: TextFormField(
                  controller: draft.name,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: FluttyTheme.monoStyle,
                  decoration: InputDecoration(
                    labelText: 'Name',
                    hintText: namePlaceholder,
                  ),
                  validator: (value) => isHeader
                      ? AcpMcpServerValidation.headerName(value ?? '')
                      : AcpMcpServerValidation.envName(value ?? ''),
                ),
              ),
              const SizedBox(width: FluttyTheme.spacingSm),
              Expanded(
                flex: 3,
                child: StatefulBuilder(
                  builder: (context, setLocalState) => TextFormField(
                    controller: draft.value,
                    autocorrect: false,
                    enableSuggestions: false,
                    obscureText: !draft.revealed,
                    style: FluttyTheme.monoStyle,
                    decoration: InputDecoration(
                      labelText: 'Value',
                      suffixIcon: IconButton(
                        tooltip: draft.revealed ? 'Hide value' : 'Show value',
                        icon: Icon(
                          draft.revealed
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                        ),
                        onPressed: () => setLocalState(
                          () => draft.revealed = !draft.revealed,
                        ),
                      ),
                    ),
                    validator: (value) => AcpMcpServerValidation.secretValue(
                      value ?? '',
                      header: isHeader,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.close),
                onPressed: () {
                  drafts.removeAt(index);
                  onChanged();
                  // Dispose once the row's fields have unmounted.
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => draft.dispose(),
                  );
                },
              ),
            ],
          ),
        ),
    ],
  );
}
