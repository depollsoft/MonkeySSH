import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/app_metadata.dart';
import '../../app/theme.dart';
import '../../domain/services/auth_service.dart';
import '../../domain/services/secure_transfer_service.dart';
import '../widgets/file_picker_helpers.dart';

/// File extension used for encrypted MonkeySSH transfer packages.
const monkeySshTransferFileExtension = 'monkeysshx';

/// MIME type for encrypted transfer packages.
const monkeySshTransferMimeType = 'application/x-monkeyssh-transfer';
const _maxTransferPayloadBytes = 10 * 1024 * 1024;

/// Whether the current platform uses the system share sheet for exports.
///
/// iOS uses the share sheet because Save to Files is exposed as a share target.
///
/// Android uses the system create-document picker instead so users can choose a
/// local Files destination directly.
bool get useShareSheet => useShareSheetForPlatform(defaultTargetPlatform);

/// Returns whether transfer exports should use the share sheet on [platform].
bool useShareSheetForPlatform(TargetPlatform platform, {bool isWeb = kIsWeb}) =>
    !isWeb && platform == TargetPlatform.iOS;

/// Computes the share sheet anchor rect from a widget's [BuildContext].
///
/// Required on iPad where the share popover must attach to a source rect.
Rect? shareOriginFromContext(BuildContext context) {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) {
    return null;
  }
  return box.localToGlobal(Offset.zero) & box.size;
}

/// Exports an encrypted transfer payload.
///
/// On iOS this opens the system share sheet so the user can AirDrop, save to
/// Files, or send via any installed app. Android, desktop, and web use a
/// file-save dialog/create-document picker.
Future<void> saveTransferPayloadToFile({
  required BuildContext context,
  required String payload,
  required String defaultFileName,
  Rect? sharePositionOrigin,
}) async {
  final bytes = Uint8List.fromList(utf8.encode(payload));
  final sanitizedBaseName = sanitizeTransferFileBaseName(defaultFileName);
  final fileName = '$sanitizedBaseName.$monkeySshTransferFileExtension';

  if (useShareSheet) {
    await _sharePayloadViaNativeSheet(
      context: context,
      bytes: bytes,
      fileName: fileName,
      sharePositionOrigin: sharePositionOrigin,
    );
    return;
  }

  await _savePayloadToFileDialog(
    context: context,
    bytes: bytes,
    fileName: fileName,
  );
}

/// Opens the system share sheet with the transfer file attached.
Future<void> _sharePayloadViaNativeSheet({
  required BuildContext context,
  required Uint8List bytes,
  required String fileName,
  Rect? sharePositionOrigin,
}) async {
  final tempDir = await getTemporaryDirectory();
  final tempFile = File(p.join(tempDir.path, fileName));
  try {
    await tempFile.writeAsBytes(bytes, flush: true);
  } on FileSystemException {
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Couldn’t create the transfer file. Check storage space and try again.',
        ),
      ),
    );
    return;
  }

  try {
    if (!context.mounted) {
      return;
    }

    final result = await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile(
            tempFile.path,
            mimeType: monkeySshTransferMimeType,
            name: fileName,
          ),
        ],
        sharePositionOrigin: sharePositionOrigin,
      ),
    );

    if (!context.mounted) {
      return;
    }

    if (result.status == ShareResultStatus.dismissed) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Share cancelled')));
    }
  } on Object catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'transfer',
        context: ErrorDescription('while sharing transfer file'),
      ),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Couldn’t open the share sheet. Try again, or save the file instead.',
          ),
        ),
      );
    }
  } finally {
    try {
      if (tempFile.existsSync()) {
        await tempFile.delete();
      }
    } on FileSystemException {
      // Best-effort cleanup; the OS will reclaim temp storage.
    }
  }
}

