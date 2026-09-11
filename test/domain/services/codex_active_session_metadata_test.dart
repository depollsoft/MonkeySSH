import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/monkeymux_service.dart';
import 'package:monkeyssh/domain/services/tmux_service.dart';

void main() {
  group(
    'Codex active session identity',
    () {
      late _CodexProbe probe;

      setUp(() async {
        probe = await _CodexProbe.create();
      });
      tearDown(() => probe.home.delete(recursive: true));

      test(
        'ignores wrapper shells, code-mode helpers, and app-server children',
        () async {
          await probe.processes([
            '42 1 -zsh -zsh -i -c codex --yolo',
            '501 42 codex codex --yolo compare claude and copilot',
            '502 501 codex-code-mode-host /opt/.codex/bin/codex-code-mode-host',
            '503 501 node_repl /Applications/Codex.app/node_repl',
            '504 503 codex /Applications/Codex.app/codex app-server --listen stdio://',
            '43 1 -zsh -zsh -i -c codex --yolo',
            '601 43 codex codex --yolo',
            '602 601 codex-code-mode-host /opt/.codex/bin/codex-code-mode-host',
          ]);
          await probe.openRollout(501, '11111111-1111-4111-8111-111111111111');
          await probe.openRollout(601, '22222222-2222-4222-8222-222222222222');
          final output = await probe.run();

          expect(output.trim().split('\n'), hasLength(2));
          final metadata = parseAgentActiveSessionMetadataOutput(output, {
            42,
            43,
          });
          expect(
            metadata[42]?.sessionId,
            '11111111-1111-4111-8111-111111111111',
          );
          expect(metadata[42]?.title, 'Audit the codebase');
          expect(
            metadata[43]?.sessionId,
            '22222222-2222-4222-8222-222222222222',
          );
          expect(metadata[43]?.title, 'Fix paste prompts');
          expect(metadata[42]?.confidence, AgentSessionConfidence.high);

          // MonkeyMux consumes the same command and parser as tmux.
          final windows = applyMonkeyMuxAgentMetadataForTesting(const [
            TmuxWindow(
              index: 3,
              name: 'Codex',
              isActive: false,
              currentCommand: 'codex',
              panePid: 42,
            ),
            TmuxWindow(
              index: 4,
              name: 'Codex',
              isActive: true,
              currentCommand: 'codex',
              panePid: 43,
            ),
          ], output);
          expect(windows.map((window) => window.agentSessionTitle), [
            'Audit the codebase',
            'Fix paste prompts',
          ]);
          expect(windows.map((window) => window.activeAgentSessionId), [
            '11111111-1111-4111-8111-111111111111',
            '22222222-2222-4222-8222-222222222222',
          ]);
        },
      );

      test(
        'open rollout outranks a Node launcher guess in either row order',
        () async {
          await probe.processes([
            '42 1 zsh zsh',
            '501 42 node node /opt/@openai/codex/bin/codex.js',
            '502 501 codex /opt/@openai/codex/vendor/codex',
          ]);
          await probe.openRollout(502, '11111111-1111-4111-8111-111111111111');
          final output = await probe.run();
          final rows = output.trim().split('\n');
          expect(rows, hasLength(2));
          expect(
            rows.any(
              (row) => row.contains('22222222-2222-4222-8222-222222222222'),
            ),
            isTrue,
          );
          for (final ordered in [rows, rows.reversed]) {
            final metadata = parseAgentActiveSessionMetadataOutput(
              ordered.join('\n'),
              {42},
            );
            expect(
              metadata[42]?.sessionId,
              '11111111-1111-4111-8111-111111111111',
            );
            expect(metadata[42]?.confidence, AgentSessionConfidence.high);
          }
        },
      );

      test(
        'native rollout outranks a launcher with an outdated resume ID',
        () async {
          await probe.processes([
            '42 1 zsh zsh',
            '501 42 node node /opt/@openai/codex/bin/codex.js resume 22222222-2222-4222-8222-222222222222',
            '502 501 codex codex resume 22222222-2222-4222-8222-222222222222',
          ]);
          await probe.openRollout(502, '11111111-1111-4111-8111-111111111111');
          final rows = (await probe.run()).trim().split('\n');
          expect(rows, hasLength(2));
          for (final ordered in [rows, rows.reversed]) {
            final metadata = parseAgentActiveSessionMetadataOutput(
              ordered.join('\n'),
              {42},
            );
            expect(
              metadata[42]?.sessionId,
              '11111111-1111-4111-8111-111111111111',
            );
            expect(metadata[42]?.confidence, AgentSessionConfidence.high);
          }
        },
      );

      test('does not guess when two panes share a working directory', () async {
        await probe.processes([
          '42 1 codex codex --yolo',
          '43 1 codex codex --yolo',
        ]);
        expect((await probe.run()).trim(), isEmpty);
        // A resolved pane still counts toward cwd ambiguity for another pane.
        await probe.openRollout(43, '22222222-2222-4222-8222-222222222222');
        final metadata = parseAgentActiveSessionMetadataOutput(
          await probe.run(),
          {42, 43},
        );
        expect(metadata.keys, [43]);
      });

      test('explicit resume ID outranks a newer cwd match', () async {
        await probe.processes([
          '42 1 codex codex --yolo resume 11111111-1111-4111-8111-111111111111',
        ]);
        final metadata = parseAgentActiveSessionMetadataOutput(
          await probe.run(),
          {42},
        );
        expect(metadata[42]?.sessionId, '11111111-1111-4111-8111-111111111111');
        expect(metadata[42]?.title, 'Audit the codebase');
        expect(metadata[42]?.confidence, AgentSessionConfidence.medium);
      });

      test('open rollout outranks an outdated resume argument', () async {
        await probe.processes([
          '42 1 codex codex resume 22222222-2222-4222-8222-222222222222',
        ]);
        await probe.openRollout(42, '11111111-1111-4111-8111-111111111111');
        final metadata = parseAgentActiveSessionMetadataOutput(
          await probe.run(),
          {42},
        );
        expect(metadata[42]?.sessionId, '11111111-1111-4111-8111-111111111111');
      });

      test(
        'PID-scoped logs resolve same-cwd panes without open rollouts',
        () async {
          await probe.processes([
            '42 1 codex codex resume 22222222-2222-4222-8222-222222222222',
            '43 1 codex codex',
          ]);
          await File(
            '${probe.home.path}/.codex/logs_2.sqlite',
          ).writeAsString('fixture');
          await probe.executable('sqlite3', r'''
case "$2" in
  *pid:42:*) echo 11111111-1111-4111-8111-111111111111 ;;
  *pid:43:*) echo 22222222-2222-4222-8222-222222222222 ;;
esac
''');
          final metadata = parseAgentActiveSessionMetadataOutput(
            await probe.run(),
            {42, 43},
          );
          expect(
            metadata[42]?.sessionId,
            '11111111-1111-4111-8111-111111111111',
          );
          expect(
            metadata[43]?.sessionId,
            '22222222-2222-4222-8222-222222222222',
          );
          expect(
            metadata.values.every(
              (value) => value.confidence == AgentSessionConfidence.high,
            ),
            isTrue,
          );
        },
      );

      test('single-pane cwd fallback remains low confidence', () async {
        await probe.processes(['42 1 codex codex resume --last']);
        final metadata = parseAgentActiveSessionMetadataOutput(
          await probe.run(),
          {42},
        );
        expect(metadata[42]?.sessionId, '22222222-2222-4222-8222-222222222222');
        expect(metadata[42]?.confidence, AgentSessionConfidence.low);
      });

      test('resume options are not emitted as session IDs', () async {
        await probe.processes(['42 1 codex codex resume --last']);
        await Directory('${probe.home.path}/.codex').delete(recursive: true);
        expect((await probe.run()).trim(), isEmpty);
      });
    },
    skip: Platform.isWindows ? 'Requires a POSIX shell' : false,
  );
}

