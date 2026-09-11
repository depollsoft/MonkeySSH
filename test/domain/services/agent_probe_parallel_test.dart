import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_runtime_info.dart';
import 'package:monkeyssh/domain/services/agent_management_service.dart';
import 'package:monkeyssh/domain/services/windows_remote_powershell.dart';

import '../../helpers/powershell_test_helpers.dart';

void main() {
  final ps = Platform.isWindows
      ? 'powershell.exe'
      : Platform.environment['MONKEYSSH_TEST_POWERSHELL'];
  for (final metadata in [false, true]) {
    test(
      'Windows ${metadata ? 'metadata' : 'versions'} run concurrently and retain separate records',
      () async {
        final root = await Directory.systemTemp.createTemp('parallel-probes-');
        addTearDown(() => root.delete(recursive: true));
        if (!Platform.isWindows) {
          await Link('${root.path}/powershell.exe').create(ps!);
        }
        final barrier =
            '''
param([string]\$name)
[IO.File]::WriteAllText(${powerShellSingleQuote(root.path)} + '/' + \$name + '.ready','');
\$until=[DateTime]::UtcNow.AddSeconds(3);
while (@(Get-ChildItem -LiteralPath ${powerShellSingleQuote(root.path)} -Filter '*.ready').Count -lt 2) {
  if ([DateTime]::UtcNow -gt \$until) { exit 1 }; Start-Sleep -Milliseconds 20;
}; Write-Output '1.2.3'; exit 0;
''';
        final gate = File('${root.path}/barrier.ps1');
        await gate.writeAsString(barrier);
        for (final name in ['alpha', 'beta']) {
          await File('${root.path}/$name.ps1').writeAsString(
            '& ${powerShellSingleQuote(gate.path)} $name; exit \$LASTEXITCODE',
          );
        }
        await File('${root.path}/npm.ps1').writeAsString(
          "if (\$args[0] -eq 'view') { & ${powerShellSingleQuote(gate.path)} \$args[1]; exit \$LASTEXITCODE }; exit 0;",
        );
        final definitions = [
          for (final name in ['alpha', 'beta'])
            AgentRuntimeDefinition(
              id: 'cli:$name',
              label: name,
              kind: AgentRuntimeKind.cli,
              executableNames: ['$name.ps1'],
              registry: AgentPackageRegistry.npm,
              packageName: name,
            ),
        ];
        final command = metadata
            ? buildAgentMetadataProbeCommand(definitions, windows: true)
            : buildAgentBatchProbeCommand(definitions, windows: true);
        var script = decodeEncodedPowerShell(command).replaceFirst(
          powerShellProfilePathPreamble,
          '\$env:Path=${powerShellSingleQuote(root.path)} + [IO.Path]::PathSeparator + \$env:Path;',
        );
        if (!Platform.isWindows) {
          script = '\$env:Path=\$env:PATH; $script';
          // .NET process startup uses the case-sensitive Unix PATH variable.
          script = script.replaceFirst(
            'function ConvertTo-AgentLiteral',
            r'$env:PATH=$env:Path; function ConvertTo-AgentLiteral',
          );
          // Metadata invokes npm by name; PowerShell only resolves .ps1 suffixes
          // implicitly on Windows, so make that platform difference explicit.
          script = script.replaceAll('& npm ', '& npm.ps1 ');
        }
        final result = await Process.run(ps!, [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-EncodedCommand',
          encodePowerShellCommand(script),
        ]).timeout(const Duration(seconds: 30));
        expect(result.exitCode, 0, reason: '${result.stderr}');
        if (metadata) {
          final values = parseAgentMetadataProbeOutput(result.stdout as String);
          expect(values.keys, unorderedEquals(['cli:alpha', 'cli:beta']));
          expect(
            values.values.map((v) => v.latestVersionOutput),
            everyElement('1.2.3'),
            reason: '${result.stdout} ${result.stderr}',
          );
        } else {
          final values = parseAgentBatchProbeOutput(result.stdout as String);
          expect(values.keys, unorderedEquals(['cli:alpha', 'cli:beta']));
          expect(
            values.values.map((v) => v.versionOutput),
            everyElement('1.2.3'),
            reason: '${result.stdout} ${result.stderr}',
          );
        }
      },
      skip: ps == null,
    );
  }

  test(
    'POSIX metadata requests overlap without mixing records',
    () async {
      final root = await Directory.systemTemp.createTemp('parallel-metadata-');
      addTearDown(() => root.delete(recursive: true));
      final npm = File('${root.path}/.local/bin/npm');
      await npm.parent.create(recursive: true);
      await npm.writeAsString('''
#!/bin/sh
[ "\$1" = view ] || exit 0
touch '${root.path}/'"\$2".ready
attempt=0
while [ "\$(find '${root.path}' -name '*.ready' | wc -l | tr -d ' ')" -lt 2 ]; do
  attempt=\$((attempt+1)); [ "\$attempt" -lt 30 ] || exit 1; sleep 0.1
done
echo 1.2.3
''');
      await Process.run('chmod', ['+x', npm.path]);
      final definitions = [
        for (final name in ['alpha', 'beta'])
          AgentRuntimeDefinition(
            id: 'cli:$name',
            label: name,
            kind: AgentRuntimeKind.cli,
            executableNames: [name],
            registry: AgentPackageRegistry.npm,
            packageName: name,
          ),
      ];
      final file = File('${root.path}/probe.sh');
      await file.writeAsString(
        buildAgentMetadataProbeCommand(definitions, windows: false),
      );
      final result = await Process.run(
        '/bin/sh',
        [file.path],
        environment: {'HOME': root.path, 'PATH': '${root.path}:/usr/bin:/bin'},
        includeParentEnvironment: false,
      ).timeout(const Duration(seconds: 20));
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final values = parseAgentMetadataProbeOutput(result.stdout as String);
      expect(values.keys, unorderedEquals(['cli:alpha', 'cli:beta']));
      expect(
        values.values.map((v) => v.latestVersionOutput),
        everyElement('1.2.3'),
      );
    },
    skip: Platform.isWindows,
  );
}
