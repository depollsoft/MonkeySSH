import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/agent_management_service.dart';
import 'package:monkeyssh/domain/services/windows_remote_powershell.dart';

String _decodeInstaller(String command) {
  final payload = RegExp(
    r"FromBase64String\('([^']+)'\)",
  ).firstMatch(command)![1]!;
  return utf8.decode(gzip.decode(base64.decode(payload)));
}

// Locate Git Bash relative to git.exe on PATH rather than assuming a global
// Program Files install. Do not accidentally select Windows' WSL bash shim:
// these fixtures pass native host paths, not paths inside a Linux VM.
Future<String?> _findFixtureBash() async {
  if (!Platform.isWindows) return 'bash';
  try {
    final result = await Process.run('where.exe', ['git.exe']);
    for (final line in (result.stdout as String).split(RegExp(r'[\r\n]+'))) {
      if (line.trim().isEmpty) continue;
      var directory = File(line.trim()).parent;
      for (var depth = 0; depth < 3; depth++) {
        for (final relative in ['bin/bash.exe', 'usr/bin/bash.exe']) {
          final candidate = File('${directory.path}/$relative');
          if (candidate.existsSync()) return candidate.path;
        }
        directory = directory.parent;
      }
    }
  } on ProcessException {
    // Git is optional for Windows developers; Linux CI still runs the fixtures.
  }
  return null;
}

