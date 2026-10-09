import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'agent_management_service.dart' show remoteProfilePathPrefix;
import 'diagnostics_log_service.dart';
import 'remote_file_service.dart';
import 'ssh_error_policy.dart';
import 'ssh_exec_queue.dart';
import 'ssh_service.dart';

/// The only command line the host's login shell parses for archive work. It
/// carries no paths or other user data; each script travels on stdin to
/// `/bin/sh`, so csh, tcsh and fish never parse POSIX quoting.
const kArchiveHostCommandLine = 'exec /bin/sh -s';

/// Most entries an archive may list before extraction is refused.
const remoteArchiveMaxEntries = 100000;

/// Most bytes read from one archive listing. Larger listings are refused, so
/// a huge member list cannot exhaust the app's memory.
const remoteArchiveMaxListingBytes = 16 * 1024 * 1024;

const _toolMissingMarker = 'MONKEYSSH_ARCHIVE_TOOL_MISSING';
const _listTimeout = Duration(minutes: 1);
const _extractTimeout = Duration(minutes: 10);
const _execOpenTimeout = Duration(seconds: 10);
const _smallOutputBytes = 64 * 1024;
const _maxNameAttempts = 100;
const _snapshotName = 'archive';
const _outputFolderName = 'out';

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

/// Output of a script run on the host.
@immutable
class RemoteCommandResult {
  /// Creates a result.
  const RemoteCommandResult({
    required this.exitCode,
    required this.stdout,
    this.truncated = false,
  });

  /// Exit status, or null when the server did not report one.
  final int? exitCode;

  /// Standard output, at most the requested number of bytes.
  final String stdout;

  /// Whether output stopped at the byte limit; the command was then stopped.
  final bool truncated;
}

/// Runs a POSIX `sh` [script] on the host and collects at most
/// [maxOutputBytes] of its standard output.
typedef RemoteCommandRunner = Future<RemoteCommandResult> Function(
  String script, {
  required Duration timeout,
  required int maxOutputBytes,
});

/// Runs scripts on [session] through its bounded exec queue.
///
/// The exec request carries only [kArchiveHostCommandLine]; the script, with
/// any quoted paths, is written to the channel's stdin, so no archive name
/// or path reaches the login shell. Output past the limit stops the command.
RemoteCommandRunner sshRemoteCommandRunner(SshSession session) =>
    (script, {required timeout, required maxOutputBytes}) =>
        session.runQueuedExec(() async {
          final exec = await openSshExec(
            session.execute(kArchiveHostCommandLine),
            _execOpenTimeout,
          );
          return collectRemoteCommandOutput(
            exec,
            script: script,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes,
          );
        });

/// Writes [script] to [exec]'s stdin, then reads at most [maxOutputBytes] of
/// stdout and discards stderr. Reaching the limit or [timeout] destroys the
/// channel instead of draining it.
@visibleForTesting
Future<RemoteCommandResult> collectRemoteCommandOutput(
  SSHSession exec, {
  required String script,
  required Duration timeout,
  required int maxOutputBytes,
}) async {
  final bytes = BytesBuilder(copy: false);
  var truncated = false;
  var finished = false;
  final capReached = Completer<void>();
  final stdoutDone = Completer<void>();
  final stdout = exec.stdout.listen(null, cancelOnError: true)
    ..onData((chunk) {
      if (truncated) return;
      final remaining = maxOutputBytes - bytes.length;
      if (chunk.length <= remaining) {
        bytes.add(chunk);
        return;
      }
      if (remaining > 0) {
        bytes.add(Uint8List.sublistView(chunk, 0, remaining));
      }
      truncated = true;
      if (!capReached.isCompleted) capReached.complete();
    })
    ..onDone(() {
      if (!stdoutDone.isCompleted) stdoutDone.complete();
    })
    ..onError((Object error, StackTrace stackTrace) {
      if (!stdoutDone.isCompleted) stdoutDone.completeError(error, stackTrace);
    });
  final stderr = exec.stderr.listen(
    (_) {},
    onError: (Object _) {},
    cancelOnError: true,
  );
  exec.stdin.add(Uint8List.fromList(utf8.encode(script)));
  unawaited(exec.stdin.close().then<void>((_) {}, onError: (Object _) {}));
  try {
    await Future.any<void>([
      Future.wait<void>([stdoutDone.future, exec.done]),
      capReached.future,
    ]).timeout(timeout);
    finished = !truncated;
  } finally {
    await stdout.cancel();
    await stderr.cancel();
    if (finished) {
      exec.close();
    } else {
      await closeAbandonedSshExec(exec, grace: Duration.zero);
    }
  }
  return RemoteCommandResult(
    exitCode: finished ? exec.exitCode : null,
    stdout: const Utf8Decoder(allowMalformed: true).convert(bytes.takeBytes()),
    truncated: truncated,
  );
}