/// Saves the transfer payload via a native file-save dialog.
Future<void> _savePayloadToFileDialog({
  required BuildContext context,
  required Uint8List bytes,
  required String fileName,
}) async {
  final appName = await loadAppName();
  try {
    final targetPath = await FilePicker.saveFile(
      dialogTitle: 'Export encrypted $appName transfer file',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: const [monkeySshTransferFileExtension],
      bytes: bytes,
    );
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          targetPath == null
              ? 'Export cancelled'
              : 'Encrypted file saved: $targetPath',
        ),
      ),
    );
  } on Exception {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Couldn’t write the transfer file. Free up space and try again.',
          ),
        ),
      );
    }
  }
}

/// Imports payload content from an encrypted transfer file.
Future<String?> pickTransferPayloadFromFile(BuildContext context) async {
  final appName = await loadAppName();
  final selectedFile = await FilePicker.pickFile(
    dialogTitle: 'Select encrypted $appName transfer file',
    type: pickerFileTypeForCustomExtension(defaultTargetPlatform),
    allowedExtensions: pickerAllowedExtensionsForCustomExtension(
      defaultTargetPlatform,
      const [monkeySshTransferFileExtension],
    ),
  );

  if (selectedFile == null) {
    return null;
  }

  if (!platformFileMatchesExpectedExtension(
    selectedFile,
    monkeySshTransferFileExtension,
  )) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a .monkeysshx transfer file')),
      );
    }
    return null;
  }

  String message;
  try {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in selectedFile.readAsByteStream()) {
      if (bytes.length + chunk.length > _maxTransferPayloadBytes) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Transfer file is too large')),
          );
        }
        return null;
      }
      bytes.add(chunk);
    }
    if (bytes.isEmpty) {
      throw const FileSystemException('Empty transfer file');
    }
    return utf8.decode(bytes.takeBytes());
  } on FormatException {
    message =
        'That isn’t a valid MonkeySSH transfer file. Export it again from MonkeySSH.';
  } on Exception {
    message =
        'Couldn’t read that file. Pick a .monkeysshx file exported from MonkeySSH.';
  }
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
  return null;
}

/// Dialog that asks for transfer passphrase.
Future<String?> showTransferPassphraseDialog({
  required BuildContext context,
  required String title,
}) async {
  final value = await showDialog<String>(
    context: context,
    builder: (context) => _TransferPassphraseDialog(title: title),
  );

  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  return trimmed;
}

class _TransferPassphraseDialog extends StatefulWidget {
  const _TransferPassphraseDialog({required this.title});

  final String title;

  @override
  State<_TransferPassphraseDialog> createState() =>
      _TransferPassphraseDialogState();
}

class _TransferPassphraseDialogState extends State<_TransferPassphraseDialog> {
  final _controller = TextEditingController();
  var _obscureText = true;

  @override
  void dispose() {
    // The TextField still needs its controller during the route's exit animation.
    _controller
      ..clear()
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _controller,
      autofocus: true,
      obscureText: _obscureText,
      decoration: InputDecoration(
        labelText: 'Transfer passphrase',
        helperText: 'Required to encrypt/decrypt transfer data',
        suffixIcon: IconButton(
          onPressed: () => setState(() => _obscureText = !_obscureText),
          icon: Icon(_obscureText ? Icons.visibility : Icons.visibility_off),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text.trim()),
        child: const Text('Continue'),
      ),
    ],
  );
}

/// Requests local authentication for sensitive transfer exports.
Future<bool> authorizeSensitiveTransferExport({
  required BuildContext context,
  required AuthService authService,
  required AuthState Function() readAuthState,
  required String reason,
}) async {
  final isAuthEnabled = await authService.isAuthEnabled();
  if (!isAuthEnabled || !context.mounted) {
    return true;
  }

  AuthMethod method;
  try {
    method = await authService.getAuthMethod();
  } on Object catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'auth',
        context: ErrorDescription(
          'while determining the available authentication method for sensitive transfers',
        ),
      ),
    );
    return false;
  }
  if (!context.mounted) {
    return false;
  }

  switch (method) {
    case AuthMethod.none:
      return true;
    case AuthMethod.biometric:
      final biometricSuccess = await authService.authenticateWithBiometrics(
        reason: reason,
      );
      if (!_isSensitiveTransferAuthSessionUnlocked(readAuthState)) {
        return false;
      }
      return biometricSuccess;
    case AuthMethod.pin:
      final pin = await _showPinDialog(context);
      if (pin == null) {
        return false;
      }
      return authService.verifyPin(pin);
    case AuthMethod.both:
      final biometricSuccess = await authService.authenticateWithBiometrics(
        reason: reason,
      );
      if (!_isSensitiveTransferAuthSessionUnlocked(readAuthState)) {
        return false;
      }
      if (biometricSuccess) {
        return true;
      }
      if (!context.mounted) {
        return false;
      }
      final pin = await _showPinDialog(context);
      if (pin == null) {
        return false;
      }
      return authService.verifyPin(pin);
  }
}

