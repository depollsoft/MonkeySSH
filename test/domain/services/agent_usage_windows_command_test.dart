import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/agent_usage_windows_command.dart';
import 'package:monkeyssh/domain/services/windows_remote_powershell.dart';

import '../../helpers/powershell_test_helpers.dart';

void main() {
  final shell = Platform.isWindows
      ? 'powershell.exe'
      : Platform.environment['MONKEYSSH_TEST_POWERSHELL'];

  for (final mode in ['profile', 'sibling', 'missing']) {
    test(
      'usage bootstrap finds Node through $mode with piped stdin',
      () async {
        final root = await Directory.systemTemp.createTemp('usage windows é ');
        addTearDown(() => root.delete(recursive: true));
        final nodeDir = await Directory('${root.path}/node').create();
        final node = File('${nodeDir.path}/node.exe');
        final located = await Process.run(
          Platform.isWindows ? 'where.exe' : 'which',
          ['node'],
        );
        final realNode = (located.stdout as String)
            .trim()
            .split(RegExp(r'[\r\n]+'))
            .first;
        expect(realNode, isNotEmpty);
        if (Platform.isWindows) {
          await File(realNode).copy(node.path);
        } else {
          await Link(node.path).create(realNode);
        }
        final profile = File('${root.path}/profile.ps1');
        await profile.writeAsString(
          "\uFEFFWrite-Output 'profile chatter'; "
          '\$env:Path=${powerShellSingleQuote(nodeDir.path)} + [IO.Path]::PathSeparator + \$env:Path;',
        );
        final launcher = mode == 'sibling'
            ? '${nodeDir.path}/codex.cmd'
            : '${root.path}/codex.cmd';
        final command = buildWindowsAgentUsageCommand({'codex': launcher});
        expect(command.length, lessThan(7500));
        var script = decodeEncodedPowerShell(command);
        // Use a synthetic profile and hide machine/user Node installs, without
        // changing any real profile or persistent environment variable.
        script = script.replaceFirst(
          "[Environment]::GetEnvironmentVariable('Path','User')",
          "''",
        );
        final profilePath = mode == 'profile'
            ? profile.path
            : '${root.path}/absent.ps1';
        script =
            '\$PROFILE=[pscustomobject]@{CurrentUserAllHosts=${powerShellSingleQuote(profilePath)}}; '
            "\$env:Path=''; $script";
        if (!Platform.isWindows) {
          script = script.replaceFirst(
            r'$__flNode=(Get-Command',
            r'$env:PATH=$env:Path; $__flNode=(Get-Command',
          );
        }
        final wrapped = buildCompactWindowsPowerShellCommand(script);
        // Exercise cmd.exe's outer quoting and Windows PowerShell 5.1 in CI.
        final batch = File('${root.path}/probe.cmd');
        await batch.writeAsString('@echo off\r\n$wrapped\r\n');
        final process = await Process.start(
          Platform.isWindows ? 'cmd.exe' : shell!,
          Platform.isWindows
              ? ['/d', '/c', batch.path]
              : [
                  '-NoProfile',
                  '-NonInteractive',
                  '-EncodedCommand',
                  encodePowerShellCommand(script),
                ],
        );
        final stdout = process.stdout.transform(utf8.decoder).join();
        final stderr = process.stderr.transform(utf8.decoder).join();
        // A Unicode normalized record exercises the complete stdin/bootstrap and
        // redirected stdout chain, independent of credentials or remote APIs.
        const source =
            r"process.stdout.write('__monkeyssh_usage__='+JSON.stringify({id:'codex',status:'available',windows:[{label:'Crédits',usedPercent:25}]})+'\n')";
        process.stdin.writeln(base64.encode(utf8.encode(source)));
        await process.stdin.close();
        final exit = await process.exitCode.timeout(
          const Duration(seconds: 20),
          onTimeout: () {
            process.kill();
            throw StateError('PowerShell usage probe timed out');
          },
        );
        final output = await stdout;
        expect(
          exit,
          mode == 'missing' ? 1 : 0,
          reason: '$output ${await stderr}',
        );
        expect(output, isNot(contains('profile chatter')));
        expect(
          output,
          contains(mode == 'missing' ? 'runtimeUnavailable' : 'Crédits'),
        );
      },
      skip: shell == null,
    );
  }
}
