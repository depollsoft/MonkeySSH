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
///
/// [lines] report their result with `finish <status>`, which prints
/// [marker] and the status on a line of their own. A script that never
/// reaches it (a startup file read the script from stdin, say) is detected
/// by the missing marker rather than read as success.
@visibleForTesting
String remoteArchiveScript(List<String> lines, {required String marker}) => [
  '{',
  remoteProfilePathPrefix,
  'm=${shellEscapePosix(marker)}',
  r"""finish() { printf '\n%s %s\n' "$m" "$1"; exit 0; }""",
  ...lines,
  'finish 0',
  '} </dev/null',
  '',
].join('\n');

/// The output of a script built by [remoteArchiveScript]: what it printed
/// before its marker, and the status it finished with. Null when the marker
/// is missing.
@visibleForTesting
({String output, int status})? parseRemoteArchiveOutput(
  RemoteCommandResult result,
  String marker,
) {
  if (result.truncated) return null;
  final text = result.stdout;
  final index = text.lastIndexOf('\n$marker ');
  if (index < 0) return null;
  final status = int.tryParse(text.substring(index + marker.length + 2).trim());
  if (status == null) return null;
  return (output: text.substring(0, index), status: status);
}

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
/// All work happens on the host inside a new private folder beside the
/// archive. The folder is made with `mkdir` under `umask 077`, checked to be
/// empty and owned by the user, and identified by its inode; every later
/// step `cd`s into it and checks the inode again, so a co-user who swaps the
/// name for a link is refused, and paths inside it are relative. The archive
/// is copied in with an exclusive create, and only that copy is listed and
/// extracted, so replacing the original after the check has no effect.
///
/// The listing must pass [validateRemoteArchiveEntries]. After extraction,
/// anything that is not a plain file or a folder (a link, a device, a file
/// with more than one hard link) refuses the whole archive, which catches
/// zip links that list as plain entries. A single top-level entry then
/// moves up beside the archive under a free name; otherwise the extracted
/// folder takes the archive's name. The private folder is removed with
/// `rm -rf`, which never follows a link at its name. Decompressed size is not
/// limited, so an archive bomb can still fill the host's disk.
class RemoteArchiveExtractor {
  /// Creates an extractor that runs scripts with [runCommand].
  RemoteArchiveExtractor({required this.runCommand, Random? random})
    : _random = random ?? Random.secure();

  /// Runs scripts on the host.
  final RemoteCommandRunner runCommand;

  final Random _random;

  String _hex() => _random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');

