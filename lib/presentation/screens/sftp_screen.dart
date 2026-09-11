import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../app/theme.dart';
import '../../data/repositories/host_repository.dart';
import '../../domain/models/monetization.dart';
import '../../domain/models/terminal_themes.dart';
import '../../domain/services/diagnostics_log_service.dart';
import '../../domain/services/monetization_service.dart';
import '../../domain/services/remote_file_service.dart';
import '../../domain/services/settings_service.dart';
import '../../domain/services/ssh_error_policy.dart';
import '../../domain/services/ssh_service.dart';
import '../../domain/services/telemetry_service.dart';
import '../../domain/services/terminal_theme_service.dart';
import '../widgets/brand_empty_state.dart';
import '../widgets/brand_error_state.dart';
import '../widgets/brand_list_skeleton.dart';
import '../widgets/connection_preview_snippet.dart';
import '../widgets/syntax_highlight_controller.dart';
import '../widgets/syntax_highlight_language.dart';
import '../widgets/syntax_highlight_theme.dart';
import 'remote_text_editor_screen.dart';

const _maxEditableBytes = 1024 * 1024;
const _maxPreviewBytes = 10 * 1024 * 1024;
const _sftpOperationTimeout = Duration(seconds: 10);

/// Maximum remote video size cached for inline preview playback.
@visibleForTesting
const maxRemoteVideoPreviewBytes = 100 * 1024 * 1024;

const _requestedPathLookupTimeout = Duration(seconds: 5);
const _sftpFileRowExtentEstimate = 64.0;
const _sftpHighlightedFileScrollPadding = 16.0;
const _sftpScrollAnimationDuration = Duration(milliseconds: 220);
const _videoPreviewCacheDirectoryName = 'monkeyssh-sftp-video-preview';
// Update the download dialog at most this often / this many bytes so streaming
// a large video doesn't rebuild the modal on every chunk and starve the UI.
const _videoPreviewProgressByteInterval = 512 * 1024;
const _videoPreviewProgressInterval = Duration(milliseconds: 50);
const _redactStoreScreenshotIdentities = bool.fromEnvironment(
  'STORE_SCREENSHOT_REDACT_IDENTITIES',
);

enum _LocalFileExport { cancelled, saved, shared }

Future<_LocalFileExport> _exportLocalFile(
  BuildContext context, {
  required File file,
  required String fileName,
  String? mimeType,
  bool share = false,
}) async {
  final largeFile = await file.length() > _maxPreviewBytes;
  if (!context.mounted) {
    return _LocalFileExport.cancelled;
  }
  final mobile = switch (Theme.of(context).platform) {
    TargetPlatform.android || TargetPlatform.iOS => true,
    _ => false,
  };
  if (share || (largeFile && mobile)) {
    final box = context.findRenderObject() as RenderBox?;
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: mimeType, name: fileName)],
        sharePositionOrigin: box != null && box.hasSize
            ? box.localToGlobal(Offset.zero) & box.size
            : null,
      ),
    );
    return result.status == ShareResultStatus.dismissed
        ? _LocalFileExport.cancelled
        : _LocalFileExport.shared;
  }
  final destination = await FilePicker.saveFile(
    dialogTitle: 'Save $fileName',
    fileName: fileName,
    mimeType: mimeType ?? 'application/octet-stream',
    bytes: largeFile ? Uint8List(0) : await file.readAsBytes(),
  );
  if (destination == null) {
    return _LocalFileExport.cancelled;
  }
  if (largeFile) {
    await file.copy(destination.toFilePath());
  }
  return _LocalFileExport.saved;
}

/// Identifies a remembered SFTP browser location.
typedef SftpBrowserLocationKey = ({int hostId, int? connectionId});

/// Last successfully opened SFTP directory, keyed by host and connection.
final StateProvider<Map<SftpBrowserLocationKey, String>>
sftpBrowserLastPathsProvider =
    StateProvider<Map<SftpBrowserLocationKey, String>>((ref) => const {});

/// Bounds SFTP operations so stale SSH channels don't leave the browser loading
/// forever.
@visibleForTesting
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
@visibleForTesting
String sftpTimeoutMessage(String action) =>
    'Timed out $action. The SSH connection may be stale; reconnect and try again.';

Future<int?> _selectedUploadSizeBytes(List<PlatformFile> files) async {
  var total = 0;
  try {
    for (final file in files) {
      final size = await file.length();
      if (size < 0) {
        return null;
      }
      total += size;
    }
  } on Object {
    return null;
  }
  return total;
}

String _sftpTelemetryFailureCategory(Object error) {
  if (error is TimeoutException) {
    return 'timeout';
  }
  if (error is SftpStatusError) {
    return 'remote_status';
  }
  if (error is FileSystemException) {
    return 'local_file';
  }
  if (error is SSHChannelOpenError || error is SSHSocketError) {
    return 'connection';
  }
  return 'unknown';
}

/// Returns the parent directory for a remote SFTP path.
@visibleForTesting
String parentRemotePath(String remotePath) => parentSftpPath(remotePath);

/// A single clickable segment in the SFTP breadcrumb row.
typedef SftpBreadcrumbItem = ({String path, String label});

/// Builds clickable breadcrumb segments for an SFTP path.
@visibleForTesting
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
@visibleForTesting
List<String> pushSftpPathHistory(List<String> history, String remotePath) {
  final nextHistory = List<String>.from(history);
  if (nextHistory.isEmpty || nextHistory.last != remotePath) {
    nextHistory.add(remotePath);
  }
  return nextHistory;
}

/// Pops browser history while always retaining at least one location.
@visibleForTesting
List<String> popSftpPathHistory(List<String> history) {
  if (history.length <= 1) {
    return history.isEmpty ? ['/'] : List<String>.from(history);
  }
  return List<String>.from(history)..removeLast();
}

/// Resolves the list offset needed to reveal a highlighted file row.
@visibleForTesting
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
@visibleForTesting
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
@visibleForTesting
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
@visibleForTesting
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
@visibleForTesting
bool isSvgFileName(String filename) =>
    path.extension(filename).toLowerCase() == '.svg';

/// Returns the best-effort MIME type for a remote file name.
///
/// Only types already recognized by the SFTP preview helpers are inferred.
@visibleForTesting
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
@visibleForTesting
bool isPreviewableVideoFileName(String filename) {
  final extension = path.extension(filename).toLowerCase();
  return {'.mp4', '.mov', '.m4v', '.webm'}.contains(extension);
}

/// Returns the best-effort MIME type for a previewable video file name.
@visibleForTesting
String? remoteVideoMimeTypeForFileName(String filename) =>
    switch (path.extension(filename).toLowerCase()) {
      '.mp4' => 'video/mp4',
      '.mov' => 'video/quicktime',
      '.m4v' => 'video/x-m4v',
      '.webm' => 'video/webm',
      _ => null,
    };

/// Whether a known remote video size is allowed for inline preview caching.
@visibleForTesting
bool isRemoteVideoPreviewSizeAllowed(
  int? sizeBytes, {
  int maxBytes = maxRemoteVideoPreviewBytes,
}) => sizeBytes == null || sizeBytes <= maxBytes;

/// Describes why a remote video is too large for inline preview.
@visibleForTesting
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
@visibleForTesting
enum SftpPreviewKind {
  /// Image preview.
  image,

  /// Video preview.
  video,
}

/// Resolves the available preview kind for an SFTP entry.
@visibleForTesting
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
@visibleForTesting
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
@visibleForTesting
String buildSftpCopyPathClipboardText({
  required String directory,
  required String filename,
}) => shellEscapePosix(joinRemotePath(directory, filename));

/// Returns a user-facing image preview block reason, if preview should stop.
@visibleForTesting
String? resolveSftpImagePreviewBlockMessage({required int byteCount}) =>
    byteCount > _maxPreviewBytes
    ? 'File is too large to preview here (max 10 MB)'
    : null;

/// Returns a user-facing text edit block reason, if editing should stop.
@visibleForTesting
String? resolveSftpTextEditBlockMessage({
  required int byteCount,
  Uint8List? loadedBytes,
}) {
  if (byteCount > _maxEditableBytes) {
    return 'File is too large to edit here (max 1 MB)';
  }
  if (loadedBytes != null && looksLikeBinaryContent(loadedBytes)) {
    return 'Binary files cannot be edited here';
  }
  return null;
}

/// Formats a remote modified time stored as seconds since the Unix epoch.
@visibleForTesting
String? formatRemoteModifiedTime(int? modifyTime) {
  if (modifyTime == null) {
    return null;
  }
  return DateTime.fromMillisecondsSinceEpoch(
    modifyTime * 1000,
  ).toString().split('.').first;
}

/// Returns an error when a picker-provided upload name is not a single file.
@visibleForTesting
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
@visibleForTesting
String resolveUnsafeSftpUploadNameMessage(List<PlatformFile> files) =>
    files.length == 1
    ? 'The selected file has an unsafe name'
    : '${files.length} selected files have unsafe names';

/// Returns a validation error for a new remote folder name, or null if valid.
@visibleForTesting
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
@visibleForTesting
String sftpCopyPathSnackBarMessage(String remotePath) =>
    'Copied shell-safe path for "$remotePath"';

/// Formats the snackbar message shown after creating a remote folder.
@visibleForTesting
String sftpCreatedDirectorySnackBarMessage(String remotePath) =>
    'Created folder "$remotePath"';

/// How a file row tap should behave in the SFTP browser.
@visibleForTesting
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
@visibleForTesting
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

/// Builds an error-state video preview screen for widget tests.
@visibleForTesting
Widget buildRemoteVideoPreviewErrorForTesting({
  required String fileName,
  required String remotePath,
  required String localPath,
  required String errorMessage,
  int sizeBytes = 0,
  DateTime? modifiedAt,
  String? mimeType,
}) => _RemoteVideoViewerScreen(
  fileName: fileName,
  localFile: File(localPath),
  remotePath: remotePath,
  sizeBytes: sizeBytes,
  modifiedAt: modifiedAt,
  mimeType: mimeType,
  initialError: errorMessage,
);

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
typedef RemoteFileSelectionAvailability =
    String? Function(RemoteFileSelection file);

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
@visibleForTesting
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
@visibleForTesting
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
@visibleForTesting
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
@visibleForTesting
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
@visibleForTesting
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

/// Pushes the SFTP browser in remote-file selection mode.
///
/// Returns null when the picker is cancelled. Otherwise the returned list
/// preserves the order in which the user selected files.
Future<List<RemoteFileSelection>?> showRemoteFilePicker({
  required BuildContext context,
  required int hostId,
  int? connectionId,
  String? startDirectory,
  RemoteFilePickerConstraints constraints = const RemoteFilePickerConstraints(),
}) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  if (!context.mounted) {
    return null;
  }
  return Navigator.of(
    context,
    rootNavigator: true,
  ).push<List<RemoteFileSelection>>(
    MaterialPageRoute(
      requestFocus: false,
      builder: (context) {
        final mediaQuery = MediaQuery.of(context);
        return MediaQuery(
          data: mediaQuery.copyWith(viewInsets: EdgeInsets.zero),
          child: SftpScreen(
            hostId: hostId,
            connectionId: connectionId,
            initialPath: startDirectory,
            selectionConstraints: constraints,
            showCloseButton: true,
          ),
        );
      },
    ),
  );
}

