import 'dart:async';
import 'dart:convert';
import 'dart:io' show gzip;

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'command_output_marker_reader.dart';
import 'diagnostics_log_service.dart';
import 'monkeymux_windows_cleanup.dart';
import 'remote_file_service.dart';
import 'ssh_exec_queue.dart';
import 'ssh_service.dart';
import 'windows_remote_powershell.dart';

/// Asset path for the bundled MonkeyMux binary manifest.
const monkeyMuxManifestAssetPath = 'assets/monkeymux/manifest.json';

const _monkeyMuxInstallTimeout = Duration(seconds: 20);
const _monkeyMuxExecMarker = '__monkeymux_exec_done__';

/// Provides the app-bundled MonkeyMux binary manifest.
final monkeyMuxManifestProvider = FutureProvider<MonkeyMuxManifest>(
  (ref) => MonkeyMuxManifest.load(),
);

/// Installs and verifies MonkeyMux helpers on remote SSH hosts.
final monkeyMuxInstallerServiceProvider = Provider<MonkeyMuxInstallerService>(
  (ref) => MonkeyMuxInstallerService(
    manifestFuture: ref.watch(monkeyMuxManifestProvider.future),
    remoteFileService: ref.watch(remoteFileServiceProvider),
  ),
);

/// Parsed MonkeyMux asset manifest.
class MonkeyMuxManifest {
  /// Creates a parsed MonkeyMux asset manifest.
  const MonkeyMuxManifest({required this.version, required this.entries});

  /// Parses a manifest JSON object.
  factory MonkeyMuxManifest.fromJson(Map<String, Object?> json) {
    final entriesJson = json['entries'];
    return MonkeyMuxManifest(
      version: json['version'] as String? ?? '',
      entries: entriesJson is List
          ? entriesJson
                .whereType<Map<String, Object?>>()
                .map(MonkeyMuxManifestEntry.fromJson)
                .toList(growable: false)
          : const <MonkeyMuxManifestEntry>[],
    );
  }

  /// Loads the default bundled manifest.
  static Future<MonkeyMuxManifest> load({AssetBundle? assetBundle}) async {
    final bundle = assetBundle ?? rootBundle;
    final jsonText = await bundle.loadString(monkeyMuxManifestAssetPath);
    return MonkeyMuxManifest.fromJson(
      jsonDecode(jsonText) as Map<String, Object?>,
    );
  }

  /// Version shared by all manifest entries.
  final String version;

  /// Bundled platform binaries.
  final List<MonkeyMuxManifestEntry> entries;

  /// Finds the entry for [platformKey].
  MonkeyMuxManifestEntry? entryForPlatform(String platformKey) {
    for (final entry in entries) {
      if (entry.platform == platformKey) {
        return entry;
      }
    }
    return null;
  }
}

/// One bundled MonkeyMux binary entry.
class MonkeyMuxManifestEntry {
  /// Creates a MonkeyMux manifest entry.
  const MonkeyMuxManifestEntry({
    required this.platform,
    required this.asset,
    required this.sha256,
    required this.size,
    this.encoding,
  });

  /// Parses a manifest entry JSON object.
  factory MonkeyMuxManifestEntry.fromJson(Map<String, Object?> json) =>
      MonkeyMuxManifestEntry(
        platform: json['platform'] as String? ?? '',
        asset: json['asset'] as String? ?? '',
        encoding: json['encoding'] as String?,
        sha256: json['sha256'] as String? ?? '',
        size: json['size'] as int? ?? 0,
      );

  /// Platform key, for example `linux-amd64`.
  final String platform;

  /// Flutter asset path for the binary data.
  final String asset;

  /// Optional asset encoding used to keep bundled executables as data files.
  final String? encoding;

  /// Expected SHA-256 of the binary bytes.
  final String sha256;

  /// Expected binary size in bytes.
  final int size;
}

/// Result of installing or reusing a remote MonkeyMux helper.
class MonkeyMuxInstallation {
  /// Creates a MonkeyMux installation result.
  const MonkeyMuxInstallation({
    required this.executablePath,
    required this.platform,
    required this.version,
    this.installedDuringCall = false,
  });

  /// Absolute remote executable path.
  final String executablePath;

  /// Resolved remote platform key.
  final String platform;

