import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'diagnostics_log_service.dart';
import 'remote_file_service.dart';
import 'ssh_error_policy.dart';
import 'ssh_exec_queue.dart';
import 'ssh_service.dart';

const _toolMissingMarker = 'MONKEYSSH_ARCHIVE_TOOL_MISSING';
const _listTimeout = Duration(minutes: 1);
const _extractTimeout = Duration(minutes: 10);
const _execOpenTimeout = Duration(seconds: 10);
const _maxFolderAttempts = 100;

/// Archive formats "Extract here" understands.
enum RemoteArchiveKind {
  /// `.zip`, extracted with `unzip`.
  zip(['.zip'], ''),

  /// Plain `.tar`.
  tar(['.tar'], ''),

  /// Gzip-compressed tar.
  tarGzip(['.tar.gz', '.tgz'], 'z'),

  /// Bzip2-compressed tar.
  tarBzip2(['.tar.bz2', '.tbz2', '.tbz'], 'j'),

  /// XZ-compressed tar.
  tarXz(['.tar.xz', '.txz'], 'J');

  const RemoteArchiveKind(this.suffixes, this.tarFlag);

  /// Lowercase name endings for this kind.
  final List<String> suffixes;

  /// Compression flag added to `tar`.
  final String tarFlag;

  /// The command-line tool that reads this kind.
  String get tool => this == zip ? 'unzip' : 'tar';
}

/// The archive kind [fileName] names, or null for anything else.
RemoteArchiveKind? remoteArchiveKindForName(String fileName) {
  final lower = fileName.toLowerCase();
  for (final kind in RemoteArchiveKind.values.reversed) {
    if (kind.suffixes.any(
      (suffix) => lower.length > suffix.length && lower.endsWith(suffix),
    )) {
      return kind;
    }
  }
  return null;
}

/// [fileName] without its archive suffix, used to name the output folder.
String remoteArchiveStem(String fileName, RemoteArchiveKind kind) {
  final lower = fileName.toLowerCase();
  for (final suffix in kind.suffixes) {
    if (lower.endsWith(suffix)) {
      final stem = fileName.substring(0, fileName.length - suffix.length);
      return stem.isEmpty ? 'archive' : stem;
    }
  }
  return fileName;
}

/// Output of a command run on the host.
@immutable
class RemoteCommandResult {
  /// Creates a result.
  const RemoteCommandResult({
    required this.exitCode,
    required this.stdout,
    this.stderr = '',
  });

  /// Exit status, or null when the server did not report one.
  final int? exitCode;

  /// Standard output.
  final String stdout;

  /// Standard error.
  final String stderr;
}

/// Runs a POSIX shell command on the host.
typedef RemoteCommandRunner = Future<RemoteCommandResult> Function(
  String command, {
  required Duration timeout,
});

/// Runs commands on [session] through its bounded exec queue.
RemoteCommandRunner sshRemoteCommandRunner(SshSession session) =>
    (command, {required timeout}) => session.runQueuedExec(() async {
      final exec = await openSshExec(
        session.execute(command),
        _execOpenTimeout,
      );
      try {
        final stdout = BytesBuilder(copy: false);
        final stderr = BytesBuilder(copy: false);
        await Future.wait<void>([
          exec.stdout.forEach(stdout.add),
          exec.stderr.forEach(stderr.add),
          exec.done,
        ]).timeout(timeout);
        return RemoteCommandResult(
          exitCode: exec.exitCode,
          stdout: utf8.decode(stdout.takeBytes(), allowMalformed: true),
          stderr: utf8.decode(stderr.takeBytes(), allowMalformed: true),
        );
      } on TimeoutException {
        exec.channel.destroy();
        rethrow;
      } finally {
        exec.close();
      }
    });

/// Builds the command runner the SFTP browser uses for a session; tests
/// override it to avoid real exec channels.
final remoteCommandRunnerFactoryProvider =
    Provider<RemoteCommandRunner Function(SshSession session)>(
      (ref) => sshRemoteCommandRunner,
    );

/// A user-facing reason extraction did not happen. Never contains paths.
class RemoteArchiveException implements Exception {
  /// Creates the exception.
  const RemoteArchiveException(this.message);

