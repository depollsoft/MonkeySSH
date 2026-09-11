import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/models/terminal_backend.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/agent_session_discovery_service.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/terminal_connection_backend_service.dart';

import '../../helpers/mock_ssh_exec_session.dart';
import '../../helpers/powershell_test_helpers.dart';

class _MockSshClient extends Mock implements SSHClient {}

class _MockExecSession extends MockSessionWithChannel {}

class _MockTerminalConnectionBackendService extends Mock
    implements TerminalConnectionBackendService {}

class _MockTerminalConnectionBackend extends Mock
    implements TerminalConnectionBackend {}

SshSession _buildDiscoverySession(SSHClient client) => SshSession(
  connectionId: 1,
  hostId: 1,
  client: client,
  config: const SshConnectionConfig(
    hostname: 'example.com',
    port: 22,
    username: 'demo',
  ),
);

Stream<Uint8List> _utf8Stream(String value) => value.isEmpty
    ? const Stream<Uint8List>.empty()
    : Stream<Uint8List>.value(Uint8List.fromList(utf8.encode(value)));

void _ignoreInvocation(Invocation _) {}

SSHSession _buildExecSession({String stdout = '', String stderr = ''}) {
  final session = _MockExecSession();
  when(() => session.stdout).thenAnswer((_) => _utf8Stream(stdout));
  when(() => session.stderr).thenAnswer((_) => _utf8Stream(stderr));
  when(() => session.write(any())).thenAnswer(_ignoreInvocation);
  when(session.close).thenAnswer(_ignoreInvocation);
  return session;
}

SSHSession _buildOpenMarkerExecSession({String stdout = '', int? chunkSize}) {
  final session = _MockExecSession();
  final stdoutController = StreamController<Uint8List>();
  final stderrController = StreamController<Uint8List>();

  scheduleMicrotask(() {
    final bytes = utf8.encode(
      '$stdout\n__flutty_agent_discovery_exec_done__:0\n',
    );
    final size = chunkSize ?? bytes.length;
    for (var offset = 0; offset < bytes.length; offset += size) {
      stdoutController.add(
        Uint8List.fromList(
          bytes.sublist(offset, (offset + size).clamp(0, bytes.length)),
        ),
      );
    }
  });

  when(() => session.stdout).thenAnswer((_) => stdoutController.stream);
  when(() => session.stderr).thenAnswer((_) => stderrController.stream);
  when(() => session.write(any())).thenAnswer(_ignoreInvocation);
  when(session.close).thenAnswer((_) {
    if (!stdoutController.isClosed) unawaited(stdoutController.close());
    if (!stderrController.isClosed) unawaited(stderrController.close());
  });
  return session;
}

SSHSession _buildAcpSessionListExecSession({
  required List<Map<String, Object?>> sessions,
  bool supportsList = true,
  bool malformedSecondPage = false,
  bool repeatedCursor = false,
  List<String?>? requestedCwds,
}) {
  final session = _MockExecSession();
  final stdoutController = StreamController<Uint8List>();
  final stderrController = StreamController<Uint8List>();
  var listRequestCount = 0;

  void send(Map<String, Object?> payload) {
    stdoutController.add(
      Uint8List.fromList(utf8.encode('${jsonEncode(payload)}\n')),
    );
  }

  when(() => session.stdout).thenAnswer((_) => stdoutController.stream);
  when(() => session.stderr).thenAnswer((_) => stderrController.stream);
  when(() => session.write(any())).thenAnswer((invocation) {
    final bytes = invocation.positionalArguments.first as Uint8List;
    final decoded = jsonDecode(utf8.decode(bytes).trim());
    if (decoded is! Map<String, dynamic>) return;
    final id = decoded['id'] as int;
    switch (decoded['method']) {
      case 'initialize':
        send({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'protocolVersion': 1,
            'agentCapabilities': {
              'sessionCapabilities': {
                if (supportsList) 'list': <String, Object?>{},
              },
            },
          },
        });
        return;
      case 'session/list':
        final params = decoded['params'];
        requestedCwds?.add(
          params is Map<String, dynamic> ? params['cwd'] as String? : null,
        );
        listRequestCount += 1;
        send({
          'jsonrpc': '2.0',
          'id': id,
          'result': malformedSecondPage && listRequestCount == 2
              ? 'malformed'
              : <String, Object?>{
                  'sessions': sessions,
                  if ((repeatedCursor && listRequestCount < 10) ||
                      (malformedSecondPage && listRequestCount == 1))
                    'nextCursor': 'page-2',
                },
        });
        return;
    }
  });
  when(session.close).thenAnswer((_) {
    if (!stdoutController.isClosed) unawaited(stdoutController.close());
    if (!stderrController.isClosed) unawaited(stderrController.close());
  });
  return session;
}

String _remoteSnapshotLine(String path, String content, {int mtime = 0}) =>
    '$path\x1f$mtime\x1f${base64Encode(utf8.encode(content))}\n';

String _markedDiscoveryOutput(String stdout) =>
    '$stdout\n__flutty_agent_discovery_exec_done__:0\n';