/// SFTP file browser screen.
class SftpScreen extends ConsumerStatefulWidget {
  /// Creates a new [SftpScreen].
  const SftpScreen({
    required this.hostId,
    this.connectionId,
    this.initialPath,
    this.initialWorkingDirectory,
    this.connectionStartDirectory,
    this.tmuxPaneDirectory,
    this.selectionConstraints,
    this.showCloseButton = false,
    super.key,
  });

  /// The host ID to connect to.
  final int hostId;

  /// Optional existing connection ID to reuse.
  final int? connectionId;

  /// Optional remote path to open when the browser loads.
  final String? initialPath;

  /// Optional terminal working directory used to resolve relative paths.
  final String? initialWorkingDirectory;

  /// Optional directory where the terminal connection first opened.
  final String? connectionStartDirectory;

  /// Optional working directory reported by the active tmux pane.
  final String? tmuxPaneDirectory;

  /// Optional selection constraints for remote-file picker mode.
  ///
  /// When null, file taps keep their normal preview, video, and editor actions.
  final RemoteFilePickerConstraints? selectionConstraints;

  /// Whether to show an explicit close affordance in the app bar.
  final bool showCloseButton;

  @override
  ConsumerState<SftpScreen> createState() => _SftpScreenState();
}

class _SftpScreenState extends ConsumerState<SftpScreen> {
  SftpClient? _sftp;
  int? _connectionId;
  final ScrollController _breadcrumbScrollController = ScrollController();
  final ScrollController _fileListScrollController = ScrollController();
  String _currentPath = '/';
  int _directoryRequest = 0;
  List<SftpName> _files = [];
  bool _isLoading = true;
  bool _isConnectingSession = false;
  String? _error;
  final List<String> _pathHistory = ['/'];
  String? _hostLabel;
  String? _pendingInitialPath;
  String? _highlightedDirectoryPath;
  String? _highlightedFileName;
  String? _homeDirectoryPath;
  String? _fallbackDirectoryPath;
  String? _connectionStartDirectoryPath;
  String? _tmuxPaneDirectoryPath;
  List<RemoteFileSelection> _selectedFiles = const [];

  bool get _isSelectionMode => widget.selectionConstraints != null;

  @override
  void initState() {
    super.initState();
    _pendingInitialPath = _sanitizeRequestedPath(widget.initialPath);
    _connectionStartDirectoryPath = normalizeSftpAbsolutePath(
      widget.connectionStartDirectory,
    );
    _tmuxPaneDirectoryPath = normalizeSftpAbsolutePath(
      widget.tmuxPaneDirectory,
    );
    _connect();
  }

  @override
  void didUpdateWidget(covariant SftpScreen oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.connectionStartDirectory != widget.connectionStartDirectory) {
      _connectionStartDirectoryPath = normalizeSftpAbsolutePath(
        widget.connectionStartDirectory,
      );
    }
    if (oldWidget.tmuxPaneDirectory != widget.tmuxPaneDirectory) {
      _tmuxPaneDirectoryPath = normalizeSftpAbsolutePath(
        widget.tmuxPaneDirectory,
      );
    }

    if (oldWidget.initialPath == widget.initialPath &&
        oldWidget.initialWorkingDirectory == widget.initialWorkingDirectory) {
      return;
    }

