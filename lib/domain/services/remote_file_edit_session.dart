import 'dart:convert';
import 'dart:math';
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
/// A changed modified time always triggers a re-read, whatever the size.
const remoteEditRehashMaxBytes = 256 * 1024;

const _maxCopyAttempts = 100;
const _maxNameBytes = 255;
const _permissionBits = 0x1FF;

/// How the host's file differs from the version an editor loaded.
enum RemoteFileChange {
  /// The content matches, or size and modified time match where the content
  /// was not re-read.
  unchanged,

  /// The file exists but its content no longer matches the loaded version.
  modified,

  /// Nothing exists at the path any more.
  deleted,

  /// The path now names a folder or another entry that is not a file.
  notAFile,
}

/// The host's file changed between the save check and the write, so the
/// write was abandoned with the file untouched.
class RemoteFileChangedDuringSaveException implements Exception {
  /// Creates the exception.
  const RemoteFileChangedDuringSaveException();

  @override
  String toString() => 'The file changed on the host while saving';
}

/// One version of a remote file: the server's size, modified time and
/// permission bits, plus a SHA-256 of the bytes that were read.
@immutable
class RemoteFileVersion {
  /// Creates a version record.
  const RemoteFileVersion({
    required this.size,
    required this.modifyTime,
    required this.length,
    required this.digest,
    this.mode,
  });

  /// Records [bytes] as read, with the server's [attrs] when they are known.
  factory RemoteFileVersion.of(List<int> bytes, [SftpFileAttrs? attrs]) =>
      RemoteFileVersion(
        size: attrs?.size ?? bytes.length,
        modifyTime: attrs?.modifyTime,
        length: bytes.length,
        digest: crypto.sha256.convert(bytes),
        mode: _permissionsOf(attrs),
      );

  /// Size the server reported, or the byte count read when it reported none.
  final int? size;

  /// Modified time in seconds since the epoch, when the server reported one.
  final int? modifyTime;

  /// Number of bytes hashed into [digest].
  final int length;

  /// SHA-256 of the bytes that were read.
  final crypto.Digest digest;

  /// Permission bits (`0777` range), when the server reported them.
  final int? mode;

  /// Whether [attrs] reports a different size. Content of a different size
  /// cannot match, so this is decisive.
  bool sizeDiffers(SftpFileAttrs attrs) =>
      size != null && attrs.size != null && size != attrs.size;

  /// Whether [attrs] reports a different modified time, or either side left
  /// it out. Rewrites with identical bytes also change it, so this only says
  /// the content needs comparing.
  bool modifyTimeUncertain(SftpFileAttrs attrs) =>
      modifyTime == null ||
      attrs.modifyTime == null ||
      modifyTime != attrs.modifyTime;

  /// This version with the size, time and mode of [attrs], for content that
  /// was found to be the same.
  RemoteFileVersion withAttributes(SftpFileAttrs attrs) => RemoteFileVersion(
    size: attrs.size ?? size,
    modifyTime: attrs.modifyTime,
    length: length,
    digest: digest,
    mode: _permissionsOf(attrs) ?? mode,
  );
}

int? _permissionsOf(SftpFileAttrs? attrs) {
  final value = attrs?.mode?.value;
  return value == null ? null : value & _permissionBits;
}

