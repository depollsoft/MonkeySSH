import 'dart:async';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/database/database.dart';
import '../../data/repositories/snippet_repository.dart';
import '../../domain/services/telemetry_service.dart';
import '../widgets/snippet_folder_dialog.dart';
import '../widgets/unsaved_changes_guard.dart';

typedef _SnippetEditDraft = ({
  String name,
  String command,
  String description,
  int? selectedFolderId,
});

const _createFolderDropdownValue = -1;

/// Initial values used when creating a new snippet draft.
@immutable
class SnippetEditPrefill {
  /// Creates initial snippet editor values.
  const SnippetEditPrefill({
    this.name,
    this.command,
    this.description,
    this.folderId,
  });

  /// Initial snippet name.
  final String? name;

  /// Initial command content.
  final String? command;

  /// Initial snippet description.
  final String? description;

  /// Initial folder selection.
  final int? folderId;
}

/// Screen for adding or editing a snippet.
class SnippetEditScreen extends ConsumerStatefulWidget {
  /// Creates a new [SnippetEditScreen].
  const SnippetEditScreen({
    this.snippetId,
    this.prefill = const SnippetEditPrefill(),
    super.key,
  });

  /// The snippet ID to edit, or null for a new snippet.
  final int? snippetId;

  /// Initial values for a new snippet draft.
  final SnippetEditPrefill prefill;

  @override
  ConsumerState<SnippetEditScreen> createState() => _SnippetEditScreenState();
}