    final nextInitialPath = _sanitizeRequestedPath(widget.initialPath);
    _pendingInitialPath = nextInitialPath;
    if (_sftp != null && nextInitialPath != null) {
      final pathToOpen = nextInitialPath;
      _pendingInitialPath = null;
      unawaited(_openRequestedPath(pathToOpen));
    }
  }

  @override
  void dispose() {
    _breadcrumbScrollController.dispose();
    _fileListScrollController.dispose();
    _sftp = null;
    super.dispose();
  }

  /// Abandons the in-flight SSH connection attempt for this browser's host.
  void _cancelConnectionAttempt() {
    ref
        .read(activeSessionsProvider.notifier)
        .cancelConnectionAttempt(widget.hostId);
  }

  Future<void> _connect() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    SftpClient? pendingSftp;
    SshSession? session;
    try {
      final remoteFileService = ref.read(remoteFileServiceProvider);
      final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
      var connectionId =
          widget.connectionId ??
          sessionsNotifier.getPreferredConnectionForHost(widget.hostId);
      session = connectionId == null
          ? null
          : sessionsNotifier.getSession(connectionId);
      final monetizationState =
          ref.read(monetizationStateProvider).asData?.value ??
          ref.read(monetizationServiceProvider).currentState;
      final useHostThemeOverrides = monetizationState.allowsFeature(
        MonetizationFeature.hostSpecificThemes,
      );

      // Connect if not already connected
      if (session == null) {
        setState(() => _isConnectingSession = true);
        final SshConnectionResult result;
        try {
          result = await sessionsNotifier.connect(
            widget.hostId,
            useHostThemeOverrides: useHostThemeOverrides,
          );
        } finally {
          if (mounted) {
            setState(() => _isConnectingSession = false);
          }
        }
        if (!mounted) {
          return;
        }
        if (!result.success) {
          setState(() {
            _isLoading = false;
            _error =
                result.error ??
                (result.cancelled
                    ? 'Connection cancelled'
                    : 'Connection failed');
          });
          return;
        }
        connectionId = result.connectionId;
        if (connectionId != null) {
          session = sessionsNotifier.getSession(connectionId);
        }
      }

      if (session == null) {
        if (!mounted) {
          return;
        }
        setState(() {
          _isLoading = false;
          _error = 'Session not found';
        });
        return;
      }

      _connectionId = connectionId;
      await sessionsNotifier.syncBackgroundStatus();
      if (!mounted) {
        return;
      }
      final sftp = await _openSftpClient(session);
      if (!mounted) {
        return;
      }
      pendingSftp = sftp;
      final initialPath = await withSftpOperationTimeout(
        remoteFileService.resolveInitialDirectory(sftp),
      );
      if (!mounted) {
        return;
      }
      _sftp = sftp;
      pendingSftp = null;
      _hostLabel = session.config.hostname;
      _fallbackDirectoryPath = normalizeSftpAbsolutePath(initialPath) ?? '/';
      _homeDirectoryPath ??= _fallbackDirectoryPath;
      _connectionStartDirectoryPath ??= _fallbackDirectoryPath;
      final requestedPath = _pendingInitialPath;
      if (requestedPath != null) {
        _pendingInitialPath = null;
        await _openRequestedPath(requestedPath);
        return;
      }
      final request = ++_directoryRequest;
      if (await _loadDirectory(
        _fallbackDirectoryPath!,
        requestGeneration: request,
        nextHistory: [_fallbackDirectoryPath!],
        rethrowTimeout: true,
        showError: false,
      )) {
        return;
      }
      if (!mounted || request != _directoryRequest) {
        return;
      }
      await _openFallbackDirectory(preferredPath: _fallbackDirectoryPath);
    } on SSHError catch (e) {
      _handleConnectFailure(e, pendingSftp, session);
    } on Object catch (e) {
      if (e is! Exception && !isExpectedSshOperationError(e)) {
        rethrow;
      }
      _handleConnectFailure(e, pendingSftp, session);
    }
  }

  Future<SftpClient> _openSftpClient(SshSession session) async {
    final sftpOpenFuture = session.sftp();
    try {
      return await withSftpOperationTimeout(sftpOpenFuture);
    } on TimeoutException {
      session.discardSftpOpen(sftpOpenFuture);
      rethrow;
    }
  }

  void _handleConnectFailure(
    Object error,
    SftpClient? pendingSftp,
    SshSession? session,
  ) {
    DiagnosticsLogService.instance.warning(
      'sftp',
      'connect_failed',
      fields: {'errorType': error.runtimeType},
    );
    if (_shouldReconnectSftpAfterDirectoryError(error)) {
      session?.discardSftpClient(pendingSftp);
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _isLoading = false;
      _error = error is TimeoutException
          ? sftpTimeoutMessage('opening the SFTP browser')
          : 'SFTP connection failed. Check the connection and try again.';
    });
  }

  Future<String?> _resolveHomeDirectoryPath() async {
    if (_homeDirectoryPath != null) {
      return _homeDirectoryPath;
    }
    if (_sftp == null) {
      return null;
    }

    try {
      final resolvedPath = normalizeSftpAbsolutePath(
        await _sftp!.absolute('.').timeout(_requestedPathLookupTimeout),
      );
      if (resolvedPath != null) {
        _homeDirectoryPath = resolvedPath;
      }
      return resolvedPath;
    } on TimeoutException {
      return null;
    } on SftpStatusError {
      return null;
    }
  }

  Future<void> _openFallbackDirectory({String? preferredPath}) async {
    final request = ++_directoryRequest;
    final candidatePaths = <String>[];

    void addCandidate(String? path) {
      final normalizedPath = normalizeSftpAbsolutePath(path);
      if (normalizedPath == null || candidatePaths.contains(normalizedPath)) {
        return;
      }
      candidatePaths.add(normalizedPath);
    }

    addCandidate(preferredPath);
    addCandidate(_fallbackDirectoryPath);
    addCandidate(widget.initialWorkingDirectory);
    addCandidate(_currentPath);
    addCandidate(await _resolveHomeDirectoryPath());
    addCandidate('/');

    for (final candidatePath in candidatePaths) {
      if (!mounted || request != _directoryRequest) {
        return;
      }
      try {
        if (await _loadDirectory(
          candidatePath,
          requestGeneration: request,
          nextHistory: [candidatePath],
          rethrowTimeout: true,
          showError: false,
        )) {
          _pendingInitialPath = null;
          return;
        }
      } on TimeoutException {
        if (mounted && request == _directoryRequest) {
          setState(() {
            _isLoading = false;
            _error = sftpTimeoutMessage('opening the SFTP browser');
          });
        }
        return;
      }
    }

    if (!mounted || request != _directoryRequest) {
      return;
    }
    setState(() {
      _isLoading = false;
      _error = 'Failed to open SFTP browser';
    });
  }

  Future<bool> _loadDirectory(
    String path, {
    List<String>? nextHistory,
    bool rethrowTimeout = false,
    bool showError = true,
    bool allowReconnect = true,
    int? requestGeneration,
  }) async {
    final request = requestGeneration ?? ++_directoryRequest;
    if (_sftp == null) {
      return _reconnectSftpAndLoadDirectory(
        path,
        request: request,
        nextHistory: nextHistory,
        showError: showError,
      );
    }

    setState(() => _isLoading = true);

    try {
      final items = await withSftpOperationTimeout(_sftp!.listdir(path));
      if (!mounted || request != _directoryRequest) {
        return false;
      }
      setState(() {
        _currentPath = path;
        _files = items
          ..sort((a, b) {
            // Directories first, then by name
            final aIsDir = a.attr.isDirectory;
            final bIsDir = b.attr.isDirectory;
            if (aIsDir && !bIsDir) return -1;
            if (!aIsDir && bIsDir) return 1;
            return a.filename.compareTo(b.filename);
          });
        if (nextHistory != null) {
          _pathHistory
            ..clear()
            ..addAll(nextHistory);
        }
        if (_highlightedDirectoryPath != path) {
          _highlightedDirectoryPath = null;
          _highlightedFileName = null;
        }
        _isLoading = false;
        _error = null;
      });
      _rememberCurrentPath(path);
      _queueScrollBreadcrumbTailIntoView();
      return true;
    } on Object catch (e) {
      if (e is! Exception && !isExpectedSshOperationError(e)) {
        rethrow;
      }
      if (!mounted || request != _directoryRequest) {
        return false;
      }
      if (rethrowTimeout && e is TimeoutException) {
        rethrow;
      }
      return _handleLoadDirectoryFailure(
        e,
        path,
        request: request,
        nextHistory: nextHistory,
        showError: showError,
        allowReconnect: allowReconnect,
      );
    }
  }

  Future<bool> _handleLoadDirectoryFailure(
    Object error,
    String path, {
    required int request,
    List<String>? nextHistory,
    bool showError = true,
    bool allowReconnect = true,
  }) async {
    if (!mounted || request != _directoryRequest) {
      return false;
    }
    if (allowReconnect && _shouldReconnectSftpAfterDirectoryError(error)) {
      final reconnected = await _reconnectSftpAndLoadDirectory(
        path,
        request: request,
        nextHistory: nextHistory,
        showError: showError,
      );
      if (reconnected || !mounted || request != _directoryRequest) {
        return reconnected;
      }
    }
    DiagnosticsLogService.instance.warning(
      'sftp',
      'list_failed',
      fields: {'errorType': error.runtimeType},
    );
    if (!mounted || request != _directoryRequest) {
      return false;
    }
    setState(() {
      _isLoading = false;
      if (showError) {
        _error = error is TimeoutException
            ? sftpTimeoutMessage('listing this directory')
            : 'Failed to list this directory. Try another folder.';
      }
    });
    return false;
  }

  bool _shouldReconnectSftpAfterDirectoryError(Object error) =>
      error is TimeoutException ||
      error is SSHError ||
      (error is SftpError && error is! SftpStatusError);

  Future<bool> _reconnectSftpAndLoadDirectory(
    String path, {
    required int request,
    List<String>? nextHistory,
    bool showError = true,
  }) async {
    if (!mounted || request != _directoryRequest) {
      return false;
    }
    final connectionId = _connectionId ?? widget.connectionId;
    if (connectionId == null) {
      return false;
    }
    final session = ref
        .read(activeSessionsProvider.notifier)
        .getSession(connectionId);
    if (session == null) {
      return false;
    }

    DiagnosticsLogService.instance.info(
      'sftp',
      'reconnect_start',
      fields: {'connectionId': connectionId},
    );
    if (_sftp != null) {
      session.discardSftpClient(_sftp);
    }
    _sftp = null;

    try {
      final sftp = await _openSftpClient(session);
      if (!mounted || request != _directoryRequest) {
        return false;
      }
      _sftp = sftp;
      DiagnosticsLogService.instance.info(
        'sftp',
        'reconnect_success',
        fields: {'connectionId': connectionId},
      );
      return _loadDirectory(
        path,
        requestGeneration: request,
        nextHistory: nextHistory,
        showError: showError,
        allowReconnect: false,
      );
    } on Object catch (error) {
      if (error is! Exception && !isExpectedSshOperationError(error)) {
        rethrow;
      }
      return _handleSftpReconnectFailure(
        connectionId,
        error,
        request: request,
        showError: showError,
      );
    }
  }

  bool _handleSftpReconnectFailure(
    int connectionId,
    Object error, {
    required int request,
    required bool showError,
  }) {
    DiagnosticsLogService.instance.warning(
      'sftp',
      'reconnect_failed',
      fields: {'connectionId': connectionId, 'errorType': error.runtimeType},
    );
    if (!mounted || request != _directoryRequest || !showError) {
      return false;
    }
    setState(() {
      _isLoading = false;
      _error = error is TimeoutException
          ? sftpTimeoutMessage('reconnecting the SFTP browser')
          : 'SFTP connection failed. Check the connection and try again.';
    });
    return false;
  }

  Future<void> _navigateTo(String path) async {
    _clearHighlightedFile();
    if (path == _currentPath) {
      return;
    }
    await _loadDirectory(
      path,
      nextHistory: pushSftpPathHistory(_pathHistory, path),
    );
  }

  Future<void> _navigateUp() async {
    _clearHighlightedFile();
    if (_currentPath == '/') {
      return;
    }
    final parentPath = parentRemotePath(_currentPath);
    await _loadDirectory(
      parentPath,
      nextHistory: pushSftpPathHistory(_pathHistory, parentPath),
    );
  }

  Future<void> _goBack() async {
    _clearHighlightedFile();
    if (_pathHistory.length <= 1) {
      return;
    }
    final nextHistory = popSftpPathHistory(_pathHistory);
    await _loadDirectory(nextHistory.last, nextHistory: nextHistory);
  }

  void _rememberCurrentPath(String remotePath) {
    final normalizedPath = normalizeSftpAbsolutePath(remotePath);
    if (normalizedPath == null) {
      return;
    }

    final key = (
      hostId: widget.hostId,
      connectionId: _connectionId ?? widget.connectionId,
    );
    final notifier = ref.read(sftpBrowserLastPathsProvider.notifier);
    notifier.state = <SftpBrowserLocationKey, String>{
      ...notifier.state,
      key: normalizedPath,
    };
  }

  Future<bool> _openRequestedPath(String requestedPath) async {
    final request = ++_directoryRequest;
    final homeDirectory = await _resolveHomeDirectoryPath();
    if (!mounted || request != _directoryRequest) {
      return false;
    }
    final normalizedPath = resolveRequestedSftpPath(
      requestedPath,
      workingDirectory: widget.initialWorkingDirectory,
      homeDirectory: homeDirectory,
    );
    if (normalizedPath == null) {
      _closeRequestedPathWithError(
        'Could not open "$requestedPath" in SFTP: could not resolve path',
      );
      return false;
    }

    if (normalizedPath == '/') {
      if (await _loadDirectory(
        normalizedPath,
        requestGeneration: request,
        nextHistory: [normalizedPath],
        showError: false,
      )) {
        return true;
      }
      if (!mounted || request != _directoryRequest) {
        return false;
      }
      _closeRequestedPathWithError(
        'Could not open "$normalizedPath" in SFTP: failed to list directory',
      );
      return false;
    }

    final sftp = _sftp;
    if (sftp == null) {
      _closeRequestedPathWithError('Could not open "$requestedPath" in SFTP');
      return false;
    }

    late final SftpFileAttrs requestedPathStat;
    try {
      requestedPathStat = await sftp
          .stat(normalizedPath)
          .timeout(_requestedPathLookupTimeout);
    } on TimeoutException {
      if (!mounted || request != _directoryRequest) {
        return false;
      }
      _closeRequestedPathWithError(
        'Timed out opening "$normalizedPath" in SFTP',
      );
      return false;
    } on SftpStatusError catch (error) {
      if (!mounted || request != _directoryRequest) {
        return false;
      }
      if (error.code == SftpStatusCode.noSuchFile) {
        _closeRequestedPathWithError(
          'Could not open "$normalizedPath" in SFTP: path does not exist',
        );
        return false;
      }
      _closeRequestedPathWithError('Could not open "$normalizedPath" in SFTP');
      return false;
    }

    if (!mounted || request != _directoryRequest) {
      return false;
    }
    final navigationTarget = resolveRequestedSftpNavigationTarget(
      normalizedPath,
      isDirectory: requestedPathStat.isDirectory,
    );
    if (await _loadDirectory(
      navigationTarget.directoryPath,
      requestGeneration: request,
      nextHistory: [navigationTarget.directoryPath],
      showError: false,
    )) {
      final fileName = navigationTarget.highlightedFileName;
      if (fileName == null) {
        return true;
      }

      SftpName? matchingEntry;
      for (final entry in _files) {
        if (entry.filename == fileName) {
          matchingEntry = entry;
          break;
        }
      }
      if (matchingEntry == null) {
        _closeRequestedPathWithError(
          'Could not open "$normalizedPath" in SFTP: path does not exist',
        );
        return false;
      }

      if (!mounted || request != _directoryRequest) {
        return true;
      }
      _highlightFile(navigationTarget.directoryPath, fileName);
      await _openFileFromRequestedPath(matchingEntry);
      return true;
    }

    if (!mounted || request != _directoryRequest) {
      return false;
    }
    _closeRequestedPathWithError('Could not open "$normalizedPath" in SFTP');
    return false;
  }

  Future<void> _openFileFromRequestedPath(SftpName file) async {
    if (_isSelectionMode) {
      _toggleRemoteFileSelection(file, announceDisabled: false);
      if (!mounted) {
        return;
      }
      _highlightFile(_currentPath, file.filename);
      final disabledReason = _selectionDisabledReasonForFile(file);
      if (disabledReason != null) {
        _showMessage(disabledReason);
      }
      return;
    }

    switch (resolveSftpFileTapIntent(
      isDirectory: file.attr.isDirectory,
      filename: file.filename,
    )) {
      case SftpFileTapIntent.navigate:
        return;
      case SftpFileTapIntent.preview:
        await _previewImageFile(file);
      case SftpFileTapIntent.previewVideo:
        await _previewVideoFile(file);
      case SftpFileTapIntent.edit:
        await _editTextFile(file);
    }
    if (!mounted) {
      return;
    }
    _highlightFile(_currentPath, file.filename);
  }

  void _highlightFile(String directoryPath, String fileName) {
    setState(() {
      _highlightedDirectoryPath = directoryPath;
      _highlightedFileName = fileName;
    });
    _queueScrollHighlightedFileIntoView();
  }

  void _clearHighlightedFile() {
    if (_highlightedFileName == null && _highlightedDirectoryPath == null) {
      return;
    }
    setState(() {
      _highlightedDirectoryPath = null;
      _highlightedFileName = null;
    });
  }

  void _closeRequestedPathWithError(String message) {
    if (!mounted) {
      return;
    }

    final navigator = Navigator.of(context);
    if (!_isSelectionMode && navigator.canPop()) {
      navigator.pop(message);
      return;
    }

    setState(() {
      _isLoading = false;
      _error = message;
    });
    unawaited(_openFallbackDirectory(preferredPath: _currentPath));
  }

  void _queueScrollHighlightedFileIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _highlightedDirectoryPath != _currentPath ||
          _highlightedFileName == null ||
          !_fileListScrollController.hasClients) {
        return;
      }

      final highlightedIndex = _files.indexWhere(
        (file) => file.filename == _highlightedFileName,
      );
      if (highlightedIndex < 0) {
        return;
      }

      final position = _fileListScrollController.position;
      final targetOffset = resolveSftpHighlightedFileScrollOffset(
        highlightedIndex: highlightedIndex,
        currentOffset: _fileListScrollController.offset,
        itemExtentEstimate: _sftpFileRowExtentEstimate,
        viewportExtent: position.viewportDimension,
        maxScrollExtent: position.maxScrollExtent,
      );
      if ((targetOffset - _fileListScrollController.offset).abs() < 0.5) {
        return;
      }

      unawaited(
        _fileListScrollController.animateTo(
          targetOffset,
          duration: _sftpScrollAnimationDuration,
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  void _queueScrollBreadcrumbTailIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_breadcrumbScrollController.hasClients) {
        return;
      }

      final position = _breadcrumbScrollController.position;
      final targetOffset = position.maxScrollExtent;
      if ((targetOffset - _breadcrumbScrollController.offset).abs() < 0.5) {
        return;
      }

      unawaited(
        _breadcrumbScrollController.animateTo(
          targetOffset,
          duration: _sftpScrollAnimationDuration,
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  String? _sanitizeRequestedPath(String? path) {
    final trimmedPath = path?.trim();
    if (trimmedPath == null || trimmedPath.isEmpty) {
      return null;
    }
    return trimmedPath;
  }

  RemoteFileSelection _remoteFileSelectionFor(SftpName file) =>
      RemoteFileSelection(
        remotePath: joinRemotePath(_currentPath, file.filename),
        displayName: file.filename,
        sizeBytes: file.attr.size,
        mimeType: inferRemoteFileMimeType(file.filename),
      );

  bool _isRemoteFileSelected(SftpName file) {
    final remotePath = joinRemotePath(_currentPath, file.filename);
    return _selectedFiles.any((entry) => entry.remotePath == remotePath);
  }

  String? _selectionDisabledReasonForFile(SftpName file) {
    final constraints = widget.selectionConstraints;
    if (constraints == null || file.attr.isDirectory) {
      return null;
    }
    return resolveRemoteFileSelectionDisabledReason(
      constraints: constraints,
      currentSelection: _selectedFiles,
      candidate: _remoteFileSelectionFor(file),
    );
  }

  String _selectionSummaryText() {
    final constraints = widget.selectionConstraints;
    if (constraints == null) {
      return '';
    }
    final selectedCount = _selectedFiles.length;
    final maxSelectionCount = constraints.allowMultiple
        ? constraints.maxSelectionCount
        : 1;
    if (selectedCount == 0) {
      if (!constraints.allowMultiple) {
        return 'Choose 1 file to continue.';
      }
      if (maxSelectionCount == null) {
        return 'Choose one or more files to continue.';
      }
      return maxSelectionCount == 1
          ? 'Choose up to 1 file to continue.'
          : 'Choose up to $maxSelectionCount files to continue.';
    }

    final noun = selectedCount == 1 ? 'file' : 'files';
    if (maxSelectionCount == null) {
      return '$selectedCount $noun selected';
    }
    final totalNoun = maxSelectionCount == 1 ? 'file' : 'files';
    return '$selectedCount of $maxSelectionCount $totalNoun selected';
  }

  void _showMessage(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _toggleRemoteFileSelection(
    SftpName file, {
    bool announceDisabled = true,
  }) {
    final constraints = widget.selectionConstraints;
    if (constraints == null || file.attr.isDirectory) {
      return;
    }

    final disabledReason = _selectionDisabledReasonForFile(file);
    if (disabledReason != null) {
      if (announceDisabled) {
        _showMessage(disabledReason);
      }
      return;
    }

    final nextSelection = toggleRemoteFileSelection(
      currentSelection: _selectedFiles,
      file: _remoteFileSelectionFor(file),
      allowMultiple: constraints.allowMultiple,
    );
    setState(() {
      _selectedFiles = List<RemoteFileSelection>.unmodifiable(nextSelection);
    });
  }

  void _confirmRemoteFileSelection() {
    final navigator = Navigator.of(context);
    if (!navigator.canPop() || _selectedFiles.isEmpty) {
      return;
    }
    navigator.pop(List<RemoteFileSelection>.unmodifiable(_selectedFiles));
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _pathHistory.length <= 1,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && _pathHistory.length > 1) {
        unawaited(_goBack());
      }
    },
    child: Scaffold(
      appBar: AppBar(
        leading: widget.showCloseButton
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _closeBrowser,
                tooltip: 'Close file browser',
              )
            : null,
        title: Text(
          _hostLabel == null
              ? (_isSelectionMode ? 'Select files' : 'Files')
              : '${_isSelectionMode ? 'Select files' : 'Files'} - $_hostLabel',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _clearHighlightedFile();
              unawaited(_loadDirectory(_currentPath));
            },
            tooltip: 'Refresh',
          ),
          if (!_isSelectionMode)
            IconButton(
              icon: const Icon(Icons.create_new_folder),
              onPressed: () {
                _clearHighlightedFile();
                unawaited(_showCreateDirectoryDialog());
              },
              tooltip: 'New folder',
            ),
        ],
      ),
      body: Column(
        children: [
          _buildLocationShortcuts(),
          _buildBreadcrumbs(),
          Expanded(child: _buildFileList()),
        ],
      ),
      bottomNavigationBar: _isSelectionMode
          ? _RemoteFileSelectionBar(
              selectedCount: _selectedFiles.length,
              summaryText: _selectionSummaryText(),
              onCancel: _closeBrowser,
              onConfirm: _selectedFiles.isEmpty
                  ? null
                  : _confirmRemoteFileSelection,
            )
          : null,
      floatingActionButton: _isSelectionMode
          ? null
          : FloatingActionButton(
              onPressed: () {
                _clearHighlightedFile();
                unawaited(_showUploadDialog());
              },
              tooltip: 'Upload files',
              child: const Icon(Icons.upload_file),
            ),
    ),
  );

  void _closeBrowser() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }
    context.go('/');
  }

  Widget _buildLocationShortcuts() {
    final shortcuts = resolveSftpLocationShortcuts(
      homeDirectory: _homeDirectoryPath,
      connectionStartDirectory: _connectionStartDirectoryPath,
      tmuxPaneDirectory: _tmuxPaneDirectoryPath,
    );
    if (shortcuts.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final shortcut in shortcuts)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _buildLocationShortcutChip(shortcut, theme),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLocationShortcutChip(String shortcutPath, ThemeData theme) {
    final isCurrent = shortcutPath == _currentPath;
    final displayPath = _displaySftpPath(shortcutPath);
    if (isCurrent) {
      return Tooltip(
        message: 'Current folder: $displayPath',
        child: Chip(
          avatar: Icon(
            Icons.check_circle_rounded,
            color: theme.colorScheme.onPrimaryContainer,
            size: 18,
          ),
          label: Text(displayPath),
          labelStyle: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onPrimaryContainer,
            fontWeight: FontWeight.w700,
          ),
          backgroundColor: theme.colorScheme.primaryContainer,
          side: BorderSide(color: theme.colorScheme.primary),
        ),
      );
    }

    return ActionChip(
      label: Text(displayPath),
      labelStyle: theme.textTheme.labelLarge?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
      backgroundColor: theme.colorScheme.surface,
      side: BorderSide(color: theme.colorScheme.outlineVariant),
      onPressed: () => unawaited(_navigateTo(shortcutPath)),
      tooltip: 'Go to $displayPath',
    );
  }

  Widget _buildBreadcrumbs() {
    final breadcrumbItems = buildSftpBreadcrumbItems(_currentPath);
    final displayParts = buildSftpBreadcrumbItems(
      _displaySftpPath(_currentPath),
    ).map((item) => item.label).toList();
    final theme = Theme.of(context);

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, size: 20),
            onPressed: _pathHistory.length > 1
                ? () => unawaited(_goBack())
                : null,
            tooltip: 'Back',
          ),
          IconButton(
            icon: const Icon(Icons.arrow_upward, size: 20),
            onPressed: !isSftpPathRoot(_currentPath)
                ? () => unawaited(_navigateUp())
                : null,
            tooltip: 'Up',
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              controller: _breadcrumbScrollController,
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < breadcrumbItems.length; i++) ...[
                    if (i > 0)
                      Icon(
                        Icons.chevron_right,
                        size: 16,
                        color: theme.colorScheme.outline,
                      ),
                    InkWell(
                      onTap: () =>
                          unawaited(_navigateTo(breadcrumbItems[i].path)),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 8,
                        ),
                        child: Text(
                          _displaySftpBreadcrumbPart(
                            breadcrumbItems[i].label,
                            displayParts: displayParts,
                            index: i,
                            isLast: i == breadcrumbItems.length - 1,
                          ),
                          style: FluttyTheme.monoStyle.copyWith(
                            fontWeight: i == breadcrumbItems.length - 1
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: i == breadcrumbItems.length - 1
                                ? theme.colorScheme.onSurface
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _displaySftpPath(String remotePath) {
    if (!_redactStoreScreenshotIdentities || remotePath == '/') {
      return remotePath;
    }
    return '/release-workspace';
  }

  String _displaySftpBreadcrumbPart(
    String realPart, {
    required List<String> displayParts,
    required int index,
    required bool isLast,
  }) {
    if (!_redactStoreScreenshotIdentities) {
      return realPart;
    }
    if (isLast && displayParts.isNotEmpty) {
      return displayParts.last;
    }
    return '...';
  }

  Widget _buildFileList() {
    if (_isLoading) {
      if (!_isConnectingSession) {
        return const BrandListSkeleton();
      }
      final isCancelling =
          ref.watch(connectionAttemptProvider(widget.hostId))?.isCancelling ??
          false;
      return Column(
        children: [
          const Expanded(child: BrandListSkeleton()),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TextButton.icon(
              onPressed: isCancelling ? null : _cancelConnectionAttempt,
              icon: const Icon(Icons.close),
              label: Text(isCancelling ? 'Cancelling…' : 'Cancel connection'),
            ),
          ),
        ],
      );
    }

    if (_error != null) {
      return BrandErrorState(
        title: 'couldn’t load files',
        message: _error,
        onRetry: () => unawaited(_connect()),
      );
    }

    if (_files.isEmpty) {
      return _isSelectionMode
          ? const BrandEmptyState(
              title: 'empty directory',
              message: 'No files in this folder yet.',
            )
          : BrandEmptyState(
              title: 'empty directory',
              message: 'Nothing here yet.',
              primaryLabel: 'Upload',
              primaryIcon: Icons.upload_file_outlined,
              onPrimary: () => unawaited(_showUploadDialog()),
              secondaryActions: [
                BrandEmptyAction(
                  icon: Icons.create_new_folder_outlined,
                  label: 'New folder',
                  onTap: () => unawaited(_showCreateDirectoryDialog()),
                ),
              ],
            );
    }

    return RefreshIndicator(
      onRefresh: () async {
        _clearHighlightedFile();
        await _loadDirectory(_currentPath);
      },
      child: ListView.builder(
        controller: _fileListScrollController,
        itemCount: _files.length,
        itemBuilder: (context, index) {
          final file = _files[index];
          // Skip . and ..
          if (file.filename == '.' || file.filename == '..') {
            return const SizedBox.shrink();
          }
          final selectionDisabledReason = _selectionDisabledReasonForFile(file);
          final isSelected = _isSelectionMode && _isRemoteFileSelected(file);
          return _FileListTile(
            file: file,
            isHighlighted:
                (_highlightedDirectoryPath == _currentPath &&
                    _highlightedFileName == file.filename) ||
                isSelected,
            onTap: () => _handleFileTap(file),
            onLongPress: _isSelectionMode ? null : () => _showFileOptions(file),
            onShowOptions: _isSelectionMode
                ? null
                : () => _showFileOptions(file),
            disabledReason: selectionDisabledReason,
            trailingIcon: !_isSelectionMode || file.attr.isDirectory
                ? null
                : selectionDisabledReason != null
                ? Icons.block_outlined
                : isSelected
                ? Icons.check_circle
                : Icons.radio_button_unchecked,
            trailingTooltip: _isSelectionMode
                ? remoteFileSelectionTooltip(
                    isDirectory: file.attr.isDirectory,
                    fileName: file.filename,
                    isSelected: isSelected,
                    disabledReason: selectionDisabledReason,
                  )
                : null,
            semanticsLabel: _isSelectionMode
                ? remoteFileSelectionSemanticsLabel(
                    isDirectory: file.attr.isDirectory,
                    fileName: file.filename,
                    isSelected: isSelected,
                    disabledReason: selectionDisabledReason,
                  )
                : null,
            semanticsHint: _isSelectionMode
                ? remoteFileSelectionSemanticsHint(
                    isDirectory: file.attr.isDirectory,
                    isSelected: isSelected,
                    disabledReason: selectionDisabledReason,
                  )
                : null,
          );
        },
      ),
    );
  }

  void _handleFileTap(SftpName file) {
    _clearHighlightedFile();
    if (_isSelectionMode && !file.attr.isDirectory) {
      _toggleRemoteFileSelection(file);
      return;
    }

    switch (resolveSftpFileTapIntent(
      isDirectory: file.attr.isDirectory,
      filename: file.filename,
    )) {
      case SftpFileTapIntent.navigate:
        unawaited(_navigateTo(joinRemotePath(_currentPath, file.filename)));
      case SftpFileTapIntent.preview:
        unawaited(_previewImageFile(file));
      case SftpFileTapIntent.previewVideo:
        unawaited(_previewVideoFile(file));
      case SftpFileTapIntent.edit:
        unawaited(_editTextFile(file));
    }
  }

  void _showFileOptions(SftpName file) {
    _clearHighlightedFile();
    final previewKind = resolveSftpPreviewKind(
      isDirectory: file.attr.isDirectory,
      filename: file.filename,
    );
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Info'),
              onTap: () {
                Navigator.pop(context);
                _showFileInfo(file);
              },
            ),
            if (previewKind != null)
              ListTile(
                leading: Icon(
                  previewKind == SftpPreviewKind.video
                      ? Icons.video_file_outlined
                      : Icons.image_outlined,
                ),
                title: Text(
                  previewKind == SftpPreviewKind.video
                      ? 'Preview video'
                      : 'View',
                ),
                onTap: () {
                  Navigator.pop(context);
                  switch (previewKind) {
                    case SftpPreviewKind.image:
                      unawaited(_previewImageFile(file));
                    case SftpPreviewKind.video:
                      unawaited(_previewVideoFile(file));
                  }
                },
              ),
            if (!file.attr.isDirectory)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () {
                  Navigator.pop(context);
                  unawaited(_editTextFile(file));
                },
              ),
            if (!file.attr.isDirectory)
              ListTile(
                leading: const Icon(Icons.download),
                title: const Text('Download'),
                onTap: () {
                  Navigator.pop(context);
                  unawaited(_downloadFile(file));
                },
              ),
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('Copy as path'),
              onTap: () async {
                Navigator.pop(context);
                await _copyRemotePath(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename'),
              onTap: () {
                Navigator.pop(context);
                unawaited(_showRenameDialog(file));
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                'Delete',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () {
                Navigator.pop(context);
                unawaited(_deleteFile(file));
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showFileInfo(SftpName file) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(file.filename),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _InfoRow('Type', file.attr.isDirectory ? 'Directory' : 'File'),
            _InfoRow('Size', formatRemoteFileSize(file.attr.size ?? 0)),
            if (formatRemoteModifiedTime(file.attr.modifyTime) != null)
              _InfoRow(
                'Modified',
                formatRemoteModifiedTime(file.attr.modifyTime)!,
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showCreateDirectoryDialog() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _CreateDirectoryDialog(currentPath: _currentPath),
    );

    if (name == null || _sftp == null) {
      return;
    }

    final validationMessage = validateSftpDirectoryName(name);
    if (validationMessage != null) {
      _showMessage(validationMessage);
      return;
    }

    final remotePath = joinRemotePath(_currentPath, name.trim());
    try {
      await _sftp!.mkdir(remotePath);
      await _loadDirectory(_currentPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(sftpCreatedDirectorySnackBarMessage(remotePath)),
          ),
        );
      }
    } on Object catch (e) {
      if (e is! Exception && !isExpectedSshOperationError(e)) {
        rethrow;
      }
      _showSftpFailureSnackBar(
        message: 'Could not create folder. Check permissions and try again.',
        eventName: 'create_directory_failed',
        error: e,
      );
    }
  }

  Future<void> _showRenameDialog(SftpName file) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => _RenameDialog(initialName: file.filename),
    );

    if (newName != null && newName.isNotEmpty && _sftp != null) {
      try {
        await _sftp!.rename(
          joinRemotePath(_currentPath, file.filename),
          joinRemotePath(_currentPath, newName),
        );
        await _loadDirectory(_currentPath);
        _showMessage('Renamed to "$newName"');
      } on Object catch (e) {
        if (e is! Exception && !isExpectedSshOperationError(e)) {
          rethrow;
        }
        _showSftpFailureSnackBar(
          message: 'Could not rename item. Check permissions and try again.',
          eventName: 'rename_failed',
          error: e,
        );
      }
    }
  }

  Future<void> _deleteFile(SftpName file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete'),
        content: Text('Delete "${file.filename}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if ((confirmed ?? false) && _sftp != null) {
      try {
        final path = joinRemotePath(_currentPath, file.filename);
        if (file.attr.isDirectory) {
          await _sftp!.rmdir(path);
        } else {
          await _sftp!.remove(path);
        }
        await _loadDirectory(_currentPath);
        _showMessage('Deleted "${file.filename}"');
      } on Object catch (e) {
        if (e is! Exception && !isExpectedSshOperationError(e)) {
          rethrow;
        }
        _showSftpFailureSnackBar(
          message: e is SftpStatusError && e.code == SftpStatusCode.noSuchFile
              ? 'Item no longer exists. Refresh the folder and try again.'
              : file.attr.isDirectory
              ? 'Could not delete folder. Make sure it is empty and you have permission.'
              : 'Could not delete item. Check permissions and try again.',
          eventName: 'delete_failed',
          error: e,
        );
      }
    }
  }

  Future<void> _downloadFile(SftpName file) async {
    if (_sftp == null) {
      return;
    }

    final telemetryService = ref.read(telemetryServiceProvider);
    final remoteFileService = ref.read(remoteFileServiceProvider);
    final sftp = _sftp!;
    final remotePath = joinRemotePath(_currentPath, file.filename);
    Directory? stagingDirectory;
    var keepStagedFile = false;
    final startedAt = DateTime.now();
    final sizeBytes = file.attr.size;
    unawaited(
      telemetryService.logSftpTransferStarted(
        direction: 'download',
        fileCount: 1,
        sizeBytes: sizeBytes,
      ),
    );
    try {
      stagingDirectory = await (await getTemporaryDirectory()).createTemp(
        'sftp-export-',
      );
      final localFile = File(
        path.join(stagingDirectory.path, path.basename(file.filename)),
      );
      await remoteFileService.downloadFile(
        sftp: sftp,
        remotePath: remotePath,
        localPath: localFile.path,
      );
      if (!mounted) {
        return;
      }
      final result = await _exportLocalFile(
        context,
        file: localFile,
        fileName: file.filename,
      );
      keepStagedFile = result == _LocalFileExport.shared;
      if (result == _LocalFileExport.cancelled) {
        return;
      }

      _showMessage('Downloaded "${file.filename}"');
      unawaited(
        telemetryService.logSftpTransferCompleted(
          direction: 'download',
          fileCount: 1,
          sizeBytes: sizeBytes,
          duration: DateTime.now().difference(startedAt),
        ),
      );
    } on Object catch (e) {
      if (e is! Exception && !isExpectedSshOperationError(e)) {
        rethrow;
      }
      unawaited(
        telemetryService.logSftpTransferFailed(
          direction: 'download',
          fileCount: 1,
          sizeBytes: sizeBytes,
          duration: DateTime.now().difference(startedAt),
          failureCategory: _sftpTelemetryFailureCategory(e),
        ),
      );
      _showSftpFailureSnackBar(
        message: 'Download failed. Check the connection and try again.',
        eventName: 'download_failed',
        error: e,
      );
    } finally {
      if (!keepStagedFile && stagingDirectory != null) {
        try {
          await stagingDirectory.delete(recursive: true);
        } on FileSystemException {
          // Temporary storage may already have removed the staging directory.
        }
      }
    }
  }

  Future<void> _showUploadDialog() async {
    if (_sftp == null) {
      return;
    }

    final destinationDirectory = _currentPath;
    final telemetryService = ref.read(telemetryServiceProvider);
    final remoteFileService = ref.read(remoteFileServiceProvider);
    late final List<PlatformFile> result;
    try {
      result = await FilePicker.pickFiles();
    } on Exception catch (error) {
      DiagnosticsLogService.instance.warning(
        'sftp.upload',
        'picker_failed',
        fields: {'errorType': error.runtimeType},
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open the file picker. Try again.'),
          ),
        );
      }
      return;
    }
    if (result.isEmpty) {
      return;
    }

    final selectedFiles = result;
    final unsafeUploads = selectedFiles
        .where((file) => validateSftpUploadFileName(file.name) != null)
        .toList();
    if (unsafeUploads.isNotEmpty) {
      unawaited(
        telemetryService.logSftpTransferFailed(
          direction: 'upload',
          fileCount: selectedFiles.length,
          sizeBytes: await _selectedUploadSizeBytes(selectedFiles),
          duration: Duration.zero,
          failureCategory: 'invalid_name',
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(resolveUnsafeSftpUploadNameMessage(unsafeUploads)),
          ),
        );
      }
      return;
    }

    final startedAt = DateTime.now();
    final sizeBytes = await _selectedUploadSizeBytes(selectedFiles);
    if (!mounted || _sftp == null) {
      return;
    }
    final sftp = _sftp!;
    unawaited(
      telemetryService.logSftpTransferStarted(
        direction: 'upload',
        fileCount: selectedFiles.length,
        sizeBytes: sizeBytes,
      ),
    );
    var uploadedFileCount = 0;
    try {
      for (final file in selectedFiles) {
        await remoteFileService.uploadStream(
          sftp: sftp,
          remotePath: joinRemotePath(destinationDirectory, file.name),
          stream: file.readAsByteStream(),
        );
        uploadedFileCount++;
      }
    } on Object catch (e) {
      // Remote file implementations can throw Error subtypes as well as
      // SSH/SFTP errors. Stop the batch and report the failed transfer.
      unawaited(
        telemetryService.logSftpTransferFailed(
          direction: 'upload',
          fileCount: selectedFiles.length,
          sizeBytes: sizeBytes,
          duration: DateTime.now().difference(startedAt),
          failureCategory: _sftpTelemetryFailureCategory(e),
        ),
      );
      if (uploadedFileCount > 0 && mounted) {
        await _loadDirectory(_currentPath);
      }
      _showSftpFailureSnackBar(
        message: uploadedFileCount == 0
            ? 'Upload failed. Check the connection and try again.'
            : 'Uploaded $uploadedFileCount of ${selectedFiles.length} files. '
                  'Upload failed. Check the connection and try again.',
        eventName: 'upload_failed',
        error: e,
      );
      return;
    }
    if (mounted) {
      await _loadDirectory(_currentPath);
      if (mounted) {
        final message = selectedFiles.length == 1
            ? 'Uploaded "${selectedFiles.single.name}"'
            : 'Uploaded ${selectedFiles.length} files';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    }
    unawaited(
      telemetryService.logSftpTransferCompleted(
        direction: 'upload',
        fileCount: selectedFiles.length,
        sizeBytes: sizeBytes,
        duration: DateTime.now().difference(startedAt),
      ),
    );
  }

  Future<void> _copyRemotePath(SftpName file) async {
    final remotePath = joinRemotePath(_currentPath, file.filename);
    try {
      await Clipboard.setData(
        ClipboardData(
          text: buildSftpCopyPathClipboardText(
            directory: _currentPath,
            filename: file.filename,
          ),
        ),
      );
    } on Exception catch (error) {
      _showSftpFailureSnackBar(
        message: 'Could not copy the path. Try again.',
        eventName: 'copy_path_failed',
        error: error,
      );
      return;
    }
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(sftpCopyPathSnackBarMessage(remotePath))),
    );
  }

  Future<Uint8List> _readFileBytes(String remotePath, int length) async {
    final file = await _sftp!.open(remotePath);
    try {
      return await file.readBytes(length: length);
    } finally {
      await file.close();
    }
  }

  Future<void> _previewImageFile(SftpName file) async {
    if (_sftp == null) {
      return;
    }

    final preflightMessage = resolveSftpImagePreviewBlockMessage(
      byteCount: file.attr.size ?? 0,
    );
    if (preflightMessage != null) {
      _showMessage(preflightMessage);
      return;
    }

    final remotePath = joinRemotePath(_currentPath, file.filename);
    try {
      final bytes = await _readFileBytes(remotePath, _maxPreviewBytes + 1);

      final loadedMessage = resolveSftpImagePreviewBlockMessage(
        byteCount: bytes.length,
      );
      if (loadedMessage != null) {
        _showMessage(loadedMessage);
        return;
      }

      if (!mounted) {
        return;
      }

      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (context) => _RemoteImageViewerScreen(
            remotePath: remotePath,
            bytes: bytes,
            isSvg: isSvgFileName(file.filename),
          ),
        ),
      );
    } on Object catch (e) {
      if (e is! Exception && !isExpectedSshOperationError(e)) {
        rethrow;
      }
      if (!mounted) {
        return;
      }
      _showSftpFailureSnackBar(
        message: 'Preview failed. Download the file to open it locally.',
        eventName: 'preview_failed',
        error: e,
      );
    }
  }

  Future<void> _previewVideoFile(SftpName file) async {
    final sftp = _sftp;
    if (sftp == null) {
      return;
    }

    final remotePath = joinRemotePath(_currentPath, file.filename);
    final knownSize = file.attr.size;
    if (!isRemoteVideoPreviewSizeAllowed(knownSize)) {
      _showVideoPreviewFallbackSnackBar(
        file,
        remoteVideoPreviewTooLargeMessage(sizeBytes: knownSize),
      );
      return;
    }

    final progress = ValueNotifier<_RemoteVideoDownloadProgress>(
      _RemoteVideoDownloadProgress(
        remotePath: remotePath,
        downloadedBytes: 0,
        totalBytes: knownSize ?? 0,
      ),
    );
    final cancelToken = RemoteFileDownloadCancelToken();
    final downloadFuture = _cacheRemoteVideoFile(
      sftp: sftp,
      file: file,
      remotePath: remotePath,
      progress: progress,
      cancelToken: cancelToken,
    );

    _RemoteVideoCacheDialogResult? dialogResult;
    try {
      dialogResult = await showDialog<_RemoteVideoCacheDialogResult>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _RemoteVideoCachingDialog(
          fileName: file.filename,
          progressListenable: progress,
          downloadFuture: downloadFuture,
          onCancel: cancelToken.cancel,
        ),
      );
    } on Object {
      cancelToken.cancel();
      await _discardRemoteVideoDownload(downloadFuture);
      progress.dispose();
      rethrow;
    }

    if (!mounted || dialogResult == null) {
      cancelToken.cancel();
      final cacheResult = dialogResult?.cacheResult;
      if (cacheResult == null) {
        await _discardRemoteVideoDownload(downloadFuture);
      } else {
        await _deleteCachedRemoteVideoFile(cacheResult.localFile);
      }
      progress.dispose();
      return;
    }

    if (dialogResult.cancelled) {
      cancelToken.cancel();
      await _discardRemoteVideoDownload(downloadFuture);
      progress.dispose();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Video preview cancelled')));
      return;
    }
    progress.dispose();

    final cacheResult = dialogResult.cacheResult;
    if (cacheResult == null) {
      _showVideoPreviewFallbackSnackBar(
        file,
        'Video preview failed: ${_describePreviewError(dialogResult.error)}',
      );
      return;
    }

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => _RemoteVideoViewerScreen(
          fileName: file.filename,
          localFile: cacheResult.localFile,
          remotePath: remotePath,
          sizeBytes: file.attr.size ?? cacheResult.downloadedBytes,
          modifiedAt: file.attr.modifyTime == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                  file.attr.modifyTime! * 1000,
                ),
          mimeType: remoteVideoMimeTypeForFileName(file.filename),
        ),
      ),
    );
  }

  Future<void> _discardRemoteVideoDownload(
    Future<_CachedRemoteVideo> downloadFuture,
  ) async {
    try {
      final cacheResult = await downloadFuture;
      await _deleteCachedRemoteVideoFile(cacheResult.localFile);
    } on Object {
      // Cancellation/errors are surfaced by the preview dialog when relevant.
    }
  }

  void _showVideoPreviewFallbackSnackBar(SftpName file, String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(
          label: 'Download',
          onPressed: () => unawaited(_downloadFile(file)),
        ),
      ),
    );
  }

  Future<_CachedRemoteVideo> _cacheRemoteVideoFile({
    required SftpClient sftp,
    required SftpName file,
    required String remotePath,
    required ValueNotifier<_RemoteVideoDownloadProgress> progress,
    required RemoteFileDownloadCancelToken cancelToken,
  }) async {
    final tempDirectory = await getTemporaryDirectory();
    final cacheDirectory = Directory(
      path.join(tempDirectory.path, _videoPreviewCacheDirectoryName),
    );
    await cacheDirectory.create(recursive: true);
    cancelToken.throwIfCancelled();

    final cacheFile = File(
      path.join(
        cacheDirectory.path,
        '${DateTime.now().toUtc().microsecondsSinceEpoch}-'
        '${_sanitizeVideoCacheFileName(file.filename)}',
      ),
    );

    var downloadedBytes = 0;
    try {
      final progressStopwatch = Stopwatch()..start();
      var reportedBytes = 0;
      void publishProgress() {
        reportedBytes = downloadedBytes;
        progressStopwatch.reset();
        progress.value = progress.value.copyWith(
          downloadedBytes: downloadedBytes,
        );
      }

      await ref
          .read(remoteFileServiceProvider)
          .downloadFile(
            sftp: sftp,
            remotePath: remotePath,
            localPath: cacheFile.path,
            maxBytes: maxRemoteVideoPreviewBytes,
            cancelToken: cancelToken,
            onProgress: (bytes) async {
              downloadedBytes = bytes;
              if (downloadedBytes - reportedBytes >=
                      _videoPreviewProgressByteInterval ||
                  progressStopwatch.elapsed >= _videoPreviewProgressInterval) {
                publishProgress();
                await Future<void>.delayed(Duration.zero);
              }
            },
          );
      if (downloadedBytes != reportedBytes) {
        publishProgress();
      }
      return _CachedRemoteVideo(
        localFile: cacheFile,
        downloadedBytes: downloadedBytes,
      );
    } on Object {
      await _deleteCachedRemoteVideoFile(cacheFile);
      rethrow;
    }
  }

  String _sanitizeVideoCacheFileName(String filename) {
    final sanitized = path.posix
        .basename(filename)
        .replaceAll(RegExp('[^A-Za-z0-9._-]+'), '-')
        .replaceAll(RegExp('-+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return sanitized.isEmpty ? 'video' : sanitized;
  }

  String _describePreviewError(Object? error) {
    if (error == null) {
      return 'Unknown error';
    }
    if (error is RemoteFileDownloadLimitException) {
      return remoteVideoPreviewTooLargeMessage(sizeBytes: error.byteCount);
    }
    if (error is RemoteFileDownloadCancelledException) {
      return 'Cancelled';
    }
    return error.toString().replaceFirst(RegExp('^Exception: '), '');
  }

  Future<void> _editTextFile(SftpName file) async {
    if (_sftp == null) {
      return;
    }

    final preflightMessage = resolveSftpTextEditBlockMessage(
      byteCount: file.attr.size ?? 0,
    );
    if (preflightMessage != null) {
      _showMessage(preflightMessage);
      return;
    }

    final remotePath = joinRemotePath(_currentPath, file.filename);
    try {
      final bytes = await _readFileBytes(remotePath, _maxEditableBytes + 1);

      final loadedMessage = resolveSftpTextEditBlockMessage(
        byteCount: bytes.length,
        loadedBytes: bytes,
      );
      if (loadedMessage != null) {
        _showMessage(loadedMessage);
        return;
      }

      final decodedText = utf8.decode(bytes, allowMalformed: true);
      final detectedLanguage = detectLanguageFromFilename(file.filename);
      final useHighlighting =
          detectedLanguage != null && bytes.length <= syntaxHighlightSizeLimit;

      if (!mounted) {
        return;
      }
      final brightness = Theme.of(context).brightness;
      final navigator = Navigator.of(context);
      final host = await ref
          .read(hostRepositoryProvider)
          .getById(widget.hostId);
      final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
      final preferredConnectionId =
          widget.connectionId ??
          sessionsNotifier.getPreferredConnectionForHost(widget.hostId);
      final session = preferredConnectionId == null
          ? null
          : sessionsNotifier.getSession(preferredConnectionId);
      final monetizationState =
          ref.read(monetizationStateProvider).asData?.value ??
          ref.read(monetizationServiceProvider).currentState;
      final useHostThemeOverrides = monetizationState.allowsFeature(
        MonetizationFeature.hostSpecificThemes,
      );
      final terminalThemeSettings = ref.read(terminalThemeSettingsProvider);
      final terminalThemes =
          ref.read(allTerminalThemesProvider).asData?.value ??
          TerminalThemes.all;
      final editorTheme = resolveConnectionPreviewTheme(
        brightness: brightness,
        themeSettings: terminalThemeSettings,
        availableThemes: terminalThemes,
        lightThemeId:
            session?.terminalThemeLightId ??
            (useHostThemeOverrides ? host?.terminalThemeLightId : null),
        darkThemeId:
            session?.terminalThemeDarkId ??
            (useHostThemeOverrides ? host?.terminalThemeDarkId : null),
      );
      final fontFamily =
          host?.terminalFontFamily ??
          ref.read(fontFamilyNotifierProvider) ??
          'monospace';
      final initialFontSize =
          session?.terminalFontSize ?? ref.read(fontSizeNotifierProvider) ?? 14;

      final TextEditingController controller;
      if (useHighlighting) {
        final syntaxTheme = buildSyntaxThemeFromTerminal(editorTheme);
        controller = SyntaxHighlightController(
          text: decodedText,
          language: detectedLanguage,
          theme: syntaxTheme,
        );
      } else {
        controller = TextEditingController(text: decodedText);
      }

      if (!mounted) {
        controller.dispose();
        return;
      }
      final saved = await navigator.push<bool>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (context) => RemoteTextEditorScreen(
            fileName: file.filename,
            filePath: remotePath,
            controller: controller,
            onSave: (text) => ref
                .read(remoteFileServiceProvider)
                .uploadBytes(
                  sftp: _sftp!,
                  remotePath: remotePath,
                  bytes: Uint8List.fromList(utf8.encode(text)),
                  applyPrivateMode: false,
                ),
            terminalTheme: editorTheme,
            fontFamily: fontFamily,
            initialFontSize: initialFontSize,
          ),
        ),
      );
      controller.dispose();
      if (saved != true) {
        return;
      }

      await _loadDirectory(_currentPath);
      _showMessage('Saved "${file.filename}"');
    } on Object catch (e) {
      if (e is! Exception && !isExpectedSshOperationError(e)) {
        rethrow;
      }
      _showSftpFailureSnackBar(
        message: 'Could not save changes. Check permissions and try again.',
        eventName: 'edit_failed',
        error: e,
      );
    }
  }

  void _showSftpFailureSnackBar({
    required String message,
    required String eventName,
    required Object error,
  }) {
    DiagnosticsLogService.instance.warning(
      'sftp',
      eventName,
      fields: {'errorType': error.runtimeType},
    );
    _showMessage(message);
  }
}

