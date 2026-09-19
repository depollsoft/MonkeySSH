import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import '../../domain/services/remote_file_service.dart';

/// Largest file the SFTP browser will preview inline.
const maxSftpPreviewBytes = 10 * 1024 * 1024;

/// Maximum remote video size cached for inline preview playback.
const maxRemoteVideoPreviewBytes = 100 * 1024 * 1024;

const _sftpHighlightedFileScrollPadding = 16.0;

const _sftpOperationTimeout = Duration(seconds: 10);

/// Maximum remote text file size accepted by the editor.
const maxSftpEditableBytes = 1024 * 1024;

/// Bounds SFTP operations so stale SSH channels don't leave the browser loading
/// forever.
Future<T> withSftpOperationTimeout<T>(
  Future<T> operation, {
  Duration timeout = _sftpOperationTimeout,
}) => operation.timeout(
  timeout,
  onTimeout: () {
    throw TimeoutException('SFTP operation timed out', timeout);
  },
);

/// User-facing timeout message for SFTP operations.
String sftpTimeoutMessage(String action) =>
    'Timed out $action. The SSH connection may be stale; reconnect and try again.';

/// Sums picker-reported sizes, or `null` when any file's length is unknown.
Future<int?> selectedUploadSizeBytes(List<PlatformFile> files) async {
  var total = 0;
  try {
    for (final file in files) {
      final size = await file.length();
      if (size == null || size < 0) {
        return null;
      }
      total += size;
    }
  } on Object {
    return null;
  }
  return total;
}

/// Returns the parent directory for a remote SFTP path.
String parentRemotePath(String remotePath) => parentSftpPath(remotePath);

/// A single clickable segment in the SFTP breadcrumb row.
typedef SftpBreadcrumbItem = ({String path, String label});

/// Builds clickable breadcrumb segments for an SFTP path.
List<SftpBreadcrumbItem> buildSftpBreadcrumbItems(String remotePath) {
  final normalizedPath = normalizeSftpAbsolutePath(remotePath) ?? remotePath;
  final root = sftpPathRoot(normalizedPath) ?? '/';
  final items = <SftpBreadcrumbItem>[(path: root, label: root)];
  if (normalizedPath == root) {
    return items;
  }

  final relativePath = root == '/'
      ? normalizedPath.replaceFirst(RegExp('^/+'), '')
      : normalizedPath.substring(root.length);
  var pathSoFar = root;
  for (final part in relativePath.split('/')) {
    if (part.isEmpty) {
      continue;
    }
    pathSoFar = joinRemotePath(pathSoFar, part);
    items.add((path: pathSoFar, label: part));
  }
  return items;
}

/// Appends a visited remote path to browser history without duplicating the top.
List<String> pushSftpPathHistory(List<String> history, String remotePath) {
  final nextHistory = List<String>.from(history);
  if (nextHistory.isEmpty || nextHistory.last != remotePath) {
    nextHistory.add(remotePath);
  }
  return nextHistory;
}

/// Pops browser history while always retaining at least one location.
List<String> popSftpPathHistory(List<String> history) {
  if (history.length <= 1) {
    return history.isEmpty ? ['/'] : List<String>.from(history);
  }
  return List<String>.from(history)..removeLast();
}

/// Resolves the list offset needed to reveal a highlighted file row.
double resolveSftpHighlightedFileScrollOffset({
  required int highlightedIndex,
  required double currentOffset,
  required double itemExtentEstimate,
  required double viewportExtent,
  required double maxScrollExtent,
  double padding = _sftpHighlightedFileScrollPadding,
}) {
  final itemTop = highlightedIndex * itemExtentEstimate;
  final itemBottom = itemTop + itemExtentEstimate;
  final viewportTop = currentOffset;
  final viewportBottom = currentOffset + viewportExtent;

  if (itemTop - padding < viewportTop) {
    return (itemTop - padding).clamp(0.0, maxScrollExtent);
  }
  if (itemBottom + padding > viewportBottom) {
    return (itemBottom + padding - viewportExtent).clamp(0.0, maxScrollExtent);
  }
  return currentOffset.clamp(0.0, maxScrollExtent);
}

/// Resolves how a requested path should open in the browser.
({String directoryPath, String? highlightedFileName})
resolveRequestedSftpNavigationTarget(
  String normalizedPath, {
  required bool isDirectory,
}) => (
  directoryPath: isDirectory
      ? normalizedPath
      : parentRemotePath(normalizedPath),
  highlightedFileName: isDirectory ? null : path.posix.basename(normalizedPath),
);