  /// Installed MonkeyMux version.
  final String version;

  /// Whether this call uploaded the helper instead of reusing an existing copy.
  final bool installedDuringCall;

  /// Whether the resolved platform is Windows, which affects how the helper is
  /// invoked (native `.exe` path and double-quoted shell arguments).
  bool get isWindows => platform.startsWith('windows-');
}

/// Details for a pending MonkeyMux helper install.
class MonkeyMuxInstallRequest {
  /// Creates pending MonkeyMux install details.
  const MonkeyMuxInstallRequest({
    required this.platform,
    required this.version,
    required this.size,
  });

  /// Remote platform key for the helper, for example `linux-amd64`.
  final String platform;

  /// MonkeyMux helper version that would be installed.
  final String version;

  /// Helper binary size in bytes.
  final int size;
}

/// Confirms whether MonkeyMux may install its helper on the connected host.
typedef MonkeyMuxInstallConfirmation =
    Future<bool> Function(MonkeyMuxInstallRequest request);

/// Error thrown when MonkeyMux cannot be installed or used.
class MonkeyMuxInstallException implements Exception {
  /// Creates a MonkeyMux installation error.
  const MonkeyMuxInstallException(this.message);

  /// Human-readable failure message.
  final String message;

  @override
  String toString() => message;
}

/// Error thrown when MonkeyMux needs app-level install confirmation.
class MonkeyMuxInstallConfirmationRequiredException
    extends MonkeyMuxInstallException {
  /// Creates a confirmation-required install error.
  const MonkeyMuxInstallConfirmationRequiredException()
    : super('MonkeyMux install requires confirmation.');
}

/// Error thrown when the user declines a MonkeyMux helper install.
class MonkeyMuxInstallDeclinedException extends MonkeyMuxInstallException {
  /// Creates a declined install error.
  const MonkeyMuxInstallDeclinedException()
    : super('MonkeyMux install was canceled.');
}

/// Installs and verifies the bundled MonkeyMux helper on a remote host.
class MonkeyMuxInstallerService {
  /// Creates a MonkeyMux installer.
  const MonkeyMuxInstallerService({
    required Future<MonkeyMuxManifest> manifestFuture,
    required RemoteFileService remoteFileService,
    AssetBundle? assetBundle,
  }) : _manifestFuture = manifestFuture,
       _remoteFileService = remoteFileService,
       _assetBundle = assetBundle;

  final Future<MonkeyMuxManifest> _manifestFuture;
  final RemoteFileService _remoteFileService;
  final AssetBundle? _assetBundle;
  static final _installCache = <int, MonkeyMuxInstallation>{};
  static final _installRequests = <int, _MonkeyMuxInstallInFlight>{};
  static final _passiveInstallFailures = <int, (Object, StackTrace)>{};

