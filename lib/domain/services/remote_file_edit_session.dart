import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart' show immutable;

import 'diagnostics_log_service.dart';
import 'remote_file_service.dart';
import 'ssh_error_policy.dart';

/// Largest loaded file that [RemoteFileEditSession.checkForChanges] re-reads
/// to compare content when its size and modified time still match.
///
/// SFTP v3 reports modified times in whole seconds, so a same-size edit made
/// within the second the file loaded only shows in its content. Re-reading is
/// a second download, so larger files rely on size and modified time alone.
const remoteEditRehashMaxBytes = 256 * 1024;

const _maxCopyAttempts = 100;
const _maxNameBytes = 255;

/// How the host's file differs from the version an editor loaded.
enum RemoteFileChange {
  /// Size, modified time and, where it was checked, content all match.
  unchanged,

  /// The file exists but no longer matches the loaded version.
  modified,

  /// Nothing exists at the path any more.
  deleted,
}

/// One version of a remote file: the server's size and modified time, plus a
/// SHA-256 of the bytes that were read.
@immutable
class RemoteFileVersion {
  /// Creates a version record.
  const RemoteFileVersion({
    required this.size,
    required this.modifyTime,
    required this.length,
    required this.digest,
  });

  /// Records [bytes] as read, with the server's [attrs] when they are known.
  factory RemoteFileVersion.of(List<int> bytes, [SftpFileAttrs? attrs]) =>
      RemoteFileVersion(
        size: attrs?.size ?? bytes.length,
        modifyTime: attrs?.modifyTime,
        length: bytes.length,
        digest: crypto.sha256.convert(bytes),
      );

  /// Size the server reported, or the byte count read when it reported none.
  final int? size;

  /// Modified time in seconds since the epoch, when the server reported one.
  final int? modifyTime;

  /// Number of bytes hashed into [digest].
  final int length;

  /// SHA-256 of the bytes that were read.
  final crypto.Digest digest;

  /// Whether [attrs] reports a different size or modified time.
  ///
  /// A field either side leaves out is not compared.
  bool metadataDiffers(SftpFileAttrs attrs) =>
      (size != null && attrs.size != null && size != attrs.size) ||
      (modifyTime != null &&
          attrs.modifyTime != null &&
          modifyTime != attrs.modifyTime);
}

/// Bytes read from a remote file and the version they came from.
@immutable
class RemoteFileSnapshot {
  /// Creates a snapshot.
  const RemoteFileSnapshot(this.bytes, this.version);

  /// The bytes read, at most the requested limit.
  final Uint8List bytes;

  /// The version [bytes] identify.
  final RemoteFileVersion version;
}

/// Tracks the version of a remote file open in an editor so a save can tell
/// whether something else changed the file in the meantime.
///
/// SFTP has no conditional write: [checkForChanges] and [save] are separate
/// requests, so a change that lands between them is still overwritten. The
/// window is a few round trips, not the whole editing session.
class RemoteFileEditSession {
  /// Creates a session for [remotePath].
  RemoteFileEditSession({
    required this.remotePath,
    this.service = const RemoteFileService(),
  });

  /// Path the editor opened, which may be a symlink.
  final String remotePath;

  /// Writes saves; replaceable in tests.
  final RemoteFileService service;

  RemoteFileVersion? _baseline;

  /// The version the editor's text is based on, once one was accepted.
  RemoteFileVersion? get baseline => _baseline;

  /// Reads at most [maxBytes] of the file along with the version they came
  /// from.
  ///
  /// The handle's attributes are read before its content, so a change between
  /// the two shows as a changed file at save time rather than going
  /// unnoticed. The result only becomes the baseline through [accept].
  Future<RemoteFileSnapshot> read(
    SftpClient sftp, {
    required int maxBytes,
  }) async {
    final file = await sftp.open(remotePath);
    try {
      SftpFileAttrs? attrs;
      try {
        attrs = await file.stat();
      } on SftpStatusError {
        // Without fstat the content hash alone identifies the version.
      }
      final bytes = await file.readBytes(length: maxBytes);
      return RemoteFileSnapshot(bytes, RemoteFileVersion.of(bytes, attrs));
    } finally {
      await file.close();
    }
  }

  /// Makes [snapshot] the version later saves are checked against.
  void accept(RemoteFileSnapshot snapshot) => _baseline = snapshot.version;

  /// Compares the host's file with the accepted baseline.
  ///
  /// A size or modified-time difference is decisive. When both match and the
  /// baseline is at most [remoteEditRehashMaxBytes], or the server gives no
  /// modified time, the file is re-read and its hash compared.
  Future<RemoteFileChange> checkForChanges(SftpClient sftp) async {
    final baseline = _baseline;
    if (baseline == null) {
      throw StateError('No baseline version was accepted');
    }
    final SftpFileAttrs attrs;
    try {
      attrs = await sftp.stat(remotePath);
    } on SftpStatusError catch (error) {
      if (error.code == SftpStatusCode.noSuchFile) {
        return RemoteFileChange.deleted;
      }
      rethrow;
    }
    if (attrs.isDirectory || baseline.metadataDiffers(attrs)) {
      return RemoteFileChange.modified;
    }
    final hasModifyTimes =
        baseline.modifyTime != null && attrs.modifyTime != null;
    if (hasModifyTimes && baseline.length > remoteEditRehashMaxBytes) {
      return RemoteFileChange.unchanged;
    }
    final RemoteFileSnapshot current;
    try {
      // One byte past the baseline shows a file that grew.
      current = await read(sftp, maxBytes: baseline.length + 1);
    } on SftpStatusError catch (error) {
      if (error.code == SftpStatusCode.noSuchFile) {
        return RemoteFileChange.deleted;
      }
      rethrow;
    }
    return current.version.digest == baseline.digest
        ? RemoteFileChange.unchanged
        : RemoteFileChange.modified;
  }

