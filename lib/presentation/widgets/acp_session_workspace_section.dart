/// Per-session workspace choices in the new-session sheet: which configured
/// MCP servers to attach and which additional directories to share.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../domain/models/acp_mcp_server.dart';
import '../../domain/models/acp_session_workspace.dart';
import '../screens/acp_mcp_servers_screen.dart';

/// Holds the MCP server selection and additional-directory drafts for one
/// session launch.
class AcpSessionWorkspaceController extends ChangeNotifier {
  /// Creates a controller that loads servers through [loadServers].
  AcpSessionWorkspaceController({required this.loadServers});

  /// Loads the configured MCP servers.
  final Future<List<AcpMcpServerConfig>> Function() loadServers;

  List<AcpMcpServerConfig> _servers = const <AcpMcpServerConfig>[];
  Set<String> _selected = <String>{};
  var _loaded = false;
  var _customized = false;
  var _fromRecent = false;
  var _disposed = false;
  final List<TextEditingController> _directories = <TextEditingController>[];
  TextEditingController? _lastAddedDirectory;

  /// Configured servers, in stored order.
  List<AcpMcpServerConfig> get servers => _servers;

  /// Whether the server list has loaded.
  bool get loaded => _loaded;

  /// Draft additional directories.
  List<TextEditingController> get directories =>
      List<TextEditingController>.unmodifiable(_directories);

  /// The directory draft the user just added, which takes focus.
  TextEditingController? get lastAddedDirectory => _lastAddedDirectory;

  /// Whether [serverId] is attached to this launch.
  bool isSelected(String serverId) => _selected.contains(serverId);

  /// Number of selected servers that exist.
  int get selectedCount =>
      _servers.where((server) => _selected.contains(server.id)).length;

  /// Loads (or reloads) the configured servers. Until the user changes the
  /// selection, it tracks the servers marked "use by default".
  Future<void> refresh() async {
    List<AcpMcpServerConfig> servers;
    try {
      servers = await loadServers();
    } on Object {
      servers = const <AcpMcpServerConfig>[];
    }
    if (_disposed) return;
    _servers = servers;
    final known = {for (final server in servers) server.id};
    _selected = _customized
        ? _selected.intersection(known)
        : {
            for (final server in servers)
              if (server.useByDefault) server.id,
          };
    _loaded = true;
    notifyListeners();
  }

  /// Attaches or detaches [serverId].
  void setSelected(String serverId, {required bool selected}) {
    _customized = true;
    if (selected) {
      _selected.add(serverId);
    } else {
      _selected.remove(serverId);
    }
    notifyListeners();
  }

  /// Adds an empty directory draft.
  void addDirectory() {
    if (_directories.length >= kAcpMaxAdditionalDirectories) return;
    final added = TextEditingController();
    _directories.add(added);
    _lastAddedDirectory = added;
    notifyListeners();
  }

  /// Removes the directory draft at [index].
  void removeDirectoryAt(int index) {
    final removed = _directories.removeAt(index);
    notifyListeners();
    WidgetsBinding.instance.addPostFrameCallback((_) => removed.dispose());
  }

  /// Loads the choices a recent session was last opened with.
  void applyRecent(AcpSessionWorkspaceOptions workspace) {
    final ids = workspace.mcpServerIds;
    _fromRecent = true;
    _customized = ids != null;
    _selected = ids == null
        ? {
            for (final server in _servers)
              if (server.useByDefault) server.id,
          }
        : ids.toSet();
    _replaceDirectories(workspace.additionalDirectories);
    notifyListeners();
  }

  /// Restores the defaults after a recent session's choices were applied.
  void clearRecent() {
    if (!_fromRecent) return;
    _fromRecent = false;
    _customized = false;
    _selected = {
      for (final server in _servers)
        if (server.useByDefault) server.id,
    };
    _replaceDirectories(const <String>[]);
    notifyListeners();
  }

  void _replaceDirectories(List<String> paths) {
    final old = List<TextEditingController>.of(_directories);
    _directories
      ..clear()
      ..addAll([for (final path in paths) TextEditingController(text: path)]);
    if (old.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final controller in old) {
          controller.dispose();
        }
      });
    }
  }

  /// The choices to launch with. Before the server list loads, an untouched
  /// selection is left unspecified so the configured defaults apply.
  AcpSessionWorkspaceOptions get options => AcpSessionWorkspaceOptions(
    mcpServerIds: _loaded
        ? [
            for (final server in _servers)
              if (_selected.contains(server.id)) server.id,
          ]
        : (_customized ? _selected.toList() : null),
    additionalDirectories: [
      for (final controller in _directories)
        if (controller.text.trim().isNotEmpty) controller.text.trim(),
    ],
  );

  @override
  void dispose() {
    _disposed = true;
    for (final controller in _directories) {
      controller.dispose();
    }
    super.dispose();
  }
}