  /// Installs the helper if needed and returns its executable path.
  Future<MonkeyMuxInstallation> ensureInstalled(
    SshSession session, {
    SshExecPriority priority = SshExecPriority.low,
    MonkeyMuxInstallConfirmation? confirmInstall,
  }) async {
    final connectionId = session.connectionId;
    final cachedInstallation = _installCache[connectionId];
    if (cachedInstallation != null) {
      DiagnosticsLogService.instance.debug(
        'monkeymux.install',
        'reuse_cached',
        fields: {
          'connectionId': connectionId,
          'platform': cachedInstallation.platform,
        },
      );
      return cachedInstallation;
    }

    final existingRequest = _installRequests[connectionId];
    if (existingRequest != null &&
        (existingRequest.canPrompt || confirmInstall == null)) {
      DiagnosticsLogService.instance.debug(
        'monkeymux.install',
        'join_inflight',
        fields: {
          'connectionId': connectionId,
          'canPrompt': existingRequest.canPrompt,
        },
      );
      return existingRequest.future;
    }
    if (confirmInstall == null) {
      final failure = _passiveInstallFailures[connectionId];
      if (failure != null) {
        Error.throwWithStackTrace(failure.$1, failure.$2);
      }
    } else {
      _passiveInstallFailures.remove(connectionId);
    }
    if (existingRequest != null) {
      DiagnosticsLogService.instance.debug(
        'monkeymux.install',
        'replace_probe_with_confirmable',
        fields: {'connectionId': connectionId},
      );
    }

    final request = _MonkeyMuxInstallInFlight(
      canPrompt: confirmInstall != null,
    );
    _installRequests[connectionId] = request;
    // A prompt-capable install supersedes a probe-only install, but callers
    // already waiting on the probe should receive the prompt-capable result.
    existingRequest?.supersedeWith(request.future);
    request.bind(
      _ensureInstalled(
        session,
        priority: priority,
        confirmInstall: confirmInstall,
      ),
    );
    request.future
        .then(
          (installation) {
            if (identical(_installRequests[connectionId], request)) {
              _installCache[connectionId] = installation;
              _passiveInstallFailures.remove(connectionId);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            // Watchers cannot approve or repair an installation. Avoid repeating
            // remote probes until an explicit install attempt or a reconnect.
            if (identical(_installRequests[connectionId], request) &&
                (request.canPrompt ||
                    error is MonkeyMuxInstallConfirmationRequiredException ||
                    error is MonkeyMuxInstallDeclinedException)) {
              _passiveInstallFailures[connectionId] = (error, stackTrace);
            }
          },
        )
        .ignore();
    request.future.whenComplete(() {
      if (identical(_installRequests[connectionId], request)) {
        _installRequests.remove(connectionId);
      }
    }).ignore();
    return request.future;
  }

  /// Clears cached install state for a disconnected SSH connection.
  void clearCache(int connectionId) {
    _installCache.remove(connectionId);
    _installRequests.remove(connectionId);
    _passiveInstallFailures.remove(connectionId);
  }

  Future<MonkeyMuxInstallation> _ensureInstalled(
    SshSession session, {
    required SshExecPriority priority,
    required MonkeyMuxInstallConfirmation? confirmInstall,
  }) async {
    final platform = await probePlatform(session, priority: priority);
    final manifest = await _manifestFuture;
    final entry = manifest.entryForPlatform(platform);
    if (entry == null) {
      throw MonkeyMuxInstallException(
        'MonkeyMux is not bundled for $platform.',
      );
    }
    final sftp = await session.openStandaloneSftp();
    try {
      final homeDirectory = await _remoteFileService.resolveInitialDirectory(
        sftp,
      );
      final isWindows = _isWindowsPlatform(platform);
      // Windows locks running executables. Builds with the same helper version
      // can have different bytes, so version alone is not a safe install key.
      // Leave older builds available to their running server and attach clients.
      final buildSubdirectory = isWindows
          ? '/${entry.sha256.toLowerCase()}'
          : '';
      final installDirectory = joinRemotePath(
        homeDirectory,
        '.monkeyssh/bin/monkeymux/${manifest.version}/$platform$buildSubdirectory',
      );
      final executableName = isWindows ? 'monkeymux.exe' : 'monkeymux';
      final executableSftpPath = joinRemotePath(
        installDirectory,
        executableName,
      );
      // SFTP presents Windows paths as `/C:/...`; the shell (attach/control
      // commands, certutil) needs the native `C:\...` form.
      final executablePath = isWindows
          ? sftpPathToWindowsShellPath(executableSftpPath)
          : executableSftpPath;
      final reused = await _remoteShaMatches(
        session,
        executablePath,
        entry.sha256,
        isWindows: isWindows,
        priority: priority,
      );
      if (reused) {
        DiagnosticsLogService.instance.info(
          'monkeymux.install',
          'reuse_existing',
          fields: {'connectionId': session.connectionId, 'platform': platform},
        );
      } else {
        final installRequest = MonkeyMuxInstallRequest(
          platform: platform,
          version: manifest.version,
          size: entry.size,
        );
        if (confirmInstall == null) {
          DiagnosticsLogService.instance.warning(
            'monkeymux.install',
            'confirmation_required',
            fields: {
              'connectionId': session.connectionId,
              'platform': platform,
            },
          );
          throw const MonkeyMuxInstallConfirmationRequiredException();
        }
        DiagnosticsLogService.instance.info(
          'monkeymux.install',
          'confirmation_requested',
          fields: {
            'connectionId': session.connectionId,
            'platform': platform,
            'size': entry.size,
          },
        );
        final confirmed = await confirmInstall(installRequest);
        if (!confirmed) {
          DiagnosticsLogService.instance.info(
            'monkeymux.install',
            'confirmation_declined',
            fields: {
              'connectionId': session.connectionId,
              'platform': platform,
            },
          );
          throw const MonkeyMuxInstallDeclinedException();
        }
        DiagnosticsLogService.instance.info(
          'monkeymux.install',
          'confirmation_accepted',
          fields: {'connectionId': session.connectionId, 'platform': platform},
        );

        final assetBytes = await _loadAssetBytes(entry);
        DiagnosticsLogService.instance.info(
          'monkeymux.install',
          'upload_start',
          fields: {
            'connectionId': session.connectionId,
            'platform': platform,
            'size': entry.size,
          },
        );
        await _remoteFileService.ensureDirectoryExists(sftp, installDirectory);
        final temporaryExecutablePath = joinRemotePath(
          installDirectory,
          '.monkeymux.${session.connectionId}.'
          '${DateTime.now().microsecondsSinceEpoch}.tmp',
        );
        final temporaryCommandPath = isWindows
            ? sftpPathToWindowsShellPath(temporaryExecutablePath)
            : temporaryExecutablePath;
        var installStage = 'upload';
        try {
          await _remoteFileService.uploadBytes(
            sftp: sftp,
            remotePath: temporaryExecutablePath,
            bytes: assetBytes,
          );
          if (isWindows) {
            installStage = 'verify_upload';
            if (!await _remoteShaMatches(
              session,
              temporaryCommandPath,
              entry.sha256,
              isWindows: true,
              priority: priority,
            )) {
              throw const MonkeyMuxInstallException(
                'Uploaded MonkeyMux checksum verification failed.',
              );
            }
            // Only a corrupt copy of this exact build can occupy the target.
            // Keep real permission errors visible; only absence is harmless.
            installStage = 'remove_target';
            try {
              await sftp.remove(executableSftpPath);
            } on SftpStatusError catch (error) {
              if (error.code != SftpStatusCode.noSuchFile) {
                rethrow;
              }
            }
            installStage = 'rename_upload';
            await sftp.rename(temporaryExecutablePath, executableSftpPath);
          } else {
            installStage = 'finalize_upload';
            await _runRemoteCommand(
              session,
              r'__monkeymux_sha__=$(sha256sum '
              '${_shellQuote(temporaryExecutablePath)} 2>/dev/null || '
              'shasum -a 256 ${_shellQuote(temporaryExecutablePath)} '
              '2>/dev/null) && '
              '[ "\${__monkeymux_sha__%% *}" = ${_shellQuote(entry.sha256)} ] && '
              'chmod 700 ${_shellQuote(temporaryExecutablePath)} && '
              'mv -f ${_shellQuote(temporaryExecutablePath)} '
              '${_shellQuote(executableSftpPath)}',
              priority: priority,
            );
          }
        } on Object catch (error, stackTrace) {
          DiagnosticsLogService.instance.warning(
            'monkeymux.install',
            'upload_failed',
            fields: {
              'connectionId': session.connectionId,
              'platform': platform,
              'stage': installStage,
              'errorType': error.runtimeType,
              if (error is SftpStatusError) 'sftpStatus': error.code,
            },
          );
          await _removeRemoteTemporaryFile(
            session,
            temporaryExecutablePath,
            sftp: sftp,
          );
          Error.throwWithStackTrace(error, stackTrace);
        }
        if (isWindows &&
            !await _remoteShaMatches(
              session,
              executablePath,
              entry.sha256,
              isWindows: true,
              priority: priority,
            )) {
          throw const MonkeyMuxInstallException(
            'Installed MonkeyMux checksum verification failed.',
          );
        }
        DiagnosticsLogService.instance.info(
          'monkeymux.install',
          'upload_complete',
          fields: {'connectionId': session.connectionId, 'platform': platform},
        );
      }
      await _ensureDirectCommandLauncherBestEffort(
        session,
        homeDirectory: homeDirectory,
        executablePath: executablePath,
        version: manifest.version,
        platform: platform,
        isWindows: isWindows,
        priority: priority,
      );
      return MonkeyMuxInstallation(
        executablePath: executablePath,
        platform: platform,
        version: manifest.version,
        installedDuringCall: !reused,
      );
    } finally {
      await sftp.close();
    }
  }

  Future<void> _ensureDirectCommandLauncherBestEffort(
    SshSession session, {
    required String homeDirectory,
    required String executablePath,
    required String version,
    required String platform,
    required bool isWindows,
    required SshExecPriority priority,
  }) async {
    try {
      await _ensureDirectCommandLauncher(
        session,
        homeDirectory: homeDirectory,
        executablePath: executablePath,
        version: version,
        platform: platform,
        isWindows: isWindows,
        priority: priority,
      );
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'monkeymux.install',
        'launcher_unavailable',
        fields: {
          'connectionId': session.connectionId,
          'platform': platform,
          'errorType': error.runtimeType.toString(),
        },
      );
    }
  }

