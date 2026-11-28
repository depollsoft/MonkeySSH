import 'package:flutter/material.dart';

/// Asks the user to confirm a destructive delete.
///
/// Resolves to `true` only when the user taps **Delete**; dismissing the
/// dialog or tapping **Cancel** resolves to `false`.
Future<bool> showDeleteConfirmationDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Delete',
  bool? requestFocus,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    requestFocus: requestFocus,
    builder: (context) {
      final colorScheme = Theme.of(context).colorScheme;
      return AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: colorScheme.error,
              foregroundColor: colorScheme.onError,
            ),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}