  /// Replaces the file with [bytes] and makes them the new baseline.
  ///
  /// Keeps [RemoteFileService.replaceFileBytes]'s safe replacement and
  /// symlink handling. When the attributes cannot be read back afterwards,
  /// the next check falls back to comparing content.
  Future<void> save(SftpClient sftp, Uint8List bytes) async {
    await service.replaceFileBytes(
      sftp: sftp,
      remotePath: remotePath,
      bytes: bytes,
    );
    SftpFileAttrs? attrs;
    try {
      attrs = await sftp.stat(remotePath);
    } on Object catch (error) {
      if (error is! Exception && !isExpectedSshOperationError(error)) rethrow;
      DiagnosticsLogService.instance.warning(
        'sftp.editor',
        'post_save_stat_failed',
        fields: {'errorType': error.runtimeType},
      );
    }
    _baseline = RemoteFileVersion(
      size: attrs?.size,
      modifyTime: attrs?.modifyTime,
      length: bytes.length,
      digest: crypto.sha256.convert(bytes),
    );
  }

  /// Writes [bytes] to a new file beside [remotePath] and returns its path.
  ///
  /// The original is never opened for writing. The copy is created
  /// exclusively, so an existing file is never replaced, and is given the
  /// original's permission bits (or owner-only access when the original is
  /// gone) before any content is written to it.
  Future<String> saveCopy(SftpClient sftp, Uint8List bytes) async {
    SftpFileMode? originalMode;
    try {
      originalMode = (await sftp.stat(remotePath)).mode;
    } on SftpStatusError catch (error) {
      if (error.code != SftpStatusCode.noSuchFile) rethrow;
    }
    final mode = originalMode == null
        ? remoteUploadFileMode
        : SftpFileMode.value(originalMode.value & 0x1FF);
    for (var attempt = 1; attempt <= _maxCopyAttempts; attempt++) {
      final candidate = remoteFileCopyPath(remotePath, attempt);
      if (await _exists(sftp, candidate)) continue;
      final SftpFile file;
      try {
        file = await sftp.open(
          candidate,
          mode:
              SftpFileOpenMode.write |
              SftpFileOpenMode.create |
              SftpFileOpenMode.exclusive,
        );
      } on SftpStatusError catch (error) {
        // SFTP v3 reports an existing name as a generic failure.
        if (error.code == SftpStatusCode.failure &&
            await _exists(sftp, candidate)) {
          continue;
        }
        rethrow;
      }
      try {
        try {
          await sftp.setStat(candidate, SftpFileAttrs(mode: mode));
          await file.writeBytes(bytes);
        } finally {
          await file.close();
        }
      } on Object {
        await _removeQuietly(sftp, candidate);
        rethrow;
      }
      return candidate;
    }
    throw FileSystemException('No free name for a copy', remotePath);
  }

  Future<bool> _exists(SftpClient sftp, String path) async {
    try {
      await sftp.stat(path, followLink: false);
      return true;
    } on SftpStatusError catch (error) {
      if (error.code == SftpStatusCode.noSuchFile) return false;
      rethrow;
    }
  }

  Future<void> _removeQuietly(SftpClient sftp, String path) async {
    try {
      await sftp.remove(path);
    } on Object catch (error) {
      if (error is! Exception && !isExpectedSshOperationError(error)) rethrow;
      DiagnosticsLogService.instance.warning(
        'sftp.editor',
        'copy_cleanup_failed',
        fields: {'errorType': error.runtimeType},
      );
    }
  }
}

/// Path for the [attempt]th copy of [remotePath] in the same directory.
///
/// `notes.txt` becomes `notes (copy).txt`, then `notes (copy 2).txt`. A
/// leading dot does not start an extension, so `.env` becomes `.env (copy)`.
/// The stem is shortened when the name would pass the usual 255-byte limit.
String remoteFileCopyPath(String remotePath, int attempt) {
  final slash = remotePath.lastIndexOf('/');
  final directory = remotePath.substring(0, slash + 1);
  final name = remotePath.substring(slash + 1);
  final dot = name.lastIndexOf('.');
  final hasExtension = dot > 0 && dot < name.length - 1;
  var stem = hasExtension ? name.substring(0, dot) : name;
  final extension = hasExtension ? name.substring(dot) : '';
  final suffix = attempt <= 1 ? ' (copy)' : ' (copy $attempt)';
  final tail = '$suffix$extension';
  final tailBytes = utf8.encode(tail).length;
  while (stem.isNotEmpty &&
      utf8.encode(stem).length + tailBytes > _maxNameBytes) {
    final runes = stem.runes.toList()..removeLast();
    stem = String.fromCharCodes(runes);
  }
  return '$directory$stem$tail';
}