  Future<void> _ensureDirectCommandLauncher(
    SshSession session, {
    required String homeDirectory,
    required String executablePath,
    required String version,
    required String platform,
    required bool isWindows,
    required SshExecPriority priority,
  }) async {
    final launcherDirectory = joinRemotePath(homeDirectory, '.local/bin');
    final launcherSftpPath = joinRemotePath(
      launcherDirectory,
      isWindows ? 'monkeymux.cmd' : 'monkeymux',
    );
    if (isWindows) {
      final launcherPath = sftpPathToWindowsShellPath(launcherSftpPath);
      final pointerSftpPath = joinRemotePath(
        launcherDirectory,
        '.monkeymux-current',
      );
      final pointerPath = sftpPathToWindowsShellPath(pointerSftpPath);
      final buildDirectory = executablePath.split(r'\').reversed.elementAt(1);
      final relativeTarget =
          '$version\\$platform\\$buildDirectory\\monkeymux.exe';
      const managedMarker = '@REM Managed by MonkeySSH launcher v1';
      final script = <String>[
        r"$ErrorActionPreference = 'Stop'",
        '\$path = ${powerShellSingleQuote(launcherPath)}',
        '\$pointer = ${powerShellSingleQuote(pointerPath)}',
        '\$managedMarker = ${powerShellSingleQuote(managedMarker)}',
        '\$target = ${powerShellSingleQuote(relativeTarget)}',
        'function Set-AtomicAsciiFile {',
        r'  param([string]$Destination, [string[]]$Lines)',
        r'  for ($attempt = 0; $attempt -lt 3; $attempt++) {',
        r'    $temp = "$Destination.$PID.$attempt.tmp"',
        '    try {',
        r'      $Lines | Set-Content -LiteralPath $temp -Encoding Ascii',
        r'      if (Test-Path -LiteralPath $Destination) {',
        r'        [System.IO.File]::Replace($temp, $Destination, $null)',
        '      } else {',
        r'        [System.IO.File]::Move($temp, $Destination)',
        '      }',
        '      return',
        '    } catch {',
        r'      Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue',
        r'      if ($attempt -eq 2) { throw }',
        '      Start-Sleep -Milliseconds 50',
        '    }',
        '  }',
        '}',
        r'$exists = Test-Path -LiteralPath $path',
        r'$first = if ($exists -and (Test-Path -LiteralPath $path -PathType Leaf)) {',
        r'  Get-Content -LiteralPath $path -TotalCount 1',
        r'} else { $null }',
        r'if ($exists -and $first -ne $managedMarker) {',
        "  Write-Output 'MONKEYMUX_LAUNCHER_PRESERVED'",
        '  exit 0',
        '}',
        r'New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null',
        r'Set-AtomicAsciiFile -Destination $pointer -Lines @($target)',
        r'Set-AtomicAsciiFile -Destination $path -Lines @(',
        '  ${powerShellSingleQuote(managedMarker)},',
        "  '@echo off',",
        '''  'set /p "MONKEYMUX_TARGET="<"%~dp0.monkeymux-current"',''',
        r'''  '"%~dp0..\..\.monkeyssh\bin\monkeymux\%MONKEYMUX_TARGET%" %*',''',
        "  'exit /b %errorlevel%'",
        ')',
        buildMonkeyMuxWindowsCleanupScript(
          installRoot: sftpPathToWindowsShellPath(
            joinRemotePath(homeDirectory, '.monkeyssh/bin/monkeymux'),
          ),
          executablePath: executablePath,
          platform: platform,
        ),
        "Write-Output 'MONKEYMUX_LAUNCHER_MANAGED'",
      ].join('\n');
      final output = await _runRawRemoteCommand(
        session,
        'powershell -NoProfile -NonInteractive -EncodedCommand '
        '${encodePowerShellCommand(script)}',
        priority: priority,
      );
      if (!output.contains('MONKEYMUX_LAUNCHER_MANAGED') &&
          !output.contains('MONKEYMUX_LAUNCHER_PRESERVED')) {
        throw const MonkeyMuxInstallException(
          'Could not install the MonkeyMux command launcher.',
        );
      }
      final cleanup = RegExp(
        r'MONKEYMUX_CLEANUP:(\d+):(\d+)',
      ).firstMatch(output);
      if (cleanup != null) {
        DiagnosticsLogService.instance.info(
          'monkeymux.install',
          'old_builds_cleanup',
          fields: {
            'connectionId': session.connectionId,
            'removedCount': int.tryParse(cleanup[1]!),
            'retainedCount': int.tryParse(cleanup[2]!),
          },
        );
      }
    } else {
      final managedPrefix = joinRemotePath(
        homeDirectory,
        '.monkeyssh/bin/monkeymux/',
      );
      await _runRemoteCommand(
        session,
        'mkdir -p ${_shellQuote(launcherDirectory)} && '
        'if [ ! -e ${_shellQuote(launcherSftpPath)} ] && '
        '[ ! -L ${_shellQuote(launcherSftpPath)} ]; then '
        'ln -s ${_shellQuote(executablePath)} '
        '${_shellQuote(launcherSftpPath)}; '
        'elif [ -L ${_shellQuote(launcherSftpPath)} ]; then '
        r'__monkeymux_link="$(readlink '
        '${_shellQuote(launcherSftpPath)} 2>/dev/null || true)"; '
        r'case "$__monkeymux_link" in '
        '${_shellQuote(managedPrefix)}*) '
        'ln -sfn ${_shellQuote(executablePath)} '
        '${_shellQuote(launcherSftpPath)} ;; '
        'esac; fi',
        priority: priority,
      );
    }
    DiagnosticsLogService.instance.info(
      'monkeymux.install',
      'launcher_checked',
      fields: {
        'connectionId': session.connectionId,
        'platform': isWindows ? 'windows' : 'posix',
      },
    );
  }

  /// Probes the remote host and returns a manifest platform key.
  Future<String> probePlatform(
    SshSession session, {
    SshExecPriority priority = SshExecPriority.low,
  }) async {
    final platform = session.remoteIsWindows
        ? await _probeWindowsPlatform(session, priority: priority)
        : await _probePosixPlatform(session, priority: priority);
    DiagnosticsLogService.instance.info(
      'monkeymux.install',
      'platform_probe',
      fields: {'connectionId': session.connectionId, 'platform': platform},
    );
    return platform;
  }

  Future<String> _probePosixPlatform(
    SshSession session, {
    required SshExecPriority priority,
  }) async {
    String output;
    try {
      output = await _runRemoteCommand(
        session,
        r'printf "%s\n%s\n" "$(uname -s 2>/dev/null)" "$(uname -m 2>/dev/null)"',
        priority: priority,
      );
    } on MonkeyMuxInstallException {
      output = '';
    }
    final platform = _parsePosixPlatform(output);
    if (platform != null) {
      return platform;
    }
    // The POSIX probe produced nothing usable. The host may be a Windows SSH
    // server whose banner did not identify itself, so fall back to a Windows
    // probe that self-validates before being trusted.
    final arch = await _probeWindowsArch(session, priority: priority);
    if (arch != null) {
      return 'windows-$arch';
    }
    throw const MonkeyMuxInstallException(
      'Could not detect remote MonkeyMux platform.',
    );
  }

  String? _parsePosixPlatform(String output) {
    final lines = output
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.length < 2) {
      return null;
    }
    final osName = switch (lines[0].toLowerCase()) {
      'darwin' => 'darwin',
      'linux' => 'linux',
      final value => value,
    };
    final arch = switch (lines[1].toLowerCase()) {
      'x86_64' || 'amd64' => 'amd64',
      'aarch64' || 'arm64' => 'arm64',
      final value => value,
    };
    if (osName.isEmpty || arch.isEmpty) {
      return null;
    }
    return '$osName-$arch';
  }

