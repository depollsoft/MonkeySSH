import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import 'diagnostics_log_service.dart';

final _sftpWindowsDriveRootPattern = RegExp(r'^/?[A-Za-z]:(?:/|$)');
final _terminalControlCharacterPattern = RegExp(r'[\x00-\x1f\x7f-\x9f]');

/// Display path for files pasted directly into a terminal session.
const remoteClipboardUploadDirectoryDisplay = '~/.cache/monkeyssh/uploads';

/// Windows display path for files pasted directly into a terminal session.
const remoteClipboardWindowsUploadDirectoryDisplay =
    r'%USERPROFILE%\.cache\monkeyssh\uploads';

/// Private directory permissions for terminal upload staging directories.
final remoteUploadDirectoryMode = SftpFileMode(
  groupRead: false,
  groupWrite: false,
  groupExecute: false,
  otherRead: false,
  otherWrite: false,
  otherExecute: false,
);

/// Private file permissions for terminal upload staging files.
final remoteUploadFileMode = SftpFileMode(
  userExecute: false,
  groupRead: false,
  groupWrite: false,
  groupExecute: false,
  otherRead: false,
  otherWrite: false,
  otherExecute: false,
);

/// Remote path syntax to use when building paths.
enum RemotePathStyle {
  /// SFTP/POSIX path syntax using `/` separators.
  sftp,

  /// Windows shell path syntax using `\` separators.
  windows,
}

/// Returns the user-facing terminal upload directory display path.
String remoteClipboardUploadDirectoryDisplayFor({required bool windows}) =>
    windows
    ? remoteClipboardWindowsUploadDirectoryDisplay
    : remoteClipboardUploadDirectoryDisplay;

/// Builds the remote directory for files pasted directly into a terminal.
String buildRemoteClipboardUploadDirectory(
  String homeDirectory, {
  RemotePathStyle style = RemotePathStyle.sftp,
}) => joinRemotePath(homeDirectory, '.cache/monkeyssh/uploads', style: style);

/// Builds the app-owned parent directory for terminal uploads.
String buildRemoteClipboardUploadParentDirectory(
  String homeDirectory, {
  RemotePathStyle style = RemotePathStyle.sftp,
}) => joinRemotePath(homeDirectory, '.cache/monkeyssh', style: style);

