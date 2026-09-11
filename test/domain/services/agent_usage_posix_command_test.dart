import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_usage.dart';
import 'package:monkeyssh/domain/services/agent_usage_parser.dart';
import 'package:monkeyssh/domain/services/agent_usage_posix_command.dart';

void main() {
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
}
