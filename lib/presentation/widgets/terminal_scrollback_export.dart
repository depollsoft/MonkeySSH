import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:xterm/xterm.dart';

import '../../domain/services/terminal_scrollback_text.dart';

/// Opens the system share sheet. Replaced in tests.
typedef TerminalScrollbackShareSheet = Future<ShareResult> Function(
  ShareParams params,
);

/// Opens a save-file dialog and returns where the file went, or null when the
/// user cancels. Replaced in tests.
typedef TerminalScrollbackSaveDialog = Future<Uri?> Function({
  required String fileName,
  required Uint8List bytes,
});

/// Whether scrollback export uses the share sheet on [platform]: iOS and
/// Android only. There the share call returns once the target has the file
/// (Android copies it first), so the temporary copy can be deleted. On macOS
/// and Windows share_plus returns while the target may still be reading the
/// file, and Linux and the web cannot share files, so those save through a
/// file dialog instead.
bool terminalScrollbackExportUsesShareSheet(
  TargetPlatform platform, {
  bool isWeb = kIsWeb,
}) =>
    !isWeb &&
    (platform == TargetPlatform.iOS || platform == TargetPlatform.android);

/// How long a leftover export may stay in temporary storage before
/// [cleanUpTerminalScrollbackExports] removes it.
const kTerminalScrollbackExportMaxAge = Duration(minutes: 10);

/// Deletes scrollback exports left in [temporaryDirectory] (the app's
/// temporary directory when null): our own `scrollback-*` directories, and
/// the copy share_plus keeps in `share_plus/` on Android until its next
/// share. Only files older than [maxAge] go, so a share still in progress
/// keeps its file. Returns how many entries were deleted.
Future<int> cleanUpTerminalScrollbackExports({
  Directory? temporaryDirectory,
  Duration maxAge = kTerminalScrollbackExportMaxAge,
  DateTime? now,
}) async {
  final base = temporaryDirectory ?? await getTemporaryDirectory();
  final cutoff = (now ?? DateTime.now()).subtract(maxAge);
  var deleted = 0;

  Future<void> deleteIfStale(FileSystemEntity entity) async {
    try {
      if (entity.statSync().modified.isAfter(cutoff)) {
        return;
      }
      await entity.delete(recursive: true);
      deleted++;
    } on FileSystemException {
      // Best effort: the OS reclaims temporary storage.
    }
  }

  Future<void> sweep(Directory directory, bool Function(String) matches) async {
    if (!directory.existsSync()) {
      return;
    }
    await for (final entity in directory.list(followLinks: false)) {
      if (matches(p.basename(entity.path))) {
        await deleteIfStale(entity);
      }
    }
  }

  try {
    await sweep(base, (name) => name.startsWith('scrollback-'));
    await sweep(
      Directory(p.join(base.path, 'share_plus')),
      (name) =>
          name.startsWith('terminal-scrollback-') && name.endsWith('.txt'),
    );
  } on FileSystemException {
    // Best effort.
  }
  return deleted;
}

/// File name for a scrollback export taken at [time], for example
/// `terminal-scrollback-20261009-153012.txt`. It carries no host or session
/// details.
String terminalScrollbackExportFileName(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  final date = '${time.year}${two(time.month)}${two(time.day)}';
  final clock = '${two(time.hour)}${two(time.minute)}${two(time.second)}';
  return 'terminal-scrollback-$date-$clock.txt';
}

/// Global rect of [context]'s render box, to anchor the share popover on iPad
/// and macOS.
Rect? terminalShareOriginFromContext(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize || !box.attached) {
    return null;
  }
  return box.localToGlobal(Offset.zero) & box.size;
}

Future<ShareResult> _shareWithSystemSheet(ShareParams params) =>
    SharePlus.instance.share(params);

Future<Uri?> _saveWithFileDialog({
  required String fileName,
  required Uint8List bytes,
}) => FilePicker.saveFile(
  dialogTitle: 'Export scrollback',
  fileName: fileName,
  type: FileType.custom,
  allowedExtensions: const ['txt'],
  bytes: bytes,
);

/// Shares the active buffer of [terminal], scrollback included, as a
/// plain-text file.
///
/// The text is what copy would produce: soft-wrapped rows are joined, cell
/// padding is trimmed and the unused rows below the last output are dropped.
/// On the alternate screen (a full-screen app) that is only the visible
/// screen. On iOS and Android the file goes to a private temporary directory
/// that is deleted once the share sheet returns. Android's share_plus keeps
/// its own copy until its next share; [cleanUpTerminalScrollbackExports]
/// removes it at the next app start. Other platforms save through a file
/// dialog.
Future<void> exportTerminalScrollback({
  required BuildContext context,
  required Terminal terminal,
  Rect? sharePositionOrigin,
  DateTime? now,
  TargetPlatform? platform,
  Future<Directory> Function()? temporaryDirectory,
  TerminalScrollbackShareSheet share = _shareWithSystemSheet,
  TerminalScrollbackSaveDialog save = _saveWithFileDialog,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  void showMessage(String message) =>
      messenger?.showSnackBar(SnackBar(content: Text(message)));

  final text = await readTerminalBufferPlainText(terminal.buffer);
  if (text == null || text.isEmpty) {
    showMessage('Nothing to export yet');
    return;
  }
  final fileName = terminalScrollbackExportFileName(now ?? DateTime.now());
  final bytes = Uint8List.fromList(utf8.encode(text));

  if (!terminalScrollbackExportUsesShareSheet(
    platform ?? defaultTargetPlatform,
  )) {
    try {
      // The picker writes the bytes to the chosen path.
      if (await save(fileName: fileName, bytes: bytes) != null) {
        showMessage('Scrollback saved');
      }
    } on Object {
      showMessage('Couldn’t save the scrollback. Try again.');
    }
    return;
  }

  Directory? directory;
  try {
    final base = await (temporaryDirectory ?? getTemporaryDirectory)();
    directory = await base.createTemp('scrollback-');
    final file = File(p.join(directory.path, fileName));
    await file.writeAsBytes(bytes, flush: true);
    await share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'text/plain', name: fileName)],
        title: 'Terminal scrollback',
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  } on Object {
    showMessage('Couldn’t open the share sheet. Try again.');
  } finally {
    try {
      await directory?.delete(recursive: true);
    } on FileSystemException {
      // Best effort: the OS reclaims its temporary directory.
    }
  }
}
