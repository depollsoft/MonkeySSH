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

/// Whether scrollback export uses the share sheet on [platform]. Linux and the
/// web cannot share files, so they save through a file dialog instead.
bool terminalScrollbackExportUsesShareSheet(
  TargetPlatform platform, {
  bool isWeb = kIsWeb,
}) => !isWeb && platform != TargetPlatform.linux;

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
/// screen. The file goes to a private temporary directory that is deleted
/// once the share sheet returns; nothing is kept.
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
