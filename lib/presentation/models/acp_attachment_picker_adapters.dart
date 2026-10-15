import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;

import '../../domain/models/acp_attachment.dart';
import '../screens/sftp_screen.dart';

/// Adapts a file-picker result without opening any picker UI.
Future<AcpAttachmentCandidate> acpAttachmentCandidateFromPlatformFile(
  PlatformFile file,
) async {
  final name = _safePickedName(file.name, file.path);
  final localPath = file.path;
  if (localPath != null && localPath.isNotEmpty) {
    return AcpAttachmentCandidate.localFile(
      name: name,
      sizeBytes: await file.length(),
      openRead: () => File(localPath).openRead(),
      localPath: localPath,
    );
  }
  try {
    return AcpAttachmentCandidate.memory(
      name: name,
      bytes: await file.readAsBytes(),
    );
  } on Object {
    throw const AcpAttachmentException(
      AcpAttachmentFailure.unreadable,
      'A selected local file could not be read.',
    );
  }
}

/// Adapts an image-picker result without opening any picker UI.
Future<AcpAttachmentCandidate> acpAttachmentCandidateFromXFile(
  XFile file, {
  String? displayName,
}) async {
  final name = _safePickedName(displayName ?? file.name, file.path);
  int sizeBytes;
  try {
    sizeBytes = await file.length();
  } on Object {
    throw const AcpAttachmentException(
      AcpAttachmentFailure.unreadable,
      'A selected local file could not be read.',
    );
  }
  return AcpAttachmentCandidate.localFile(
    name: name,
    sizeBytes: sizeBytes,
    mimeType: file.mimeType,
    openRead: file.openRead,
    localPath: file.path.isEmpty ? null : file.path,
  );
}

/// Adapts an existing SFTP selection without downloading its content.
AcpAttachmentCandidate acpAttachmentCandidateFromRemoteFileSelection(
  RemoteFileSelection selection,
) => AcpAttachmentCandidate.remoteFile(
  name: selection.displayName,
  remotePath: selection.remotePath,
  sizeBytes: selection.sizeBytes,
  mimeType: selection.mimeType,
);

String _safePickedName(String pickerName, String? localPath) {
  final candidate = pickerName.trim().isNotEmpty
      ? pickerName.trim()
      : path.basename(localPath ?? '');
  final name = candidate.split(RegExp(r'[/\\]')).last;
  return name.isEmpty ? 'selected-file' : name;
}
