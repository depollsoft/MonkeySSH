import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../domain/models/terminal_theme.dart' show contrastRatio;
import '../../domain/services/remote_file_edit_session.dart';

/// Lets the remote editor check the host's file before saving and resolve a
/// conflict when something else changed it.
@immutable
class RemoteEditorConflictHandler {
  /// Creates a conflict handler.
  const RemoteEditorConflictHandler({
    required this.checkForChanges,
    required this.overwrite,
    required this.recreate,
    required this.reload,
    required this.saveCopy,
  });

  /// Compares the host's file with the version the editor's text is based
  /// on.
  final Future<RemoteFileChange> Function() checkForChanges;

  /// Writes [text] over the host's file without comparing versions, after
  /// the user chose to overwrite or recreate it.
  final Future<void> Function(String text) overwrite;

  /// Writes [text] to the path of a file that was deleted on the host.
  /// Throws [RemoteFileChangedDuringSaveException] instead of replacing a
  /// file that reappeared meanwhile.
  final Future<void> Function(String text) recreate;

  /// Reads the host's current text and makes it the new base version.
  ///
  /// Throws [RemoteEditorReloadBlockedException] when the host's file can no
  /// longer be edited here.
  final Future<String> Function() reload;

  /// Writes [text] to a new file beside the original and returns the new
  /// file's name.
  final Future<String> Function(String text) saveCopy;
}

/// The host's file can no longer be opened in the editor, for example because
/// it grew past the size limit or is no longer UTF-8 text.
class RemoteEditorReloadBlockedException implements Exception {
  /// Creates the exception with a user-facing [message].
  const RemoteEditorReloadBlockedException(this.message);

  /// Explains why the file cannot be reloaded.
  final String message;

  @override
  String toString() => message;
}

/// Editor route result after the edits were written to a copy instead of the
/// original file.
@immutable
class RemoteEditorSavedCopy {
  /// Creates the result.
  const RemoteEditorSavedCopy(this.fileName);

  /// Name of the new copy, in the original's directory.
  final String fileName;
}

/// How the user chose to resolve a save conflict.
enum RemoteEditorConflictChoice {
  /// Write the edits to a new file beside the original.
  saveCopy,

  /// Discard the edits and load the host's version.
  reload,

  /// Write the edits over the host's version.
  overwrite,
}

/// Asks how to save [fileName] after it changed on the host.
///
/// Returns null when the user cancels.
Future<RemoteEditorConflictChoice?> showRemoteEditorConflictDialog(
  BuildContext context, {
  required String fileName,
  required RemoteFileChange change,
}) => showDialog<RemoteEditorConflictChoice>(
  context: context,
  builder: (context) =>
      _RemoteEditorConflictDialog(fileName: fileName, change: change),
);

/// Confirms that reloading may discard unsaved edits.
Future<bool> confirmRemoteEditorReload(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Discard your edits?'),
      content: const Text(
        'Reloading replaces the editor text with the version on the host. '
        'Your unsaved edits will be lost.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Keep editing'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(dialogContext).colorScheme.error,
            foregroundColor: Theme.of(dialogContext).colorScheme.onError,
          ),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Discard and reload'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

class _RemoteEditorConflictDialog extends StatelessWidget {
  const _RemoteEditorConflictDialog({
    required this.fileName,
    required this.change,
  });

  final String fileName;
  final RemoteFileChange change;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final deleted = change == RemoteFileChange.deleted;
    // Only a changed file can be reloaded or overwritten; a folder or other
    // entry at the path can only be left alone.
    final notAFile = change == RemoteFileChange.notAFile;
    const buttonSize = Size.fromHeight(48);
    void choose(RemoteEditorConflictChoice choice) =>
        Navigator.of(context).pop(choice);
    final (icon, title, explanation) = switch (change) {
      RemoteFileChange.deleted => (
        Icons.delete_outline,
        'File deleted on the host',
        'It was deleted or moved after you opened it. Recreate it with your '
            'edits, or keep them in a new file.',
      ),
      RemoteFileChange.notAFile => (
        Icons.folder_outlined,
        'No longer a file',
        'The path is now a folder or another kind of entry, so your edits '
            'cannot be saved over it. Keep them in a new file.',
      ),
      _ => (
        Icons.sync_problem,
        'File changed on the host',
        'It changed after you opened it, possibly by an agent or another '
            'editor. Reloading discards your edits; overwriting discards the '
            "host's changes.",
      ),
    };
    final dialogBackground =
        DialogTheme.of(context).backgroundColor ??
        colorScheme.surfaceContainerHigh;

    return AlertDialog(
      // Stacked full-width buttons would otherwise stretch across a tablet.
      constraints: const BoxConstraints(minWidth: 280, maxWidth: 420),
      icon: Icon(icon),
      iconColor: colorScheme.onSurfaceVariant,
      title: Text(title),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The name is machine text, so it keeps the mono voice, on a line
          // of its own so a long name never splits the sentence.
          Text(
            fileName,
            style: FluttyTheme.monoStyle.copyWith(color: colorScheme.onSurface),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Text(explanation),
          const SizedBox(height: 24),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: buttonSize),
            icon: const Icon(Icons.file_copy_outlined),
            label: const Text('Save as a copy'),
            onPressed: () => choose(RemoteEditorConflictChoice.saveCopy),
          ),
          const SizedBox(height: 8),
          if (!deleted && !notAFile) ...[
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: buttonSize),
              icon: const Icon(Icons.refresh),
              label: const Text('Reload from host'),
              onPressed: () => choose(RemoteEditorConflictChoice.reload),
            ),
            const SizedBox(height: 8),
          ],
          if (!notAFile) ...[
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: buttonSize,
                foregroundColor: deleted
                    ? null
                    : readableDestructiveColor(colorScheme, dialogBackground),
              ),
              icon: Icon(deleted ? Icons.save_outlined : Icons.warning_amber),
              label: Text(deleted ? 'Recreate file' : 'Overwrite host file'),
              onPressed: () => choose(RemoteEditorConflictChoice.overwrite),
            ),
            const SizedBox(height: 8),
          ],
          TextButton(
            // Neutral, so the filled button stays the dialog's one signal.
            style: TextButton.styleFrom(
              minimumSize: buttonSize,
              foregroundColor: colorScheme.onSurface,
            ),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

/// The error color, moved toward the text color just far enough to read at
/// 4.5:1 on [background] (the light theme's red is too pale on white).
@visibleForTesting
Color readableDestructiveColor(ColorScheme colorScheme, Color background) {
  final surface = Color.alphaBlend(background, colorScheme.surface);
  final start = Color.alphaBlend(colorScheme.error, surface);
  final ink = Color.alphaBlend(colorScheme.onSurface, surface);
  for (var step = 0; step <= 20; step++) {
    final candidate = Color.lerp(start, ink, step / 20)!;
    if (contrastRatio(candidate, surface) >= 4.5) return candidate;
  }
  return ink;
}