class _CreateDirectoryDialog extends StatefulWidget {
  const _CreateDirectoryDialog({required this.currentPath});

  final String currentPath;

  @override
  State<_CreateDirectoryDialog> createState() => _CreateDirectoryDialogState();
}

class _CreateDirectoryDialogState extends State<_CreateDirectoryDialog> {
  late final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: _controller,
        builder: (context, value, _) {
          final validationMessage = validateSftpDirectoryName(value.text);
          final canCreate = validationMessage == null;

          return AlertDialog(
            title: const Text('Create Folder'),
            content: TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: 'Folder name',
                helperText: 'Created inside ${widget.currentPath}',
                errorText: value.text.isEmpty ? null : validationMessage,
              ),
              onSubmitted: canCreate ? _submit : null,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: canCreate ? () => _submit(value.text) : null,
                child: const Text('Create'),
              ),
            ],
          );
        },
      );

  void _submit(String value) {
    final trimmed = value.trim();
    if (validateSftpDirectoryName(trimmed) != null) {
      return;
    }
    Navigator.pop(context, trimmed);
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initialName});

  final String initialName;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Rename'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      decoration: const InputDecoration(labelText: 'New name'),
      textInputAction: TextInputAction.done,
      onSubmitted: _submit,
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => _submit(_controller.text),
        child: const Text('Rename'),
      ),
    ],
  );

  void _submit(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return;
    }
    Navigator.pop(context, trimmed);
  }
}