  /// Extracts [archivePath] of [kind] beside it.
  Future<RemoteArchiveExtraction> extractHere({
    required SftpClient sftp,
    required String archivePath,
    required RemoteArchiveKind kind,
  }) async {
    final directory = parentSftpPath(archivePath);
    final host = _ArchiveHost(
      runCommand,
      marker: '__MSSH_ARCHIVE_${_hex()}${_hex()}__',
      directory: directory,
      scratchName: '.monkeyssh-extract-${_hex()}',
    );
    final prepared = await host.run([
      'command -v ${kind.tool} >/dev/null 2>&1 || finish 10',
      'umask 077',
      'cd -- ${host.quotedDirectory} || finish 11',
      'mkdir -- ${host.quotedScratch} || finish 11',
      'cd -- ${host.quotedScratch} || finish 12',
      r'[ -O . ] && [ -z "$(ls -A .)" ] || finish 12',
      'set -C',
      'cat -- ${shellEscapePosix(archivePath)} > $_snapshotName || finish 13',
      r'set -- $(ls -di .)',
      _printFirstArgument,
    ], timeout: _extractTimeout);
    final created = prepared.status != 10 && prepared.status != 11;
    try {
      switch (prepared.status) {
        case 0:
          break;
        case 10:
          throw RemoteArchiveException(
            '${kind.tool} is not installed on this host.',
          );
        case 13:
          throw const RemoteArchiveException(
            'The archive could not be copied for checking. The host may be '
            'out of space.',
          );
        default:
          throw const RemoteArchiveException(_privateFolderMessage);
      }
      final inode = prepared.output.trim();
      if (!RegExp(r'^\d+$').hasMatch(inode)) {
        throw const RemoteArchiveException(_privateFolderMessage);
      }
      host.inode = inode;

      final (names, types) = await _list(host, kind);
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

      final extracted = await host.runVerified([
        'mkdir $_outputFolderName || finish 14',
        if (kind == RemoteArchiveKind.zip)
          'unzip -qq -o $_snapshotName -d $_outputFolderName || finish 20'
        else
          'tar -x${kind.tarFlag}f $_snapshotName -C out || finish 20',
        // Only plain files and folders may come out. A zip entry can list
        // without type bits yet carry a link mode in an extra field.
        _findUnsafeOutput,
        r'[ -z "$bad" ] || finish 21',
      ], timeout: _extractTimeout);
      DiagnosticsLogService.instance.info(
        'sftp.archive',
        'extracted',
        fields: {'kind': kind.name, 'status': extracted.status},
      );
      switch (extracted.status) {
        case 0:
          break;
        case 21:
          throw const RemoteArchiveException(_linksMessage);
        case 20:
          throw const RemoteArchiveException(
            'The archive could not be extracted. It may be damaged, or the '
            'host may be missing a decompressor.',
          );
        default:
          throw const RemoteArchiveException(_privateFolderMessage);
      }
      return await _place(
        sftp,
        host,
        folderName: remoteArchiveStem(
          archivePath.substring(archivePath.lastIndexOf('/') + 1),
          kind,
        ),
      );
    } finally {
      if (created) await host.removeScratch();
    }
  }

  Future<(List<String>, List<String>)> _list(
    _ArchiveHost host,
    RemoteArchiveKind kind,
  ) async {
    final isZip = kind == RemoteArchiveKind.zip;
    final names = await host.runVerified(
      [
        if (isZip)
          'unzip -Z1 $_snapshotName'
        else
          'tar -t${kind.tarFlag}f $_snapshotName',
        r'finish $?',
      ],
      timeout: _listTimeout,
      maxOutputBytes: remoteArchiveMaxListingBytes,
    );
    final verbose = await host.runVerified(
      [
        if (isZip)
          'unzip -Z $_snapshotName'
        else
          'tar -tv${kind.tarFlag}f $_snapshotName',
        r'finish $?',
      ],
      timeout: _listTimeout,
      maxOutputBytes: remoteArchiveMaxListingBytes,
    );
    if (names.status != 0 || verbose.status != 0) {
      throw const RemoteArchiveException(
        'The archive could not be read. It may be damaged, or the host may '
        'be missing a decompressor.',
      );
    }
    final nameLines = const LineSplitter()
        .convert(names.output)
        .where((line) => line.isNotEmpty)
        .toList();
    final verboseLines = const LineSplitter()
        .convert(verbose.output)
        .where((line) => line.isNotEmpty);
    final types = isZip
        ? [
            for (final line in verboseLines)
              if (_zipEntryLine.firstMatch(line) case final match?)
                match.group(1)!,
          ]
        : [for (final line in verboseLines) line[0]];
    return (nameLines, types);
  }

