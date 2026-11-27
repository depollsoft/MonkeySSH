import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_usage.dart';
import 'package:monkeyssh/domain/services/agent_usage_parser.dart';
import 'package:monkeyssh/domain/services/agent_usage_posix_command.dart';

/// Registers tests from agent_usage_posix_command_test.dart.
void registerDomainServicesAgentUsagePosixCommandTests() {
  group('agent_usage_posix_command', () {
    test(
      'missing Node returns a runtime status for every selected agent',
      () async {
        final command = buildPosixAgentUsageCommand('exit 99', {
          'claude': '/bin/claude',
          'codex': '/bin/codex',
        });
        final result = await Process.run(
          '/bin/sh',
          ['-c', command],
          environment: {'PATH': '/nonexistent'},
          includeParentEnvironment: false,
        );
        final values = parseAgentUsageOutput(
          result.stdout as String,
          checkedAt: DateTime.utc(2026),
        );
        expect(values.keys, ['claude', 'codex']);
        expect(
          values.values.every(
            (v) => v.status == AgentUsageStatus.runtimeUnavailable,
          ),
          isTrue,
        );
      },
      skip: Platform.isWindows,
    );

    test(
      'available Node receives literal bootstrap and encoded selections',
      () async {
        final dir = await Directory.systemTemp.createTemp('usage-node-');
        try {
          final node = File('${dir.path}/node');
          await node.writeAsString('#!/bin/sh\nprintf "%s\\n" "\$@"\n');
          await Process.run('/bin/chmod', ['+x', node.path]);
          const source = r"literal ' quotes and $(no-command)";
          const selected = {'codex': '/path with spaces/agent'};
          final result = await Process.run(
            '/bin/sh',
            ['-c', buildPosixAgentUsageCommand(source, selected)],
            environment: {'PATH': dir.path},
            includeParentEnvironment: false,
          );
          expect(result.exitCode, 0);
          final lines = (result.stdout as String).trim().split('\n');
          expect(lines.take(2), ['-e', source]);
          expect(jsonDecode(utf8.decode(base64.decode(lines.last))), selected);
        } finally {
          await dir.delete(recursive: true);
        }
      },
      skip: Platform.isWindows,
    );

    test('cached probe verifies full SHA-256, rejects tampered/symlinked files, and bootstrap repairs them', () async {
      final whichNode = await Process.run('/bin/sh', ['-c', 'command -v node']);
      if (whichNode.exitCode != 0) return;

      final home = await Directory.systemTemp.createTemp('usage-cache-home-');
      try {
        const probeJs =
            "const inp=JSON.parse(Buffer.from(process.argv[process.env.MONKEYSSH_USAGE_PROBE==='1'?1:2],'base64').toString()); "
            r"for(const id of Object.keys(inp)){process.stdout.write('__monkeyssh_usage__='+JSON.stringify({id,status:'available',windows:[]})+'\n');}";
        final probeBytes = utf8.encode(probeJs);
        final source = base64.encode(probeBytes);
        final sha256Hex = sha256.convert(probeBytes).toString();
        final cacheFile = File(
          '${home.path}/.cache/monkeyssh/usage-probe-${sha256Hex.substring(0, 16)}.cjs',
        );
        const agents = {'claude': '/bin/claude'};
        final env = {
          'HOME': home.path,
          'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
        };

        // 1. Cold cache emits miss marker.
        final cold = await Process.run(
          '/bin/sh',
          [
            '-c',
            buildCachedPosixAgentUsageCommand(
              sha256Hex: sha256Hex,
              agents: agents,
            ),
          ],
          environment: env,
          includeParentEnvironment: false,
        );
        expect(cold.exitCode, 0);
        expect((cold.stdout as String).trim(), posixAgentUsageCacheMissMarker);

        // 2. Bootstrap writes private cache file and runs the probe.
        final boot = await Process.run(
          '/bin/sh',
          [
            '-c',
            buildBootstrapPosixAgentUsageCommand(
              source: source,
              sha256Hex: sha256Hex,
              agents: agents,
            ),
          ],
          environment: env,
          includeParentEnvironment: false,
        );
        expect(boot.exitCode, 0);
        expect(boot.stdout as String, contains('__monkeyssh_usage__='));
        expect(cacheFile.existsSync(), isTrue);
        expect(cacheFile.statSync().mode & 0x1ff, 0x180); // 0600

        // 3. Valid cached execution succeeds without miss marker.
        final cached = await Process.run(
          '/bin/sh',
          [
            '-c',
            buildCachedPosixAgentUsageCommand(
              sha256Hex: sha256Hex,
              agents: agents,
            ),
          ],
          environment: env,
          includeParentEnvironment: false,
        );
        expect(cached.exitCode, 0);
        expect(cached.stdout as String, contains('__monkeyssh_usage__='));
        expect(
          cached.stdout as String,
          isNot(contains(posixAgentUsageCacheMissMarker)),
        );

        // 4. Tampered cache file is NOT executed and triggers a cache miss.
        await cacheFile.writeAsString(r"process.stdout.write('PWNED\n');");
        final tampered = await Process.run(
          '/bin/sh',
          [
            '-c',
            buildCachedPosixAgentUsageCommand(
              sha256Hex: sha256Hex,
              agents: agents,
            ),
          ],
          environment: env,
          includeParentEnvironment: false,
        );
        expect(tampered.exitCode, 0);
        expect(tampered.stdout as String, isNot(contains('PWNED')));
        expect(
          (tampered.stdout as String).trim(),
          posixAgentUsageCacheMissMarker,
        );

        // 5. Bootstrap atomically repairs the tampered cache file.
        final repaired = await Process.run(
          '/bin/sh',
          [
            '-c',
            buildBootstrapPosixAgentUsageCommand(
              source: source,
              sha256Hex: sha256Hex,
              agents: agents,
            ),
          ],
          environment: env,
          includeParentEnvironment: false,
        );
        expect(repaired.exitCode, 0);
        expect(repaired.stdout as String, contains('__monkeyssh_usage__='));
        expect(await cacheFile.readAsString(), probeJs);

        // 6. Symlinked cache file is rejected and atomically replaced on bootstrap.
        final target = File('${home.path}/evil.cjs');
        await target.writeAsString(probeJs);
        await cacheFile.delete();
        await Link(cacheFile.path).create(target.path);
        final symlinkRun = await Process.run(
          '/bin/sh',
          [
            '-c',
            buildCachedPosixAgentUsageCommand(
              sha256Hex: sha256Hex,
              agents: agents,
            ),
          ],
          environment: env,
          includeParentEnvironment: false,
        );
        expect(symlinkRun.exitCode, 0);
        expect(
          (symlinkRun.stdout as String).trim(),
          posixAgentUsageCacheMissMarker,
        );

        final symlinkRepair = await Process.run(
          '/bin/sh',
          [
            '-c',
            buildBootstrapPosixAgentUsageCommand(
              source: source,
              sha256Hex: sha256Hex,
              agents: agents,
            ),
          ],
          environment: env,
          includeParentEnvironment: false,
        );
        expect(symlinkRepair.exitCode, 0);
        expect(FileSystemEntity.isLinkSync(cacheFile.path), isFalse);
      } finally {
        await home.delete(recursive: true);
      }
    }, skip: Platform.isWindows);
  });
}