class _FileListTile extends StatelessWidget {
  const _FileListTile({
    required this.file,
    required this.onTap,
    this.onLongPress,
    this.onShowOptions,
    this.isHighlighted = false,
    this.disabledReason,
    this.trailingIcon,
    this.trailingTooltip,
    this.semanticsLabel,
    this.semanticsHint,
  });

  final SftpName file;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onShowOptions;
  final bool isHighlighted;
  final String? disabledReason;
  final IconData? trailingIcon;
  final String? trailingTooltip;
  final String? semanticsLabel;
  final String? semanticsHint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDirectory = file.attr.isDirectory;
    final isDisabled = disabledReason != null;
    final iconColor = isHighlighted
        ? theme.colorScheme.onPrimaryContainer
        : isDisabled
        ? theme.colorScheme.onSurfaceVariant
        : isDirectory
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    final trailingIconColor = isHighlighted
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurfaceVariant;
    final sizeLabel = Text(
      formatRemoteFileSize(file.attr.size ?? 0),
      style: FluttyTheme.monoStyle.copyWith(
        fontSize: 12,
        color: trailingIconColor,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final subtitle = isDirectory
        ? null
        : !isDisabled
        ? sizeLabel
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (file.attr.size != null) sizeLabel,
              Text(
                disabledReason!,
                style: FluttyTheme.monoStyle.copyWith(
                  fontSize: 12,
                  color: isHighlighted
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.error,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          );

    Widget? trailingIconWidget;
    if (trailingIcon != null) {
      trailingIconWidget = Icon(
        trailingIcon,
        size: 20,
        color: trailingIconColor,
      );
      if (trailingTooltip != null) {
        trailingIconWidget = Tooltip(
          message: trailingTooltip,
          child: trailingIconWidget,
        );
      }
    }
    final tile = ListTile(
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      minVerticalPadding: 2,
      minLeadingWidth: 32,
      tileColor: isHighlighted ? theme.colorScheme.primaryContainer : null,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      leading: Icon(
        resolveSftpFileIcon(isDirectory: isDirectory, filename: file.filename),
        color: iconColor,
      ),
      title: Text(
        file.filename,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: isHighlighted
            ? FluttyTheme.monoStyle.copyWith(
                fontSize: 14,
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              )
            : FluttyTheme.monoStyle.copyWith(
                fontSize: 14,
                color: isDisabled
                    ? theme.colorScheme.onSurface.withAlpha(170)
                    : theme.colorScheme.onSurface,
              ),
      ),
      subtitle: subtitle,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isDirectory)
            Icon(Icons.chevron_right, size: 20, color: trailingIconColor),
          ?trailingIconWidget,
          if (onShowOptions != null)
            IconButton(
              onPressed: onShowOptions,
              icon: const Icon(Icons.more_vert),
              color: trailingIconColor,
              tooltip: 'More actions for ${file.filename}',
            ),
        ],
      ),
      onTap: onTap,
      onLongPress: onLongPress,
    );