void main() {
  tearDown(resetQueuedSshExecsForTesting);

  for (final kind in ['posix', 'windows', 'acp']) {
    testWidgets('stalled $kind discovery open releases its queue slot', (
      tester,
    ) async {
      final opening = Completer<SSHSession>();
      final client = _MockSshClient();
      if (kind == 'windows') {
        when(
          () => client.remoteVersion,
        ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');
      }
      var calls = 0;
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) {
        calls++;
        final command = invocation.positionalArguments.single as String;
        if (kind != 'acp' || command.contains('copilot --acp')) {
          return opening.future;
        }
        return Future.value(_buildExecSession());
      });
      final session = _buildDiscoverySession(client);
      final toolName = kind == 'acp' ? 'Copilot CLI' : 'Claude Code';
      final result = AgentSessionDiscoveryService()
          .discoverSessionsStream(session, toolName: toolName)
          .last;
      var completed = false;
      unawaited(
        result.then((_) {
          completed = true;
        }),
      );
      await tester.pump();
      expect(calls, 1);
      expect(activeQueuedSshExecCountForTesting(session.connectionId), 1);
      var nextRan = false;
      final next = session.runQueuedExec(() async {
        nextRan = true;
      }, priority: SshExecPriority.low);
      expect(pendingQueuedSshExecCountForTesting(session.connectionId), 1);
      final deadline = Duration(seconds: kind == 'acp' ? 2 : 10);
      await tester.pump(deadline - const Duration(milliseconds: 1));
      expect(completed, isFalse);
      expect(nextRan, isFalse);
      await tester.pump(const Duration(milliseconds: 1));
      expect(completed, isTrue);
      final discovered = await result;
      if (kind == 'acp') {
        // ACP open failure must permit file-based discovery to run.
        expect(calls, greaterThan(1));
        expect(discovered.sessions, isEmpty);
      } else {
        expect(discovered.failedTools, contains(toolName));
      }
      await next;
      expect(nextRan, isTrue);
      expect(activeQueuedSshExecCountForTesting(session.connectionId), 0);
      expect(pendingQueuedSshExecCountForTesting(session.connectionId), 0);
      final late = _buildExecSession();
      opening.complete(late);
      await tester.pump();
      verify(late.channel.destroy).called(1);
    });
  }

  test(
    'newest files are sorted across find batches with BSD and GNU stat',
    () async {
      final root = await Directory.systemTemp.createTemp('discovery-order-');
      addTearDown(() => root.delete(recursive: true));
      final older = File('${root.path}/older.jsonl')..writeAsStringSync('old');
      final middle = File('${root.path}/middle\tname.jsonl')
        ..writeAsStringSync('middle');
      final newest = File("${root.path}/newest 'quoted'.jsonl")
        ..writeAsStringSync('new');
      for (final (index, file) in [older, middle, newest].indexed) {
        file.setLastModifiedSync(DateTime.utc(2026, 1, index + 1));
      }
      final bin = Directory('${root.path}/bin')..createSync();
      final batchLog = File('${root.path}/batches');
      final find = File('${bin.path}/find')
        ..writeAsStringSync(
          '''#!/bin/sh\n'''
          r'''

while [ "$1" != '-exec' ]; do shift; done
shift
runner=$1
script=$3
for file in "$OLDER" "$MIDDLE" "$NEWEST"; do
  printf 'batch\n' >> "$BATCH_LOG"
  "$runner" -c "$script" sh "$file"
done
''',
        );
      final stat = File('${bin.path}/stat')
        ..writeAsStringSync(
          '''#!/bin/sh\n'''
          r'''

if [ "$STAT_STYLE" = native ]; then exec /usr/bin/stat "$@"; fi
if [ "$STAT_STYLE" = bsd ]; then [ "$1" = -f ] || exit 1
else [ "$1" = -c ] || exit 1; fi
format=$2
shift 2
for file do
  timestamp=$(/usr/bin/stat -c %Y "$file" 2>/dev/null || /usr/bin/stat -f %m "$file")
  if [ "$format" = %Y ]; then printf '%s\n' "$timestamp"
  else printf '%s\t%s\n' "$timestamp" "$file"; fi
done
''',
        );
      final chmod = await Process.run('chmod', ['+x', find.path, stat.path]);
      expect(chmod.exitCode, 0, reason: '${chmod.stderr}');
      for (final style in ['gnu', 'bsd', 'native']) {
        batchLog.writeAsStringSync('');
        final result = await Process.run(
          'sh',
          ['-c', posixListNewestFilesCommand('find unused -type f', 2)],
          environment: {
            'PATH': '${bin.path}:/usr/bin:/bin',
            'STAT_STYLE': style,
            'OLDER': older.path,
            'MIDDLE': middle.path,
            'NEWEST': newest.path,
            'BATCH_LOG': batchLog.path,
          },
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(batchLog.readAsLinesSync(), ['batch', 'batch', 'batch']);
        expect(
          result.stdout,
          '${newest.path}\n${middle.path}\n',
          reason: style,
        );
      }
      final filtered = await Process.run(
        'sh',
        [
          '-c',
          posixListNewestFilesCommand(
            "find '${root.path}' -maxdepth 1 -name '*.jsonl' -type f "
            r'-exec grep -q -x -F new {} \;',
            2,
          ),
        ],
        environment: {'PATH': '/usr/bin:/bin'},
      );
      expect(filtered.exitCode, 0, reason: '${filtered.stderr}');
      expect(filtered.stdout, '${newest.path}\n');
    },
  );

  setUpAll(() {
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(SshExecPriority.low);
  });

  group('normalizeWorkingDirectoryForComparison', () {
    test('strips worktree branch segments from comparable paths', () {
      expect(
        normalizeWorkingDirectoryForComparison(
          '/Users/depoll/Code/flutty.worktrees/fix-session-resumption/lib',
        ),
        '/Users/depoll/Code/flutty/lib',
      );
    });
  });

  group('parseGitWorktreeRoots', () {
    test('extracts worktree paths from porcelain output', () {
      expect(
        parseGitWorktreeRoots('''
worktree /Users/depoll/Code/flutty
HEAD afdab6c
branch refs/heads/main

worktree /Users/depoll/Code/flutty.worktrees/fix-session-resumption
HEAD 1234567
branch refs/heads/fix/session-resumption
'''),
        [
          '/Users/depoll/Code/flutty',
          '/Users/depoll/Code/flutty.worktrees/fix-session-resumption',
        ],
      );
    });
  });

  group('buildRelatedWorkingDirectories', () {
    test('maps the active subdirectory across git worktrees', () {
      expect(
        buildRelatedWorkingDirectories(
          '/Users/depoll/Code/flutty.worktrees/fix-session-resumption/lib',
          gitRoot: '/Users/depoll/Code/flutty.worktrees/fix-session-resumption',
          gitWorktreeRoots: const [
            '/Users/depoll/Code/flutty',
            '/Users/depoll/Code/flutty.worktrees/feature-other',
          ],
        ),
        containsAll(<String>[
          '/Users/depoll/Code/flutty.worktrees/fix-session-resumption/lib',
          '/Users/depoll/Code/flutty/lib',
          '/Users/depoll/Code/flutty.worktrees/feature-other/lib',
          '/Users/depoll/Code/flutty.worktrees/feature-other',
        ]),
      );
    });
  });

  test(
    'root directory includes descendants and maps relative worktree paths',
    () {
      expect(matchesDiscoveredSessionWorkingDirectory('/', '/repo'), isTrue);
      expect(matchesDiscoveredSessionWorkingDirectory('/', '/'), isTrue);
      expect(
        matchesDiscoveredSessionWorkingDirectory('/repo', '/repository'),
        isFalse,
      );
      expect(
        buildRelatedWorkingDirectories(
          '/repo',
          gitRoot: '/',
          gitWorktreeRoots: const ['/', '/sibling'],
        ),
        contains('/sibling/repo'),
      );
      expect(
        scopeDiscoveredSessionsToWorkingDirectory(const [
          ToolSessionInfo(
            toolName: 'OpenCode',
            sessionId: 'root-child',
            workingDirectory: '/repo',
          ),
        ], '/').single.sessionId,
        'root-child',
      );
      expect(
        buildSqlWorkingDirectoryScopeClause(const [
          '/',
        ], columnName: 'directory'),
        contains("substr(directory, 1, length('/')) = '/'"),
      );
    },
  );

  group('matchesDiscoveredSessionWorkingDirectory', () {
    test('matches the main checkout from a sibling worktree', () {
      final relatedDirectories = buildRelatedWorkingDirectories(
        '/Users/depoll/Code/flutty.worktrees/fix-session-resumption',
        gitRoot: '/Users/depoll/Code/flutty.worktrees/fix-session-resumption',
        gitWorktreeRoots: const [
          '/Users/depoll/Code/flutty',
          '/Users/depoll/Code/flutty.worktrees/feature-other',
        ],
      );

      expect(
        matchesDiscoveredSessionWorkingDirectory(
          '/Users/depoll/Code/flutty.worktrees/fix-session-resumption',
          '/Users/depoll/Code/flutty',
          relatedWorkingDirectories: relatedDirectories,
        ),
        isTrue,
      );
      expect(
        matchesDiscoveredSessionWorkingDirectory(
          '/Users/depoll/Code/flutty.worktrees/fix-session-resumption',
          '/tmp/another-repo/flutty',
          relatedWorkingDirectories: relatedDirectories,
        ),
        isFalse,
      );
    });
  });

  group('resolveAgentSessionScopeWorkingDirectory', () {
    test('keeps the active project path when it already looks valid', () {
      expect(
        resolveAgentSessionScopeWorkingDirectory(
          activeWorkingDirectory: '/Users/depoll/Code/flutty',
          sessionWorkingDirectory: Uri.parse(
            'file:///Users/depoll/Code/flutty',
          ),
        ),
        '/Users/depoll/Code/flutty',
      );
    });

    test('falls back from Copilot state paths to the terminal cwd', () {
      expect(
        resolveAgentSessionScopeWorkingDirectory(
          activeWorkingDirectory:
              '/Users/depoll/.copilot/session-state/970e4099-a97c-456a-a6c2-408095060f72',
          sessionWorkingDirectory: Uri.parse(
            'file:///Users/depoll/Code/flutty',
          ),
        ),
        '/Users/depoll/Code/flutty',
      );
    });

    test('falls back from AI tool home directories to the terminal cwd', () {
      expect(
        resolveAgentSessionScopeWorkingDirectory(
          activeWorkingDirectory: '/Users/depoll/.copilot',
          sessionWorkingDirectory: Uri.parse(
            'file:///Users/depoll/Code/flutty',
          ),
        ),
        '/Users/depoll/Code/flutty',
      );
      expect(
        resolveAgentSessionScopeWorkingDirectory(
          activeWorkingDirectory: '/Users/depoll/.local/share/opencode',
          sessionWorkingDirectory: Uri.parse(
            'file:///Users/depoll/Code/flutty',
          ),
        ),
        '/Users/depoll/Code/flutty',
      );
      expect(
        resolveAgentSessionScopeWorkingDirectory(
          activeWorkingDirectory: '/Users/depoll/.gemini',
          sessionWorkingDirectory: Uri.parse(
            'file:///Users/depoll/Code/flutty',
          ),
        ),
        '/Users/depoll/Code/flutty',
      );
    });

    test('prefers a more specific terminal cwd over a broader pane cwd', () {
      expect(
        resolveAgentSessionScopeWorkingDirectory(
          activeWorkingDirectory: '/Users/depoll',
          sessionWorkingDirectory: Uri.parse(
            'file:///Users/depoll/Code/flutty',
          ),
        ),
        '/Users/depoll/Code/flutty',
      );
    });

    test('prefers the live terminal cwd when tmux metadata disagrees', () {
      expect(
        resolveAgentSessionScopeWorkingDirectory(
          activeWorkingDirectory: '/Users/depoll/Code/another-project',
          sessionWorkingDirectory: Uri.parse(
            'file:///Users/depoll/Code/flutty',
          ),
        ),
        '/Users/depoll/Code/flutty',
      );
    });

    test('drops temp-only paths when there is no terminal cwd fallback', () {
      expect(
        resolveAgentSessionScopeWorkingDirectory(
          activeWorkingDirectory: '/var/folders/demo/output',
        ),
        isNull,
      );
    });
  });

  group('resolveTmuxAiSessionScopeWorkingDirectory', () {
    test('prefers the live terminal cwd over stale tmux metadata', () {
      expect(
        resolveTmuxAiSessionScopeWorkingDirectory(
          liveTerminalWorkingDirectory: '/Users/depoll/Code/flutty',
          tmuxWorkingDirectory: '/Users/depoll/Code/another-project',
          sessionWorkingDirectory: Uri.parse(
            'file:///Users/depoll/Code/flutty',
          ),
        ),
        '/Users/depoll/Code/flutty',
      );
    });

    test('falls back to tmux metadata only when no live cwd exists', () {
      expect(
        resolveTmuxAiSessionScopeWorkingDirectory(
          tmuxWorkingDirectory: '/Users/depoll/Code/flutty',
        ),
        '/Users/depoll/Code/flutty',
      );
    });
  });

  group('readClaudeHistoryWorkingDirectory', () {
    test('ignores malformed non-string directory metadata', () {
      expect(
        readClaudeHistoryWorkingDirectory({
          'directory': {'path': '/Users/depoll/Code/flutty'},
          'project': 42,
        }),
        isNull,
      );

      expect(
        readClaudeHistoryWorkingDirectory({
          'directory': 42,
          'project': '/Users/depoll/Code/flutty',
        }),
        '/Users/depoll/Code/flutty',
      );
    });
  });

  group('calculateClaudeMetadataSnapshotLimit', () {
    test('caps Claude metadata snapshots to a smaller recent window', () {
      expect(calculateClaudeMetadataSnapshotLimit(6), 40);
      expect(calculateClaudeMetadataSnapshotLimit(24), 80);
      expect(calculateClaudeMetadataSnapshotLimit(48), 80);
    });
  });

  group('calculateRecentSessionMetadataReadLimit', () {
    test('caps other provider metadata reads to a smaller recent window', () {
      expect(calculateRecentSessionMetadataReadLimit(6), 24);
      expect(calculateRecentSessionMetadataReadLimit(12), 36);
      expect(calculateRecentSessionMetadataReadLimit(24), 48);
    });
  });

  group('scopeDiscoveredSessionsToWorkingDirectory', () {
    test('keeps Git worktree sessions for every discovered agent', () {
      const tools = <String>[
        'Claude Code',
        'Copilot CLI',
        'Codex',
        'Antigravity',
        'Cursor Agent',
        'OpenCode',
        'Pi',
        'Hermes',
        'Grok Build',
      ];
      final sessions = <ToolSessionInfo>[
        for (final tool in tools) ...[
          ToolSessionInfo(
            toolName: tool,
            sessionId: '$tool-worktree',
            workingDirectory: '/Users/depoll/worktrees/feature',
            summary: 'worktree',
          ),
          ToolSessionInfo(
            toolName: tool,
            sessionId: '$tool-unrelated',
            workingDirectory: '/tmp/unrelated',
            summary: 'unrelated',
          ),
        ],
      ];

      final scoped = scopeDiscoveredSessionsToWorkingDirectory(
        sessions,
        '/Users/depoll/Code/MonkeySSH',
        relatedWorkingDirectories: const [
          '/Users/depoll/Code/MonkeySSH',
          '/Users/depoll/worktrees/feature',
        ],
      );

      expect(scoped, hasLength(tools.length));
      expect(scoped.map((session) => session.toolName).toSet(), tools.toSet());
      expect(
        scoped.every((session) => session.sessionId.endsWith('-worktree')),
        isTrue,
      );
    });

    test('keeps providers that have no matching cwd metadata', () {
      final scopedSessions = scopeDiscoveredSessionsToWorkingDirectory(
        [
          ToolSessionInfo(
            toolName: 'Claude Code',
            sessionId: 'claude-match',
            workingDirectory: '/Users/depoll/Code/flutty',
            summary: 'Fix tmux filtering',
            lastActive: DateTime(2026, 4, 20, 12),
          ),
          ToolSessionInfo(
            toolName: 'Claude Code',
            sessionId: 'claude-other',
            workingDirectory: '/tmp/another-repo',
            summary: 'Other project',
            lastActive: DateTime(2026, 4, 20, 11),
          ),
          ToolSessionInfo(
            toolName: 'Codex',
            sessionId: 'codex-no-cwd',
            summary: 'Investigate session loading',
            lastActive: DateTime(2026, 4, 20, 10),
          ),
          ToolSessionInfo(
            toolName: 'Copilot CLI',
            sessionId: 'copilot-no-cwd',
            summary: 'Review recent tmux fixes',
            lastActive: DateTime(2026, 4, 20, 9),
          ),
        ],
        '/Users/depoll/Code/flutty.worktrees/feature-other',
        relatedWorkingDirectories: const [
          '/Users/depoll/Code/flutty.worktrees/feature-other',
          '/Users/depoll/Code/flutty',
        ],
      );

      expect(scopedSessions.map((session) => session.sessionId), [
        'claude-match',
        'codex-no-cwd',
        'copilot-no-cwd',
      ]);
    });
  });

  group('sortAndLimitDiscoveredSessions', () {
    test('sorts by recency before applying the cap', () {
      final limitedSessions = sortAndLimitDiscoveredSessions([
        ToolSessionInfo(
          toolName: 'Claude Code',
          sessionId: 'older',
          summary: 'older',
          lastActive: DateTime(2026, 4, 12),
        ),
        ToolSessionInfo(
          toolName: 'Claude Code',
          sessionId: 'newer',
          summary: 'newer',
          lastActive: DateTime(2026, 4, 13),
        ),
      ], 1);

      expect(limitedSessions.map((session) => session.sessionId), ['newer']);
    });
  });

  group('orderedDiscoveredSessionTools', () {
    test('includes all known providers in a stable order', () {
      final ordered = orderedDiscoveredSessionTools(
        {
          'Claude Code': const <ToolSessionInfo>[],
          'Codex': const <ToolSessionInfo>[],
        },
        const ['Antigravity'],
      );

      expect(ordered, [
        'Claude Code',
        'Copilot CLI',
        'Codex',
        'OpenCode',
        'Antigravity',
        'Cursor Agent',
        'Pi',
        'Hermes',
        'Grok Build',
      ]);
    });

    test('moves the preferred tool to the front and appends unknown tools', () {
      final ordered = orderedDiscoveredSessionTools(
        const {'Custom Tool': <ToolSessionInfo>[]},
        const ['Custom Tool'],
        preferredToolName: 'Codex',
      );

      expect(ordered, [
        'Codex',
        'Claude Code',
        'Copilot CLI',
        'OpenCode',
        'Antigravity',
        'Cursor Agent',
        'Pi',
        'Hermes',
        'Grok Build',
        'Custom Tool',
      ]);
    });
  });

  group('normalizeDiscoveredSessionInfo', () {
    for (final (summaries, expected) in [
      (
        [
          'Quoted "title"',
          '"Quoted" title',
          "Review 'title'",
          "Review users'",
          'Review `title`',
        ],
        'unchanged',
      ),
      (
        [
          '"Review title"',
          "'Review title'",
          '`Review title`',
          '"`Review title`"',
          '  "  Review   title  "  ',
        ],
        'Review title',
      ),
      (['"', "'", '`', "\"'`"], null),
    ]) {
      for (final summary in summaries) {
        test('normalizes summary quotes: $summary', () {
          final normalized = normalizeDiscoveredSessionInfo(
            ToolSessionInfo(
              toolName: 'Antigravity',
              sessionId: 'example',
              summary: summary,
            ),
          );
          if (expected == null) {
            expect(normalized, isNull);
          } else {
            expect(
              normalized?.summary,
              expected == 'unchanged' ? summary : expected,
            );
          }
        });
      }
    }

    test('drops unnamed sessions without usable fallback context', () {
      const info = ToolSessionInfo(
        toolName: 'Copilot CLI',
        sessionId: '12345678-1234-1234-1234-1234567890ab',
        summary: '12345678…',
      );

      expect(normalizeDiscoveredSessionInfo(info), isNull);
    });

    test('falls back to working directory name when title is missing', () {
      const info = ToolSessionInfo(
        toolName: 'Copilot CLI',
        sessionId: '12345678-1234-1234-1234-1234567890ab',
        workingDirectory: '/Users/depoll/Code/flutty',
      );

      final normalized = normalizeDiscoveredSessionInfo(info);
      expect(normalized, isNotNull);
      expect(normalized!.summary, 'flutty');
    });

    test(
      'drops project-name-only summaries in current working directory view',
      () {
        const info = ToolSessionInfo(
          toolName: 'Copilot CLI',
          sessionId: '12345678-1234-1234-1234-1234567890ab',
          workingDirectory: '/Users/depoll/Code/flutty',
          summary: 'flutty',
        );

        expect(
          normalizeDiscoveredSessionInfo(
            info,
            activeWorkingDirectory: '/Users/depoll/Code/flutty',
          ),
          isNull,
        );
      },
    );

    test(
      'drops directory fallback when the active working directory already matches',
      () {
        const info = ToolSessionInfo(
          toolName: 'Claude Code',
          sessionId: 'abcdef',
          workingDirectory: '/Users/depoll/Code/flutty',
        );

        expect(
          normalizeDiscoveredSessionInfo(
            info,
            activeWorkingDirectory: '/Users/depoll/Code/flutty',
          ),
          isNull,
        );
      },
    );
  });

  group('buildResumeCommand', () {
    test('resumes Codex with the discovered session UUID', () {
      const info = ToolSessionInfo(
        toolName: 'Codex',
        sessionId: '019dcbf6-c80e-7c30-b7fa-3d352bda8c4d',
        workingDirectory: '/Users/depoll/Code/flutty',
      );

      expect(
        AgentSessionDiscoveryService().buildResumeCommand(info),
        "cd '/Users/depoll/Code/flutty' && "
        "codex resume '019dcbf6-c80e-7c30-b7fa-3d352bda8c4d'",
      );
    });

    test('adds yolo mode when resuming supported sessions', () {
      const info = ToolSessionInfo(
        toolName: 'Codex',
        sessionId: '019dcbf6-c80e-7c30-b7fa-3d352bda8c4d',
        workingDirectory: '/Users/depoll/Code/flutty',
      );

      expect(
        AgentSessionDiscoveryService().buildResumeCommand(
          info,
          startInYoloMode: true,
        ),
        "cd '/Users/depoll/Code/flutty' && "
        "codex --yolo resume '019dcbf6-c80e-7c30-b7fa-3d352bda8c4d'",
      );
    });

    test('resumes Cursor Agent with the discovered chat id', () {
      const info = ToolSessionInfo(
        toolName: 'Cursor Agent',
        sessionId: 'f21ed2df-500d-46a5-b55f-12b64268491f',
        workingDirectory: '/Users/depoll/Code/flutty',
      );

      expect(
        AgentSessionDiscoveryService().buildResumeCommand(info),
        "cd '/Users/depoll/Code/flutty' && "
        "cursor-agent --resume 'f21ed2df-500d-46a5-b55f-12b64268491f'",
      );
    });
  });

  group('compareDiscoveredSessionsByRecency', () {
    test('sorts newest first and leaves untimestamped sessions last', () {
      final sessions = [
        ToolSessionInfo(
          toolName: 'OpenCode',
          sessionId: '3',
          summary: 'older',
          lastActive: DateTime(2026, 4, 10),
        ),
        const ToolSessionInfo(
          toolName: 'Copilot CLI',
          sessionId: '2',
          summary: 'no timestamp',
        ),
        ToolSessionInfo(
          toolName: 'Claude Code',
          sessionId: '1',
          summary: 'newest',
          lastActive: DateTime(2026, 4, 12),
        ),
      ];

      final sortedSessions = sessions.toList()
        ..sort(compareDiscoveredSessionsByRecency);

      expect(sortedSessions.map((session) => session.sessionId), [
        '1',
        '3',
        '2',
      ]);
    });
  });

  group('parseCopilotWorkspaceYamlMetadata', () {
    test('reads multiline summary blocks and updated_at timestamps', () {
      final metadata = parseCopilotWorkspaceYamlMetadata('''
id: example
cwd: /Users/depoll/Code/flutty
summary: |-
  Fix Handlebar Jitter And Tmux Animation
  With extra detail on the next line
updated_at: 2026-04-14T01:02:03.000Z
''');

      expect(metadata.summary, 'Fix Handlebar Jitter And Tmux Animation');
      expect(metadata.workingDirectory, '/Users/depoll/Code/flutty');
      expect(metadata.updatedAt, DateTime.parse('2026-04-14T01:02:03.000Z'));
    });

    test('falls back to repository and branch when summary is missing', () {
      final metadata = parseCopilotWorkspaceYamlMetadata('''
id: example
cwd: /Users/depoll/Code/flutty
repository: depollsoft/MonkeySSH
branch: main
updated_at: 2026-04-14T01:02:03.000Z
''');

      expect(metadata.summary, 'depollsoft/MonkeySSH (main)');
      expect(metadata.workingDirectory, '/Users/depoll/Code/flutty');
      expect(metadata.updatedAt, DateTime.parse('2026-04-14T01:02:03.000Z'));
    });

    test('prefers user-provided session names when summary is missing', () {
      final metadata = parseCopilotWorkspaceYamlMetadata('''
id: example
name: Fix active session labels
repository: depollsoft/MonkeySSH
branch: main
''');

      expect(metadata.summary, 'Fix active session labels');
    });

    test('normalizes inline summary text to a single display line', () {
      final metadata = parseCopilotWorkspaceYamlMetadata('''
summary:   Add   PR preview   commit list   
cwd: /tmp/demo
''');

      expect(metadata.summary, 'Add PR preview commit list');
      expect(metadata.workingDirectory, '/tmp/demo');
      expect(metadata.updatedAt, isNull);
    });
  });

  group('buildSqlWorkingDirectoryScopeClause', () {
    test('uses exact prefix predicates instead of LIKE wildcards', () {
      final clause = buildSqlWorkingDirectoryScopeClause(const [
        '/Users/depoll/Code/my_repo',
      ], columnName: 'directory');

      expect(clause, isNotNull);
      expect(clause, isNot(contains('LIKE')));
      expect(
        clause,
        contains(
          "substr(directory, 1, length('/Users/depoll/Code/my_repo/')) = '/Users/depoll/Code/my_repo/'",
        ),
      );
    });
  });

  group('DiscoveredSessionsResult', () {
    test('formats a readable failure message', () {
      final result = DiscoveredSessionsResult(
        sessions: const [],
        failedTools: const {'Codex', 'Antigravity'},
      );

      expect(
        result.failureMessage,
        'Could not load Antigravity and Codex sessions.',
      );
    });

    test('formats single-tool failures and keeps no-failure states quiet', () {
      expect(
        DiscoveredSessionsResult(
          sessions: const [],
          failedTools: const {'Claude Code'},
        ).failureMessage,
        'Could not load Claude Code sessions.',
      );
      expect(
        DiscoveredSessionsResult(sessions: const []).failureMessage,
        isNull,
      );
    });

    test('tracks attempted tools separately for placeholder rows', () {
      final result = DiscoveredSessionsResult(
        sessions: const [],
        attemptedTools: const {'Claude Code', 'Copilot CLI'},
      );

      expect(result.hasFailures, isFalse);
      expect(result.attemptedTools, {'Claude Code', 'Copilot CLI'});
    });
  });

  group('shouldSurfaceDiscoveryFailure', () {
    test('reports tools that failed to load any sessions', () {
      expect(
        shouldSurfaceDiscoveryFailure(hadError: true, loadedSessionCount: 0),
        isTrue,
      );
    });

    test('suppresses partial failures when sessions still loaded', () {
      expect(
        shouldSurfaceDiscoveryFailure(hadError: true, loadedSessionCount: 3),
        isFalse,
      );
    });

    test('suppresses healthy empty discovery results', () {
      expect(
        shouldSurfaceDiscoveryFailure(hadError: false, loadedSessionCount: 0),
        isFalse,
      );
    });
  });

  group('parseCodexRolloutMetadata', () {
    test('prefers the structured user_message event over input_text noise', () {
      final metadata = parseCodexRolloutMetadata('''
{"timestamp":"2026-04-12T21:07:44.781Z","type":"session_meta","payload":{"id":"019d8385-487f-72c1-9abf-766ffc76deff","cwd":"/Users/depoll/Code/flutty"}}
{"timestamp":"2026-04-12T21:07:45.000Z","type":"response_item","payload":{"type":"message","content":[{"type":"input_text","text":"<permissions instructions>"}]}}
{"timestamp":"2026-04-12T21:07:48.390Z","type":"event_msg","payload":{"type":"user_message","message":"rename this session","images":[]}}
''');

      expect(metadata.parsedAny, isTrue);
      expect(metadata.sessionId, '019d8385-487f-72c1-9abf-766ffc76deff');
      expect(metadata.workingDirectory, '/Users/depoll/Code/flutty');
      expect(metadata.summary, 'rename this session');
      expect(metadata.updatedAt, DateTime.parse('2026-04-12T21:07:44.781Z'));
    });
  });

  group('parseClaudeSessionMetadata', () {
    test('extracts the first real user prompt and ignores slash commands', () {
      final metadata = parseClaudeSessionMetadata('''
{"type":"user","isMeta":false,"message":{"role":"user","content":"/exit"}}
{"type":"user","isMeta":false,"message":{"role":"user","content":"Fix the tmux session list loading bug"}}
''');

      expect(metadata.parsedAny, isTrue);
      expect(metadata.userSummary, 'Fix the tmux session list loading bug');
    });

    test('preserves explicit metadata fields when present', () {
      final metadata = parseClaudeSessionMetadata('''
{"customTitle":"Investigate slow AI session loading","agentName":"Opus","lastPrompt":"ignored"}
''');

      expect(metadata.customTitle, 'Investigate slow AI session loading');
      expect(metadata.agentName, 'Opus');
      expect(metadata.lastPrompt, 'ignored');
    });

    test(
      'prefers the latest metadata fields while keeping the first prompt',
      () {
        final metadata = parseClaudeSessionMetadata('''
{"type":"user","isMeta":false,"message":{"role":"user","content":"Original prompt"}}
{"customTitle":"Initial title","lastPrompt":"older"}
{"customTitle":"Renamed title","lastPrompt":"newer"}
''');

        expect(metadata.userSummary, 'Original prompt');
        expect(metadata.customTitle, 'Renamed title');
        expect(metadata.lastPrompt, 'newer');
      },
    );
  });

  group('parseAntigravitySessionMetadata', () {
    test('uses stored summary, sessionId, workingDirectory, and updatedAt', () {
      final metadata = parseAntigravitySessionMetadata('''
{
  "id": "e4adef4c-bdaf-4dcb-9e81-ae9107f2ecf3",
  "summary": "Fix some bugs",
  "workingDirectory": "/Users/depoll/Code/flutty",
  "updatedAt": "2026-04-12T21:29:53.292Z"
}
''');

      expect(metadata.parsedAny, isTrue);
      expect(metadata.sessionId, 'e4adef4c-bdaf-4dcb-9e81-ae9107f2ecf3');
      expect(metadata.summary, 'Fix some bugs');
      expect(metadata.workingDirectory, '/Users/depoll/Code/flutty');
      expect(metadata.updatedAt, DateTime.parse('2026-04-12T21:29:53.292Z'));
    });

    test('prefers history display names over stale summaries', () {
      final metadata = parseAntigravitySessionMetadata('''
{
  "id": "e4adef4c-bdaf-4dcb-9e81-ae9107f2ecf3",
  "display": "Updated session name",
  "summary": "Original summary"
}
''');

      expect(metadata.parsedAny, isTrue);
      expect(metadata.summary, 'Updated session name');
    });

    for (final (name, uri, expectedPath) in [
      (
        'extracts working directory from nested folderUri',
        'file:///Users/depoll/Code/flutty',
        '/Users/depoll/Code/flutty',
      ),
      (
        'decodes percent-encoded folderUri paths',
        'file:///Users/depoll/My%20Code/flutty',
        '/Users/depoll/My Code/flutty',
      ),
      (
        'maps Windows drive-letter folderUri to a backslash path',
        'file:///C:/Users/demo/My%20Repo',
        r'C:\Users\demo\My Repo',
      ),
    ]) {
      test(name, () {
        final metadata = parseAntigravitySessionMetadata('''
{
  "id": "e4adef4c-bdaf-4dcb-9e81-ae9107f2ecf3",
  "name": "Untitled",
  "projectResources": {
    "resources": [
      {"gitFolder": {"folderUri": "$uri", "allowWrite": true}}
    ]
  }
}
''');

        expect(metadata.parsedAny, isTrue);
        expect(metadata.workingDirectory, expectedPath);
      });
    }

    test('falls back to name when it is an absolute path', () {
      final metadata = parseAntigravitySessionMetadata('''
{
  "id": "e4adef4c-bdaf-4dcb-9e81-ae9107f2ecf3",
  "name": "/Users/depoll/Code/flutty"
}
''');

      expect(metadata.parsedAny, isTrue);
      expect(metadata.workingDirectory, '/Users/depoll/Code/flutty');
    });

    test(
      'extracts metadata from a truncated JSON prefix (partial parsing)',
      () {
        final metadata = parseAntigravitySessionMetadata('''
{
  "id": "e4adef4c-bdaf-4dcb-9e81-ae9107f2ecf3",
  "name": "/Users/depoll/Code/flutty",
  "folderUri": "file:///Users/depoll/Code/flutty",
  "updatedAt": "2026-04-12T21:29:53.2
''');

        expect(metadata.parsedAny, isTrue);
        expect(metadata.sessionId, 'e4adef4c-bdaf-4dcb-9e81-ae9107f2ecf3');
        expect(metadata.summary, '/Users/depoll/Code/flutty');
        expect(metadata.workingDirectory, '/Users/depoll/Code/flutty');
      },
    );

    test('sets parsedAny to false when no recognized fields are present', () {
      final metadata = parseAntigravitySessionMetadata('''
{
  "unknownField": "value"
}
''');

      expect(metadata.parsedAny, isFalse);
    });
  });

  group('parseGrokSessionMetadata', () {
    test('uses generated title, authoritative info, and last activity', () {
      final metadata = parseGrokSessionMetadata('''
{
  "info": {
    "id": "019f6cb5-f7e4-7bc1-bb25-9985af59619e",
    "cwd": "/Users/depoll/Code/flutty"
  },
  "session_summary": "Older summary",
  "generated_title": "Fix Grok session resumption",
  "created_at": "2026-08-14T20:00:00Z",
  "updated_at": "2026-08-14T20:05:00Z",
  "last_active_at": "2026-08-14T20:04:00Z"
}
''');

      expect(metadata.parsedAny, isTrue);
      expect(metadata.sessionId, '019f6cb5-f7e4-7bc1-bb25-9985af59619e');
      expect(metadata.summary, 'Fix Grok session resumption');
      expect(metadata.workingDirectory, '/Users/depoll/Code/flutty');
      expect(metadata.updatedAt, DateTime.parse('2026-08-14T20:04:00Z'));
      expect(metadata.isHidden, isFalse);
    });

    test('falls back to session summary and identifies hidden subagents', () {
      final metadata = parseGrokSessionMetadata('''
{
  "info": {"id": "child", "cwd": "/tmp/repo"},
  "session_summary": "Child work",
  "updated_at": "2026-08-14T20:05:00Z",
  "session_kind": "subagent"
}
''');

      expect(metadata.summary, 'Child work');
      expect(metadata.isHidden, isTrue);
    });

    test('honors an explicit hidden boolean over the session kind', () {
      final visibleSubagent = parseGrokSessionMetadata('''
{
  "info": {"id": "child", "cwd": "/tmp/repo"},
  "session_kind": "subagent",
  "hidden": false
}
''');
      final hiddenRoot = parseGrokSessionMetadata('''
{
  "info": {"id": "root", "cwd": "/tmp/repo"},
  "session_kind": "root",
  "hidden": true
}
''');

      expect(visibleSubagent.isHidden, isFalse);
      expect(hiddenRoot.isHidden, isTrue);
    });

    test('rejects malformed metadata', () {
      expect(parseGrokSessionMetadata('{broken').parsedAny, isFalse);
    });
  });

  group('parsePiSessionHeader', () {
    test('reads id, cwd, and timestamp from the first session record', () {
      final header = parsePiSessionHeader('''
{"type":"session","version":3,"id":"01JYX7","timestamp":"2026-04-12T21:07:44.781Z","cwd":"/Users/depoll/Code/MonkeySSH"}
''');

      expect(header.valid, isTrue);
      expect(header.sessionId, '01JYX7');
      expect(header.workingDirectory, '/Users/depoll/Code/MonkeySSH');
      expect(header.createdAt, DateTime.parse('2026-04-12T21:07:44.781Z'));
    });

    test('ignores every record after the first line', () {
      final header = parsePiSessionHeader('''
{"type":"session","id":"01JYX7","cwd":"/Users/depoll/Code/MonkeySSH"}
{"type":"session","id":"WRONG","cwd":"/tmp/wrong"}
{"type":"message","message":{"role":"user","content":"private prompt"}}
''');

      expect(header.valid, isTrue);
      expect(header.sessionId, '01JYX7');
      expect(header.workingDirectory, '/Users/depoll/Code/MonkeySSH');
    });

    test('rejects malformed, non-session, and incomplete first records', () {
      expect(parsePiSessionHeader('not json').valid, isFalse);
      expect(
        parsePiSessionHeader('{"type":"message","id":"x"}').valid,
        isFalse,
      );
      expect(
        parsePiSessionHeader('{"type":"session","id":"x"}').valid,
        isFalse,
      );
    });
  });

  group('parsePiSessionLabelOutput', () {
    test('decodes and normalizes identifiable labels', () {
      const firstPath = '/tmp/first.jsonl';
      const secondPath = '/tmp/second.jsonl';
      final output =
          '$firstPath\x1f${base64Encode(utf8.encode('Named session'))}\n'
          '$secondPath\x1f${base64Encode(utf8.encode('  First user\nrequest  '))}\n';

      expect(parsePiSessionLabelOutput(output), {
        firstPath: 'Named session',
        secondPath: 'First user request',
      });
    });

    test('skips malformed records without dropping valid labels', () {
      const path = '/tmp/valid.jsonl';
      final output =
          'missing-separator\n'
          '/tmp/broken.jsonl\x1fnot-base64!\n'
          '$path\x1f${base64Encode(utf8.encode('Useful prompt'))}\n';

      expect(parsePiSessionLabelOutput(output), {path: 'Useful prompt'});
    });
  });

  group('piEncodedSessionDirectoryName', () {
    test('matches the bucket Pi stores sessions for a directory in', () {
      expect(
        piEncodedSessionDirectoryName('/Users/depoll/Code/MonkeySSH'),
        '--Users-depoll-Code-MonkeySSH--',
      );
    });

    test('ignores a trailing slash so scoping still matches', () {
      expect(
        piEncodedSessionDirectoryName('/Users/depoll/Code/MonkeySSH/'),
        piEncodedSessionDirectoryName('/Users/depoll/Code/MonkeySSH'),
      );
    });

    test('returns null when there is no directory to encode', () {
      expect(piEncodedSessionDirectoryName(null), isNull);
      expect(piEncodedSessionDirectoryName('  '), isNull);
    });
  });

  group('discoveredSessionMatchesScope', () {
    const info = ToolSessionInfo(
      toolName: 'Pi',
      sessionId: 'a',
      workingDirectory: '/home/dev/worktree',
      originWorkingDirectory: '/home/dev/project',
    );

    test('matches the directory a session was relocated out of', () {
      expect(discoveredSessionMatchesScope(info, '/home/dev/project'), isTrue);
    });

    test('matches the directory a session currently records', () {
      expect(discoveredSessionMatchesScope(info, '/home/dev/worktree'), isTrue);
    });

    test('rejects an unrelated directory', () {
      expect(discoveredSessionMatchesScope(info, '/home/dev/other'), isFalse);
    });
  });

  group('parseHermesDbOutput', () {
    test('maps separated columns onto session metadata', () {
      final sessions = parseHermesDbOutput(
        '${<String>['20250305_091523_a1b2c3', 'Refactor auth', '/Users/depoll/Code/flutty', '1783405351'].join('\x1f')}\n',
      );

      expect(sessions, hasLength(1));
      expect(sessions.single.toolName, 'Hermes');
      expect(sessions.single.sessionId, '20250305_091523_a1b2c3');
      expect(sessions.single.summary, 'Refactor auth');
      expect(sessions.single.workingDirectory, '/Users/depoll/Code/flutty');
      expect(
        sessions.single.lastActive,
        DateTime.fromMillisecondsSinceEpoch(1783405351000),
      );
    });

    test('tolerates empty titles, cwd, and timestamps', () {
      final sessions = parseHermesDbOutput(
        '20250305_091523_a1b2c3\x1f\x1f\x1f0\n\n',
      );

      expect(sessions, hasLength(1));
      expect(sessions.single.workingDirectory, isNull);
      expect(sessions.single.lastActive, isNull);
      expect(sessions.single.summary, isNotEmpty);
    });

    test('skips malformed rows without an id', () {
      final sessions = parseHermesDbOutput('\x1fno id\x1f/tmp\x1f1\nbroken\n');

      expect(sessions, isEmpty);
    });
  });

  group('parseCursorSessionMetadata', () {
    test('uses title, cwd, and updatedAtMs epoch milliseconds', () {
      final metadata = parseCursorSessionMetadata('''
{
  "schemaVersion": 1,
  "createdAtMs": 1783404550969,
  "hasConversation": true,
  "title": "Copilot Theming Fix",
  "updatedAtMs": 1783405351095,
  "cwd": "/Users/depoll/Code/flutty"
}
''');

      expect(metadata.parsedAny, isTrue);
      expect(metadata.summary, 'Copilot Theming Fix');
      expect(metadata.workingDirectory, '/Users/depoll/Code/flutty');
      expect(metadata.hasConversation, isTrue);
      expect(
        metadata.updatedAt,
        DateTime.fromMillisecondsSinceEpoch(1783405351095),
      );
    });

    test('falls back to createdAtMs when updatedAtMs is absent', () {
      final metadata = parseCursorSessionMetadata('''
{
  "createdAtMs": 1783404550969,
  "title": "New chat",
  "cwd": "/tmp/project"
}
''');

      expect(metadata.parsedAny, isTrue);
      expect(
        metadata.updatedAt,
        DateTime.fromMillisecondsSinceEpoch(1783404550969),
      );
    });

    test('marks empty chats as not having a conversation', () {
      final metadata = parseCursorSessionMetadata('''
{
  "title": "Empty",
  "hasConversation": false,
  "cwd": "/tmp/project"
}
''');

      expect(metadata.hasConversation, isFalse);
    });

    test('defaults hasConversation to true and parsedAny false on garbage', () {
      final metadata = parseCursorSessionMetadata('not json');
      expect(metadata.parsedAny, isFalse);
      expect(metadata.hasConversation, isTrue);
    });
  });

  group('parseOpenCodeStorageSessionMetadata', () {
    test('maps JSON storage sessions to unified metadata', () {
      final metadata = parseOpenCodeStorageSessionMetadata(r'''
{
  "id": "ses_123",
  "directory": "C:\\Users\\demo\\repo",
  "title": "Fix Windows discovery",
  "time": {"updated": 1770000000000}
}
''');

      expect(metadata.parsedAny, isTrue);
      expect(metadata.sessionId, 'ses_123');
      expect(metadata.workingDirectory, r'C:\Users\demo\repo');
      expect(metadata.summary, 'Fix Windows discovery');
      expect(
        metadata.updatedAt,
        DateTime.fromMillisecondsSinceEpoch(1770000000000),
      );
      expect(metadata.parentId, isNull);
      expect(metadata.isArchived, isFalse);
    });

    test('identifies archived child sessions', () {
      final metadata = parseOpenCodeStorageSessionMetadata('''
{
  "id": "child",
  "parentID": "parent",
  "time": {"archived": 1770000000000}
}
''');

      expect(metadata.parentId, 'parent');
      expect(metadata.isArchived, isTrue);
    });
  });

  group('discoverSessionsStream caching', () {
    test('discovers sessions via PowerShell on Windows remotes', () async {
      final client = _MockSshClient();
      when(
        () => client.remoteVersion,
      ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');

      final issuedScripts = <String>[];
      _stubDiscoveryExec(client, (command) async {
        final script = decodeEncodedPowerShell(command);
        issuedScripts.add(script);
        // Copilot workspace listing.
        if (script.contains('.copilot/session-state') &&
            !script.contains('[char]0x1f')) {
          return _buildExecSession(
            stdout:
                'C:/Users/demo/.copilot/session-state/newer/workspace.yaml\n'
                'C:/Users/demo/.copilot/session-state/abc/workspace.yaml\n',
          );
        }
        // Snapshot read of the workspace.yaml.
        if (script.contains('[char]0x1f') &&
            script.contains('workspace.yaml')) {
          return _buildExecSession(
            stdout:
                _remoteSnapshotLine(
                  'C:/Users/demo/.copilot/session-state/newer/workspace.yaml',
                  'id: newer\ncwd: C:\\other\nsummary: Other project\n'
                      'updated_at: 2026-07-06T00:00:00Z\n',
                  mtime: 1780000001,
                ) +
                _remoteSnapshotLine(
                  'C:/Users/demo/.copilot/session-state/abc/workspace.yaml',
                  'id: abc\ncwd: C:\\proj\nsummary: My session\n'
                      'updated_at: 2026-07-05T00:00:00Z\n',
                  mtime: 1780000000,
                ),
          );
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);
      final results = await discovery
          .discoverSessionsStream(
            session,
            workingDirectory: r'C:\proj',
            maxPerTool: 1,
          )
          .toList();
      final result = results.last;
      final preview = results.firstWhere(
        (result) =>
            result.attemptedTools.length == 1 &&
            result.attemptedTools.contains('Copilot CLI'),
      );
      expect(preview.sessions.single.sessionId, 'abc');
      final finalOnly = await AgentSessionDiscoveryService()
          .discoverSessionsStream(
            session,
            workingDirectory: r'C:\proj',
            maxPerTool: 1,
            toolName: 'Copilot CLI',
          )
          .last;
      expect(finalOnly.sessions.single.sessionId, 'abc');

      // Every issued command is a PowerShell EncodedCommand, never POSIX.
      final commands = verify(
        () => client.execute(captureAny()),
      ).captured.cast<String>();
      expect(commands, isNotEmpty);
      expect(
        commands.every((command) => command.contains('-EncodedCommand ')),
        isTrue,
      );
      expect(
        issuedScripts.any((script) => script.contains('Get-ChildItem')),
        isTrue,
      );
      final copilot = result.sessions.where(
        (info) => info.toolName == 'Copilot CLI',
      );
      expect(copilot, isNotEmpty);
      expect(copilot.first.summary, 'My session');
    });

    test(
      'OpenCode discovery reads Windows JSON storage without sqlite3',
      () async {
        final client = _MockSshClient();
        when(
          () => client.remoteVersion,
        ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');

        const storagePath =
            'C:/Users/demo/.local/share/opencode/storage/session/project/'
            'ses_123.json';
        final sessionJson = jsonEncode({
          'id': 'ses_123',
          'directory': r'C:\Users\demo\repo',
          'title': 'Review Windows discovery',
          'time': {'updated': 1770000000000},
        });

        _stubDiscoveryExec(client, (command) async {
          final script = decodeEncodedPowerShell(command);
          if (script.contains('opencode session list --format json')) {
            return _buildExecSession();
          }
          if (script.contains('.local/share/opencode/storage/session') &&
              !script.contains('[char]0x1f')) {
            return _buildExecSession(stdout: '$storagePath\n');
          }
          if (script.contains('[char]0x1f') && script.contains(storagePath)) {
            return _buildExecSession(
              stdout: _remoteSnapshotLine(storagePath, sessionJson, mtime: 1),
            );
          }
          return _buildExecSession();
        });

        final discovery = AgentSessionDiscoveryService();
        final session = _buildDiscoverySession(client);
        final result = await discovery
            .discoverSessionsStream(
              session,
              workingDirectory: r'C:\Users\demo\repo',
              toolName: 'OpenCode',
            )
            .last;

        expect(result.sessions, hasLength(1));
        expect(result.sessions.single.toolName, 'OpenCode');
        expect(result.sessions.single.sessionId, 'ses_123');
        expect(result.sessions.single.summary, 'Review Windows discovery');
        expect(result.sessions.single.workingDirectory, r'C:\Users\demo\repo');
        expect(
          verify(() => client.execute(captureAny())).captured.cast<String>(),
          everyElement(contains('-EncodedCommand ')),
        );
      },
    );

    test('Antigravity discovery reads Windows JSON sessions', () async {
      final client = _MockSshClient();
      when(
        () => client.remoteVersion,
      ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');

      const antigravityPath = 'C:/Users/demo/.antigravity/sessions/ag-123.json';
      final sessionJson = jsonEncode({
        'id': 'ag-123',
        'summary': 'Review Antigravity history',
        'workingDirectory': r'C:\Users\demo\repo',
        'updatedAt': '2026-07-05T20:15:00.000Z',
      });

      _stubDiscoveryExec(client, (command) async {
        final script = decodeEncodedPowerShell(command);
        if (script.contains('.antigravity/sessions') &&
            !script.contains('[char]0x1f')) {
          return _buildExecSession(stdout: '$antigravityPath\n');
        }
        if (script.contains('[char]0x1f') && script.contains(antigravityPath)) {
          return _buildExecSession(
            stdout: _remoteSnapshotLine(antigravityPath, sessionJson, mtime: 1),
          );
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);
      final result = await discovery
          .discoverSessionsStream(
            session,
            workingDirectory: r'C:\Users\demo\repo',
            toolName: 'Antigravity',
          )
          .last;

      expect(result.sessions, hasLength(1));
      expect(result.sessions.single.toolName, 'Antigravity');
      expect(result.sessions.single.sessionId, 'ag-123');
      expect(result.sessions.single.summary, 'Review Antigravity history');
      expect(result.sessions.single.workingDirectory, r'C:\Users\demo\repo');
    });

    test('Copilot discovery uses ACP session/list when available', () async {
      final client = _MockSshClient();
      final commands = <String>[];
      final requestedCwds = <String?>[];
      _stubDiscoveryExec(client, (command) async {
        commands.add(command);
        if (command.contains('worktree list --porcelain')) {
          return _buildExecSession(
            stdout: '''
root=/Users/depoll/Code/flutty
worktree /Users/depoll/Code/flutty
HEAD afdab6c
branch refs/heads/main

worktree /Users/depoll/Code/flutty.worktrees/feature
HEAD 1234567
branch refs/heads/feature
''',
          );
        }
        if (command.contains('copilot --acp')) {
          return _buildAcpSessionListExecSession(
            requestedCwds: requestedCwds,
            sessions: const [
              {
                'sessionId': '12345678-1234-1234-1234-1234567890ab',
                'cwd': '/Users/depoll/Code/flutty',
                'title': 'Fix tmux ACP discovery',
                'updatedAt': '2026-05-04T05:48:19.955Z',
              },
            ],
          );
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);
      final result = await discovery
          .discoverSessionsStream(
            session,
            workingDirectory: '/Users/depoll/Code/flutty',
            toolName: 'Copilot CLI',
          )
          .last;

      expect(result.sessions, hasLength(1));
      expect(result.sessions.single.toolName, 'Copilot CLI');
      expect(
        result.sessions.single.sessionId,
        '12345678-1234-1234-1234-1234567890ab',
      );
      expect(result.sessions.single.summary, 'Fix tmux ACP discovery');
      expect(
        requestedCwds.toSet(),
        containsAll(<String>{
          '/Users/depoll/Code/flutty',
          '/Users/depoll/Code/flutty.worktrees/feature',
        }),
      );
      expect(
        commands.where((command) => command.contains('copilot --acp')),
        hasLength(1),
      );
      expect(
        commands.where((command) => command.contains('workspace.yaml')),
        isEmpty,
      );
    });

    test(
      'ACP discovery preserves earlier pages when a later page is malformed',
      () async {
        final client = _MockSshClient();
        final commands = <String>[];
        _stubDiscoveryExec(client, (command) async {
          commands.add(command);
          if (command.contains('worktree list --porcelain')) {
            return _buildExecSession(
              stdout: '''
root=/Users/depoll/Code/flutty
worktree /Users/depoll/Code/flutty
HEAD afdab6c
branch refs/heads/main
''',
            );
          }
          if (command.contains('copilot --acp')) {
            return _buildAcpSessionListExecSession(
              sessions: const [
                {
                  'sessionId': '12345678-1234-1234-1234-1234567890ab',
                  'cwd': '/Users/depoll/Code/flutty',
                  'title': 'Preserve partial ACP discovery',
                  'updatedAt': '2026-05-04T05:48:19.955Z',
                },
              ],
              malformedSecondPage: true,
            );
          }
          return _buildExecSession();
        });

        final discovery = AgentSessionDiscoveryService();
        final result = await discovery
            .discoverSessionsStream(
              _buildDiscoverySession(client),
              workingDirectory: '/Users/depoll/Code/flutty',
              toolName: 'Copilot CLI',
            )
            .last;

        expect(result.sessions, hasLength(1));
        expect(
          result.sessions.single.summary,
          'Preserve partial ACP discovery',
        );
        expect(
          commands.where((command) => command.contains('workspace.yaml')),
          isEmpty,
        );
      },
    );

    test(
      'ACP discovery preserves sessions and stops repeated cursors per directory',
      () async {
        final client = _MockSshClient();
        final commands = <String>[];
        final requestedCwds = <String?>[];
        _stubDiscoveryExec(client, (command) async {
          commands.add(command);
          if (command.contains('worktree list --porcelain')) {
            return _buildExecSession(
              stdout: '''
root=/Users/depoll/Code/flutty
worktree /Users/depoll/Code/flutty
worktree /Users/depoll/Code/flutty.worktrees/feature
HEAD afdab6c
branch refs/heads/main
''',
            );
          }
          if (command.contains('copilot --acp')) {
            return _buildAcpSessionListExecSession(
              sessions: const [
                {
                  'sessionId': '12345678-1234-1234-1234-1234567890ab',
                  'cwd': '/Users/depoll/Code/flutty',
                  'title': 'Preserve partial ACP discovery',
                  'updatedAt': '2026-05-04T05:48:19.955Z',
                },
              ],
              repeatedCursor: true,
              requestedCwds: requestedCwds,
            );
          }
          return _buildExecSession();
        });

        final discovery = AgentSessionDiscoveryService();
        final result = await discovery
            .discoverSessionsStream(
              _buildDiscoverySession(client),
              workingDirectory: '/Users/depoll/Code/flutty',
              toolName: 'Copilot CLI',
            )
            .last;

        expect(result.sessions, hasLength(1));
        expect(result.failedTools, isEmpty);
        expect(requestedCwds, [
          '/Users/depoll/Code/flutty',
          '/Users/depoll/Code/flutty',
          '/Users/depoll/Code/flutty.worktrees/feature',
          '/Users/depoll/Code/flutty.worktrees/feature',
        ]);
        expect(
          result.sessions.single.workingDirectory,
          '/Users/depoll/Code/flutty',
        );
        expect(
          result.sessions.single.lastActive,
          DateTime.parse('2026-05-04T05:48:19.955Z'),
        );
        expect(
          result.sessions.single.summary,
          'Preserve partial ACP discovery',
        );
        expect(
          commands.where((command) => command.contains('workspace.yaml')),
          isEmpty,
        );
      },
    );

    test('OpenCode discovery uses ACP session/list when available', () async {
      final client = _MockSshClient();
      final commands = <String>[];
      _stubDiscoveryExec(client, (command) async {
        commands.add(command);
        if (command.contains('worktree list --porcelain')) {
          return _buildExecSession(
            stdout: '''
root=/Users/depoll/Code/flutty
worktree /Users/depoll/Code/flutty
HEAD afdab6c
branch refs/heads/main
''',
          );
        }
        if (command.contains('opencode acp')) {
          return _buildAcpSessionListExecSession(
            sessions: const [
              {
                'sessionId': 'ses_123',
                'cwd': '/Users/depoll/Code/flutty',
                'title': 'Review tmux panel',
                'updatedAt': '2026-05-04T05:48:19.955Z',
              },
            ],
          );
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);
      final result = await discovery
          .discoverSessionsStream(
            session,
            workingDirectory: '/Users/depoll/Code/flutty',
            toolName: 'OpenCode',
          )
          .last;

      expect(result.sessions, hasLength(1));
      expect(result.sessions.single.toolName, 'OpenCode');
      expect(result.sessions.single.sessionId, 'ses_123');
      expect(result.sessions.single.summary, 'Review tmux panel');
      expect(
        commands.where((command) => command.contains('opencode acp')),
        hasLength(1),
      );
      expect(
        commands.where(
          (command) => command.contains('opencode session list --format json'),
        ),
        isEmpty,
      );
    });

    for (final windows in [false, true]) {
      test('Antigravity snapshots preserve metadata precedence on '
          '${windows ? 'Windows' : 'POSIX'}', () async {
        final client = _MockSshClient();
        if (windows) {
          when(
            () => client.remoteVersion,
          ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');
        }
        final home = windows ? 'C:/Users/demo' : '/Users/demo';
        final cwd = windows ? r'C:\audit\My Project' : '/audit/My Project';
        final uri = windows
            ? 'file:///C:/audit/My%20Project'
            : 'file:///audit/My%20Project';
        final root = '$home/.gemini/antigravity-cli';
        final jsonPaths = [
          "$home/.antigravity/sessions/encoded 'path.json",
          '$home/.agy/sessions/broken.json',
          '${windows ? home : '.'}/.antigravitycli/legacy.json',
          '${windows ? home : '.'}/.agycli/partial.json',
        ];
        final conversations = [
          '$root/conversations/encoded.pb',
          '$root/conversations/history.pb',
          '$root/implicit/history.pb',
          '$root/implicit/annotation.pb',
          '$root/conversations/fallback.pb',
          '$root/conversations/contextless.pb',
        ];
        final contents = {
          jsonPaths[0]: jsonEncode({
            'id': 'encoded',
            'summary': 'JSON wins',
            'projectResources': {
              'resources': [
                {
                  'gitFolder': {'folderUri': uri},
                },
              ],
            },
            'updatedAt': '2026-07-05T20:15:00Z',
          }),
          jsonPaths[1]: 'not JSON',
          jsonPaths[2]: '{"id":"legacy","summary":"Legacy root"}',
          jsonPaths[3]: '{"id":"partial","summary":"Truncated JSON",',
          '$root/annotations/encoded.pbtxt': 'title: "Ignored annotation"',
          '$root/annotations/history.pbtxt': 'title: "Old annotation"',
          '$root/annotations/annotation.pbtxt': r'title: "Quoted \"title\""',
          for (final path in conversations) path: '',
        };
        final commands = <String>[];
        _stubDecodedDiscoveryExec(client, (command) async {
          commands.add(command);
          if (command.contains('[char]0x1f') || command.contains('SEP=')) {
            return _buildExecSession(
              stdout: contents.entries
                  .where(
                    (entry) => command.contains(
                      entry.key.replaceAll("'", windows ? "''" : r"'\''"),
                    ),
                  )
                  .map(
                    (entry) => _remoteSnapshotLine(
                      entry.key,
                      entry.value,
                      mtime: 1700000000,
                    ),
                  )
                  .join(),
            );
          }
          if (command.contains('.antigravity/sessions')) {
            return _buildExecSession(stdout: jsonPaths.join('\n'));
          }
          if (command.contains('history.jsonl')) {
            return _buildExecSession(
              stdout: [
                jsonEncode({
                  'conversationId': 'history',
                  'display': 'Old history',
                }),
                'malformed history',
                jsonEncode({
                  'conversationId': 'history',
                  'display': 'Newest history',
                  'workspace': cwd,
                  'timestamp': 1780000000000,
                }),
                jsonEncode({
                  'conversationId': 'encoded',
                  'display': 'Ignored history',
                }),
                jsonEncode({'conversationId': 'fallback', 'workspace': cwd}),
              ].join('\n'),
            );
          }
          if (command.contains('antigravity-cli')) {
            return _buildExecSession(stdout: conversations.join('\n'));
          }
          return _buildExecSession();
        });
        final session = _buildDiscoverySession(client);
        final discovery = AgentSessionDiscoveryService();
        final result = await discovery
            .discoverSessionsStream(
              session,
              toolName: 'Antigravity',
              maxPerTool: 20,
            )
            .last;
        final byId = {for (final info in result.sessions) info.sessionId: info};
        expect(
          byId.keys,
          unorderedEquals([
            'encoded',
            'legacy',
            'partial',
            'history',
            'annotation',
            'fallback',
          ]),
        );
        expect(byId['encoded']!.workingDirectory, cwd);
        expect(byId['encoded']!.summary, 'JSON wins');
        expect(
          byId['encoded']!.lastActive,
          DateTime.parse('2026-07-05T20:15:00Z'),
        );
        expect(byId['history']!.summary, 'Newest history');
        expect(
          byId['history']!.lastActive,
          DateTime.fromMillisecondsSinceEpoch(1780000000000),
        );
        expect(byId['annotation']!.summary, 'Quoted "title"');
        expect(byId['fallback']!.summary, 'My Project');
        expect(byId['fallback']!.workingDirectory, cwd);
        expect(
          byId['fallback']!.lastActive,
          DateTime.fromMillisecondsSinceEpoch(1700000000000),
        );
        final scoped = await discovery
            .discoverSessionsStream(
              session,
              workingDirectory: cwd,
              toolName: 'Antigravity',
              maxPerTool: 1,
            )
            .last;
        expect(scoped.sessions.single.sessionId, 'encoded');
        expect(scoped.sessions.single.workingDirectory, cwd);
        if (!windows) {
          expect(commands, anyElement(contains('./.antigravitycli ./.agycli')));
          expect(commands, anyElement(contains('~/.agy/sessions')));
          expect(commands, isNot(anyElement(contains('python3 -c'))));
        }
      });

      for (final previewOnly in [true, false]) {
        test(
          'Antigravity ${previewOnly ? 'preview' : 'final'} bounds snapshot reads on '
          '${windows ? 'Windows' : 'POSIX'}',
          () async {
            final readLimit = previewOnly ? 6 : 24;
            final scanLimit = previewOnly ? 24 : 60;
            final client = _MockSshClient();
            if (windows) {
              when(
                () => client.remoteVersion,
              ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');
            }
            final home = windows ? 'C:/Users/demo' : '/Users/demo';
            final jsonPaths = List.generate(
              32,
              (i) => '$home/.antigravity/sessions/json-$i.json',
            );
            final conversationPaths = List.generate(
              32,
              (i) => '$home/.gemini/antigravity-cli/conversations/conv-$i.pb',
            );
            final commands = <String>[];
            _stubDecodedDiscoveryExec(client, (command) async {
              commands.add(command);
              if (command.contains('[char]0x1f') || command.contains('SEP=')) {
                return _buildExecSession(
                  stdout: [
                    for (var i = 0; i < jsonPaths.length; i++)
                      if (command.contains(jsonPaths[i]))
                        _remoteSnapshotLine(
                          jsonPaths[i],
                          '{"id":"json-$i","summary":"Session $i"}',
                          mtime: i,
                        ),
                    for (final path in conversationPaths)
                      if (command.contains(path))
                        _remoteSnapshotLine(path, '', mtime: 1),
                  ].join(),
                );
              }
              if (command.contains('.antigravity/sessions')) {
                expect(
                  command,
                  contains(
                    windows
                        ? 'Select-Object -First $scanLimit'
                        : 'head -n $scanLimit',
                  ),
                );
                return _buildExecSession(stdout: jsonPaths.join('\n'));
              }
              if (command.contains('history.jsonl')) {
                expect(
                  command,
                  contains(
                    windows
                        ? '-Tail ${scanLimit * 5}'
                        : 'tail -n ${scanLimit * 5}',
                  ),
                );
              } else if (command.contains('antigravity-cli')) {
                return _buildExecSession(stdout: conversationPaths.join('\n'));
              }
              return _buildExecSession();
            });
            final results = await AgentSessionDiscoveryService()
                .discoverSessionsStream(
                  _buildDiscoverySession(client),
                  maxPerTool: 1,
                  toolName: previewOnly ? null : 'Antigravity',
                )
                .toList();
            expect(
              results.last.sessions
                  .where((s) => s.toolName == 'Antigravity')
                  .single
                  .sessionId,
              'json-${readLimit - 1}',
            );
            final snapshots = commands
                .where(
                  (command) =>
                      command.contains('[char]0x1f') ||
                      command.contains('SEP='),
                )
                .join('\n');
            expect(
              snapshots,
              contains(windows ? 'byte[] 65536' : r'$HEAD_BIN -c 65536'),
            );
            expect(snapshots, contains(windows ? '-TotalCount 20' : "'1,20p'"));
            expect(
              snapshots,
              contains(windows ? 'byte[] 0' : r'$HEAD_BIN -c 0'),
            );
            expect(snapshots, contains('json-${readLimit - 1}.json'));
            expect(snapshots, contains('conv-${readLimit - 1}.pb'));
            expect(snapshots, isNot(contains('json-$readLimit.json')));
            expect(snapshots, isNot(contains('conv-$readLimit.pb')));
            expect(snapshots, isNot(contains('conv-$readLimit.pbtxt')));
          },
        );
      }
    }

    test(
      'all-provider discovery skips ACP probes for fast panel loads',
      () async {
        final client = _MockSshClient();
        final commands = <String>[];
        _stubDiscoveryExec(client, (command) async {
          commands.add(command);
          if (command.contains('worktree list --porcelain')) {
            return _buildExecSession(
              stdout: '''
root=/Users/depoll/Code/flutty
worktree /Users/depoll/Code/flutty
HEAD afdab6c
branch refs/heads/main
''',
            );
          }
          if (command.contains('~/.local/share/opencode/opencode.db')) {
            return _buildExecSession(
              stdout:
                  'session-1\x1fOpenCode fast path\x1f/Users/depoll/Code/flutty\x1f1770000000\n',
            );
          }
          return _buildExecSession();
        });

        final discovery = AgentSessionDiscoveryService();
        final session = _buildDiscoverySession(client);
        final result = await discovery
            .discoverSessionsStream(
              session,
              workingDirectory: '/Users/depoll/Code/flutty',
            )
            .last;

        expect(
          result.sessions.map((session) => session.toolName),
          contains('OpenCode'),
        );
        expect(commands.where((command) => command.contains(' acp')), isEmpty);
        expect(
          commands.where(
            (command) =>
                command.contains('~/.local/share/opencode/opencode.db'),
          ),
          isNotEmpty,
        );
      },
    );

    test(
      'MonkeyMux discovery uses control-channel commands and skips ACP exec',
      () async {
        final client = _MockSshClient();
        final backendService = _MockTerminalConnectionBackendService();
        final backend = _MockTerminalConnectionBackend();
        final commands = <String>[];
        final session = _buildDiscoverySession(client)
          ..remoteMuxBackend = RemoteMuxBackend.monkeyMux
          ..remoteMuxSessionName = 'dev';

        when(() => backendService.resolve(session)).thenReturn(backend);
        when(() => backend.capabilities).thenReturn(
          const TerminalBackendCapabilities(
            supportsWindows: true,
            supportsClientCommands: true,
            clientCommandsUseControlChannel: true,
          ),
        );
        when(
          () =>
              backend.runClientCommand(any(), priority: any(named: 'priority')),
        ).thenAnswer((invocation) async {
          final command = invocation.positionalArguments.first as String;
          commands.add(command);
          final output = command.contains('~/.local/share/opencode/opencode.db')
              ? 'session-1\x1fOpenCode mmux\x1f/Users/depoll/Code/flutty\x1f1770000000\n'
              : '';
          return TerminalClientCommandResult(
            output: _markedDiscoveryOutput(output),
            exitCode: 0,
          );
        });

        final discovery = AgentSessionDiscoveryService(
          terminalBackendService: backendService,
        );
        final result = await discovery
            .discoverSessionsStream(
              session,
              workingDirectory: '/Users/depoll/Code/flutty',
              toolName: 'OpenCode',
            )
            .last;

        expect(result.sessions.map((session) => session.sessionId), [
          'session-1',
        ]);
        expect(
          commands.where((command) => command.contains('opencode acp')),
          isEmpty,
        );
        expect(
          commands.where(
            (command) =>
                command.contains('~/.local/share/opencode/opencode.db'),
          ),
          hasLength(1),
        );
        verifyNever(() => client.execute(any()));
      },
    );

    test('Pi expands a tilde scope before MonkeyMux bucket lookup', () async {
      final client = _MockSshClient();
      final backendService = _MockTerminalConnectionBackendService();
      final backend = _MockTerminalConnectionBackend();
      final commands = <String>[];
      final session = _buildDiscoverySession(client)
        ..remoteMuxBackend = RemoteMuxBackend.monkeyMux
        ..remoteMuxSessionName = 'MonkeySSH';
      const sessionPath =
          '/Users/depoll/.pi/agent/sessions/'
          '--Users-depoll-Code-MonkeySSH--/'
          '2026-08-21T08-10-51-425Z_REAL.jsonl';

      when(() => backendService.resolve(session)).thenReturn(backend);
      when(() => backend.capabilities).thenReturn(
        const TerminalBackendCapabilities(
          supportsWindows: true,
          supportsClientCommands: true,
          clientCommandsUseControlChannel: true,
        ),
      );
      when(
        () => backend.runClientCommand(any(), priority: any(named: 'priority')),
      ).thenAnswer((invocation) async {
        final command = invocation.positionalArguments.first as String;
        commands.add(command);
        var output = '';
        if (command.contains('__monkeyssh_agent_discovery_home__:')) {
          output = '__monkeyssh_agent_discovery_home__:/Users/depoll\n';
        } else if (command.contains('worktree list --porcelain')) {
          output = '''
root=/Users/depoll/Code/MonkeySSH
worktree /Users/depoll/Code/MonkeySSH
HEAD abc123
branch refs/heads/main
''';
        } else if (command.contains(r"$SED_BIN -n '1,1p'") &&
            command.contains(sessionPath)) {
          output = _remoteSnapshotLine(sessionPath, '''
{"type":"session","id":"REAL","timestamp":"2026-08-21T08:12:27.194Z","cwd":"/Users/depoll/Code/MonkeySSH"}
''', mtime: 1787300289);
        } else if (command.contains('Buffer.from(process.argv[1]') &&
            command.contains(sessionPath)) {
          output =
              '$sessionPath\x1f${base64Encode(utf8.encode('Fix recent Pi session discovery'))}\n';
        } else if (command.contains('--Users-depoll-Code-MonkeySSH--')) {
          output = sessionPath;
        }
        return TerminalClientCommandResult(
          output: _markedDiscoveryOutput(output),
          exitCode: 0,
        );
      });

      final result =
          await AgentSessionDiscoveryService(
                terminalBackendService: backendService,
              )
              .discoverSessionsStream(
                session,
                workingDirectory: '~/Code/MonkeySSH',
                toolName: 'Pi',
              )
              .last;

      expect(result.sessions.map((info) => info.sessionId), ['REAL']);
      expect(result.sessions.single.summary, 'Fix recent Pi session discovery');
      expect(
        commands,
        anyElement(contains("git -C '/Users/depoll/Code/MonkeySSH'")),
      );
      expect(commands, anyElement(contains('--Users-depoll-Code-MonkeySSH--')));
      expect(commands, isNot(anyElement(contains('--~-Code-MonkeySSH--'))));
      verifyNever(() => client.execute(any()));
    });

    test(
      'all-provider stream emits lightweight previews before final aggregate',
      () async {
        final client = _MockSshClient();
        final commands = <String>[];
        _stubDiscoveryExec(client, (command) async {
          commands.add(command);
          if (command.contains('~/.local/share/opencode/opencode.db')) {
            return _buildExecSession(
              stdout: List<String>.generate(
                4,
                (index) =>
                    'session-$index\x1fOpenCode $index\x1f/Users/demo/project\x1f${1770000000 - index}',
              ).join('\n'),
            );
          }
          return _buildExecSession();
        });

        final discovery = AgentSessionDiscoveryService();
        final session = _buildDiscoverySession(client);

        final results = await discovery
            .discoverSessionsStream(session, maxPerTool: 2)
            .toList();

        expect(results, hasLength(greaterThan(1)));
        expect(
          results.take(results.length - 1),
          everyElement(
            isA<DiscoveredSessionsResult>()
                .having(
                  (result) => result.attemptedTools,
                  'attemptedTools',
                  hasLength(1),
                )
                .having(
                  (result) => result.sessions,
                  'sessions',
                  hasLength(lessThanOrEqualTo(1)),
                ),
          ),
        );
        expect(results.last.attemptedTools, contains('OpenCode'));
        expect(results.last.sessions.map((session) => session.sessionId), [
          'session-0',
        ]);
        expect(
          commands.where((command) => command.contains('LIMIT 12;')),
          isNotEmpty,
        );
      },
    );

    test('parses large remote snapshots off the UI isolate', () async {
      final client = _MockSshClient();
      const metaPath =
          '/Users/demo/.cursor/chats/workspace/'
          '0d8d2b7c-6f1e-4d0f-9c1a-2b3c4d5e6f70/meta.json';
      final largeMetaJson = jsonEncode({
        'schemaVersion': 1,
        'createdAtMs': 1783404550969,
        'hasConversation': true,
        'title': 'Large Cursor session',
        'updatedAtMs': 1783405351095,
        'cwd': '/Users/depoll/Code/flutty',
        'padding': List<String>.filled(9000, 'x').join(),
      });

      _stubDiscoveryExec(client, (command) async {
        if (command.contains('find ~/.cursor/chats')) {
          return _buildExecSession(stdout: metaPath);
        }
        if (command.contains(metaPath)) {
          return _buildExecSession(
            stdout: _remoteSnapshotLine(metaPath, largeMetaJson),
          );
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);

      final result = await discovery
          .discoverSessionsStream(session, toolName: 'Cursor Agent')
          .last;

      expect(result.sessions.map((session) => session.sessionId), [
        '0d8d2b7c-6f1e-4d0f-9c1a-2b3c4d5e6f70',
      ]);
      expect(result.sessions.single.summary, 'Large Cursor session');
    });

    test('returns when SSH exec stdout stays open after done marker', () async {
      final client = _MockSshClient();
      const metaPath =
          '/Users/demo/.cursor/chats/workspace/'
          '1e9f3c8d-7a2b-4e1c-8d2b-3c4d5e6f7a81/meta.json';
      final metaJson = jsonEncode({
        'schemaVersion': 1,
        'createdAtMs': 1783404550969,
        'hasConversation': true,
        'title': 'Open stream Cursor session',
        'updatedAtMs': 1783405351095,
        'cwd': '/Users/depoll/Code/flutty',
      });

      _stubDiscoveryExec(client, (command) async {
        if (command.contains('find ~/.cursor/chats')) {
          return _buildOpenMarkerExecSession(stdout: metaPath);
        }
        if (command.contains(metaPath)) {
          return _buildOpenMarkerExecSession(
            stdout: _remoteSnapshotLine(metaPath, metaJson),
          );
        }
        return _buildOpenMarkerExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);

      final result = await discovery
          .discoverSessionsStream(session, toolName: 'Cursor Agent')
          .last
          .timeout(const Duration(seconds: 2));

      expect(result.sessions.map((session) => session.sessionId), [
        '1e9f3c8d-7a2b-4e1c-8d2b-3c4d5e6f7a81',
      ]);
    });

    test('reads split markers and fragmented large discovery output', () async {
      final client = _MockSshClient();
      const metaPath =
          '/Users/demo/.cursor/chats/workspace/'
          '1e9f3c8d-7a2b-4e1c-8d2b-3c4d5e6f7a81/meta.json';
      final metaJson = jsonEncode({
        'schemaVersion': 1,
        'createdAtMs': 1783404550969,
        'hasConversation': true,
        'title': 'Open stream Cursor session',
        'padding': 'x' * 100000,
        'updatedAtMs': 1783405351095,
        'cwd': '/Users/depoll/Code/flutty',
      });

      _stubDiscoveryExec(client, (command) async {
        if (command.contains('find ~/.cursor/chats')) {
          return _buildOpenMarkerExecSession(stdout: metaPath, chunkSize: 1);
        }
        if (command.contains(metaPath)) {
          return _buildOpenMarkerExecSession(
            stdout: _remoteSnapshotLine(metaPath, metaJson),
            chunkSize: 7,
          );
        }
        return _buildOpenMarkerExecSession(chunkSize: 1);
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);

      final result = await discovery
          .discoverSessionsStream(session, toolName: 'Cursor Agent')
          .last
          .timeout(const Duration(seconds: 2));

      expect(result.sessions.single.summary, 'Open stream Cursor session');
      expect(result.sessions.map((session) => session.sessionId), [
        '1e9f3c8d-7a2b-4e1c-8d2b-3c4d5e6f7a81',
      ]);
    });

    test('global discovery never probes Gemini CLI storage', () async {
      final client = _MockSshClient();
      final commands = <String>[];
      _stubDiscoveryExec(client, (command) async {
        commands.add(command);
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);

      final result = await discovery.discoverSessionsStream(session).last;

      expect(commands, isNotEmpty);
      expect(commands, isNot(anyElement(contains('.gemini/tmp'))));
      expect(commands, isNot(anyElement(contains('session-*.json'))));
      expect(commands, isNot(anyElement(contains('gemini --list-sessions'))));
      expect(result.attemptedTools, isNot(contains('Gemini CLI')));
      expect(result.failedTools, isNot(contains('Gemini CLI')));
      expect(
        result.sessions.map((info) => info.toolName),
        isNot(contains('Gemini CLI')),
      );
      // Antigravity storage under ~/.gemini/antigravity-cli must stay probed.
      expect(commands, anyElement(contains('antigravity-cli')));
      expect(result.attemptedTools, contains('Antigravity'));
    });

    test('scoped discovery never probes Gemini CLI storage', () async {
      final client = _MockSshClient();
      final commands = <String>[];
      _stubDiscoveryExec(client, (command) async {
        commands.add(command);
        if (command.contains('worktree list --porcelain')) {
          return _buildExecSession(
            stdout: '''
root=/Users/depoll/Code/flutty
worktree /Users/depoll/Code/flutty
HEAD afdab6c
branch refs/heads/main
''',
          );
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);

      final result = await discovery
          .discoverSessionsStream(
            session,
            workingDirectory: '/Users/depoll/Code/flutty',
          )
          .last;

      expect(commands, isNotEmpty);
      expect(commands, isNot(anyElement(contains('.gemini/tmp'))));
      expect(commands, isNot(anyElement(contains('session-*.json'))));
      expect(commands, isNot(anyElement(contains('/flutty/chats/'))));
      expect(result.attemptedTools, isNot(contains('Gemini CLI')));
      expect(result.failedTools, isNot(contains('Gemini CLI')));
      expect(
        result.sessions.map((info) => info.toolName),
        isNot(contains('Gemini CLI')),
      );
      expect(commands, anyElement(contains('antigravity-cli')));
      expect(result.attemptedTools, contains('Antigravity'));
    });

    test('requesting the Gemini CLI provider yields no sessions', () async {
      final client = _MockSshClient();
      final commands = <String>[];
      _stubDiscoveryExec(client, (command) async {
        commands.add(command);
        return _buildExecSession();
      });

      final result = await AgentSessionDiscoveryService()
          .discoverSessionsStream(
            _buildDiscoverySession(client),
            toolName: 'Gemini CLI',
          )
          .last;

      expect(result.sessions, isEmpty);
      expect(result.failedTools, isEmpty);
      expect(commands, isNot(anyElement(contains('.gemini'))));
    });

    test(
      'Codex discovery uses resumable UUID instead of rollout filename',
      () async {
        final client = _MockSshClient();
        const rolloutPath =
            '/Users/demo/.codex/sessions/2026/04/26/'
            'rollout-2026-04-26T15-44-01-'
            '019dcbf6-c80e-7c30-b7fa-3d352bda8c4d.jsonl';
        const sessionId = '019dcbf6-c80e-7c30-b7fa-3d352bda8c4d';
        _stubDiscoveryExec(client, (command) async {
          if (command.contains('find ~/.codex/sessions')) {
            return _buildExecSession(stdout: rolloutPath);
          }
          if (command.contains('~/.codex/session_index.jsonl')) {
            return _buildExecSession(
              stdout:
                  '{"id":"$sessionId","thread_name":"Fix tmux titles",'
                  ' "updated_at":"2026-04-26T22:44:35.656609Z"}\n',
            );
          }
          if (command.contains(rolloutPath)) {
            return _buildExecSession(
              stdout: _remoteSnapshotLine(rolloutPath, '''
{"timestamp":"2026-04-26T22:44:20.349Z","type":"session_meta","payload":{"id":"$sessionId","timestamp":"2026-04-26T22:44:01.169Z","cwd":"/Users/depoll/Code/flutty"}}
{"timestamp":"2026-04-26T22:44:48.390Z","type":"event_msg","payload":{"type":"user_message","message":"fix codex resume","images":[]}}
''', mtime: 1777243460),
            );
          }
          return _buildExecSession();
        });

        final discovery = AgentSessionDiscoveryService();
        final session = _buildDiscoverySession(client);
        final result = await discovery
            .discoverSessionsStream(session, toolName: 'Codex')
            .last;

        expect(result.sessions, hasLength(1));
        expect(result.sessions.single.sessionId, sessionId);
        expect(
          discovery.buildResumeCommand(result.sessions.single),
          "cd '/Users/depoll/Code/flutty' && codex resume '$sessionId'",
        );
      },
    );

    test('Cursor discovery resolves chat id, title, and cwd', () async {
      final client = _MockSshClient();
      const metaPath =
          '/Users/demo/.cursor/chats/7fb0188e9fe01ef050275e8289ce9696/'
          'f21ed2df-500d-46a5-b55f-12b64268491f/meta.json';
      const chatId = 'f21ed2df-500d-46a5-b55f-12b64268491f';
      _stubDiscoveryExec(client, (command) async {
        if (command.contains('find ~/.cursor/chats')) {
          return _buildExecSession(stdout: metaPath);
        }
        if (command.contains(metaPath)) {
          return _buildExecSession(
            stdout: _remoteSnapshotLine(metaPath, '''
{"schemaVersion":1,"createdAtMs":1783404550969,"hasConversation":true,"title":"Copilot Theming Fix","updatedAtMs":1783405351095,"cwd":"/Users/depoll/Code/flutty"}
''', mtime: 1777243460),
          );
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);
      final result = await discovery
          .discoverSessionsStream(session, toolName: 'Cursor Agent')
          .last;

      expect(result.sessions, hasLength(1));
      final info = result.sessions.single;
      expect(info.toolName, 'Cursor Agent');
      expect(info.sessionId, chatId);
      expect(info.summary, 'Copilot Theming Fix');
      expect(info.workingDirectory, '/Users/depoll/Code/flutty');
      expect(
        info.lastActive,
        DateTime.fromMillisecondsSinceEpoch(1783405351095),
      );
      expect(
        discovery.buildResumeCommand(info),
        "cd '/Users/depoll/Code/flutty' && cursor-agent --resume '$chatId'",
      );
    });

    test(
      'Cursor discovery keeps current metadata-only chats resumable',
      () async {
        final client = _MockSshClient();
        const metaPath =
            '/Users/demo/.cursor/chats/workspace/'
            'bfc1447e-9184-4dcb-ad28-130dd28177d3/meta.json';
        _stubDiscoveryExec(client, (command) async {
          if (command.contains('find ~/.cursor/chats')) {
            return _buildExecSession(stdout: metaPath);
          }
          if (command.contains(metaPath)) {
            return _buildExecSession(
              stdout: _remoteSnapshotLine(metaPath, '''
{"schemaVersion":1,"createdAtMs":1787302131000,"hasConversation":false,"updatedAtMs":1787302132665,"cwd":"/Users/depoll/Code/MonkeySSH"}
'''),
            );
          }
          return _buildExecSession();
        });

        final result = await AgentSessionDiscoveryService()
            .discoverSessionsStream(
              _buildDiscoverySession(client),
              workingDirectory: '/Users/depoll/Code/MonkeySSH',
              toolName: 'Cursor Agent',
            )
            .last;

        expect(result.sessions, hasLength(1));
        expect(
          result.sessions.single.sessionId,
          'bfc1447e-9184-4dcb-ad28-130dd28177d3',
        );
        expect(result.sessions.single.summary, 'Cursor session bfc1447e…');
      },
    );

    test('Grok Build discovery resolves resumable summary metadata', () async {
      final client = _MockSshClient();
      final commands = <String>[];
      const summaryPath =
          '/Users/demo/.grok/sessions/%2FUsers%2Fdepoll%2FCode%2Fflutty/'
          '019f6cb5-f7e4-7bc1-bb25-9985af59619e/summary.json';
      const sessionId = '019f6cb5-f7e4-7bc1-bb25-9985af59619e';
      _stubDiscoveryExec(client, (command) async {
        commands.add(command);
        if (command.contains('worktree list --porcelain')) {
          return _buildExecSession(
            stdout: '''
root=/Users/depoll/Code/flutty
worktree /Users/depoll/Code/flutty
HEAD a

worktree /Users/depoll/worktrees/feature
HEAD b
''',
          );
        }
        if (command.contains('GROK_SESSIONS_ROOT')) {
          return _buildExecSession(stdout: summaryPath);
        }
        if (command.contains(summaryPath)) {
          return _buildExecSession(
            stdout: _remoteSnapshotLine(summaryPath, '''
{
  "info": {"id": "$sessionId", "cwd": "/Users/depoll/Code/flutty"},
  "session_summary": "Initial Grok task",
  "generated_title": "Add Grok Build support",
  "created_at": "2026-08-14T20:00:00Z",
  "updated_at": "2026-08-14T20:05:00Z",
  "last_active_at": "2026-08-14T20:04:00Z",
  "current_model_id": "grok-code-fast-1",
  "num_messages": 12
}
''', mtime: 1786740000),
          );
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);
      final result = await discovery
          .discoverSessionsStream(
            session,
            workingDirectory: '/Users/depoll/Code/flutty',
            toolName: 'Grok Build',
          )
          .last;

      expect(result.sessions, hasLength(1));
      final info = result.sessions.single;
      expect(info.toolName, 'Grok Build');
      expect(info.sessionId, sessionId);
      expect(info.summary, 'Add Grok Build support');
      expect(info.workingDirectory, '/Users/depoll/Code/flutty');
      expect(info.lastActive, DateTime.parse('2026-08-14T20:04:00Z'));
      final listCommand = commands.firstWhere(
        (command) => command.contains('GROK_SESSIONS_ROOT'),
      );
      expect(listCommand, contains('%2FUsers%2Fdepoll%2FCode%2Fflutty'));
      expect(listCommand, contains('%2FUsers%2Fdepoll%2Fworktrees%2Ffeature'));
      expect(
        discovery.buildResumeCommand(info),
        "cd '/Users/depoll/Code/flutty' && grok --resume '$sessionId'",
      );
      expect(
        discovery.buildResumeCommand(info, startInYoloMode: true),
        "cd '/Users/depoll/Code/flutty' && grok --yolo --resume '$sessionId'",
      );
    });

    test(
      'Grok Build Windows discovery lets GROK_HOME override default',
      () async {
        final client = _MockSshClient();
        when(
          () => client.remoteVersion,
        ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');

        const summaryPath =
            'C:/grok-home/sessions/C%3A%5Cwork%5Crepo/win-session/summary.json';
        final issuedScripts = <String>[];
        _stubDiscoveryExec(client, (command) async {
          final script = decodeEncodedPowerShell(command);
          issuedScripts.add(script);
          if (script.contains('[char]0x1f') && script.contains(summaryPath)) {
            return _buildExecSession(
              stdout: _remoteSnapshotLine(summaryPath, r'''
{
  "info": {"id": "win-session", "cwd": "C:\\work\\repo"},
  "generated_title": "Resume from custom Grok home",
  "last_active_at": "2026-08-14T20:04:00Z"
}
''', mtime: 1786740000),
            );
          }
          if (script.contains('Get-ChildItem') &&
              script.contains(r'$env:GROK_HOME') &&
              script.contains("'summary.json'")) {
            return _buildExecSession(stdout: '$summaryPath\n');
          }
          return _buildExecSession();
        });

        final discovery = AgentSessionDiscoveryService();
        final session = _buildDiscoverySession(client);
        final result = await discovery
            .discoverSessionsStream(session, toolName: 'Grok Build')
            .last;

        expect(
          result.sessions,
          hasLength(1),
          reason: issuedScripts.join('\n--- command ---\n'),
        );
        expect(result.sessions.single.sessionId, 'win-session');
        expect(result.sessions.single.summary, 'Resume from custom Grok home');
        final listScripts = issuedScripts
            .where(
              (script) =>
                  script.contains('Get-ChildItem') &&
                  script.contains("'summary.json'"),
            )
            .toList(growable: false);
        expect(listScripts, hasLength(1));
        expect(listScripts.single, contains(r'$env:GROK_HOME'));
        expect(
          listScripts.single,
          contains(
            r'if(![string]::IsNullOrWhiteSpace([string]$__flOverrideBase)){',
          ),
        );
      },
    );

    test('Pi discovery resolves session header id and cwd', () async {
      final client = _MockSshClient();
      const sessionPath =
          '/Users/demo/.pi/agent/sessions/--Users-depoll-Code-flutty--/'
          '2026-04-12T21-07-44-781Z_01JYX7ABCD.jsonl';
      final commands = <String>[];
      _stubDiscoveryExec(client, (command) async {
        commands.add(command);
        if (command.contains(r"$SED_BIN -n '1,1p'") &&
            command.contains(sessionPath)) {
          return _buildExecSession(
            stdout: _remoteSnapshotLine(sessionPath, '''
{"type":"session","version":3,"id":"01JYX7ABCD","timestamp":"2026-04-12T21:07:44.781Z","cwd":"/Users/depoll/Code/flutty"}
{"type":"message","message":{"role":"user","content":"Fix the tmux navigator crash"}}
''', mtime: 1777243460),
          );
        }
        if (command.contains('--Users-depoll-Code-flutty--')) {
          return _buildExecSession(stdout: sessionPath);
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);
      final result = await discovery
          .discoverSessionsStream(
            session,
            workingDirectory: '/Users/depoll/Code/flutty',
            toolName: 'Pi',
          )
          .last;

      expect(result.sessions, hasLength(1));
      final info = result.sessions.single;
      expect(info.toolName, 'Pi');
      expect(info.sessionId, '01JYX7ABCD');
      expect(info.summary, 'Pi session 01JYX7ABCD');
      expect(info.workingDirectory, '/Users/depoll/Code/flutty');
      expect(
        commands,
        contains(
          allOf(
            contains(r'{ find "$HOME"/.pi/agent/sessions/'),
            contains('--Users-depoll-Code-flutty--'),
            contains('-maxdepth 1'),
          ),
        ),
      );
      expect(commands, contains(contains(r"$SED_BIN -n '1,1p'")));
      expect(commands, contains(contains('git -C')));
      expect(
        discovery.buildResumeCommand(info),
        "cd '/Users/depoll/Code/flutty' && pi --session '01JYX7ABCD'",
      );
    });

    test('Pi discovery does not guess without a pane cwd', () async {
      final client = _MockSshClient();
      final result = await AgentSessionDiscoveryService()
          .discoverSessionsStream(
            _buildDiscoverySession(client),
            toolName: 'Pi',
          )
          .last;

      expect(result.sessions, isEmpty);
      verifyNever(() => client.execute(any()));
    });

    test('Pi discovery keeps a scoped header-only session resumable', () async {
      final client = _MockSshClient();
      const sessionPath =
          '/Users/demo/.pi/agent/sessions/--Users-depoll-Code-flutty--/'
          '2026-04-12T21-07-44-781Z_01JYX7HEADER.jsonl';
      _stubDiscoveryExec(client, (command) async {
        if (command.contains(r"$SED_BIN -n '1,1p'") &&
            command.contains(sessionPath)) {
          return _buildExecSession(
            stdout: _remoteSnapshotLine(sessionPath, '''
{"type":"session","version":3,"id":"01JYX7HEADER","timestamp":"2026-04-12T21:07:44.781Z","cwd":"/Users/depoll/Code/flutty"}
{"type":"model_change","modelId":"example"}
'''),
          );
        }
        if (command.contains('--Users-depoll-Code-flutty--')) {
          return _buildExecSession(stdout: sessionPath);
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final result = await discovery
          .discoverSessionsStream(
            _buildDiscoverySession(client),
            workingDirectory: '/Users/depoll/Code/flutty',
            toolName: 'Pi',
          )
          .last;

      expect(result.sessions, hasLength(1));
      expect(result.sessions.single.sessionId, '01JYX7HEADER');
      expect(result.sessions.single.summary, 'Pi session 01JYX7HEADER');
    });

    test('Pi provider preview reads the exact pane cwd bucket', () async {
      final client = _MockSshClient();
      const projectPath =
          '/Users/demo/.pi/agent/sessions/--Users-depoll-Code-flutty--/'
          '2026-04-12T21-07-44-781Z_01JYX7ABCD.jsonl';
      _stubDiscoveryExec(client, (command) async {
        if (command.contains(projectPath)) {
          return _buildExecSession(
            stdout: _remoteSnapshotLine(projectPath, '''
{"type":"session","version":3,"id":"01JYX7ABCD","timestamp":"2026-04-12T21:07:44.781Z","cwd":"/Users/depoll/Code/flutty"}
{"type":"message","message":{"role":"user","content":"Scoped Pi session"}}
'''),
          );
        }
        if (command.contains('--Users-depoll-Code-flutty--')) {
          return _buildExecSession(stdout: projectPath);
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final snapshots = await discovery
          .discoverSessionsStream(
            _buildDiscoverySession(client),
            workingDirectory: '/Users/depoll/Code/flutty',
            maxPerTool: 1,
          )
          .toList();
      final piPreviews = snapshots
          .expand((snapshot) => snapshot.sessions)
          .where((session) => session.toolName == 'Pi')
          .toList(growable: false);

      expect(piPreviews, isNotEmpty);
      expect(piPreviews.first.sessionId, '01JYX7ABCD');
      expect(piPreviews.first.summary, 'Pi session 01JYX7ABCD');
    });

    test('Pi discovery follows explicit Git worktree buckets', () async {
      final client = _MockSshClient();
      const mainPath =
          '/Users/demo/.pi/agent/sessions/--Users-depoll-Code-MonkeySSH--/'
          '2026-04-12T21-07-44-781Z_MAIN.jsonl';
      const worktreePath =
          '/Users/demo/.pi/agent/sessions/--Users-depoll-worktrees-feature--/'
          '2026-04-12T22-07-44-781Z_WORKTREE.jsonl';
      final commands = <String>[];
      _stubDiscoveryExec(client, (command) async {
        commands.add(command);
        if (command.contains('worktree list --porcelain')) {
          return _buildExecSession(
            stdout: '''
root=/Users/depoll/Code/MonkeySSH
worktree /Users/depoll/Code/MonkeySSH
HEAD a

worktree /Users/depoll/worktrees/feature
HEAD b
''',
          );
        }
        if (command.contains(r"$SED_BIN -n '1,1p'")) {
          return _buildExecSession(
            stdout:
                _remoteSnapshotLine(mainPath, '''
{"type":"session","id":"MAIN","timestamp":"2026-04-12T21:07:44.781Z","cwd":"/Users/depoll/Code/MonkeySSH"}
''') +
                _remoteSnapshotLine(worktreePath, '''
{"type":"session","id":"WORKTREE","timestamp":"2026-04-12T22:07:44.781Z","cwd":"/Users/depoll/worktrees/feature"}
'''),
          );
        }
        if (command.contains('--Users-depoll-Code-MonkeySSH--') &&
            command.contains('--Users-depoll-worktrees-feature--')) {
          return _buildExecSession(stdout: '$worktreePath\n$mainPath');
        }
        return _buildExecSession();
      });

      final result = await AgentSessionDiscoveryService()
          .discoverSessionsStream(
            _buildDiscoverySession(client),
            workingDirectory: '/Users/depoll/Code/MonkeySSH',
            toolName: 'Pi',
          )
          .last;

      expect(
        result.sessions.map((session) => session.sessionId),
        containsAll(<String>['MAIN', 'WORKTREE']),
      );
      final listCommand = commands.firstWhere(
        (command) => command.contains('-maxdepth 1'),
      );
      expect(listCommand, contains('--Users-depoll-Code-MonkeySSH--'));
      expect(listCommand, contains('--Users-depoll-worktrees-feature--'));
      expect(listCommand, isNot(contains('find ~/.pi/agent/sessions')));
    });

    test('Hermes discovery reads the state database', () async {
      final client = _MockSshClient();
      final commands = <String>[];
      _stubDiscoveryExec(client, (command) async {
        commands.add(command);
        if (command.contains('state.db')) {
          return _buildExecSession(
            stdout: <String>[
              '20250305_091523_a1b2c3',
              'Refactor auth',
              '/Users/depoll/Code/flutty',
              '1783405351',
            ].join('\x1f'),
          );
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);
      final result = await discovery
          .discoverSessionsStream(session, toolName: 'Hermes')
          .last;

      expect(result.sessions, hasLength(1));
      final info = result.sessions.single;
      expect(info.toolName, 'Hermes');
      expect(info.sessionId, '20250305_091523_a1b2c3');
      expect(info.summary, 'Refactor auth');
      expect(info.workingDirectory, '/Users/depoll/Code/flutty');
      expect(
        discovery.buildResumeCommand(info),
        "cd '/Users/depoll/Code/flutty' && "
        "hermes --resume '20250305_091523_a1b2c3'",
      );
      // Gateway chats from messaging platforms must stay out of the picker,
      // and HERMES_HOME must be honoured when set. The SQL is shell-quoted,
      // so assert on tokens that survive escaping.
      final query = commands.firstWhere((c) => c.contains('state.db'));
      expect(query, contains('source IN ('));
      expect(query, contains('cli'));
      expect(query, contains('tui'));
      expect(query, contains('parent_session_id IS NULL'));
      expect(query, contains(r'${HERMES_HOME:-$HOME/.hermes}/state.db'));
    });

    test('toolName limits discovery to the requested provider', () async {
      final client = _MockSshClient();
      final commands = <String>[];
      _stubDiscoveryExec(client, (command) async {
        commands.add(command);
        if (command.contains('opencode session list --format json')) {
          return _buildExecSession(
            stdout:
                '[{"id":"session-1","title":"OpenCode only","directory":"/Users/depoll/Code/flutty","updated":"2026-04-21T20:00:00.000Z"}]',
          );
        }
        if (command.contains('find ~/.codex/sessions')) {
          return _buildExecSession(stdout: '/tmp/rollout-should-not-run.jsonl');
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);
      final result = await discovery
          .discoverSessionsStream(session, toolName: 'OpenCode')
          .last;

      expect(result.sessions.map((session) => session.toolName), ['OpenCode']);
      expect(result.sessions.map((session) => session.sessionId), [
        'session-1',
      ]);
      expect(
        commands.where(
          (command) => command.contains('opencode session list --format json'),
        ),
        hasLength(1),
      );
      expect(
        commands.where((command) => command.contains('find ~/.codex/sessions')),
        isEmpty,
      );
    });

    test('prefetchSessions warms the cache for the next visible load', () async {
      final client = _MockSshClient();
      final commands = <String>[];
      _stubDiscoveryExec(client, (command) async {
        commands.add(command);
        if (command.contains('opencode session list --format json')) {
          return _buildExecSession(
            stdout:
                '[{"id":"session-1","title":"Prefetched result","directory":"/Users/depoll/Code/flutty","updated":"2026-04-21T20:00:00.000Z"}]',
          );
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);

      await discovery.prefetchSessions(session, maxPerTool: 6);
      final commandCountAfterPrefetch = commands.length;
      final result = await discovery.discoverSessionsStream(session).first;

      expect(result.sessions.map((session) => session.sessionId), [
        'session-1',
      ]);
      expect(commands.length, commandCountAfterPrefetch);
    });

    test('reuses fresh results for repeated loads in the same scope', () async {
      final client = _MockSshClient();
      final commands = <String>[];
      _stubDiscoveryExec(client, (command) async {
        commands.add(command);
        if (command.contains('opencode session list --format json')) {
          return _buildExecSession(
            stdout:
                '[{"id":"session-1","title":"Cache result","directory":"/Users/depoll/Code/flutty","updated":"2026-04-21T20:00:00.000Z"}]',
          );
        }
        return _buildExecSession();
      });

      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);

      final firstResults = await discovery
          .discoverSessionsStream(session)
          .toList();
      final firstCommandCount = commands.length;
      final secondResults = await discovery
          .discoverSessionsStream(session)
          .toList();

      expect(firstResults, isNotEmpty);
      expect(firstResults.last.sessions.map((session) => session.sessionId), [
        'session-1',
      ]);
      expect(secondResults, hasLength(1));
      expect(
        secondResults.single.sessions.map((session) => session.sessionId),
        ['session-1'],
      );
      expect(commands.length, firstCommandCount);
    });

    test(
      'invalidateSession forces the next load to re-probe providers',
      () async {
        final client = _MockSshClient();
        final commands = <String>[];
        when(() => client.execute(any())).thenAnswer((invocation) async {
          commands.add(invocation.positionalArguments.first as String);
          return _buildExecSession();
        });
        final discovery = AgentSessionDiscoveryService();
        final session = _buildDiscoverySession(client);

        await discovery.discoverSessionsStream(session).drain<void>();
        final firstCommandCount = commands.length;
        await discovery.discoverSessionsStream(session).drain<void>();
        expect(commands.length, firstCommandCount);

        discovery.invalidateSession(session);
        await discovery.discoverSessionsStream(session).drain<void>();

        expect(commands.length, greaterThan(firstCommandCount));
      },
    );

    test(
      'invalidating one host preserves another host’s in-flight caches',
      () async {
        final clients = [_MockSshClient(), _MockSshClient()];
        final probeStarted = [Completer<void>(), Completer<void>()];
        final finishProbes = Completer<void>();
        final commandCounts = [0, 0];
        final worktreeCounts = [0, 0];
        for (var index = 0; index < clients.length; index++) {
          when(() => clients[index].execute(any())).thenAnswer((
            invocation,
          ) async {
            commandCounts[index]++;
            final command = invocation.positionalArguments.first as String;
            if (command.contains('worktree list --porcelain')) {
              worktreeCounts[index]++;
              if (!probeStarted[index].isCompleted) {
                probeStarted[index].complete();
                await finishProbes.future;
              }
              return _buildExecSession(
                stdout: 'root=/project\nworktree /project\n',
              );
            }
            return _buildExecSession();
          });
        }
        final sessions = [
          _buildDiscoverySession(clients[0]),
          SshSession(
            connectionId: 2,
            hostId: 2,
            client: clients[1],
            config: const SshConnectionConfig(
              hostname: 'other.example.com',
              port: 22,
              username: 'demo',
            ),
          ),
        ];
        final discovery = AgentSessionDiscoveryService();
        final loads = [
          for (final session in sessions)
            discovery
                .discoverSessionsStream(
                  session,
                  workingDirectory: '/project',
                  toolName: 'OpenCode',
                )
                .last,
        ];
        await Future.wait(probeStarted.map((started) => started.future));
        discovery.invalidateSession(sessions[0]);
        finishProbes.complete();
        await Future.wait(loads);

        final cachedCommandCount = commandCounts[1];
        await discovery
            .discoverSessionsStream(
              sessions[1],
              workingDirectory: '/project',
              toolName: 'OpenCode',
            )
            .last;
        expect(commandCounts[1], cachedCommandCount);
        for (final session in sessions) {
          await discovery
              .discoverSessionsStream(
                session,
                workingDirectory: '/project',
                toolName: 'OpenCode',
                maxPerTool: 24,
              )
              .last;
        }
        expect(worktreeCounts, [2, 1]);
      },
    );

    test('invalidated discoveries cannot republish stale snapshots', () async {
      final client = _MockSshClient();
      final oldProbeStarted = Completer<void>();
      final finishOldProbe = Completer<void>();
      var probes = 0;
      _stubDiscoveryExec(client, (command) async {
        if (command.contains('opencode session list --format json')) {
          final probe = ++probes;
          if (probe == 1) {
            oldProbeStarted.complete();
            await finishOldProbe.future;
          }
          return _buildExecSession(
            stdout: jsonEncode([
              {
                'id': 'session-$probe',
                'title': 'Discovery result',
                'directory': '/project',
                'updated': '2026-04-21T20:00:00.000Z',
              },
            ]),
          );
        }
        return _buildExecSession();
      });
      final discovery = AgentSessionDiscoveryService();
      final session = _buildDiscoverySession(client);
      final oldLoad = discovery
          .discoverSessionsStream(session, toolName: 'OpenCode')
          .last;
      await oldProbeStarted.future;
      discovery.invalidateSession(session);
      finishOldProbe.complete();
      expect((await oldLoad).sessions.single.sessionId, 'session-1');

      final refreshed = await discovery
          .discoverSessionsStream(session, toolName: 'OpenCode')
          .toList();

      expect(probes, 2);
      expect(refreshed.last.sessions.single.sessionId, 'session-2');
      expect(
        refreshed.expand((result) => result.sessions).map((s) => s.sessionId),
        everyElement('session-2'),
      );
    });

    test(
      'reuses related worktree lookups across max-per-tool refreshes',
      () async {
        final client = _MockSshClient();
        final commands = <String>[];
        _stubDiscoveryExec(client, (command) async {
          commands.add(command);
          if (command.contains('worktree list --porcelain')) {
            return _buildExecSession(
              stdout: '''
root=/Users/depoll/Code/flutty
worktree /Users/depoll/Code/flutty
HEAD afdab6c
branch refs/heads/main
''',
            );
          }
          if (command.contains('opencode session list --format json')) {
            return _buildExecSession(
              stdout:
                  '[{"id":"session-1","title":"Scoped cache result","directory":"/Users/depoll/Code/flutty","updated":"2026-04-21T20:00:00.000Z"}]',
            );
          }
          return _buildExecSession();
        });

        final discovery = AgentSessionDiscoveryService();
        final session = _buildDiscoverySession(client);

        final firstResults = await discovery
            .discoverSessionsStream(
              session,
              workingDirectory: '/Users/depoll/Code/flutty',
            )
            .toList();
        final secondResults = await discovery
            .discoverSessionsStream(
              session,
              workingDirectory: '/Users/depoll/Code/flutty',
              maxPerTool: 24,
            )
            .toList();

        expect(firstResults.last.sessions.map((session) => session.sessionId), [
          'session-1',
        ]);
        expect(
          secondResults.last.sessions.map((session) => session.sessionId),
          ['session-1'],
        );
        expect(
          commands.where(
            (command) => command.contains('worktree list --porcelain'),
          ),
          hasLength(1),
        );
        expect(
          commands.where(
            (command) =>
                command.contains('opencode session list --format json'),
          ),
          hasLength(2),
        );
      },
    );
  });
}

void _stubDiscoveryExec(
  SSHClient client,
  FutureOr<SSHSession> Function(String) response,
) {
  when(() => client.execute(any())).thenAnswer(
    (call) async => response(call.positionalArguments.single as String),
  );
}

void _stubDecodedDiscoveryExec(
  SSHClient client,
  FutureOr<SSHSession> Function(String) response,
) => _stubDiscoveryExec(
  client,
  (command) => response(decodeEncodedPowerShell(command)),
);