  Future<String> _probeWindowsPlatform(
    SshSession session, {
    required SshExecPriority priority,
  }) async {
    final arch = await _probeWindowsArch(session, priority: priority);
    if (arch == null) {
      // The banner confirmed Windows but the architecture probe failed or was
      // unrecognized. Fail with a clear error rather than guessing amd64 and
      // installing a helper the host may not be able to run.
      throw const MonkeyMuxInstallException(
        'Could not detect the remote Windows CPU architecture.',
      );
    }
    return 'windows-$arch';
  }

  /// Detects the Windows CPU architecture. Returns `amd64`/`arm64` for
  /// supported hosts, a raw token such as `x86` for a recognized-but-unbundled
  /// architecture (so the caller surfaces a clear "not bundled" error), or null
  /// when the host does not look like Windows. Uses `cmd /c` so it works
  /// regardless of whether the default remote shell is cmd.exe or PowerShell.
  Future<String?> _probeWindowsArch(
    SshSession session, {
    required SshExecPriority priority,
  }) async {
    String output;
    try {
      output = await _runRawRemoteCommand(
        session,
        'cmd /c echo %OS% %PROCESSOR_ARCHITECTURE% %PROCESSOR_ARCHITEW6432%',
        priority: priority,
      );
    } on Object {
      return null;
    }
    final lower = output.toLowerCase();
    if (!lower.contains('windows_nt')) {
      return null;
    }
    if (lower.contains('arm64')) {
      return 'arm64';
    }
    if (lower.contains('amd64') || lower.contains('x86_64')) {
      return 'amd64';
    }
    if (lower.contains('x86')) {
      // 32-bit Windows: no bundled binary. Return the token so the caller fails
      // with an explicit "not bundled for windows-x86" instead of mis-selecting
      // the amd64 helper.
      return 'x86';
    }
    return null;
  }