/// Resolves quick-jump locations for the SFTP browser.
List<String> resolveSftpLocationShortcuts({
  String? homeDirectory,
  String? connectionStartDirectory,
  String? tmuxPaneDirectory,
}) {
  final shortcuts = <String>[];

  void addShortcut(String? directory) {
    final normalizedDirectory = normalizeSftpAbsolutePath(directory);
    if (normalizedDirectory == null ||
        shortcuts.contains(normalizedDirectory)) {
      return;
    }
    shortcuts.add(normalizedDirectory);
  }

  addShortcut(homeDirectory);
  addShortcut(connectionStartDirectory);
  addShortcut(tmuxPaneDirectory);

  return shortcuts;
}

/// Whether the file name should be previewable as an image.
bool isPreviewableImageFileName(String filename) {
  final extension = path.extension(filename).toLowerCase();
  return {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
    '.svg',
  }.contains(extension);
}

/// Whether the file name is an SVG image.
bool isSvgFileName(String filename) =>
    path.extension(filename).toLowerCase() == '.svg';

/// Returns the best-effort MIME type for a remote file name.
///
/// Only types already recognized by the SFTP preview helpers are inferred.
String? inferRemoteFileMimeType(String filename) {
  final extension = path.extension(filename).toLowerCase();
  switch (extension) {
    case '.png':
      return 'image/png';
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    case '.gif':
      return 'image/gif';
    case '.webp':
      return 'image/webp';
    case '.bmp':
      return 'image/bmp';
    case '.svg':
      return 'image/svg+xml';
    default:
      return remoteVideoMimeTypeForFileName(filename);
  }
}

/// Whether the file name should be previewable as a video.
bool isPreviewableVideoFileName(String filename) {
  final extension = path.extension(filename).toLowerCase();
  return {'.mp4', '.mov', '.m4v', '.webm'}.contains(extension);
}

/// Returns the best-effort MIME type for a previewable video file name.
String? remoteVideoMimeTypeForFileName(String filename) =>
    switch (path.extension(filename).toLowerCase()) {
      '.mp4' => 'video/mp4',
      '.mov' => 'video/quicktime',
      '.m4v' => 'video/x-m4v',
      '.webm' => 'video/webm',
      _ => null,
    };

/// Whether a known remote video size is allowed for inline preview caching.
bool isRemoteVideoPreviewSizeAllowed(
  int? sizeBytes, {
  int maxBytes = maxRemoteVideoPreviewBytes,
}) => sizeBytes == null || sizeBytes <= maxBytes;

/// Describes why a remote video is too large for inline preview.
String remoteVideoPreviewTooLargeMessage({
  int? sizeBytes,
  int maxBytes = maxRemoteVideoPreviewBytes,
}) {
  final sizeDetail = sizeBytes == null
      ? 'It exceeded the streaming limit'
      : 'It is ${formatRemoteFileSize(sizeBytes)}';
  return 'Video is too large to preview here. $sizeDetail; '
      'the preview limit is ${formatRemoteFileSize(maxBytes)}. '
      'Download it instead.';
}

/// The preview type supported by the SFTP browser for a file.
enum SftpPreviewKind {
  /// Image preview.
  image,

  /// Video preview.
  video,
}

/// Resolves the available preview kind for an SFTP entry.
SftpPreviewKind? resolveSftpPreviewKind({
  required bool isDirectory,
  required String filename,
}) {
  if (isDirectory) {
    return null;
  }
  if (isPreviewableImageFileName(filename)) {
    return SftpPreviewKind.image;
  }
  if (isPreviewableVideoFileName(filename)) {
    return SftpPreviewKind.video;
  }
  return null;
}

/// Resolves the icon shown for an SFTP file row.
IconData resolveSftpFileIcon({
  required bool isDirectory,
  required String filename,
}) {
  if (isDirectory) {
    return Icons.folder;
  }
  if (isPreviewableImageFileName(filename)) {
    return Icons.image;
  }
  if (isPreviewableVideoFileName(filename)) {
    return Icons.video_file;
  }

  final ext = filename.split('.').last.toLowerCase();
  return switch (ext) {
    'txt' || 'md' || 'log' => Icons.description,
    'pdf' => Icons.picture_as_pdf,
    'mp3' || 'wav' || 'flac' => Icons.audio_file,
    'zip' || 'tar' || 'gz' || 'rar' => Icons.archive,
    'sh' || 'bash' => Icons.terminal,
    'py' || 'js' || 'dart' || 'java' || 'go' => Icons.code,
    'json' || 'yaml' || 'yml' || 'xml' => Icons.data_object,
    _ => Icons.insert_drive_file,
  };
}