/// Compact MCP server and additional-directory pickers for a session launch.
class AcpSessionWorkspaceSection extends StatelessWidget {
  /// Creates the section.
  const AcpSessionWorkspaceSection({
    required this.controller,
    this.enabled = true,
    super.key,
  });

  /// Selection state.
  final AcpSessionWorkspaceController controller;

  /// Whether the controls accept input.
  final bool enabled;

  Future<void> _configure(BuildContext context) async {
    await openAcpMcpServersScreen(context);
    await controller.refresh();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final theme = Theme.of(context);
      final servers = controller.servers;
      final directories = controller.directories;
      final String? serverDetail;
      if (!controller.loaded) {
        serverDetail = null;
      } else if (servers.isEmpty) {
        serverDetail = 'none';
      } else {
        serverDetail = '${controller.selectedCount} of ${servers.length}';
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: FluttyTheme.spacingSm),
          _HeaderRow(
            label: 'MCP servers',
            detail: serverDetail,
            action: _SecondaryAction(
              key: const ValueKey('acp-workspace-configure-mcp'),
              icon: servers.isEmpty ? Icons.add : Icons.tune,
              label: servers.isEmpty ? 'Set up' : 'Manage',
              onPressed: enabled ? () => unawaited(_configure(context)) : null,
            ),
          ),
          if (servers.isNotEmpty) ...[
            Wrap(
              spacing: FluttyTheme.spacingSm,
              runSpacing: FluttyTheme.spacingSm,
              children: [
                for (final server in servers)
                  FilterChip(
                    key: ValueKey('acp-workspace-mcp-${server.id}'),
                    label: Text(server.name, overflow: TextOverflow.ellipsis),
                    avatar: server.hasUnreadableSecrets
                        ? Icon(
                            Icons.warning_amber_rounded,
                            size: 16,
                            color: theme.colorScheme.error,
                          )
                        : null,
                    tooltip: server.hasUnreadableSecrets
                        ? 'Saved secrets need re-entering in Settings'
                        : '${server.transport.label} MCP server',
                    selected: controller.isSelected(server.id),
                    onSelected: enabled
                        ? (selected) => controller.setSelected(
                            server.id,
                            selected: selected,
                          )
                        : null,
                  ),
              ],
            ),
            const SizedBox(height: FluttyTheme.spacingSm),
          ],
          _HeaderRow(
            label: 'Additional directories',
            action: _SecondaryAction(
              key: const ValueKey('acp-workspace-add-directory'),
              icon: Icons.add,
              label: 'Add',
              onPressed:
                  enabled && directories.length < kAcpMaxAdditionalDirectories
                  ? controller.addDirectory
                  : null,
            ),
          ),
          for (final (index, directory) in directories.indexed)
            Padding(
              key: ObjectKey(directory),
              padding: const EdgeInsets.only(bottom: FluttyTheme.spacingSm),
              child: TextField(
                key: ValueKey('acp-workspace-directory-$index'),
                controller: directory,
                enabled: enabled,
                autofocus: identical(directory, controller.lastAddedDirectory),
                autocorrect: false,
                enableSuggestions: false,
                style: FluttyTheme.monoStyle,
                decoration: InputDecoration(
                  hintText: '~/shared-lib',
                  suffixIcon: IconButton(
                    tooltip: 'Remove directory',
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: enabled
                        ? () => controller.removeDirectoryAt(index)
                        : null,
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// A quiet header action: the sheet's one teal signal stays on its primary
/// Start button, so these utility actions use the secondary ink.
class _SecondaryAction extends StatelessWidget {
  const _SecondaryAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: onPressed,
    style: TextButton.styleFrom(
      foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
      // A 44px row keeps the touch target while letting the label sit close
      // to its controls, like the sheet's other section labels.
      minimumSize: const Size(44, 44),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 12),
    ),
    icon: Icon(icon, size: 18),
    label: Text(label),
  );
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.label, required this.action, this.detail});

  final String label;
  final String? detail;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(label, style: theme.textTheme.labelLarge),
        if (detail != null) ...[
          const SizedBox(width: FluttyTheme.spacingSm),
          Text(
            detail!,
            style: FluttyTheme.monoStyle.copyWith(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const Spacer(),
        action,
      ],
    );
  }
}