/// Builds the script sent to `/bin/sh`: the login PATH, then [lines], as one
/// `{ }` group that reads `/dev/null`, so `/bin/sh` parses it all before
/// running anything and no command can consume the rest of the script.
@visibleForTesting
String remoteArchiveScript(List<String> lines) =>
    ['{', remoteProfilePathPrefix, ...lines, '} </dev/null', ''].join('\n');

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
/// With [allowUntyped], `?` counts as a plain file: zip entries written
/// without Unix type bits list that way and can only extract as files.
/// Returns a reason to refuse, or null when every entry stays inside the
/// target: no absolute names, no `..` segments, and no links or special
/// files that a later entry could write through.
String? validateRemoteArchiveEntries({
  required List<String> names,
  required List<String> types,
  bool allowUntyped = false,
}) {
  if (names.isEmpty) return 'The archive is empty.';
  if (names.length > remoteArchiveMaxEntries) {
    return 'The archive lists too many entries to extract here.';
  }
  if (names.length != types.length) {
    return 'The archive listing could not be checked.';
  }
  for (final type in types) {
    if (type != '-' && type != 'd' && !(allowUntyped && type == '?')) {
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
/// The archive is first copied into a new private (0700) folder beside it,
/// and only that copy is listed and extracted, so replacing the original
/// after the check changes nothing. The listing must pass
/// [validateRemoteArchiveEntries], and extraction writes into an empty
/// folder inside the private one. A single top-level entry then moves up
/// beside the archive under a free name; otherwise the extracted folder
/// takes the archive's name. Existing entries are checked for before each
/// move. Decompressed size is not limited, so an archive bomb can still fill
/// the host's disk.
class RemoteArchiveExtractor {
  /// Creates an extractor that runs scripts with [runCommand].
  RemoteArchiveExtractor({required this.runCommand, Random? random})
    : _random = random ?? Random.secure();

  /// Runs scripts on the host.
  final RemoteCommandRunner runCommand;

  final Random _random;

  /// Extracts [archivePath] of [kind] beside it.
  Future<RemoteArchiveExtraction> extractHere({
    required SftpClient sftp,
    required String archivePath,
    required RemoteArchiveKind kind,
  }) async {
    final tool = await runCommand(
      remoteArchiveScript([
        'command -v ${kind.tool} >/dev/null 2>&1 || echo $_toolMissingMarker',
      ]),
      timeout: _listTimeout,
      maxOutputBytes: _smallOutputBytes,
    );
    if (tool.stdout.contains(_toolMissingMarker) || tool.exitCode != 0) {
      throw RemoteArchiveException(
        '${kind.tool} is not installed on this host.',
      );
    }

    final directory = parentSftpPath(archivePath);
    final scratch = joinRemotePath(
      directory,
      '.monkeyssh-extract-${_random.nextInt(1 << 32).toRadixString(16)}',
    );
    final private = SftpFileAttrs(mode: remoteUploadDirectoryMode);
    await sftp.mkdir(scratch, private);
    try {
      // A server may ignore mkdir's mode; the folder is still empty.
      await sftp.setStat(scratch, private);
      final snapshot = joinRemotePath(scratch, _snapshotName);
      final copy = await runCommand(
        remoteArchiveScript([
          'cp ${shellEscapePosix(archivePath)} ${shellEscapePosix(snapshot)}',
        ]),
        timeout: _extractTimeout,
        maxOutputBytes: _smallOutputBytes,
      );
      if (copy.exitCode != 0) {
        throw const RemoteArchiveException(
          'The archive could not be copied for checking. The host may be '
          'out of space.',
        );
      }

      final quotedSnapshot = shellEscapePosix(snapshot);
      final (names, types) = await _list(kind, quotedSnapshot);
      final refusal = validateRemoteArchiveEntries(
        names: names,
        types: types,
        allowUntyped: kind == RemoteArchiveKind.zip,
      );
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

      final output = joinRemotePath(scratch, _outputFolderName);
      await sftp.mkdir(output);
      final quotedOutput = shellEscapePosix(output);
      final extract = await runCommand(
        remoteArchiveScript([
          if (kind == RemoteArchiveKind.zip)
            'unzip -qq -o $quotedSnapshot -d $quotedOutput'
          else
            'tar -x${kind.tarFlag}f $quotedSnapshot -C $quotedOutput',
        ]),
        timeout: _extractTimeout,
        maxOutputBytes: _smallOutputBytes,
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
        output: output,
        directory: directory,
        folderName: remoteArchiveStem(
          archivePath.substring(archivePath.lastIndexOf('/') + 1),
          kind,
        ),
      );
    } finally {
      await _removeTreeQuietly(sftp, scratch);
    }
  }

  Future<(List<String>, List<String>)> _list(
    RemoteArchiveKind kind,
    String quotedSnapshot,
  ) async {
    final isZip = kind == RemoteArchiveKind.zip;
    final namesResult = await runCommand(
      remoteArchiveScript([
        if (isZip)
          'unzip -Z1 $quotedSnapshot'
        else
          'tar -t${kind.tarFlag}f $quotedSnapshot',
      ]),
      timeout: _listTimeout,
      maxOutputBytes: remoteArchiveMaxListingBytes,
    );
    final verboseResult = namesResult.truncated
        ? namesResult
        : await runCommand(
            remoteArchiveScript([
              if (isZip)
                'unzip -Z $quotedSnapshot'
              else
                'tar -tv${kind.tarFlag}f $quotedSnapshot',
            ]),
            timeout: _listTimeout,
            maxOutputBytes: remoteArchiveMaxListingBytes,
          );
    if (namesResult.truncated || verboseResult.truncated) {
      throw const RemoteArchiveException(
        'The archive lists too many entries to extract here.',
      );
    }
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
    required String output,
    required String directory,
    required String folderName,
  }) async {
    final entries = (await sftp.listdir(output))
        .where((entry) => entry.filename != '.' && entry.filename != '..')
        .toList();
    if (entries.isEmpty) {
      throw const RemoteArchiveException('The archive is empty.');
    }
    if (entries.length == 1) {
      // One top-level entry moves up itself, renamed when its name is taken,
      // rather than nesting inside another folder.
      final only = entries.single;
      final name = await _freeName(
        sftp,
        directory,
        only.filename,
        keepExtension: !only.attr.isDirectory,
      );
      await sftp.rename(
        joinRemotePath(output, only.filename),
        joinRemotePath(directory, name),
      );
      return RemoteArchiveExtraction(
        name: name,
        isDirectory: only.attr.isDirectory,
      );
    }
    final name = await _freeName(
      sftp,
      directory,
      folderName,
      keepExtension: false,
    );
    await sftp.rename(output, joinRemotePath(directory, name));
    return RemoteArchiveExtraction(name: name, isDirectory: true);
  }

  /// [name], or `name (2)` and so on, whichever is free in [directory]. A
  /// file keeps its extension last (`notes (2).txt`).
  Future<String> _freeName(
    SftpClient sftp,
    String directory,
    String name, {
    required bool keepExtension,
  }) async {
    final dot = keepExtension ? name.lastIndexOf('.') : -1;
    final hasExtension = dot > 0 && dot < name.length - 1;
    final stem = hasExtension ? name.substring(0, dot) : name;
    final extension = hasExtension ? name.substring(dot) : '';
    for (var attempt = 1; attempt <= _maxNameAttempts; attempt++) {
      final candidate = attempt == 1 ? name : '$stem ($attempt)$extension';
      if (!await _exists(sftp, joinRemotePath(directory, candidate))) {
        return candidate;
      }
    }
    throw const RemoteArchiveException(
      'There is no free name for the extracted files.',
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

  /// Removes the private folder this extraction created, with the archive
  /// copy and anything left in it. Links are removed, never followed.
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