    if (semanticsLabel == null && semanticsHint == null) {
      return tile;
    }

    return Semantics(
      button: true,
      selected: isHighlighted,
      label: semanticsLabel,
      hint: semanticsHint,
      child: ExcludeSemantics(child: tile),
    );
  }
}

class _RemoteFileSelectionBar extends StatelessWidget {
  const _RemoteFileSelectionBar({
    required this.selectedCount,
    required this.summaryText,
    required this.onCancel,
    required this.onConfirm,
  });

  final int selectedCount;
  final String summaryText;
  final VoidCallback onCancel;
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaQuery = MediaQuery.of(context);
    final isWide = mediaQuery.size.width >= 720;
    final confirmLabel = selectedCount == 0
        ? 'Select'
        : selectedCount == 1
        ? 'Select 1 file'
        : 'Select $selectedCount files';

    final cancelButton = OutlinedButton.icon(
      onPressed: onCancel,
      icon: const Icon(Icons.close),
      label: const Text('Cancel'),
    );
    final confirmButton = FilledButton.icon(
      onPressed: onConfirm,
      icon: const Icon(Icons.check),
      label: Text(confirmLabel),
    );
    final buttons = Row(
      mainAxisSize: isWide ? MainAxisSize.min : MainAxisSize.max,
      children: [
        if (isWide) cancelButton else Expanded(child: cancelButton),
        const SizedBox(width: 12),
        if (isWide) confirmButton else Expanded(child: confirmButton),
      ],
    );
    final summary = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'remote file selection',
          style: FluttyTheme.displayMono(
            fontSize: 16,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          summaryText,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    final content = isWide
        ? Row(
            children: [
              Expanded(child: summary),
              const SizedBox(width: 16),
              buttons,
            ],
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [summary, const SizedBox(height: 12), buttons],
          );

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
        child: SafeArea(
          top: false,
          child: Align(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: FluttyTheme.monoStyle.copyWith(
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ],
    ),
  );
}

class _RemoteVideoDownloadProgress {
  const _RemoteVideoDownloadProgress({
    required this.remotePath,
    required this.downloadedBytes,
    required this.totalBytes,
  });