void main() {
  final fixtureBash = _findFixtureBash();
  test('every supported runtime has an installer on both platforms', () {
    for (final definition in [
      ...agentCliRuntimeDefinitions,
      ...agentAcpRuntimeDefinitions,
    ]) {
      expect(definition.supportsManagedInstall, isTrue, reason: definition.id);
      for (final windows in [false, true]) {
        final command = buildAgentInstallCommand(
          definition,
          windows: windows,
          update: false,
        );
        expect(
          command,
          isNotNull,
          reason: '${definition.id}: windows=$windows',
        );
        if (windows) {
          expect(command!.length, lessThan(7500));
          expect(command, contains('-OutputFormat Text'));
        }
      }
    }
  });

  final urls = {
    'cli:antigravity': [
      'https://antigravity.google/cli',
      'https://antigravity.google/cli/install.ps1',
    ],
    'cli:cursor': [
      'https://cursor.com/install',
      'https://cursor.com/install?win32=true',
    ],
    'cli:grok': ['https://x.ai/cli/install.sh', 'https://x.ai/cli/install.ps1'],
  };
  for (final entry in urls.entries) {
    final definition = agentCliRuntimeDefinitions.singleWhere(
      (d) => d.id == entry.key,
    );
    test(
      '${entry.key} uses its official installer and preserves native updates',
      () {
        expect(definition.posixInstallerUrl, entry.value[0]);
        expect(definition.windowsInstallerUrl, entry.value[1]);
        final posix = buildAgentInstallCommand(
          definition,
          windows: false,
          update: false,
        )!;
        expect(posix, contains(entry.value[0]));
        expect(posix, contains('if curl -fLsS'));
        expect(posix, isNot(contains('| bash')));
        final windows = _decodeInstaller(
          buildAgentInstallCommand(definition, windows: true, update: false)!,
        );
        expect(windows, contains(entry.value[1]));
        expect(windows, contains(r'-File $__flFile'));
        expect(windows, contains('finally {Remove-Item'));
        final update = _decodeInstaller(
          buildAgentInstallCommand(
            definition,
            windows: true,
            update: true,
            executablePath: r'C:\tools\agent.exe',
          )!,
        );
        expect(update, contains(r"& 'C:\tools\agent.exe' 'update'"));
        expect(update, isNot(contains('Invoke-WebRequest')));
      },
    );

    for (final scenario in [
      'success',
      'installer-failure',
      'download-failure',
    ]) {
      test(
        '${entry.key} POSIX installer $scenario preserves status and cleanup',
        () async {
          final root = await Directory.systemTemp.createTemp('official-posix-');
          addTearDown(() => root.delete(recursive: true));
          final command = buildAgentInstallCommand(
            definition,
            windows: false,
            update: false,
          )!;
          final quoted = command.substring(command.lastIndexOf('sh -c ') + 6);
          final body = quoted
              .substring(1, quoted.length - 1)
              .replaceAll(r"'\''", "'");
          String quote(String s) => "'${s.replaceAll("'", r"'\''")}'";
          final code = scenario == 'installer-failure' ? 7 : 0;
          final fixture =
              'echo installer-output; echo installer-warning >&2; exit $code';
          final mock =
              '''
export TMPDIR=${quote(root.path.replaceAll(r'\', '/'))}
curl() {
  for arg in "\$@"; do dest="\$arg"; done
  printf 'DOWNLOAD_PATH=%s\\n' "\$dest"
  printf '%s\\n' ${quote(fixture)} > "\$dest"
  return ${scenario == 'download-failure' ? 22 : 0}
}
''';
          final bash = await fixtureBash;
          if (bash == null) {
            markTestSkipped(
              'Git Bash is required for POSIX fixtures on Windows',
            );
            return;
          }
          final result = await Process.run(bash, [
            '-c',
            '$mock\n$body',
          ]).timeout(const Duration(seconds: 20));
          expect(
            result.exitCode,
            scenario == 'download-failure' ? 22 : code,
            reason: '${result.stdout}\n${result.stderr}',
          );
          expect(
            result.stdout,
            scenario == 'download-failure'
                ? isNot(contains('installer-output'))
                : contains('installer-output'),
          );
          final path = RegExp(
            r'DOWNLOAD_PATH=([^\r\n]+)',
          ).firstMatch(result.stdout as String)![1]!;
          expect(File(path).existsSync(), isFalse);
        },
      );
    }

    for (final scenario in [
      'success',
      'installer-failure',
      'download-failure',
    ]) {
      test(
        '${entry.key} Windows installer $scenario preserves output, status and cleanup',
        () async {
          final root = await Directory.systemTemp.createTemp('official-agent-');
          addTearDown(() => root.delete(recursive: true));
          final fixture = File('${root.path}/fixture.ps1');
          final downloaded = File('${root.path}/download-path.txt');
          final ran = File('${root.path}/ran.txt');
          final exitCode = scenario == 'installer-failure' ? 7 : 0;
          await fixture.writeAsString(
            '[IO.File]::WriteAllText(${powerShellSingleQuote(ran.path)}, "yes"); '
            'Write-Output "installer output"; '
            '[Console]::Error.WriteLine("installer warning");exit $exitCode;',
          );
          final mock =
              '''
function Invoke-WebRequest {
  param([switch]\$UseBasicParsing, [int]\$TimeoutSec, [string]\$Uri, [string]\$OutFile)
  if (\$Uri -ne ${powerShellSingleQuote(entry.value[1])}) { throw 'Wrong installer URL' }
  [IO.File]::WriteAllText(${powerShellSingleQuote(downloaded.path)}, \$OutFile)
  Copy-Item -LiteralPath ${powerShellSingleQuote(fixture.path)} -Destination \$OutFile
  ${scenario == 'download-failure' ? "throw 'download failed'" : ''}
}
''';
          final script = _decodeInstaller(
            buildAgentInstallCommand(definition, windows: true, update: false)!,
          ).replaceFirst(powerShellProfilePathPreamble, mock);
          final command = buildCompactWindowsPowerShellCommand(
            script,
            plainTextOutput: true,
          );
          final batch = File('${root.path}/run.cmd');
          await batch.writeAsString('@echo off\r\n$command\r\n');
          final result = await Process.run('cmd.exe', [
            '/d',
            '/c',
            batch.path,
          ]).timeout(const Duration(seconds: 30));
          expect(
            result.exitCode,
            scenario == 'download-failure' ? 1 : exitCode,
            reason: '${result.stdout}\n${result.stderr}',
          );
          if (scenario == 'download-failure') {
            expect(ran.existsSync(), isFalse);
            expect(result.stderr, contains('download failed'));
          } else {
            expect(ran.existsSync(), isTrue);
            expect(result.stdout, contains('installer output'));
            expect(result.stderr, contains('installer warning'));
          }
          expect(result.stderr, isNot(contains('CLIXML')));
          expect(File(await downloaded.readAsString()).existsSync(), isFalse);
        },
        skip: !Platform.isWindows,
      );
    }
  }
}
