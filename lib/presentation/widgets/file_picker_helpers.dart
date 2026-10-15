import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../domain/services/diagnostics_log_service.dart';

const _defaultFileBaseName = 'monkeyssh-transfer';

/// Normalizes a suggested export filename into a filesystem-safe base.
String sanitizeTransferFileBaseName(String input) {
  final normalized = input
      .trim()
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '-')
      .replaceAll(RegExp(r'\s+'), '-')
      .replaceAll(RegExp('-+'), '-')
      .replaceAll(RegExp(r'^\.+|\.+$'), '')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return normalized.isEmpty ? _defaultFileBaseName : normalized;
}

/// Opens the single-file picker, or returns null after a snackbar if it fails.
///
/// Android pickers report a busy picker or a missing document provider as a
/// [PlatformException] instead of a cancelled selection.
Future<PlatformFile?> pickSingleFileOrNotify(
  BuildContext context, {
  required String diagnosticsCategory,
  String? dialogTitle,
  FileType type = FileType.any,
  List<String>? allowedExtensions,
}) async {
  try {
    return await FilePicker.pickFile(
      dialogTitle: dialogTitle,
      type: type,
      allowedExtensions: allowedExtensions,
    );
  } on Exception catch (error) {
    DiagnosticsLogService.instance.warning(
      diagnosticsCategory,
      'picker_failed',
      fields: {'errorType': error.runtimeType},
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open the file picker. Try again.'),
        ),
      );
    }
    return null;
  }
}

/// Returns the native picker type to use for custom-extension files.
FileType pickerFileTypeForCustomExtension(TargetPlatform platform) =>
    platform == TargetPlatform.iOS ? FileType.any : FileType.custom;

/// Returns the picker extension filter for a custom-extension file selection.
List<String>? pickerAllowedExtensionsForCustomExtension(
  TargetPlatform platform,
  List<String> allowedExtensions,
) => platform == TargetPlatform.iOS ? null : allowedExtensions;

/// Returns whether the selected [file] matches [expectedExtension].
bool platformFileMatchesExpectedExtension(
  PlatformFile file,
  String expectedExtension,
) {
  final normalizedExpectedExtension = expectedExtension
      .toLowerCase()
      .replaceFirst(RegExp(r'^\.'), '');
  final extensionCandidates = <String?>[
    file.extension,
    p.extension(file.name),
    if (file.path case final path?) p.extension(path),
  ];
  return extensionCandidates
      .whereType<String>()
      .map(
        (extension) => extension.toLowerCase().replaceFirst(RegExp(r'^\.'), ''),
      )
      .any((extension) => extension == normalizedExpectedExtension);
}