  /// Explanation shown to the user.
  final String message;

  @override
  String toString() => message;
}

/// What "Extract here" created.
@immutable
class RemoteArchiveExtraction {
  /// Creates the result.
  const RemoteArchiveExtraction({
    required this.name,
    required this.isDirectory,
  });

  /// Name of the new entry in the archive's folder.
  final String name;

  /// Whether that entry is a folder.
  final bool isDirectory;
}

/// Checks an archive listing before anything is extracted.
///
/// [names] holds one member name per entry and [types] the matching type
/// character from the verbose listing (`-` for a file, `d` for a folder).
/// Returns a reason to refuse, or null when every entry stays inside the
/// target: no absolute names, no `..` segments, and no links or special
/// files that a later entry could write through.
String? validateRemoteArchiveEntries({
  required List<String> names,
  required List<String> types,
}) {
  if (names.isEmpty) return 'The archive is empty.';
  if (names.length != types.length) {
    return 'The archive listing could not be checked.';
  }
  for (final type in types) {
    if (type != '-' && type != 'd') {
      return 'The archive contains links or special files, which are not '
          'extracted here.';
    }
  }
  for (final name in names) {
    final segments = name.split(RegExp(r'[/\\]'));
    if (name.startsWith('/') ||
        name.startsWith(r'\') ||
        RegExp('^[A-Za-z]:').hasMatch(name) ||
        segments.contains('..')) {
      return 'The archive has entries that would land outside this folder.';
    }
  }
  return null;
}

final _zipEntryLine = RegExp(r'^(\S)\S{6,9}\s+\d+\.\d+\s+\S+\s');

/// Extracts zip and tar archives on the host through its own tools.
///
/// Extraction runs in a new folder beside the archive after the listing
/// passes [validateRemoteArchiveEntries], so nothing can be written outside
/// it. A single top-level entry is then moved up when its name is free;
/// otherwise the folder takes the archive's name. Existing files are never
/// replaced.
class RemoteArchiveExtractor {
  /// Creates an extractor that runs commands with [runCommand].
  RemoteArchiveExtractor({required this.runCommand, Random? random})
    : _random = random ?? Random.secure();

  /// Runs listing and extraction commands on the host.
  final RemoteCommandRunner runCommand;

  final Random _random;

  /// Extracts [archivePath] of [kind] into its own directory.
  Future<RemoteArchiveExtraction> extractHere({
    required SftpClient sftp,
    required String archivePath,
    required RemoteArchiveKind kind,
  }) async {
    final quotedArchive = shellEscapePosix(archivePath);
    final tool = await runCommand(
      'command -v ${kind.tool} >/dev/null 2>&1 || echo $_toolMissingMarker',
      timeout: _listTimeout,
    );
    if (tool.stdout.contains(_toolMissingMarker) || tool.exitCode != 0) {
      throw RemoteArchiveException(
        '${kind.tool} is not installed on this host.',
      );
    }

    final (names, types) = await _list(kind, quotedArchive);
    final refusal = validateRemoteArchiveEntries(names: names, types: types);
    DiagnosticsLogService.instance.info(
      'sftp.archive',
      'listed',
      fields: {
        'kind': kind.name,
        'entries': names.length,
        'refused': refusal != null,
      },
    );
    if (refusal != null) throw RemoteArchiveException(refusal);

    final directory = parentSftpPath(archivePath);
    final scratch = joinRemotePath(
      directory,
      '.monkeyssh-extract-${_random.nextInt(1 << 32).toRadixString(16)}',
    );
    await sftp.mkdir(scratch);
    try {
      final quotedScratch = shellEscapePosix(scratch);
      final extract = await runCommand(
        kind == RemoteArchiveKind.zip
            ? 'unzip -qq -o $quotedArchive -d $quotedScratch'
            : 'tar -x${kind.tarFlag}f $quotedArchive -C $quotedScratch',
        timeout: _extractTimeout,
      );
      if (extract.exitCode != 0) {
        DiagnosticsLogService.instance.warning(
          'sftp.archive',
          'extract_failed',
          fields: {'kind': kind.name, 'exitCode': extract.exitCode},
        );
        throw const RemoteArchiveException(
          'The archive could not be extracted. It may be damaged, or the '
          'host may be missing a decompressor.',
        );
      }
      return await _placeExtracted(
        sftp,
        scratch: scratch,
        directory: directory,
        folderName: remoteArchiveStem(
          archivePath.substring(archivePath.lastIndexOf('/') + 1),
          kind,
        ),
      );
    } on Object {
      await _removeTreeQuietly(sftp, scratch);
      rethrow;
    }
  }

  Future<(List<String>, List<String>)> _list(
    RemoteArchiveKind kind,
    String quotedArchive,
  ) async {
    final isZip = kind == RemoteArchiveKind.zip;
    final namesResult = await runCommand(
      isZip
          ? 'unzip -Z1 $quotedArchive'
          : 'tar -t${kind.tarFlag}f $quotedArchive',
      timeout: _listTimeout,
    );
    final verboseResult = await runCommand(
      isZip
          ? 'unzip -Z $quotedArchive'
          : 'tar -tv${kind.tarFlag}f $quotedArchive',
      timeout: _listTimeout,
    );
    if (namesResult.exitCode != 0 || verboseResult.exitCode != 0) {
      throw const RemoteArchiveException(
        'The archive could not be read. It may be damaged, or the host may '
        'be missing a decompressor.',
      );
    }
    final names = const LineSplitter()
        .convert(namesResult.stdout)
        .where((line) => line.isNotEmpty)
        .toList();
    final verboseLines = const LineSplitter()
        .convert(verboseResult.stdout)
        .where((line) => line.isNotEmpty);
    final types = isZip
        ? [
            for (final line in verboseLines)
              if (_zipEntryLine.firstMatch(line) case final match?)
                match.group(1)!,
          ]
        : [for (final line in verboseLines) line[0]];
    return (names, types);
  }

  Future<RemoteArchiveExtraction> _placeExtracted(
    SftpClient sftp, {
    required String scratch,
    required String directory,
    required String folderName,
  }) async {
    final entries = (await sftp.listdir(scratch))
        .where((entry) => entry.filename != '.' && entry.filename != '..')
        .toList();
    if (entries.isEmpty) {
      throw const RemoteArchiveException('The archive is empty.');
    }
    if (entries.length == 1) {
      final only = entries.single;
      final destination = joinRemotePath(directory, only.filename);
      if (!await _exists(sftp, destination)) {
        await sftp.rename(joinRemotePath(scratch, only.filename), destination);
        await sftp.rmdir(scratch);
        return RemoteArchiveExtraction(
          name: only.filename,
          isDirectory: only.attr.isDirectory,
        );
      }
    }
    for (var attempt = 1; attempt <= _maxFolderAttempts; attempt++) {
      final name = attempt == 1 ? folderName : '$folderName ($attempt)';
      final destination = joinRemotePath(directory, name);
      if (await _exists(sftp, destination)) continue;
      await sftp.rename(scratch, destination);
      return RemoteArchiveExtraction(name: name, isDirectory: true);
    }
    throw const RemoteArchiveException(
      'There is no free folder name for the extracted files.',
    );
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

  /// Removes the scratch folder this extraction created. Links are removed,
  /// never followed.
  Future<void> _removeTreeQuietly(SftpClient sftp, String path) async {
    Future<void> remove(String path, int depth) async {
      if (depth > 64) return;
      for (final entry in await sftp.listdir(path)) {
        if (entry.filename == '.' || entry.filename == '..') continue;
        final child = joinRemotePath(path, entry.filename);
        if (entry.attr.isDirectory) {
          await remove(child, depth + 1);
        } else {
          await sftp.remove(child);
        }
      }
      await sftp.rmdir(path);
    }

    try {
      await remove(path, 0);
    } on Object catch (error) {
      if (error is! Exception && !isExpectedSshOperationError(error)) rethrow;
      DiagnosticsLogService.instance.warning(
        'sftp.archive',
        'cleanup_failed',
        fields: {'errorType': error.runtimeType},
      );
    }
  }
}