bool _isNotAFile(SftpFileAttrs attrs) =>
    attrs.isDirectory ||
    attrs.isBlockDevice ||
    attrs.isCharacterDevice ||
    attrs.isPipe ||
    attrs.isSocket;

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
/// SFTP has no conditional write. [save] re-checks size and modified time
/// immediately before its final rename. A change is still missed when it
/// lands in the single round trip between that stat and the rename, when it
/// keeps both size and modified time on a file too large to re-read, or when
/// it keeps the size and lands within the same second as the file's
/// previous write: SFTP v3 modified times have one-second resolution, so
/// the final stat cannot tell such a write from the version that was
/// checked.
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
  SftpFileAttrs? _checkedAttrs;

  /// The version the editor's text is based on, once one was accepted.
  RemoteFileVersion? get baseline => _baseline;

  /// Reads at most [maxBytes] of the file along with the version they came
  /// from.
  ///
  /// The handle's attributes are read before its content, so a change between
  /// the two shows as a changed file at save time rather than going
  /// unnoticed. The result only becomes the baseline through [accept].
  Future<RemoteFileSnapshot> read(SftpClient sftp, {required int maxBytes}) =>
      _read(sftp, maxBytes: maxBytes, withAttributes: true);

  Future<RemoteFileSnapshot> _read(
    SftpClient sftp, {
    required int maxBytes,
    required bool withAttributes,
  }) async {
    final file = await sftp.open(remotePath);
    try {
      SftpFileAttrs? attrs;
      if (withAttributes) {
        try {
          attrs = await file.stat();
        } on SftpStatusError {
          // Without fstat the content hash alone identifies the version.
        }
      }
      final bytes = await file.readBytes(length: maxBytes);
      return RemoteFileSnapshot(bytes, RemoteFileVersion.of(bytes, attrs));
    } finally {
      await file.close();
    }
  }

  /// Makes [snapshot] the version later saves are checked against.
  void accept(RemoteFileSnapshot snapshot) {
    _baseline = snapshot.version;
    _checkedAttrs = null;
  }

  /// Compares the host's file with the accepted baseline.
  ///
  /// A different size is decisive. A different (or unknown) modified time
  /// means the file is re-read and its hash compared, so rewrites with the
  /// same bytes (`sed -i`, `git stash pop`) do not count as changes; the
  /// baseline then takes the new attributes. With both unchanged, files up to
  /// [remoteEditRehashMaxBytes] are still re-read to catch a same-second
  /// edit.
  Future<RemoteFileChange> checkForChanges(SftpClient sftp) async {
    final baseline = _baseline;
    if (baseline == null) {
      throw StateError('No baseline version was accepted');
    }
    _checkedAttrs = null;
    final SftpFileAttrs attrs;
    try {
      attrs = await sftp.stat(remotePath);
    } on SftpStatusError catch (error) {
      if (error.code == SftpStatusCode.noSuchFile) {
        return RemoteFileChange.deleted;
      }
      rethrow;
    }
    if (_isNotAFile(attrs)) return RemoteFileChange.notAFile;
    if (baseline.sizeDiffers(attrs)) return RemoteFileChange.modified;
    final needsRead =
        baseline.modifyTimeUncertain(attrs) ||
        baseline.length <= remoteEditRehashMaxBytes;
    if (needsRead) {
      final RemoteFileSnapshot current;
      try {
        // One byte past the baseline shows a file that grew.
        current = await _read(
          sftp,
          maxBytes: baseline.length + 1,
          withAttributes: false,
        );
      } on SftpStatusError catch (error) {
        if (error.code == SftpStatusCode.noSuchFile) {
          return RemoteFileChange.deleted;
        }
        rethrow;
      }
      if (current.version.digest != baseline.digest) {
        return RemoteFileChange.modified;
      }
      _baseline = baseline.withAttributes(attrs);
    }
    _checkedAttrs = attrs;
    return RemoteFileChange.unchanged;
  }

  /// Replaces the file with [bytes] and makes them the new baseline.
  ///
  /// Keeps [RemoteFileService.replaceFileBytes]'s safe replacement and
  /// symlink handling. After an unchanged [checkForChanges], the size and
  /// modified time are compared again just before the final rename and a
  /// difference throws [RemoteFileChangedDuringSaveException] with the file
  /// untouched. [force] skips that comparison, for an overwrite the user
  /// chose. A file that no longer exists is recreated with the permission
  /// bits it had when loaded, or owner-only access when they are unknown.
  Future<void> save(
    SftpClient sftp,
    Uint8List bytes, {
    bool force = false,
  }) async {
    final checked = force ? null : _checkedAttrs;
    final loadedMode = _baseline?.mode;
    await service.replaceFileBytes(
      sftp: sftp,
      remotePath: remotePath,
      bytes: bytes,
      newFileMode: loadedMode == null
          ? remoteUploadFileMode
          : SftpFileMode.value(loadedMode),
      beforeReplace: checked == null
          ? null
          : () async {
              final SftpFileAttrs current;
              try {
                current = await sftp.stat(remotePath);
              } on SftpStatusError catch (error) {
                if (error.code != SftpStatusCode.noSuchFile) rethrow;
                throw const RemoteFileChangedDuringSaveException();
              }
              if (current.size != checked.size ||
                  current.modifyTime != checked.modifyTime) {
                throw const RemoteFileChangedDuringSaveException();
              }
            },
    );
    // The modified time is left unknown so a later check compares content,
    // whatever another writer did after the rename.
    _baseline = RemoteFileVersion(
      size: bytes.length,
      modifyTime: null,
      length: bytes.length,
      digest: crypto.sha256.convert(bytes),
      mode: loadedMode,
    );
    _checkedAttrs = null;
  }

  /// Recreates a file that was deleted on the host, with the permission bits
  /// it loaded with (owner-only when unknown).
  ///
  /// Unlike a forced [save], this never replaces a file: if something
  /// recreated the path in the meantime, it throws
  /// [RemoteFileChangedDuringSaveException] so the editor checks again.
  Future<void> recreate(SftpClient sftp, Uint8List bytes) async {
    final loadedMode = _baseline?.mode;
    Future<void> ensureStillMissing() async {
      try {
        await sftp.stat(remotePath, followLink: false);
      } on SftpStatusError catch (error) {
        if (error.code == SftpStatusCode.noSuchFile) return;
        rethrow;
      }
      throw const RemoteFileChangedDuringSaveException();
    }

    await ensureStillMissing();
    await service.replaceFileBytes(
      sftp: sftp,
      remotePath: remotePath,
      bytes: bytes,
      newFileMode: loadedMode == null
          ? remoteUploadFileMode
          : SftpFileMode.value(loadedMode),
      beforeReplace: ensureStillMissing,
    );
    _baseline = RemoteFileVersion(
      size: bytes.length,
      modifyTime: null,
      length: bytes.length,
      digest: crypto.sha256.convert(bytes),
      mode: loadedMode,
    );
    _checkedAttrs = null;
  }

  /// Writes [bytes] to a new file beside [remotePath] and returns its path.
  ///
  /// The original is never opened for writing and an existing file is never
  /// replaced. A name is reserved with an empty, exclusively created
  /// placeholder. The content is written to a file in a private (0700)
  /// scratch folder, restricted on its open handle to the original's
  /// permission bits (the loaded ones when the path is no longer a file, or
  /// owner-only), and renamed over the placeholder only while the
  /// placeholder is still that empty file. Renames act on names, so a
  /// placeholder swapped for a link is refused rather than followed. There
  /// is no in-place fallback: a host that refuses the scratch folder refuses
  /// the copy.
  Future<String> saveCopy(SftpClient sftp, Uint8List bytes) async {
    int? currentMode;
    try {
      final attrs = await sftp.stat(remotePath);
      if (attrs.isFile) currentMode = _permissionsOf(attrs);
    } on SftpStatusError catch (error) {
      if (error.code != SftpStatusCode.noSuchFile) rethrow;
    }
    final mode = SftpFileMode.value(
      currentMode ?? _baseline?.mode ?? remoteUploadFileMode.value,
    );
    for (var attempt = 1; attempt <= _maxCopyAttempts; attempt++) {
      final candidate = remoteFileCopyPath(remotePath, attempt);
      if (await _exists(sftp, candidate)) continue;
      final SftpFile placeholder;
      try {
        placeholder = await sftp.open(
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
          await placeholder.setStat(SftpFileAttrs(mode: mode));
        } finally {
          await placeholder.close();
        }
        await _installCopy(sftp, candidate, bytes, mode);
      } on Object {
        await _removePlaceholderQuietly(sftp, candidate);
        rethrow;
      }
      return candidate;
    }
    throw const RemoteFileRefusedException(
      'There is no free name for a copy beside the file.',
    );
  }

  Future<void> _installCopy(
    SftpClient sftp,
    String candidate,
    Uint8List bytes,
    SftpFileMode mode,
  ) async {
    final scratch =
        '${candidate.substring(0, candidate.lastIndexOf('/') + 1)}'
        '.monkeyssh-save-${Random.secure().nextInt(1 << 32).toRadixString(16)}';
    final private = SftpFileAttrs(mode: remoteUploadDirectoryMode);
    await sftp.mkdir(scratch, private);
    final staged = '$scratch/new';
    try {
      // A server may ignore mkdir's mode; the folder is still empty.
      await sftp.setStat(scratch, private);
      final file = await sftp.open(
        staged,
        mode:
            SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.exclusive,
      );
      try {
        await file.setStat(SftpFileAttrs(mode: mode));
        await file.writeBytes(bytes);
      } finally {
        await file.close();
      }
      final reserved = await sftp.stat(candidate, followLink: false);
      if (reserved.isSymbolicLink ||
          reserved.isDirectory ||
          (reserved.size ?? 0) != 0) {
        throw const RemoteFileRefusedException(
          'Another program took the name chosen for the copy.',
        );
      }
      try {
        await sftp.rename(staged, candidate);
      } on SftpStatusError catch (error) {
        if (error.code != SftpStatusCode.failure) rethrow;
        // Without posix-rename the placeholder name must be free first.
        final aside = '$scratch/placeholder';
        await sftp.rename(candidate, aside);
        try {
          await sftp.rename(staged, candidate);
        } on Object {
          await _quietly(sftp.rename(aside, candidate));
          rethrow;
        }
        await _quietly(sftp.remove(aside));
      }
    } finally {
      await _quietly(_removeIfPresent(sftp, staged));
      await _quietly(sftp.rmdir(scratch));
    }
  }

  Future<void> _removeIfPresent(SftpClient sftp, String path) async {
    if (await _exists(sftp, path)) await sftp.remove(path);
  }

  Future<void> _quietly(Future<void> cleanup) async {
    try {
      await cleanup;
    } on Object catch (error) {
      if (error is! Exception && !isExpectedSshOperationError(error)) rethrow;
      DiagnosticsLogService.instance.warning(
        'sftp.editor',
        'copy_cleanup_failed',
        fields: {'errorType': error.runtimeType},
      );
    }
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

  /// Removes a reserved copy name only while it is still an empty file, so a
  /// copy that did land is never deleted.
  Future<void> _removePlaceholderQuietly(SftpClient sftp, String path) async {
    try {
      final attrs = await sftp.stat(path, followLink: false);
      if (attrs.isFile && attrs.size == 0) await sftp.remove(path);
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
/// Names are kept within the usual 255-byte limit: the stem is shortened
/// first, and an extension too long to keep is treated as part of the stem.
String remoteFileCopyPath(String remotePath, int attempt) {
  final slash = remotePath.lastIndexOf('/');
  final directory = remotePath.substring(0, slash + 1);
  final name = remotePath.substring(slash + 1);
  final suffix = attempt <= 1 ? ' (copy)' : ' (copy $attempt)';
  final dot = name.lastIndexOf('.');
  var stem = name;
  var extension = '';
  if (dot > 0 && dot < name.length - 1) {
    final candidateExtension = name.substring(dot);
    // Keep at least a little of the stem beside the extension.
    if (utf8.encode('$suffix$candidateExtension').length < _maxNameBytes - 8) {
      stem = name.substring(0, dot);
      extension = candidateExtension;
    }
  }
  final tailBytes = utf8.encode('$suffix$extension').length;
  while (stem.isNotEmpty &&
      utf8.encode(stem).length + tailBytes > _maxNameBytes) {
    final runes = stem.runes.toList()..removeLast();
    stem = String.fromCharCodes(runes);
  }
  return '$directory$stem$suffix$extension';
}