  final String remotePath;
  final int downloadedBytes;
  final int totalBytes;

  double? get fraction =>
      totalBytes <= 0 ? null : (downloadedBytes / totalBytes).clamp(0.0, 1.0);

  _RemoteVideoDownloadProgress copyWith({int? downloadedBytes}) =>
      _RemoteVideoDownloadProgress(
        remotePath: remotePath,
        downloadedBytes: downloadedBytes ?? this.downloadedBytes,
        totalBytes: totalBytes,
      );
}

class _CachedRemoteVideo {
  const _CachedRemoteVideo({
    required this.localFile,
    required this.downloadedBytes,
  });

  final File localFile;
  final int downloadedBytes;
}

Future<void> _deleteCachedRemoteVideoFile(File file) async {
  try {
    await file.delete();
  } on FileSystemException {
    // Best-effort cleanup; temp storage may already have removed the file.
  }
}

void _deleteCachedRemoteVideoFileSync(File file) {
  try {
    file.deleteSync();
  } on FileSystemException {
    // Best-effort cleanup; temp storage may already have removed the file.
  }
}

class _RemoteVideoCacheDialogResult {
  const _RemoteVideoCacheDialogResult.success(this.cacheResult)
    : error = null,
      cancelled = false;

  const _RemoteVideoCacheDialogResult.failure(this.error)
    : cacheResult = null,
      cancelled = false;