  bool _isWindowsPlatform(String platform) => platform.startsWith('windows-');

  /// Extracts the SHA-256 digest from `certutil -hashfile` output, tolerating
  /// the byte-spaced formatting older certutil versions emit.
  String? _extractCertutilSha(String output) {
    for (final line in const LineSplitter().convert(output)) {
      final compact = line.replaceAll(RegExp(r'\s'), '').toLowerCase();
      if (RegExp(r'^[0-9a-f]{64}$').hasMatch(compact)) {
        return compact;
      }
    }
    return null;
  }

  Future<Uint8List> _loadAssetBytes(MonkeyMuxManifestEntry entry) async {
    final bundle = _assetBundle ?? rootBundle;
    final bytes = await bundle.load(entry.asset);
    final assetBytes = bytes.buffer.asUint8List(
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
    return compute(_verifyAssetBytes, (
      assetBytes,
      entry.encoding,
      entry.sha256,
    ));
  }

  Future<bool> _remoteShaMatches(
    SshSession session,
    String executablePath,
    String expectedSha, {
    required bool isWindows,
    required SshExecPriority priority,
  }) async {
    try {
      if (isWindows) {
        final output = await _runRawRemoteCommand(
          session,
          'certutil -hashfile "$executablePath" SHA256',
          priority: priority,
        );
        final digest = _extractCertutilSha(output);
        return digest != null && digest == expectedSha.toLowerCase();
      }
      final output = await _runRemoteCommand(
        session,
        '(sha256sum ${_shellQuote(executablePath)} 2>/dev/null || '
        'shasum -a 256 ${_shellQuote(executablePath)} 2>/dev/null) | '
        r"awk '{print $1}'",
        priority: priority,
      );
      return output.trim() == expectedSha;
    } on Exception {
      return false;
    }
  }

  Future<void> _removeRemoteTemporaryFile(
    SshSession session,
    String remotePath, {
    required SftpClient sftp,
  }) async {
    try {
      await sftp.remove(remotePath);
    } on Object catch (error) {
      DiagnosticsLogService.instance.debug(
        'monkeymux.install',
        'temp_cleanup_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
    }
  }
}

Uint8List _verifyAssetBytes((Uint8List, String?, String) input) {
  final (assetBytes, encoding, expectedSha) = input;
  final bytes = switch (encoding) {
    null || '' || 'none' => assetBytes,
    'gzip' => Uint8List.fromList(gzip.decode(assetBytes)),
    _ => throw MonkeyMuxInstallException(
      'Unsupported MonkeyMux asset encoding: $encoding',
    ),
  };
  if (sha256.convert(bytes).toString() != expectedSha) {
    throw const MonkeyMuxInstallException(
      'Bundled MonkeyMux checksum does not match the manifest.',
    );
  }
  return bytes;
}

class _MonkeyMuxInstallInFlight {
  _MonkeyMuxInstallInFlight({required this.canPrompt});

  final bool canPrompt;
  final _completer = Completer<MonkeyMuxInstallation>();
  bool _superseded = false;

  Future<MonkeyMuxInstallation> get future => _completer.future;

  void bind(Future<MonkeyMuxInstallation> operation) {
    operation
        .then(
          (installation) {
            if (!_superseded && !_completer.isCompleted) {
              _completer.complete(installation);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!_superseded && !_completer.isCompleted) {
              _completer.completeError(error, stackTrace);
            }
          },
        )
        .ignore();
  }

  void supersedeWith(Future<MonkeyMuxInstallation> replacement) {
    if (_completer.isCompleted) {
      return;
    }
    _superseded = true;
    replacement
        .then(
          (installation) {
            if (!_completer.isCompleted) {
              _completer.complete(installation);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!_completer.isCompleted) {
              _completer.completeError(error, stackTrace);
            }
          },
        )
        .ignore();
  }
}

Future<String> _runRemoteCommand(
  SshSession session,
  String command, {
  SshExecPriority priority = SshExecPriority.normal,
}) => session.runQueuedExec(() async {
  final execSession = await openSshExec(
    session.execute(_markRemoteCommandDone(command)),
    _monkeyMuxInstallTimeout,
  );
  try {
    execSession.stderr.drain<void>().ignore();
    return await _readStdoutUntilMarker(execSession);
  } finally {
    execSession.close();
  }
}, priority: priority);

/// Runs a command without the POSIX completion-marker wrapper, collecting stdout
/// until the channel closes. Used for probes and Windows shells (cmd.exe /
/// PowerShell) that cannot evaluate the POSIX marker script.
Future<String> _runRawRemoteCommand(
  SshSession session,
  String command, {
  SshExecPriority priority = SshExecPriority.normal,
}) => session.runQueuedExec(() async {
  final execSession = await openSshExec(
    session.execute(command),
    _monkeyMuxInstallTimeout,
  );
  final chunks = StreamIterator(
    execSession.stdout.cast<List<int>>().transform(utf8.decoder),
  );
  try {
    execSession.stderr.drain<void>().ignore();
    return await (() async {
      final output = StringBuffer();
      while (await chunks.moveNext()) {
        output.write(chunks.current);
      }
      return output.toString();
    })().timeout(_monkeyMuxInstallTimeout);
  } finally {
    chunks.cancel().ignore();
    execSession.close();
  }
}, priority: priority);

String _markRemoteCommandDone(String command) =>
    '{ $command; __monkeymux_status__=\$?; '
    'printf ${_shellQuote('\n$_monkeyMuxExecMarker:%s\n')} '
    r'"$__monkeymux_status__"; }';

Future<String> _readStdoutUntilMarker(SSHSession execSession) async {
  final chunks = StreamIterator(
    execSession.stdout.cast<List<int>>().transform(utf8.decoder),
  );
  Stream<String> output() async* {
    while (await chunks.moveNext()) {
      yield chunks.current;
    }
  }

  try {
    final result = await readCommandOutputUntilMarker(
      output(),
      _monkeyMuxExecMarker,
    ).timeout(_monkeyMuxInstallTimeout);
    if (result.status != 0) {
      throw MonkeyMuxInstallException(
        'Remote command failed with exit status ${result.status}.',
      );
    }
    return result.output.trimRight();
  } on CommandOutputMarkerMissingException {
    throw const MonkeyMuxInstallException(
      'Remote command closed before completion marker.',
    );
  } finally {
    chunks.cancel().ignore();
  }
}

String _shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";