String _normalizeSftpPathSeparators(String value) =>
    value.replaceAll(r'\', '/');

({String root, String rest})? _splitSftpWindowsDriveRoot(String remotePath) {
  final match = _sftpWindowsDriveRootPattern.matchAsPrefix(remotePath);
  if (match == null) {
    return null;
  }

  final matchedRoot = remotePath.substring(0, match.end);
  final root = matchedRoot.endsWith('/') ? matchedRoot : '$matchedRoot/';
  return (root: root, rest: remotePath.substring(match.end));
}

List<String> _normalizeSftpPathSegments(String pathSuffix) {
  final segments = <String>[];
  for (final segment in pathSuffix.split('/')) {
    if (segment.isEmpty || segment == '.') {
      continue;
    }
    if (segment == '..') {
      if (segments.isNotEmpty) {
        segments.removeLast();
      }
      continue;
    }
    segments.add(segment);
  }
  return segments;
}

/// Whether [remotePath] is an absolute SFTP path.
bool isSftpAbsolutePath(String remotePath) =>
    normalizeSftpAbsolutePath(remotePath) != null;

/// Returns the root segment for an absolute SFTP path.
String? sftpPathRoot(String remotePath) {
  final normalizedPath = normalizeSftpAbsolutePath(remotePath);
  if (normalizedPath == null) {
    return null;
  }
  if (normalizedPath == '/') {
    return '/';
  }
  return _splitSftpWindowsDriveRoot(normalizedPath)?.root;
}

/// Whether [remotePath] is the root of an SFTP path hierarchy.
bool isSftpPathRoot(String remotePath) {
  final normalizedPath = normalizeSftpAbsolutePath(remotePath);
  if (normalizedPath == null) {
    return false;
  }
  return normalizedPath == sftpPathRoot(normalizedPath);
}

/// Returns the parent directory for an absolute SFTP path.
String parentSftpPath(String remotePath) {
  final normalizedPath = normalizeSftpAbsolutePath(remotePath);
  if (normalizedPath == null) {
    final parent = path.posix.dirname(_normalizeSftpPathSeparators(remotePath));
    return parent.isEmpty || parent == '.' ? '/' : parent;
  }
  if (normalizedPath == '/') {
    return '/';
  }

  final windowsRoot = _splitSftpWindowsDriveRoot(normalizedPath);
  if (windowsRoot != null) {
    if (normalizedPath == windowsRoot.root) {
      return windowsRoot.root;
    }
    final trimmedPath = normalizedPath.endsWith('/')
        ? normalizedPath.substring(0, normalizedPath.length - 1)
        : normalizedPath;
    final slashIndex = trimmedPath.lastIndexOf('/');
    if (slashIndex < windowsRoot.root.length) {
      return windowsRoot.root;
    }
    return trimmedPath.substring(0, slashIndex);
  }

  final parent = path.posix.dirname(normalizedPath);
  return parent.isEmpty || parent == '.' ? '/' : parent;
}

/// Joins a remote directory and child name into a normalized absolute path.
String joinRemotePath(
  String directory,
  String name, {
  RemotePathStyle style = RemotePathStyle.sftp,
}) {
  if (style == RemotePathStyle.windows) {
    return _joinWindowsRemotePath(directory, name);
  }

  final baseDirectory =
      normalizeSftpAbsolutePath(directory) ??
      (directory.isEmpty ? '/' : _normalizeSftpPathSeparators(directory));
  final nameWithRemoteSeparators =
      _splitSftpWindowsDriveRoot(baseDirectory) == null
      ? name
      : _normalizeSftpPathSeparators(name);
  final cleanName = nameWithRemoteSeparators.replaceFirst(RegExp('^/+'), '');
  final joined = path.posix.join(baseDirectory, cleanName);
  final normalized = normalizeSftpAbsolutePath(joined);
  if (normalized != null) {
    return normalized;
  }
  final normalizedRelative = path.posix.normalize(joined);
  return normalizedRelative.startsWith('/')
      ? normalizedRelative
      : '/$normalizedRelative';
}

String _joinWindowsRemotePath(String directory, String name) {
  final cleanName = name.replaceFirst(RegExp(r'^[\\/]+'), '');
  final baseDirectory = directory.isEmpty
      ? r'\'
      : sftpPathToWindowsShellPath(directory);
  return path.windows.normalize(path.windows.join(baseDirectory, cleanName));
}

/// Converts a Windows OpenSSH SFTP path into a native Windows shell path.
///
/// OpenSSH SFTP reports drive paths as `/C:/Users/...`; cmd.exe and PowerShell
/// expect `C:\Users\...`.
String sftpPathToWindowsShellPath(String sftpPath) {
  var normalized = sftpPath.trim();
  if (RegExp(r'^/[A-Za-z]:($|/)').hasMatch(normalized)) {
    normalized = normalized.substring(1);
  }
  return normalized.replaceAll('/', r'\');
}

/// Converts an SFTP path into the path syntax expected by the remote shell.
String remoteShellPathForSftpPath(String sftpPath, {required bool windows}) =>
    windows ? sftpPathToWindowsShellPath(sftpPath) : sftpPath;

/// Normalizes an absolute remote path by collapsing `.`, `..`, and extra `/`.
String? normalizeSftpAbsolutePath(String? remotePath) {
  final trimmedPath = remotePath?.trim();
  if (trimmedPath == null || trimmedPath.isEmpty) {
    return null;
  }

  final normalizedSeparators = _normalizeSftpPathSeparators(trimmedPath);
  final windowsRoot = _splitSftpWindowsDriveRoot(normalizedSeparators);
  if (windowsRoot != null) {
    final segments = _normalizeSftpPathSegments(windowsRoot.rest);
    return segments.isEmpty
        ? windowsRoot.root
        : '${windowsRoot.root}${segments.join('/')}';
  }

  if (!normalizedSeparators.startsWith('/')) {
    return null;
  }

  final segments = _normalizeSftpPathSegments(normalizedSeparators);
  return segments.isEmpty ? '/' : '/${segments.join('/')}';
}

/// Resolves a requested SFTP path against terminal context.
String? resolveRequestedSftpPath(
  String? requestedPath, {
  String? workingDirectory,
  String? homeDirectory,
}) {
  final trimmedPath = requestedPath?.trim();
  if (trimmedPath == null || trimmedPath.isEmpty) {
    return null;
  }

  if (isSftpAbsolutePath(trimmedPath)) {
    return normalizeSftpAbsolutePath(trimmedPath);
  }

  if (trimmedPath == '~' || trimmedPath.startsWith('~/')) {
    final normalizedHomeDirectory = normalizeSftpAbsolutePath(homeDirectory);
    if (normalizedHomeDirectory == null) {
      return null;
    }
    if (trimmedPath == '~') {
      return normalizedHomeDirectory;
    }
    return normalizeSftpAbsolutePath(
      joinRemotePath(normalizedHomeDirectory, trimmedPath.substring(2)),
    );
  }

  final normalizedWorkingDirectory = normalizeSftpAbsolutePath(
    workingDirectory,
  );
  if (normalizedWorkingDirectory == null) {
    return null;
  }

  return normalizeSftpAbsolutePath(
    joinRemotePath(normalizedWorkingDirectory, trimmedPath),
  );
}

/// Sanitizes a filename for remote uploads.
///
/// Restricts the name to a strict shell-safe allowlist (letters, digits, `.`,
/// `_`, `-`) so the resulting remote path can be pasted into the terminal
/// unquoted. Unquoted paths are required for agent CLIs (e.g. Copilot CLI) to
/// recognise a pasted path as an attachment, and the allowlist keeps the file
/// extension intact so image previews still resolve.
String sanitizeRemoteUploadFileName(String name) {
  final sanitized = path
      .basename(name)
      .trim()
      .replaceAll(RegExp('[^A-Za-z0-9._-]'), '-')
      .replaceAll(RegExp('-+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  // A name made only of dots (`.`, `..`) is a path-traversal token rather than a
  // file, so fall back to a literal name even though it survives the allowlist.
  if (sanitized.isEmpty || RegExp(r'^\.+$').hasMatch(sanitized)) {
    return 'file';
  }
  return sanitized;
}

/// Creates a unique remote filename for clipboard uploads.
String buildClipboardUploadFileName(
  String originalName,
  DateTime timestamp, {
  int sequence = 0,
}) {
  final safeName = sanitizeRemoteUploadFileName(originalName);
  return 'clipboard-${timestamp.toUtc().millisecondsSinceEpoch}-$sequence-$safeName';
}

/// Builds a remote filename for clipboard image uploads.
String buildClipboardImageFileName(DateTime timestamp, {int sequence = 0}) =>
    buildClipboardUploadFileName('image.png', timestamp, sequence: sequence);

/// Formats a byte count into a human-readable file size.
String formatRemoteFileSize(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// Whether the byte sample looks like binary content.
bool looksLikeBinaryContent(Uint8List bytes) {
  final sample = bytes.length > 1024 ? bytes.sublist(0, 1024) : bytes;
  return sample.contains(0);
}

/// Escapes a path so it can be pasted directly into a POSIX shell.
String shellEscapePosix(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// Escapes a path so it can be pasted directly into a Windows shell.
String shellEscapeWindows(String value) {
  if (value.isEmpty) {
    return '""';
  }
  return '"${value.replaceAll('"', '')}"';
}

/// Bracketed-paste introducer and terminator (`CSI 200~` / `CSI 201~`).
const _bracketedPasteStart = '\x1b[200~';
const _bracketedPasteEnd = '\x1b[201~';

bool _isTerminalSafeAttachmentPath(String path) =>
    !_terminalControlCharacterPattern.hasMatch(path);

bool _isUnquotedAttachmentPath(String path, {required bool windows}) {
  final safePathPattern = windows
      ? RegExp(r'^[A-Za-z0-9._/\\:-]+$')
      : RegExp(r'^[A-Za-z0-9._/-]+$');
  return safePathPattern.hasMatch(path);
}

bool _isRawAgentAttachmentPath(String path, {required bool windows}) {
  final safePathPattern = windows
      ? RegExp(r'^[A-Za-z0-9._/\\: -]+$')
      : RegExp(r'^[A-Za-z0-9._/ -]+$');
  return safePathPattern.hasMatch(path);
}

String _shellEscapeAttachmentPath(String path, {required bool windows}) =>
    windows ? shellEscapeWindows(path) : shellEscapePosix(path);

/// Builds the terminal-input segments that reference uploaded [remotePaths]
/// after a paste upload.
///
/// When [bracketedPasteMode] is true, each path containing only normal path
/// characters (including spaces) is returned as its own bracketed-paste segment
/// (`CSI 200~ <path> CSI 201~ ` with a trailing space). The raw path stays
/// unquoted for paths that are shell-safe, and also for space-containing paths
/// when [preferRawAgentPaths] confirms an agent CLI owns the pane. Other
/// printable paths are shell-escaped inside the framing.
///
/// When bracketed paste is not requested, paths are shell-escaped for the
/// current remote shell and returned as one segment. Paths containing terminal
/// control characters are omitted in either mode because they cannot be safely
/// represented as terminal input.
///
/// Segments must be written straight to the session input sink (e.g.
/// `Terminal.onOutput`), not through `Terminal.paste`, which would strip the
/// bracketed-paste control sequences.
List<String> buildTerminalAttachmentPasteSegments(
  Iterable<String> remotePaths, {
  required bool bracketedPasteMode,
  bool windows = false,
  bool preferRawAgentPaths = false,
}) {
  final paths = remotePaths
      .where(
        (remotePath) =>
            remotePath.isNotEmpty && _isTerminalSafeAttachmentPath(remotePath),
      )
      .toList();
  if (paths.isEmpty) {
    return const [];
  }
  if (!bracketedPasteMode) {
    return [
      '${paths.map((path) => _shellEscapeAttachmentPath(path, windows: windows)).join(' ')} ',
    ];
  }
  return paths.map((remotePath) {
    final useRawPath =
        _isUnquotedAttachmentPath(remotePath, windows: windows) ||
        (preferRawAgentPaths &&
            _isRawAgentAttachmentPath(remotePath, windows: windows));
    final payload = useRawPath
        ? remotePath
        : _shellEscapeAttachmentPath(remotePath, windows: windows);
    return '$_bracketedPasteStart$payload$_bracketedPasteEnd ';
  }).toList();
}

/// Counts paths that can be safely represented as terminal attachment input.
int countTerminalAttachmentPastePaths(Iterable<String> remotePaths) =>
    remotePaths
        .where(
          (remotePath) =>
              remotePath.isNotEmpty &&
              _isTerminalSafeAttachmentPath(remotePath),
        )
        .length;

/// Signals cancellation to active remote file downloads.
class RemoteFileDownloadCancelToken {
  final _callbacks = <void Function()>[];
  var _isCancelled = false;

  /// Cancels current and future downloads using this token.
  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    for (final callback in _callbacks) {
      callback();
    }
  }

  /// Throws if cancellation has been requested.
  void throwIfCancelled() {
    if (_isCancelled) throw const RemoteFileDownloadCancelledException();
  }
}

/// A remote file download was cancelled.
class RemoteFileDownloadCancelledException implements Exception {
  /// Creates a cancellation exception.
  const RemoteFileDownloadCancelledException();

  @override
  String toString() => 'Download cancelled';
}

/// A download exceeded its configured byte limit.
class RemoteFileDownloadLimitException implements Exception {
  /// Creates an exception with the observed byte count.
  const RemoteFileDownloadLimitException(this.byteCount);

  /// Number of bytes received, including the chunk exceeding the limit.
  final int byteCount;

  @override
  String toString() => 'Download exceeds byte limit';
}

/// Shared helpers for remote file transfers over SFTP.
final remoteFileServiceProvider = Provider<RemoteFileService>(
  (ref) => const RemoteFileService(),
);

/// Shared helpers for remote file transfers over SFTP.
class RemoteFileService {
  /// Creates a new [RemoteFileService].
  const RemoteFileService();

  /// Resolves the remote home directory for an SFTP session.
  Future<String> resolveInitialDirectory(SftpClient sftp) => sftp.absolute('.');

  /// Ensures the target remote directory exists.
  Future<void> ensureDirectoryExists(
    SftpClient sftp,
    String remotePath, {
    SftpFileMode? mode,
  }) async {
    try {
      final stat = await sftp.stat(remotePath);
      if (!stat.isDirectory) {
        throw FileSystemException(
          'Remote path exists but is not a directory',
          remotePath,
        );
      }
      if (mode != null) {
        await sftp.setStat(remotePath, SftpFileAttrs(mode: mode));
      }
      return;
    } on SftpStatusError catch (error) {
      if (error.code != SftpStatusCode.noSuchFile) {
        rethrow;
      }
    }

    final parentPath = parentSftpPath(remotePath);
    if (parentPath != remotePath) {
      await ensureDirectoryExists(sftp, parentPath);
    }
    try {
      await sftp.mkdir(
        remotePath,
        mode == null ? null : SftpFileAttrs(mode: mode),
      );
      if (mode != null) {
        await sftp.setStat(remotePath, SftpFileAttrs(mode: mode));
      }
    } on SftpStatusError catch (error, stackTrace) {
      try {
        final stat = await sftp.stat(remotePath);
        if (stat.isDirectory) {
          if (mode != null) {
            await sftp.setStat(remotePath, SftpFileAttrs(mode: mode));
          }
          return;
        }
      } on SftpStatusError {
        Error.throwWithStackTrace(error, stackTrace);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Downloads a remote file to a local path.
  ///
  /// Progress reports bytes written to disk. The caller owns partial-file
  /// cleanup on failure. Completion includes closing both file handles.
  Future<void> downloadFile({
    required SftpClient sftp,
    required String remotePath,
    required String localPath,
    FutureOr<void> Function(int downloadedBytes)? onProgress,
    int? maxBytes,
    RemoteFileDownloadCancelToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();
    final remoteFile = await sftp.open(remotePath);
    Future<void>? closing;
    Future<void> closeRemote() => closing ??= Future.sync(remoteFile.close);
    void cancel() => unawaited(
      closeRemote().then<void>(
        (_) {},
        onError: (Object error, StackTrace _) {
          DiagnosticsLogService.instance.warning(
            'sftp.transfer',
            'cancel_close_failed',
            fields: {'errorType': error.runtimeType},
          );
        },
      ),
    );
    cancelToken?._callbacks.add(cancel);
    try {
      cancelToken?.throwIfCancelled();
      final localFile = await File(localPath).open(mode: FileMode.write);
      try {
        cancelToken?.throwIfCancelled();
        var downloadedBytes = 0;
        await for (final chunk in remoteFile.read()) {
          cancelToken?.throwIfCancelled();
          final nextBytes = downloadedBytes + chunk.length;
          if (maxBytes != null && nextBytes > maxBytes) {
            throw RemoteFileDownloadLimitException(nextBytes);
          }
          await localFile.writeFrom(chunk);
          downloadedBytes = nextBytes;
          await onProgress?.call(downloadedBytes);
        }
        cancelToken?.throwIfCancelled();
      } finally {
        await localFile.close();
      }
    } finally {
      cancelToken?._callbacks.remove(cancel);
      await closeRemote();
    }
    cancelToken?.throwIfCancelled();
  }

  /// Uploads a stream into a remote file path.
  Future<void> uploadStream({
    required SftpClient sftp,
    required String remotePath,
    required Stream<List<int>> stream,
    bool applyPrivateMode = true,
  }) async {
    final remoteFile = await sftp.open(
      remotePath,
      mode:
          SftpFileOpenMode.write |
          SftpFileOpenMode.create |
          SftpFileOpenMode.truncate,
    );
    try {
      // dartssh2's stream writer does not forward source-stream or async
      // chunk-write failures to .done. Own both futures here instead.
      var offset = 0;
      await for (final chunk in _normalizeByteStream(stream)) {
        await remoteFile.writeBytes(chunk, offset: offset);
        offset += chunk.length;
      }
    } on Object catch (error, stackTrace) {
      try {
        await remoteFile.close();
      } on Object catch (closeError) {
        // Preserve the transfer failure for the caller if cleanup also fails.
        DiagnosticsLogService.instance.warning(
          'sftp.upload',
          'close_failed',
          fields: {'errorType': closeError.runtimeType},
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    await remoteFile.close();
    if (applyPrivateMode) {
      await sftp.setStat(remotePath, SftpFileAttrs(mode: remoteUploadFileMode));
    }
  }

  /// Uploads raw bytes into a remote file path.
  Future<void> uploadBytes({
    required SftpClient sftp,
    required String remotePath,
    required Uint8List bytes,
    bool applyPrivateMode = true,
  }) => uploadStream(
    sftp: sftp,
    remotePath: remotePath,
    stream: Stream<List<int>>.value(bytes),
    applyPrivateMode: applyPrivateMode,
  );

  Stream<Uint8List> _normalizeByteStream(Stream<List<int>> stream) => stream
      .map((chunk) => chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
}