class _SnippetEditScreenState extends ConsumerState<SnippetEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _contentController = TextEditingController();
  final _descriptionController = TextEditingController();

  bool _isLoading = false;
  String? _loadError;
  Snippet? _existingSnippet;
  int? _selectedFolderId;
  int _folderDropdownRevision = 0;
  List<SnippetFolder> _folders = [];
  _SnippetEditDraft? _initialDraft;

  @override
  void initState() {
    super.initState();
    unawaited(_loadFolders());
    if (widget.snippetId != null) {
      unawaited(_loadSnippet());
    } else {
      _applyPrefill(widget.prefill);
      _initialDraft = _currentDraft();
    }
  }

  void _applyPrefill(SnippetEditPrefill prefill) {
    _nameController.text = prefill.name ?? '';
    _contentController.text = prefill.command ?? '';
    _descriptionController.text = prefill.description ?? '';
    _selectedFolderId = prefill.folderId;
  }

  Future<void> _loadFolders() async {
    final folders = await ref.read(snippetRepositoryProvider).getAllFolders();
    if (mounted) {
      setState(() {
        _folders = folders;
        _folderDropdownRevision += 1;
      });
    }
  }

  Future<void> _loadSnippet() async {
    setState(() => _isLoading = true);
    try {
      final snippet = await ref
          .read(snippetRepositoryProvider)
          .getById(widget.snippetId!);
      if (!mounted) return;
      if (snippet == null) {
        _loadError = 'Snippet not found.';
        return;
      }
      _existingSnippet = snippet;
      _nameController.text = snippet.name;
      _contentController.text = snippet.command;
      _descriptionController.text = snippet.description ?? '';
      _selectedFolderId = snippet.folderId;
      _initialDraft = _currentDraft();
    } on Object {
      if (mounted) _loadError = 'Could not load snippet. Try again.';
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _contentController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.snippetId != null;

    return UnsavedChangesGuard(
      hasUnsavedChanges: _hasUnsavedChanges,
      child: Scaffold(
        appBar: AppBar(
          title: Text(isEditing ? 'Edit Snippet' : 'Add Snippet'),
          actions: [
            IconButton(
              icon: const Icon(Icons.help_outline),
              onPressed: _showVariablesHelp,
              tooltip: 'Variable syntax',
            ),
          ],
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
            ? Center(child: Text(_loadError!))
            : Form(
                key: _formKey,
                onChanged: () => setState(() {}),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    // Name
                    TextFormField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                        labelText: 'Name',
                        hintText: 'Restart Docker',
                        prefixIcon: Icon(Icons.label),
                      ),
                      textInputAction: TextInputAction.next,
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Please enter a name';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),

                    // Description (optional)
                    TextFormField(
                      controller: _descriptionController,
                      decoration: const InputDecoration(
                        labelText: 'Description (optional)',
                        hintText: 'What this snippet does',
                        prefixIcon: Icon(Icons.description),
                      ),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 16),

                    DropdownButtonFormField<int?>(
                      key: ValueKey(
                        'snippet-folder-$_selectedFolderId-'
                        '$_folderDropdownRevision-${_folders.length}',
                      ),
                      initialValue:
                          _folders.any(
                            (folder) => folder.id == _selectedFolderId,
                          )
                          ? _selectedFolderId
                          : null,
                      decoration: const InputDecoration(
                        labelText: 'Folder (optional)',
                        prefixIcon: Icon(Icons.folder_outlined),
                      ),
                      items: [
                        const DropdownMenuItem<int?>(child: Text('No folder')),
                        ..._folders.map(
                          (folder) => DropdownMenuItem<int?>(
                            value: folder.id,
                            child: Text(folder.name),
                          ),
                        ),
                        const DropdownMenuItem<int?>(
                          value: _createFolderDropdownValue,
                          child: Text('Create folder...'),
                        ),
                      ],
                      onChanged: _handleFolderChanged,
                    ),
                    const SizedBox(height: 16),

                    // Content
                    TextFormField(
                      controller: _contentController,
                      decoration: const InputDecoration(
                        labelText: 'Command',
                        hintText: 'docker restart {{container}}',
                        alignLabelWithHint: true,
                      ),
                      maxLines: 6,
                      style: FluttyTheme.monoStyle.copyWith(fontSize: 14),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Please enter a command';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Use {{variable}} placeholders. Examples: '
                      '{{container}}, {{branch}}, {{log_file}}.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Variable preview
                    _buildVariablePreview(),
                    const SizedBox(height: 32),

                    // Save button
                    FilledButton.icon(
                      onPressed: _saveSnippet,
                      icon: const Icon(Icons.save),
                      label: Text(isEditing ? 'Save Changes' : 'Add Snippet'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  bool get _hasUnsavedChanges {
    final initialDraft = _initialDraft;
    return initialDraft != null && _currentDraft() != initialDraft;
  }

  _SnippetEditDraft _currentDraft() => (
    name: _nameController.text,
    command: _contentController.text,
    description: _descriptionController.text,
    selectedFolderId: _selectedFolderId,
  );

  void _handleFolderChanged(int? value) {
    if (value == _createFolderDropdownValue) {
      unawaited(_createFolderFromDropdown());
      return;
    }
    setState(() => _selectedFolderId = value);
  }

  Future<void> _createFolderFromDropdown() async {
    setState(() => _folderDropdownRevision += 1);
    final name = await showCreateSnippetFolderDialog(context);
    if (name == null || !mounted) {
      if (mounted) {
        setState(() => _folderDropdownRevision += 1);
      }
      return;
    }

    try {
      final repo = ref.read(snippetRepositoryProvider);
      final folderId = await repo.insertFolder(
        SnippetFoldersCompanion.insert(name: name),
      );
      final folders = await repo.getAllFolders();
      if (!mounted) {
        return;
      }
      setState(() {
        _folders = folders;
        _selectedFolderId = folderId;
        _folderDropdownRevision += 1;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Created folder "$name"')));
    } on Exception catch (e) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          library: 'snippets',
          context: ErrorDescription('while creating a snippet folder'),
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not create folder. Try again.')),
        );
        setState(() => _folderDropdownRevision += 1);
      }
    }
  }

  void _closeWithoutUnsavedPrompt(SnackBar snackBar) {
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _initialDraft = _currentDraft();
      _isLoading = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      context.pop();
      messenger.showSnackBar(snackBar);
    });
  }

  Widget _buildVariablePreview() {
    final content = _contentController.text;
    final variables = _extractVariables(content);

    if (variables.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Variables', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: variables
                  .map(
                    (v) => Chip(
                      label: Text(v),
                      visualDensity: VisualDensity.compact,
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  List<String> _extractVariables(String content) {
    final regex = RegExp(r'\{\{(\w+)\}\}');
    final matches = regex.allMatches(content);
    return matches.map((m) => m.group(1)!).toSet().toList();
  }

  Future<void> _saveSnippet() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);
    var didScheduleClose = false;

    try {
      final repo = ref.read(snippetRepositoryProvider);
      final description = _descriptionController.text.isEmpty
          ? null
          : _descriptionController.text;

      if (widget.snippetId != null && _existingSnippet != null) {
        // Update existing snippet
        await repo.update(
          _existingSnippet!.copyWith(
            name: _nameController.text,
            command: _contentController.text,
            description: drift.Value(description),
            folderId: drift.Value(_selectedFolderId),
          ),
        );
      } else {
        // Create new snippet
        await repo.insert(
          SnippetsCompanion.insert(
            name: _nameController.text,
            command: _contentController.text,
            description: drift.Value(description),
            folderId: drift.Value(_selectedFolderId),
          ),
        );
        unawaited(
          ref
              .read(telemetryServiceProvider)
              .logSnippetCreated(
                method: widget.prefill.command == null
                    ? 'manual'
                    : 'from_terminal',
              ),
        );
      }

      if (mounted) {
        didScheduleClose = true;
        _closeWithoutUnsavedPrompt(
          SnackBar(
            content: Text(
              widget.snippetId != null ? 'Snippet updated' : 'Snippet added',
            ),
          ),
        );
      }
    } on Exception catch (e) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          library: 'snippets',
          context: ErrorDescription('while saving a snippet'),
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save snippet. Try again.')),
        );
      }
    } finally {
      if (mounted && !didScheduleClose) setState(() => _isLoading = false);
    }
  }

  void _showVariablesHelp() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Variable Substitution'),
        content: const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Use {{variable}} syntax to create placeholders.'),
              SizedBox(height: 16),
              Text('Examples:', style: TextStyle(fontWeight: FontWeight.bold)),
              SizedBox(height: 8),
              Text('• ssh {{user}}@{{host}}'),
              Text('• tail -f {{log_file}}'),
              Text('• docker restart {{container}}'),
              Text('• git pull && {{restart_command}}'),
              SizedBox(height: 16),
              Text('When executing, you\'ll be prompted to fill in values.'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }
}