bool _isSensitiveTransferAuthSessionUnlocked(
  AuthState Function() readAuthState,
) => readAuthState() == AuthState.unlocked;

Future<String?> _showPinDialog(BuildContext context) async {
  final controller = TextEditingController();
  try {
    return await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enter PIN'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'PIN'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  } finally {
    controller
      ..clear()
      ..dispose();
  }
}

/// Shared merge/replace mode chooser for migration imports.
Future<MigrationImportMode?> showMigrationImportModeDialog({
  required BuildContext context,
  required MigrationPreview preview,
  required String title,
  String message = 'Choose how to apply imported data.',
}) async => showDialog<MigrationImportMode>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(title),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DefaultTextStyle.merge(
          style: FluttyTheme.monoStyle,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Settings: ${preview.settingsCount}'),
              Text('Hosts: ${preview.hostCount}'),
              Text('Keys: ${preview.keyCount}'),
              Text('Groups: ${preview.groupCount}'),
              Text('Snippets: ${preview.snippetCount}'),
              Text('Snippet folders: ${preview.snippetFolderCount}'),
              Text('Port forwards: ${preview.portForwardCount}'),
              Text('Known hosts: ${preview.knownHostCount}'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(message),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      OutlinedButton(
        onPressed: () => Navigator.pop(context, MigrationImportMode.merge),
        child: const Text('Merge'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, MigrationImportMode.replace),
        child: const Text('Replace'),
      ),
    ],
  ),
);

/// Shows a confirmation dialog before importing a decrypted host or key.
Future<bool> showTransferPayloadImportConfirmationDialog({
  required BuildContext context,
  required TransferPayload payload,
}) async {
  final details = switch (payload.type) {
    TransferPayloadType.host => _hostTransferDetails(payload),
    TransferPayloadType.key => _keyTransferDetails(payload),
    TransferPayloadType.fullMigration => const <String>[],
  };
  if (details.isEmpty) {
    return true;
  }

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        payload.type == TransferPayloadType.host
            ? 'Import host?'
            : 'Import SSH key?',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Review this decrypted transfer before adding it to MonkeySSH.',
            ),
            const SizedBox(height: 12),
            for (final detail in details)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(detail, style: FluttyTheme.monoStyle),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Import'),
        ),
      ],
    ),
  );

  return confirmed ?? false;
}

List<String> _hostTransferDetails(TransferPayload payload) {
  final host = payload.data['host'];
  if (host is! Map) {
    return const [];
  }
  final label = _displayTransferValue(host['label']);
  final hostname = _displayTransferValue(host['hostname']);
  final username = _displayTransferValue(host['username']);
  final port = _displayTransferValue(host['port'] ?? 22);
  return [
    'Label: $label',
    'Host: $hostname',
    'Port: $port',
    'Username: $username',
  ];
}

List<String> _keyTransferDetails(TransferPayload payload) {
  final key = payload.data['key'];
  if (key is! Map) {
    return const [];
  }
  final name = _displayTransferValue(key['name']);
  final type = _displayTransferValue(key['keyType']);
  final fingerprint = _displayTransferValue(key['fingerprint']);
  return ['Name: $name', 'Type: $type', 'Fingerprint: $fingerprint'];
}

String _displayTransferValue(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? 'Not provided' : text;
}