/// Builds the shell-safe clipboard text for SFTP "Copy as path".
String buildSftpCopyPathClipboardText({
  required String directory,
  required String filename,
}) => shellEscapePosix(joinRemotePath(directory, filename));

/// Returns a user-facing image preview block reason, if preview should stop.
String? resolveSftpImagePreviewBlockMessage({required int byteCount}) =>
    byteCount > maxSftpPreviewBytes
    ? 'File is too large to preview here (max 10 MB)'
    : null;

/// Returns a user-facing text edit block reason, if editing should stop.
String? resolveSftpTextEditBlockMessage({
  required int byteCount,
  Uint8List? loadedBytes,
}) {
  if (byteCount > maxSftpEditableBytes) {
    return 'File is too large to edit here (max 1 MB)';
  }
  if (loadedBytes != null && looksLikeBinaryContent(loadedBytes)) {
    return 'Binary files cannot be edited here';
  }
  return null;
}

/// Formats a remote modified time stored as seconds since the Unix epoch.
String? formatRemoteModifiedTime(int? modifyTime) {
  if (modifyTime == null) {
    return null;
  }
  return DateTime.fromMillisecondsSinceEpoch(modifyTime * 1000)
      .toString()
      .split('.')
      .first;
}

/// Returns an error when a picker-provided upload name is not a single file.
String? validateSftpUploadFileName(String name) {
  final trimmedName = name.trim();
  if (trimmedName.isEmpty) {
    return 'File name is required';
  }
  if (trimmedName == '.' || trimmedName == '..') {
    return 'File name cannot be a navigation shortcut';
  }
  if (name.contains('/') || name.contains(r'\') || name.contains('\x00')) {
    return 'File name cannot contain path separators';
  }
  return null;
}

/// Resolves the message shown when selected uploads contain unsafe names.
String resolveUnsafeSftpUploadNameMessage(List<PlatformFile> files) =>
    files.length == 1
    ? 'The selected file has an unsafe name'
    : '${files.length} selected files have unsafe names';

/// Returns a validation error for a new remote folder name, or null if valid.
String? validateSftpDirectoryName(String name) {
  final trimmedName = name.trim();
  if (trimmedName.isEmpty) {
    return 'Folder name is required';
  }
  if (trimmedName == '.' || trimmedName == '..') {
    return 'Choose a folder name, not a navigation shortcut';
  }
  if (trimmedName.contains('/')) {
    return 'Folder name cannot contain /';
  }
  return null;
}

/// Formats the snackbar message shown after copying a remote path.
String sftpCopyPathSnackBarMessage(String remotePath) =>
    'Copied shell-safe path for "$remotePath"';

/// Formats the snackbar message shown after creating a remote folder.
String sftpCreatedDirectorySnackBarMessage(String remotePath) =>
    'Created folder "$remotePath"';

/// How a file row tap should behave in the SFTP browser.
enum SftpFileTapIntent {
  /// Navigate into a tapped directory.
  navigate,

  /// Preview a tapped image file.
  preview,

  /// Preview a tapped video file.
  previewVideo,

  /// Open a tapped non-image file in the editor.
  edit,
}

/// Resolves the primary action for tapping an SFTP entry.
SftpFileTapIntent resolveSftpFileTapIntent({
  required bool isDirectory,
  required String filename,
}) {
  if (isDirectory) {
    return SftpFileTapIntent.navigate;
  }
  switch (resolveSftpPreviewKind(isDirectory: false, filename: filename)) {
    case SftpPreviewKind.image:
      return SftpFileTapIntent.preview;
    case SftpPreviewKind.video:
      return SftpFileTapIntent.previewVideo;
    case null:
      return SftpFileTapIntent.edit;
  }
}

/// Immutable metadata for a remote file selected from SFTP.
///
/// Picker results preserve the order in which the user selected them.
@immutable
class RemoteFileSelection {
  /// Creates a [RemoteFileSelection].
  const RemoteFileSelection({
    required this.remotePath,
    required this.displayName,
    this.sizeBytes,
    this.mimeType,
  });

  /// Absolute remote path reported by SFTP.
  final String remotePath;

  /// File name shown to the user.
  final String displayName;

  /// File size in bytes when the remote listing reports it.
  final int? sizeBytes;

  /// Best-effort MIME type inferred from the file name.
  final String? mimeType;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RemoteFileSelection &&
          other.remotePath == remotePath &&
          other.displayName == displayName &&
          other.sizeBytes == sizeBytes &&
          other.mimeType == mimeType;

  @override
  int get hashCode => Object.hash(remotePath, displayName, sizeBytes, mimeType);
}

/// Returns null when a remote file can be selected, or a short user-facing
/// reason when it should remain visible but unavailable.
typedef RemoteFileSelectionAvailability = String? Function(
  RemoteFileSelection file,
);

/// Configures SFTP remote-file selection mode.
///
/// When [allowMultiple] is false, the picker behaves as single selection. When
/// [allowMultiple] is true, [maxSelectionCount] can cap the number of selected
/// files. Use [selectionAvailability] to keep files visible while explaining
/// why a file is unavailable.
@immutable
class RemoteFilePickerConstraints {
  /// Creates [RemoteFilePickerConstraints].
  const RemoteFilePickerConstraints({
    this.allowMultiple = false,
    this.maxSelectionCount,
    this.selectionAvailability,
  }) : assert(
         maxSelectionCount == null || maxSelectionCount > 0,
         'maxSelectionCount must be greater than zero when provided.',
       ),
       assert(
         allowMultiple || maxSelectionCount == null || maxSelectionCount == 1,
         'Single selection only supports a maximum count of 1.',
       );

  /// Whether the picker can keep more than one file selected at a time.
  final bool allowMultiple;

  /// Maximum selected file count when [allowMultiple] is true.
  final int? maxSelectionCount;

  /// Optional availability check for each listed remote file.
  ///
  /// Return null to allow selection, or a short explanation to keep the file
  /// visible but disabled.
  final RemoteFileSelectionAvailability? selectionAvailability;
}

/// Toggles a remote file selection while preserving selection order.
List<RemoteFileSelection> toggleRemoteFileSelection({
  required List<RemoteFileSelection> currentSelection,
  required RemoteFileSelection file,
  required bool allowMultiple,
}) {
  final nextSelection = List<RemoteFileSelection>.from(currentSelection);
  final existingIndex = nextSelection.indexWhere(
    (entry) => entry.remotePath == file.remotePath,
  );
  if (existingIndex >= 0) {
    nextSelection.removeAt(existingIndex);
    return nextSelection;
  }
  if (!allowMultiple) {
    return [file];
  }
  nextSelection.add(file);
  return nextSelection;
}

/// Describes why a remote file is unavailable for selection.
String? resolveRemoteFileSelectionDisabledReason({
  required RemoteFilePickerConstraints constraints,
  required List<RemoteFileSelection> currentSelection,
  required RemoteFileSelection candidate,
}) {
  final customReason = constraints.selectionAvailability?.call(candidate);
  if (customReason != null) {
    return customReason;
  }

  if (!constraints.allowMultiple) {
    return null;
  }

  final maxSelectionCount = constraints.maxSelectionCount;
  final isSelected = currentSelection.any(
    (entry) => entry.remotePath == candidate.remotePath,
  );
  if (!isSelected &&
      maxSelectionCount != null &&
      currentSelection.length >= maxSelectionCount) {
    return maxSelectionCount == 1
        ? 'You can select up to 1 file.'
        : 'You can select up to $maxSelectionCount files.';
  }

  return null;
}

/// Builds the spoken label for a remote-file selection row.
String remoteFileSelectionSemanticsLabel({
  required bool isDirectory,
  required String fileName,
  required bool isSelected,
  String? disabledReason,
}) {
  if (isDirectory) {
    return 'Open folder $fileName';
  }
  if (disabledReason != null) {
    return 'Unavailable remote file $fileName';
  }
  if (isSelected) {
    return 'Deselect remote file $fileName';
  }
  return 'Select remote file $fileName';
}

/// Builds the spoken hint for a remote-file selection row.
String remoteFileSelectionSemanticsHint({
  required bool isDirectory,
  required bool isSelected,
  String? disabledReason,
}) {
  if (isDirectory) {
    return 'Opens this folder.';
  }
  if (disabledReason != null) {
    return disabledReason;
  }
  if (isSelected) {
    return 'Removes this file from the current selection.';
  }
  return 'Adds this file to the current selection.';
}

/// Builds the touch tooltip for a remote-file selection row.
String? remoteFileSelectionTooltip({
  required bool isDirectory,
  required String fileName,
  required bool isSelected,
  String? disabledReason,
}) {
  if (isDirectory) {
    return null;
  }
  if (disabledReason != null) {
    return '$fileName is unavailable: $disabledReason';
  }
  return isSelected ? 'Deselect $fileName' : 'Select $fileName';
}
