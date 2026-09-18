import 'package:flutter/material.dart';

/// Shows a dialog that prompts for a new snippet folder name.
Future<String?> showCreateSnippetFolderDialog(BuildContext context) =>
    showDialog<String>(
      context: context,
      builder: (context) => const _CreateSnippetFolderDialog(),
    );

class _CreateSnippetFolderDialog extends StatefulWidget {
  const _CreateSnippetFolderDialog();

  @override
  State<_CreateSnippetFolderDialog> createState() =>
      _CreateSnippetFolderDialogState();
}

class _CreateSnippetFolderDialogState
    extends State<_CreateSnippetFolderDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New Folder'),
    content: Form(
      key: _formKey,
      child: TextFormField(
        controller: _nameController,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Folder name',
          hintText: 'Deployment',
        ),
        textInputAction: TextInputAction.done,
        onFieldSubmitted: (_) => _submit(),
        validator: (value) {
          final name = value?.trim() ?? '';
          if (name.isEmpty) {
            return 'Please enter a folder name';
          }
          if (name.length > 255) {
            return 'Name must be 255 characters or fewer';
          }
          return null;
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Create')),
    ],
  );

  void _submit() {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    Navigator.pop(context, _nameController.text.trim());
  }
}