  Future<RemoteArchiveExtraction> _place(
    SftpClient sftp,
    _ArchiveHost host, {
    required String folderName,
  }) async {
    // The listing only chooses names; the move runs inside the verified
    // folder, so a swapped name cannot redirect it.
    final entries =
        (await sftp.listdir(
              joinRemotePath(host.scratchPath, _outputFolderName),
            ))
            .where((entry) => entry.filename != '.' && entry.filename != '..')
            .toList();
    if (entries.isEmpty) {
      throw const RemoteArchiveException('The archive is empty.');
    }
    final single = entries.length == 1 ? entries.single : null;
    final name = await _freeName(
      sftp,
      host.directory,
      single?.filename ?? folderName,
      keepExtension: single != null && !single.attr.isDirectory,
    );
    final source = single == null
        ? _outputFolderName
        : '$_outputFolderName/${single.filename}';
    final destination = shellEscapePosix(joinRemotePath(host.directory, name));
    final moved = await host.runVerified([
      '{ [ -e $destination ] || [ -L $destination ]; } && finish 30',
      'mv -- ${shellEscapePosix(source)} $destination || finish 31',
    ], timeout: _listTimeout);
    switch (moved.status) {
      case 0:
        return RemoteArchiveExtraction(
          name: name,
          isDirectory: single?.attr.isDirectory ?? true,
        );
      case 30:
        throw const RemoteArchiveException(
          'Another program took the name chosen for the extracted files.',
        );
      default:
        throw const RemoteArchiveException(
          'The extracted files could not be moved beside the archive.',
        );
    }
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
}

const _printFirstArgument = r'''printf '%s' "$1"''';

/// Prints the first output entry that is a link, a device or another
/// non-file, or a file with more than one hard link.
const _findUnsafeOutput =
    r'bad=$(find out \( -type l -o \( ! -type f ! -type d \) '
    r'-o \( -type f -links +1 \) \) -print | head -n 1)';

const _privateFolderMessage =
    'A private folder for the extraction could not be made beside the '
    'archive.';
const _linksMessage =
    'The archive contains links or special files, which are not extracted '
    'here.';

/// Runs the extraction's scripts with a shared marker and checks that each
/// later step is still inside the private folder the first step made.
class _ArchiveHost {
  _ArchiveHost(
    this._runCommand, {
    required this.marker,
    required this.directory,
    required this.scratchName,
  });

  final RemoteCommandRunner _runCommand;
  final String marker;

  /// Folder holding the archive.
  final String directory;

  /// Name of the private folder inside [directory].
  final String scratchName;

  /// Inode of the private folder, recorded when it was made.
  String? inode;

  String get scratchPath => joinRemotePath(directory, scratchName);
  String get quotedDirectory => shellEscapePosix(directory);
  String get quotedScratch => shellEscapePosix(scratchName);

  Future<({String output, int status})> run(
    List<String> lines, {
    required Duration timeout,
    int maxOutputBytes = _smallOutputBytes,
  }) async {
    final result = await _runCommand(
      remoteArchiveScript(lines, marker: marker),
      timeout: timeout,
      maxOutputBytes: maxOutputBytes,
    );
    final parsed = parseRemoteArchiveOutput(result, marker);
    if (parsed != null) return parsed;
    if (result.truncated) {
      throw const RemoteArchiveException(
        'The archive lists too many entries to extract here.',
      );
    }
    throw const RemoteArchiveException(
      'The host stopped the extraction early. A shell startup file may be '
      'reading input.',
    );
  }

  /// Runs [lines] inside the private folder after checking it is still the
  /// one made for this extraction.
  Future<({String output, int status})> runVerified(
    List<String> lines, {
    required Duration timeout,
    int maxOutputBytes = _smallOutputBytes,
  }) => run(
    [
      'cd -- $quotedDirectory || finish 11',
      '[ -L $quotedScratch ] && finish 12',
      'cd -- $quotedScratch || finish 12',
      '[ -O . ] || finish 12',
      r'set -- $(ls -di .)',
      '[ "\$1" = ${shellEscapePosix(inode ?? '')} ] || finish 12',
      ...lines,
    ],
    timeout: timeout,
    maxOutputBytes: maxOutputBytes,
  );

  /// Removes the private folder on the host. `rm -rf` removes a link at the
  /// name itself and never follows links inside the tree.
  Future<void> removeScratch() async {
    try {
      final removed = await run([
        'cd -- $quotedDirectory || finish 11',
        'rm -rf -- $quotedScratch || finish 40',
      ], timeout: _extractTimeout);
      if (removed.status != 0) {
        DiagnosticsLogService.instance.warning(
          'sftp.archive',
          'cleanup_failed',
          fields: {'status': removed.status},
        );
      }
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