  const _RemoteVideoCacheDialogResult.cancelled()
    : cacheResult = null,
      error = null,
      cancelled = true;

  final _CachedRemoteVideo? cacheResult;
  final Object? error;
  final bool cancelled;
}

class _RemoteVideoCachingDialog extends StatefulWidget {
  const _RemoteVideoCachingDialog({
    required this.fileName,
    required this.progressListenable,
    required this.downloadFuture,
    required this.onCancel,
  });

  final String fileName;
  final ValueListenable<_RemoteVideoDownloadProgress> progressListenable;
  final Future<_CachedRemoteVideo> downloadFuture;
  final VoidCallback onCancel;

  @override
  State<_RemoteVideoCachingDialog> createState() =>
      _RemoteVideoCachingDialogState();
}

class _RemoteVideoCachingDialogState extends State<_RemoteVideoCachingDialog> {
  var _completed = false;

  void _complete(_RemoteVideoCacheDialogResult result) {
    if (_completed || !mounted) return;
    _completed = true;
    Navigator.of(context).pop(result);
  }

  @override
  void initState() {
    super.initState();
    widget.downloadFuture.then<void>(
      (cacheResult) =>
          _complete(_RemoteVideoCacheDialogResult.success(cacheResult)),
      onError: (Object error, StackTrace _) =>
          _complete(_RemoteVideoCacheDialogResult.failure(error)),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Loading video preview'),
    content: ValueListenableBuilder<_RemoteVideoDownloadProgress>(
      valueListenable: widget.progressListenable,
      builder: (context, progress, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
          Text(
            progress.remotePath,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          LinearProgressIndicator(value: progress.fraction),
          const SizedBox(height: 8),
          Text(
            progress.totalBytes > 0
                ? '${formatRemoteFileSize(progress.downloadedBytes)} of '
                      '${formatRemoteFileSize(progress.totalBytes)}'
                : '${formatRemoteFileSize(progress.downloadedBytes)} loaded',
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () {
          if (_completed) return;
          _complete(const _RemoteVideoCacheDialogResult.cancelled());
          widget.onCancel();
        },
        child: const Text('Cancel'),
      ),
    ],
  );
}

class _RemoteVideoViewerScreen extends StatefulWidget {
  const _RemoteVideoViewerScreen({
    required this.fileName,
    required this.localFile,
    required this.remotePath,
    required this.sizeBytes,
    this.modifiedAt,
    this.mimeType,
    this.initialError,
  });

  final String fileName;
  final File localFile;
  final String remotePath;
  final int sizeBytes;
  final DateTime? modifiedAt;
  final String? mimeType;
  final String? initialError;

  @override
  State<_RemoteVideoViewerScreen> createState() =>
      _RemoteVideoViewerScreenState();
}

class _RemoteVideoViewerScreenState extends State<_RemoteVideoViewerScreen> {
  VideoPlayerController? _controller;
  String? _error;
  var _keepCachedFile = false;

  @override
  void initState() {
    super.initState();
    _error = widget.initialError;
    if (_error == null) {
      unawaited(_initializeController());
    }
  }

  Future<void> _initializeController() async {
    final controller = VideoPlayerController.file(widget.localFile);
    _controller = controller..addListener(_handleVideoValueChanged);
    try {
      await controller.initialize();
      if (!mounted) {
        return;
      }
      setState(() {});
    } on Object catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'sftp',
          context: ErrorDescription('while initializing remote video preview'),
        ),
      );
      if (mounted) {
        setState(() {
          _error = _playbackErrorMessage(error);
        });
      }
    }
  }

  void _handleVideoValueChanged() {
    final controller = _controller;
    if (!mounted || controller == null) {
      return;
    }
    final value = controller.value;
    if (value.hasError) {
      final message = _playbackErrorMessage(
        value.errorDescription ?? 'Unknown playback error',
      );
      if (_error != message) {
        setState(() {
          _error = message;
        });
      }
      return;
    }
    if (_error == null) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) {
      controller.removeListener(_handleVideoValueChanged);
      unawaited(_disposeControllerAndCachedFile(controller));
    } else if (!_keepCachedFile) {
      _deleteCachedRemoteVideoFileSync(widget.localFile);
    }
    super.dispose();
  }

  Future<void> _disposeControllerAndCachedFile(
    VideoPlayerController controller,
  ) async {
    await controller.dispose();
    if (!_keepCachedFile) {
      await _deleteCachedRemoteVideoFile(widget.localFile);
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    final controller = _controller;

    return Scaffold(
      appBar: AppBar(
        title: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text(widget.remotePath),
        ),
      ),
      body: error != null
          ? _buildErrorBody(context, error)
          : controller == null || !controller.value.isInitialized
          ? _buildLoadingBody(context)
          : _buildPlayerBody(context, controller),
    );
  }

  Widget _buildLoadingBody(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        const Text('Preparing video playback…'),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _buildMetadataCard(context),
        ),
      ],
    ),
  );

  Widget _buildPlayerBody(
    BuildContext context,
    VideoPlayerController controller,
  ) {
    final theme = Theme.of(context);
    final videoValue = controller.value;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        DecoratedBox(
          decoration: const BoxDecoration(color: Colors.black),
          child: AspectRatio(
            aspectRatio: videoValue.aspectRatio == 0
                ? 16 / 9
                : videoValue.aspectRatio,
            child: VideoPlayer(controller),
          ),
        ),
        const SizedBox(height: 12),
        _buildPlaybackControls(context, controller),
        const SizedBox(height: 16),
        Text('Remote video', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        _buildMetadataCard(context),
      ],
    );
  }

  Widget _buildErrorBody(BuildContext context, String error) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Icon(
        Icons.video_file_outlined,
        size: 64,
        color: Theme.of(context).colorScheme.error,
      ),
      const SizedBox(height: 16),
      Text(
        'Could not play video preview',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 8),
      Text(error, textAlign: TextAlign.center),
      const SizedBox(height: 16),
      Text(
        'The cached file is still available. Save it locally or open/share it '
        'with another app that supports this codec.',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      const SizedBox(height: 24),
      Wrap(
        alignment: WrapAlignment.center,
        spacing: 12,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: _exportCachedCopy,
            icon: const Icon(Icons.download),
            label: const Text('Save copy'),
          ),
          FilledButton.icon(
            onPressed: () => _exportCachedCopy(share: true),
            icon: const Icon(Icons.ios_share),
            label: const Text('Open/Share'),
          ),
        ],
      ),
      const SizedBox(height: 24),
      _buildMetadataCard(context),
    ],
  );

  Widget _buildPlaybackControls(
    BuildContext context,
    VideoPlayerController controller,
  ) {
    final value = controller.value;
    final duration = value.duration;
    final position = value.position > duration ? duration : value.position;
    final canSeek = duration.inMilliseconds > 0;
    final max = canSeek ? duration.inMilliseconds.toDouble() : 1.0;
    final sliderValue = canSeek
        ? position.inMilliseconds.clamp(0, duration.inMilliseconds).toDouble()
        : 0.0;

    return Column(
      children: [
        Row(
          children: [
            IconButton.filled(
              onPressed: () {
                if (value.isPlaying) {
                  unawaited(controller.pause());
                } else {
                  unawaited(controller.play());
                }
              },
              icon: Icon(value.isPlaying ? Icons.pause : Icons.play_arrow),
              tooltip: value.isPlaying ? 'Pause' : 'Play',
            ),
            const SizedBox(width: 12),
            Text(_formatVideoDuration(position)),
            Expanded(
              child: Slider(
                value: sliderValue,
                max: max,
                onChanged: canSeek
                    ? (value) => unawaited(
                        controller.seekTo(
                          Duration(milliseconds: value.round()),
                        ),
                      )
                    : null,
              ),
            ),
            Text(_formatVideoDuration(duration)),
          ],
        ),
      ],
    );
  }

  Widget _buildMetadataCard(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _InfoRow('Path', widget.remotePath),
          _InfoRow('Size', formatRemoteFileSize(widget.sizeBytes)),
          if (widget.modifiedAt != null)
            _InfoRow(
              'Modified',
              widget.modifiedAt!.toString().split('.').first,
            ),
          _InfoRow('MIME', widget.mimeType ?? 'Unknown'),
          _InfoRow('Cached copy', widget.localFile.path),
        ],
      ),
    ),
  );

  Future<void> _exportCachedCopy({bool share = false}) async {
    try {
      final result = await _exportLocalFile(
        context,
        file: widget.localFile,
        fileName: widget.fileName,
        mimeType: widget.mimeType,
        share: share,
      );
      _keepCachedFile |= result == _LocalFileExport.shared;
      if (mounted && result == _LocalFileExport.saved) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Saved "${widget.fileName}"')));
      } else if (mounted && share && result == _LocalFileExport.cancelled) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Open/share cancelled')));
      }
    } on Exception catch (error) {
      DiagnosticsLogService.instance.warning(
        'sftp.preview',
        'export_failed',
        fields: {'errorType': error.runtimeType},
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not export the file. Try again.'),
          ),
        );
      }
    }
  }

  String _playbackErrorMessage(Object _) =>
      'This platform could not decode or play the video. Try saving or '
      'opening the cached copy in another app.';

  String _formatVideoDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }
}

class _RemoteImageViewerScreen extends StatelessWidget {
  const _RemoteImageViewerScreen({
    required this.remotePath,
    required this.bytes,
    required this.isSvg,
  });

  final String remotePath;
  final Uint8List bytes;
  final bool isSvg;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      title: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(remotePath),
      ),
    ),
    body: InteractiveViewer(
      maxScale: 8,
      minScale: 0.5,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: isSvg
              ? Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(16),
                  child: SvgPicture.memory(bytes),
                )
              : Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) => Text(
                    'Could not render image preview',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: Colors.white),
                  ),
                ),
        ),
      ),
    ),
  );
}