class _CodexProbe {
  _CodexProbe(this.home);
  final Directory home;
  String get bin => '${home.path}/bin';

  static Future<_CodexProbe> create() async {
    final probe = _CodexProbe(
      await Directory.systemTemp.createTemp('codex-metadata-'),
    );
    await Directory(probe.bin).create();
    await probe.executable('ps', r'''
case "$1" in
  -eo) cat "$HOME/processes" ;;
  -p) echo 00:10 ;;
esac
''');
    await probe.executable('lsof', r'''
pid=
cwd=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p) shift; pid=$1 ;;
    -d) cwd=true ;;
  esac
  shift
done
if $cwd; then
  printf 'n/workspace\n'
elif [ -r "$HOME/open-$pid" ]; then
  printf 'n'; cat "$HOME/open-$pid"
fi
''');
    await probe.executable('sqlite3', 'exit 0\n');
    final sessions = await Directory(
      '${probe.home.path}/.codex/sessions/2026/09/08',
    ).create(recursive: true);
    for (final id in [
      '11111111-1111-4111-8111-111111111111',
      '22222222-2222-4222-8222-222222222222',
    ]) {
      await File('${sessions.path}/rollout-$id.jsonl').writeAsString(
        '${jsonEncode({
          'type': 'session_meta',
          'payload': {'id': id, 'cwd': '/workspace'},
        })}\n',
      );
    }
    final index = File('${probe.home.path}/.codex/session_index.jsonl');
    await index.writeAsString(
      [
        jsonEncode({
          'id': '11111111-1111-4111-8111-111111111111',
          'thread_name': 'Audit the codebase',
          'updated_at': '2020-01-01T00:00:00Z',
        }),
        jsonEncode({
          'id': '22222222-2222-4222-8222-222222222222',
          'thread_name': 'Fix paste prompts',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }),
      ].join('\n'),
    );
    return probe;
  }

  Future<void> executable(String name, String script) async {
    final file = File('$bin/$name');
    await file.writeAsString('#!/bin/sh\n$script');
    final result = await Process.run('chmod', ['+x', file.path]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
  }

  Future<void> processes(List<String> rows) =>
      File('${home.path}/processes').writeAsString('${rows.join('\n')}\n');

  Future<void> openRollout(int pid, String id) =>
      File('${home.path}/open-$pid').writeAsString(
        '${home.path}/.codex/sessions/2026/09/08/rollout-$id.jsonl\n',
      );

  Future<String> run() async {
    final result = await Process.run(
      '/bin/sh',
      [
        '-c',
        buildAgentActiveSessionMetadataCommand({42, 43}),
      ],
      environment: {'HOME': home.path, 'PATH': '$bin:/usr/bin:/bin'},
      includeParentEnvironment: false,
    );
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(result.stderr.toString(), isEmpty);
    return result.stdout.toString();
  }
}
