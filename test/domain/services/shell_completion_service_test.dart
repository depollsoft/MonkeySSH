import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart' as ssh;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/shell_completion_service.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

import '../../helpers/mock_ssh_exec_session.dart';
import '../../helpers/powershell_test_helpers.dart';

class _MockSshClient extends Mock implements ssh.SSHClient {}

class _MockSshExecSession extends MockSessionWithChannel {}

class _MockByteSink extends Mock implements StreamSink<Uint8List> {}

SshSession _buildShellCompletionSession(
  ssh.SSHClient client, {
  required int connectionId,
  required int hostId,
}) => SshSession(
  connectionId: connectionId,
  hostId: hostId,
  client: client,
  config: const SshConnectionConfig(
    hostname: 'example.com',
    port: 22,
    username: 'tester',
  ),
);

void _stubHistoryExec(ssh.SSHClient client, List<String> commands) {
  final exec = _MockSshExecSession();
  final output = [
    '__FLUTTY_HISTORY_START__',
    ...commands.map((command) => 'bash\t$command'),
    '__FLUTTY_HISTORY_DONE__',
  ].join('\n');
  when(() => exec.stdout).thenAnswer(
    (_) => Stream<Uint8List>.fromIterable([
      Uint8List.fromList(utf8.encode(output)),
    ]),
  );
  when(() => exec.stderr).thenAnswer((_) => const Stream<Uint8List>.empty());
  when(() => exec.done).thenAnswer((_) => Future<void>.value());
  when(
    () => client.execute(any(), pty: any(named: 'pty')),
  ).thenAnswer((_) async => exec);
}

class _PendingHistoryExec {
  _PendingHistoryExec(ssh.SSHClient client) {
    when(() => exec.stdout).thenAnswer((_) => _stdout.stream);
    when(() => exec.stderr).thenAnswer((_) => const Stream<Uint8List>.empty());
    when(() => exec.done).thenAnswer((_) => _done.future);
    when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
      _,
    ) async {
      if (!started.isCompleted) {
        started.complete();
      }
      return exec;
    });
  }

  final _MockSshExecSession exec = _MockSshExecSession();
  final StreamController<Uint8List> _stdout = StreamController<Uint8List>();
  final Completer<void> _done = Completer<void>();
  final Completer<void> started = Completer<void>();

  Future<void> complete(List<String> commands) async {
    final output = [
      '__FLUTTY_HISTORY_START__',
      ...commands.map((command) => 'bash\t$command'),
      '__FLUTTY_HISTORY_DONE__',
    ].join('\n');
    _stdout.add(Uint8List.fromList(utf8.encode(output)));
    await _stdout.close();
    if (!_done.isCompleted) {
      _done.complete();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    registerFallbackValue(const ssh.SSHPtyConfig());
    registerFallbackValue(Uint8List(0));
  });
  tearDown(resetQueuedSshExecsForTesting);

  for (final history in [false, true]) {
    test(
      'stdout collector decodes split UTF-8 and truncates, history=$history',
      () async {
        const command = 'éclair';
        const historyOutput = '__FLUTTY_HISTORY_START__\nbash\t$command\n';
        const completionOutput = 'command\t$command\n';
        final retained = history ? historyOutput : completionOutput;
        final service = ShellCompletionService(
          maxHistoryOutputChars: history ? retained.length : 80000,
          maxOutputChars: history ? 12000 : retained.length,
        );
        final client = _MockSshClient();
        final session = _buildShellCompletionSession(
          client,
          connectionId: 101,
          hostId: 101,
        );
        final execs = <ssh.SSHSession>[];
        var calls = 0;
        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
          _,
        ) async {
          final output = !history && calls++ == 0
              ? ''
              : '$retained${history ? 'bash' : 'command'}\téother\n';
          final exec = _MockSshExecSession();
          execs.add(exec);
          when(() => exec.stdout).thenAnswer(
            (_) => Stream.fromIterable(
              utf8.encode(output).map((byte) => Uint8List.fromList([byte])),
            ),
          );
          when(
            () => exec.stderr,
          ).thenAnswer((_) => Stream.value(Uint8List.fromList([1, 2, 3])));
          when(() => exec.done).thenAnswer((_) => Future<void>.value());
          return exec;
        });
        final invocation = _commandInvocation('é', '/repo');
        final suggestions = await service.complete(session, invocation);
        expect(suggestions.map((entry) => entry.label), [command]);
        for (final exec in execs) {
          verify(exec.close).called(1);
          verify(() => exec.stderr).called(1);
        }
      },
    );
  }

  test(
    'stdout collector closes completion and history channels on timeout',
    () async {
      final service = ShellCompletionService(
        timeout: const Duration(milliseconds: 10),
        historyTimeout: const Duration(milliseconds: 10),
      );
      final client = _MockSshClient();
      final session = _buildShellCompletionSession(
        client,
        connectionId: 102,
        hostId: 102,
      );
      final execs = <ssh.SSHSession>[];
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        _,
      ) async {
        final exec = _MockSshExecSession();
        execs.add(exec);
        when(() => exec.stdout).thenAnswer((_) => const Stream.empty());
        when(() => exec.stderr).thenAnswer((_) => const Stream.empty());
        when(() => exec.done).thenAnswer((_) => Completer<void>().future);
        return exec;
      });
      final invocation = _commandInvocation('xyz', '/repo');
      await expectLater(
        service.complete(session, invocation),
        throwsA(isA<TimeoutException>()),
      );
      expect(execs, hasLength(2));
      for (final exec in execs) {
        verify(exec.close).called(1);
      }
    },
  );

  for (final lateResult in ['never', 'channel', 'error']) {
    test('history and completion opens time out with late $lateResult', () async {
      final service = ShellCompletionService(
        timeout: const Duration(milliseconds: 10),
        historyTimeout: const Duration(milliseconds: 10),
      );
      final client = _MockSshClient();
      final session = _buildShellCompletionSession(
        client,
        connectionId: 104,
        hostId: 104,
      );
      final openings = <Completer<ssh.SSHSession>>[];
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((_) {
        final opening = Completer<ssh.SSHSession>();
        openings.add(opening);
        return opening.future;
      });
      final invocation = _commandInvocation('xyz', '/repo');
      // Repeating the exact request also proves neither in-flight entry sticks.
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          service.complete(session, invocation),
          throwsA(isA<TimeoutException>()),
        );
        expect(activeQueuedSshExecCountForTesting(104), 0);
        expect(pendingQueuedSshExecCountForTesting(104), 0);
      }
      expect(openings, hasLength(4));
      final channels = <ssh.SSHSession>[];
      for (final opening in openings) {
        if (lateResult == 'channel') {
          final channel = _MockSshExecSession();
          channels.add(channel);
          opening.complete(channel);
        } else if (lateResult == 'error') {
          opening.completeError(StateError('late failure'));
        }
      }
      await pumpEventQueue();
      for (final channel in channels) {
        verify(channel.channel.destroy).called(1);
      }
    });
  }

  for (final stdinCloseHangs in [false, true]) {
    test('interactive collector subscribes before writing and closes once '
        '(stdin close hangs: $stdinCloseHangs)', () async {
      final client = _MockSshClient();
      final session = _buildShellCompletionSession(
        client,
        connectionId: 103,
        hostId: 103,
      );
      final exec = _MockSshExecSession();
      final input = _MockByteSink();
      final output = StreamController<Uint8List>();
      final done = Completer<void>();
      when(() => exec.stdout).thenAnswer((_) => output.stream);
      when(() => exec.stderr).thenAnswer((_) => const Stream.empty());
      when(() => exec.done).thenAnswer((_) => done.future);
      when(() => exec.stdin).thenReturn(input);
      when(() => exec.write(any())).thenAnswer((_) {
        expect(output.hasListener, isTrue);
        output.add(
          Uint8List.fromList(
            utf8.encode('argument\téclair\n__FLUTTY_ZSH_NATIVE_DONE__\n'),
          ),
        );
      });
      when(input.close).thenAnswer((_) async {
        await output.close();
        done.complete();
        if (stdinCloseHangs) await Completer<void>().future;
      });
      final history = _MockSshExecSession();
      when(() => history.stdout).thenAnswer((_) => const Stream.empty());
      when(() => history.stderr).thenAnswer((_) => const Stream.empty());
      when(() => history.done).thenAnswer((_) => Future<void>.value());
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer(
        (invocation) async =>
            invocation.namedArguments[#pty] == null ? history : exec,
      );
      const invocation = ShellCompletionInvocation(
        commandLine: 'tool é',
        cursorOffset: 6,
        token: 'é',
        tokenStart: 5,
        mode: ShellCompletionMode.argument,
        commandName: 'tool',
        shellCommand: 'zsh',
        words: ['tool', 'é'],
        wordIndex: 1,
        workingDirectory: '/repo',
      );
      final service = ShellCompletionService(
        interactiveZshTimeout: const Duration(milliseconds: 10),
      );
      final results = await Future.wait([
        service.complete(session, invocation),
        service.complete(session, invocation),
      ]).timeout(const Duration(seconds: 1));
      for (final suggestions in results) {
        if (stdinCloseHangs) {
          expect(suggestions, isEmpty);
        } else {
          expect(suggestions.single.label, 'tool éclair');
        }
      }
      verify(input.close).called(1);
      verify(exec.close).called(1);
    });
  }

  group('buildShellCompletionInvocation', () {
    test('uses a captured prompt prefix to isolate the command text', () {
      const prompt = 'depoll@mac-mini ~ % ';
      final invocation = buildShellCompletionInvocation(
        terminalText: '${prompt}gi',
        terminalCursorOffset: '${prompt}gi'.length,
        promptPrefix: prompt,
        workingDirectory: '/Users/depoll',
      );

      expect(invocation, isNotNull);
      expect(invocation!.commandLine, 'gi');
      expect(invocation.cursorOffset, 2);
      expect(invocation.token, 'gi');
      expect(invocation.tokenStart, 0);
      expect(invocation.mode, ShellCompletionMode.command);
      expect(invocation.workingDirectory, '/Users/depoll');
    });

    test('falls back to common shell prompt markers', () {
      final invocation = buildShellCompletionInvocation(
        terminalText: r'tester@host ~/project $ git',
        terminalCursorOffset: r'tester@host ~/project $ git'.length,
      );

      expect(invocation, isNotNull);
      expect(invocation!.commandLine, 'git');
      expect(invocation.mode, ShellCompletionMode.command);
    });

    test('recovers from a prompt prefix that captured command text', () {
      final invocation = buildShellCompletionInvocation(
        terminalText: 'tester@host ~/project % git ch',
        terminalCursorOffset: 'tester@host ~/project % git ch'.length,
        promptPrefix: 'tester@host ~/project % git ',
      );

      expect(invocation, isNotNull);
      expect(invocation!.commandLine, 'git ch');
      expect(invocation.commandName, 'git');
      expect(invocation.token, 'ch');
      expect(invocation.tokenStart, 4);
      expect(invocation.mode, ShellCompletionMode.argument);
    });

    test('resolves cd arguments as directory completions', () {
      final invocation = buildShellCompletionInvocation(
        terminalText: 'tester@host ~ % cd Ser',
        terminalCursorOffset: 'tester@host ~ % cd Ser'.length,
      );

      expect(invocation, isNotNull);
      expect(invocation!.commandLine, 'cd Ser');
      expect(invocation.commandName, 'cd');
      expect(invocation.token, 'Ser');
      expect(invocation.tokenStart, 3);
      expect(invocation.mode, ShellCompletionMode.directory);
    });

    test('does not request all commands at an empty prompt', () {
      final invocation = buildShellCompletionInvocation(
        terminalText: 'tester@host ~ % ',
        terminalCursorOffset: 'tester@host ~ % '.length,
      );

      expect(invocation, isNull);
    });

    test('allows empty argument tokens for history-only completions', () {
      final argumentInvocation = buildShellCompletionInvocation(
        terminalText: 'tester@host ~ % git ',
        terminalCursorOffset: 'tester@host ~ % git '.length,
      );

      expect(argumentInvocation, isNotNull);
      expect(argumentInvocation!.commandLine, 'git ');
      expect(argumentInvocation.commandName, 'git');
      expect(argumentInvocation.token, isEmpty);
      expect(argumentInvocation.tokenStart, 4);
      expect(argumentInvocation.mode, ShellCompletionMode.argument);
    });

    test('requests shell-native argument completions for typed tokens', () {
      final argumentInvocation = buildShellCompletionInvocation(
        terminalText: 'tester@host ~ % git c',
        terminalCursorOffset: 'tester@host ~ % git c'.length,
        shellCommand: 'zsh',
      );

      expect(argumentInvocation, isNotNull);
      expect(argumentInvocation!.commandLine, 'git c');
      expect(argumentInvocation.commandName, 'git');
      expect(argumentInvocation.shellCommand, 'zsh');
      expect(argumentInvocation.token, 'c');
      expect(argumentInvocation.tokenStart, 4);
      expect(argumentInvocation.mode, ShellCompletionMode.argument);
      expect(argumentInvocation.words, ['git', 'c']);
      expect(argumentInvocation.wordIndex, 1);
    });

    test('allows empty directory tokens for history-only completions', () {
      final directoryInvocation = buildShellCompletionInvocation(
        terminalText: 'tester@host ~ % cd ',
        terminalCursorOffset: 'tester@host ~ % cd '.length,
      );

      expect(directoryInvocation, isNotNull);
      expect(directoryInvocation!.commandLine, 'cd ');
      expect(directoryInvocation.commandName, 'cd');
      expect(directoryInvocation.token, isEmpty);
      expect(directoryInvocation.tokenStart, 3);
      expect(directoryInvocation.mode, ShellCompletionMode.directory);
    });

    test('allows known fallback subcommands after an empty argument token', () {
      final invocation = buildShellCompletionInvocation(
        terminalText: 'tester@host ~ % tmux ',
        terminalCursorOffset: 'tester@host ~ % tmux '.length,
      );

      expect(invocation, isNotNull);
      expect(invocation!.commandLine, 'tmux ');
      expect(invocation.commandName, 'tmux');
      expect(invocation.token, isEmpty);
      expect(invocation.tokenStart, 5);
      expect(invocation.mode, ShellCompletionMode.argument);
      expect(invocation.words, ['tmux']);
      expect(invocation.wordIndex, 1);
    });
  });

  group('buildShellCompletionStaticSuggestions', () {
    test('builds tmux subcommand suggestions for an empty token', () {
      const invocation = ShellCompletionInvocation(
        commandLine: 'tmux ',
        cursorOffset: 5,
        token: '',
        tokenStart: 5,
        mode: ShellCompletionMode.argument,
        commandName: 'tmux',
        words: ['tmux'],
        wordIndex: 1,
        workingDirectory: '/Users/depoll',
      );

      final suggestions = buildShellCompletionStaticSuggestions(invocation);

      expect(suggestions, isNotNull);
      expect(suggestions!.take(4).map((suggestion) => suggestion.label), [
        'tmux attach',
        'tmux attach-session',
        'tmux new',
        'tmux new-session',
      ]);
      expect(suggestions.first.replacement, 'attach');
      expect(suggestions.first.replacementStart, 5);
      expect(suggestions.first.commitSuffix, ' ');
    });

    test('filters tmux subcommand suggestions as the token narrows', () {
      const invocation = ShellCompletionInvocation(
        commandLine: 'tmux a',
        cursorOffset: 6,
        token: 'a',
        tokenStart: 5,
        mode: ShellCompletionMode.argument,
        commandName: 'tmux',
        words: ['tmux', 'a'],
        wordIndex: 1,
        workingDirectory: '/Users/depoll',
      );

      final suggestions = buildShellCompletionStaticSuggestions(invocation);

      expect(suggestions!.map((suggestion) => suggestion.label), [
        'tmux attach',
        'tmux attach-session',
      ]);
    });

    test('returns null for commands without a static provider', () {
      const invocation = ShellCompletionInvocation(
        commandLine: 'git a',
        cursorOffset: 5,
        token: 'a',
        tokenStart: 4,
        mode: ShellCompletionMode.argument,
        commandName: 'git',
        words: ['git', 'a'],
        wordIndex: 1,
        workingDirectory: '/Users/depoll',
      );

      expect(buildShellCompletionStaticSuggestions(invocation), isNull);
    });
  });

  group('parseShellCompletionOutput', () {
    test('builds command and cd shortcut suggestions', () {
      const invocation = ShellCompletionInvocation(
        commandLine: 'c',
        cursorOffset: 1,
        token: 'c',
        tokenStart: 0,
        mode: ShellCompletionMode.command,
        workingDirectory: '/Users/depoll',
      );

      final suggestions = parseShellCompletionOutput(
        [
          'command\tcat',
          'command\tcd',
          'cd_directory\tServices',
          'cd_directory\t..',
        ].join('\n'),
        invocation,
      );

      expect(suggestions.map((suggestion) => suggestion.label), [
        'cd',
        'cd ..',
        'cd Services/',
        'cat',
      ]);
      expect(suggestions.first.replacement, 'cd');
      expect(suggestions.first.commitSuffix, ' ');
      expect(suggestions[2].replacement, 'cd Services/');
      expect(suggestions[2].replacementStart, 0);
    });

    test('escapes spaces in path replacements', () {
      const invocation = ShellCompletionInvocation(
        commandLine: 'cd Pro',
        cursorOffset: 6,
        token: 'Pro',
        tokenStart: 3,
        mode: ShellCompletionMode.directory,
        commandName: 'cd',
        workingDirectory: '/Users/depoll',
      );

      final suggestions = parseShellCompletionOutput(
        'directory\tProject Files',
        invocation,
      );

      expect(suggestions.single.label, 'cd Project Files/');
      expect(suggestions.single.replacement, r'Project\ Files/');
      expect(suggestions.single.replacementStart, 3);
      expect(suggestions.single.replacementEnd, 6);
    });

    test('labels dynamic argument suggestions with the command context', () {
      const invocation = ShellCompletionInvocation(
        commandLine: 'tmux a',
        cursorOffset: 6,
        token: 'a',
        tokenStart: 5,
        mode: ShellCompletionMode.argument,
        commandName: 'tmux',
        words: ['tmux', 'a'],
        wordIndex: 1,
        workingDirectory: '/Users/depoll',
      );

      final suggestions = parseShellCompletionOutput(
        'argument\tattach',
        invocation,
      );

      expect(suggestions.single.label, 'tmux attach');
      expect(suggestions.single.replacement, 'attach');
      expect(suggestions.single.replacementStart, 5);
      expect(suggestions.single.commitSuffix, ' ');
    });
  });

  group('shell history suggestions', () {
    test('parseShellHistoryOutput reads bash, zsh, and fish commands', () {
      final commands = parseShellHistoryOutput(
        [
          '__FLUTTY_HISTORY_START__',
          'bash\tgit status',
          'zsh\t: 1777870000:0;git checkout feature/login',
          r'fish	- cmd: git commit\n--amend',
          '__FLUTTY_HISTORY_DONE__',
        ].join('\n'),
      );

      expect(commands, [
        'git status',
        'git checkout feature/login',
        'git commit --amend',
      ]);
    });

    test('normalizes history entries into trimmed command patterns', () {
      expect(
        normalizeShellHistoryCommandPattern('git commit -m "do something"'),
        'git commit -m',
      );
      expect(
        normalizeShellHistoryCommandPattern(
          'codex --prompt="do something" --sandbox workspace-write',
        ),
        'codex --prompt --sandbox',
      );
      expect(
        normalizeShellHistoryCommandPattern(
          'grep -f patterns.txt --exclude "*.dart" lib',
        ),
        'grep -f --exclude lib',
      );
      expect(
        normalizeShellHistoryCommandPattern(
          ': 1777870000:0;git checkout feature/login',
        ),
        'git checkout feature/login',
      );
      expect(
        normalizeShellHistoryCommandPattern(
          'tmux%20new-session%20-A%20-s%20monkeyssh',
        ),
        isNull,
      );
    });

    test(
      'buildShellHistorySuggestions ranks by token count frequency and recency',
      () {
        const invocation = ShellCompletionInvocation(
          commandLine: 'git c',
          cursorOffset: 5,
          token: 'c',
          tokenStart: 4,
          mode: ShellCompletionMode.argument,
          commandName: 'git',
          words: ['git', 'c'],
          wordIndex: 1,
          workingDirectory: '/Users/depoll/project',
        );

        final suggestions = buildShellHistorySuggestions([
          'git commit',
          'git checkout feature/login',
          'git commit -m "old message"',
          'git cherry-pick abc',
          'git clean -fd',
          'git commit -m "new message"',
          'git cherry-pick abc',
          'git commit -m "new message"',
        ], invocation);

        expect(suggestions.map((suggestion) => suggestion.label), [
          'commit',
          'cherry-pick',
          'clean',
          'checkout',
          'git commit',
          'git cherry-pick abc',
          'git clean -fd',
          'git checkout feature/login',
          'git commit -m "new message"',
          'git commit -m "old message"',
        ]);
        expect(suggestions.first.kind, ShellCompletionSuggestionKind.history);
        expect(suggestions.first.replacementStart, 4);
        expect(suggestions.first.replacementEnd, 5);
        expect(suggestions.first.replacement, 'commit');
        expect(suggestions.first.commitSuffix, ' ');
        expect(suggestions[4].replacementStart, 0);
        expect(suggestions[4].replacementEnd, 5);
        expect(suggestions[4].replacement, 'git commit');
      },
    );

    test('buildShellHistorySuggestions filters encoded command names', () {
      final invocation = _commandInvocation('tmu', '/Users/depoll/project');

      final suggestions = buildShellHistorySuggestions([
        'tmux%20new-session%20-A%20-s%20monkeyssh',
        'tmux new-session -A -s monkeyssh',
        'tmux',
        'tmux',
      ], invocation);

      expect(suggestions.map((suggestion) => suggestion.label), [
        'tmux',
        'tmux new-session -A -s monkeyssh',
      ]);
    });

    test(
      'service reuses host-cached history while fresh connection loads',
      () async {
        final service = ShellCompletionService();
        final firstClient = _MockSshClient();
        final secondClient = _MockSshClient();
        final firstSession = _buildShellCompletionSession(
          firstClient,
          connectionId: 1,
          hostId: 42,
        );
        final secondSession = _buildShellCompletionSession(
          secondClient,
          connectionId: 2,
          hostId: 42,
        );
        const invocation = ShellCompletionInvocation(
          commandLine: 'git c',
          cursorOffset: 5,
          token: 'c',
          tokenStart: 4,
          mode: ShellCompletionMode.argument,
          commandName: 'git',
          words: ['git', 'c'],
          wordIndex: 1,
          workingDirectory: '/Users/depoll/project',
        );

        _stubHistoryExec(firstClient, ['git commit']);
        await service.complete(firstSession, invocation);

        final cachedSuggestions = service.cachedHistorySuggestions(
          secondSession,
          invocation,
        );
        expect(cachedSuggestions.map((suggestion) => suggestion.label), [
          'commit',
          'git commit',
        ]);

        _stubHistoryExec(secondClient, ['git checkout feature/login']);
        final freshSuggestions = await service.complete(
          secondSession,
          invocation,
        );

        expect(freshSuggestions.map((suggestion) => suggestion.label), [
          'checkout',
          'git checkout feature/login',
        ]);
        verify(
          () => secondClient.execute(any(), pty: any(named: 'pty')),
        ).called(1);
      },
    );

    test(
      'runs PowerShell completion and history probes on Windows remotes',
      () async {
        final service = ShellCompletionService();
        final client = _MockSshClient();
        final session = _buildShellCompletionSession(
          client,
          connectionId: 7,
          hostId: 99,
        );
        when(
          () => client.remoteVersion,
        ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');
        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
          invocation,
        ) async {
          final command = invocation.positionalArguments.first as String;
          final script = decodeEncodedPowerShell(command);
          final output = script.contains('ConsoleHost_history')
              ? '__FLUTTY_HISTORY_START__\n__FLUTTY_HISTORY_DONE__\n'
              : 'command\tgit\ncommand\tgitk\n';
          final exec = _MockSshExecSession();
          when(() => exec.stdout).thenAnswer(
            (_) => Stream<Uint8List>.fromIterable([
              Uint8List.fromList(utf8.encode(output)),
            ]),
          );
          when(
            () => exec.stderr,
          ).thenAnswer((_) => const Stream<Uint8List>.empty());
          when(() => exec.done).thenAnswer((_) => Future<void>.value());
          when(exec.close).thenAnswer((_) {});
          return exec;
        });
        const invocation = ShellCompletionInvocation(
          commandLine: 'gi',
          cursorOffset: 2,
          token: 'gi',
          tokenStart: 0,
          mode: ShellCompletionMode.command,
          workingDirectory: r'C:\Users\tester',
        );

        final suggestions = await service.complete(session, invocation);

        expect(suggestions, isNotEmpty);
        expect(
          suggestions.any((suggestion) => suggestion.label == 'git'),
          true,
        );
        final commands = verify(
          () => client.execute(captureAny(), pty: any(named: 'pty')),
        ).captured.cast<String>();
        expect(
          commands.every((command) => command.contains('-EncodedCommand ')),
          isTrue,
        );
      },
    );

    test('uses TabExpansion2 for Windows argument completions', () async {
      final service = ShellCompletionService();
      final client = _MockSshClient();
      final session = _buildShellCompletionSession(
        client,
        connectionId: 8,
        hostId: 100,
      );
      when(
        () => client.remoteVersion,
      ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        final command = invocation.positionalArguments.first as String;
        final script = decodeEncodedPowerShell(command);
        final output = script.contains('HistorySavePath')
            ? '__FLUTTY_HISTORY_START__\n__FLUTTY_HISTORY_DONE__\n'
            : 'argument\tcheckout\nargument\tcherry-pick\n';
        final exec = _MockSshExecSession();
        when(() => exec.stdout).thenAnswer(
          (_) => Stream<Uint8List>.fromIterable([
            Uint8List.fromList(utf8.encode(output)),
          ]),
        );
        when(
          () => exec.stderr,
        ).thenAnswer((_) => const Stream<Uint8List>.empty());
        when(() => exec.done).thenAnswer((_) => Future<void>.value());
        when(exec.close).thenAnswer((_) {});
        return exec;
      });
      const invocation = ShellCompletionInvocation(
        commandLine: 'git ch',
        cursorOffset: 6,
        token: 'ch',
        tokenStart: 4,
        mode: ShellCompletionMode.argument,
        commandName: 'git',
        shellCommand: 'powershell.exe',
        words: ['git', 'ch'],
        wordIndex: 1,
        workingDirectory: r'C:\Users\tester',
      );

      final suggestions = await service.complete(session, invocation);

      expect(suggestions.map((suggestion) => suggestion.label), [
        'git checkout',
        'git cherry-pick',
      ]);
      expect(suggestions.first.replacement, 'checkout');
      final commands = verify(
        () => client.execute(captureAny(), pty: any(named: 'pty')),
      ).captured.cast<String>();
      final completionScript = commands
          .map(decodeEncodedPowerShell)
          .singleWhere((script) => script.contains('TabExpansion2'));
      expect(completionScript, contains(r"$__flShell='powershell'"));
      expect(completionScript, contains(r'TabExpansion2 $__flCommandLine'));
    });

    test(
      'service keeps in-flight history loads scoped to their connection',
      () async {
        final service = ShellCompletionService();
        final firstClient = _MockSshClient();
        final secondClient = _MockSshClient();
        final firstSession = _buildShellCompletionSession(
          firstClient,
          connectionId: 1,
          hostId: 42,
        );
        final secondSession = _buildShellCompletionSession(
          secondClient,
          connectionId: 2,
          hostId: 42,
        );
        const invocation = ShellCompletionInvocation(
          commandLine: 'git c',
          cursorOffset: 5,
          token: 'c',
          tokenStart: 4,
          mode: ShellCompletionMode.argument,
          commandName: 'git',
          words: ['git', 'c'],
          wordIndex: 1,
          workingDirectory: '/Users/depoll/project',
        );

        final pendingExec = _PendingHistoryExec(firstClient);
        final firstFuture = service.complete(firstSession, invocation);
        await pendingExec.started.future;

        _stubHistoryExec(secondClient, ['git checkout feature/login']);
        final secondSuggestions = await service.complete(
          secondSession,
          invocation,
        );

        expect(secondSuggestions.map((suggestion) => suggestion.label), [
          'checkout',
          'git checkout feature/login',
        ]);
        verify(
          () => secondClient.execute(any(), pty: any(named: 'pty')),
        ).called(1);

        await pendingExec.complete(['git commit']);
        final firstSuggestions = await firstFuture;
        expect(firstSuggestions.map((suggestion) => suggestion.label), [
          'commit',
          'git commit',
        ]);
      },
    );

    test('buildShellHistorySuggestions matches patterns around arguments', () {
      const commandLine = 'codex --prompt "try history" --s';
      const invocation = ShellCompletionInvocation(
        commandLine: commandLine,
        cursorOffset: commandLine.length,
        token: '--s',
        tokenStart: 29,
        mode: ShellCompletionMode.argument,
        commandName: 'codex',
        words: ['codex', '--prompt', '"try history"', '--s'],
        wordIndex: 3,
        workingDirectory: '/Users/depoll/project',
      );

      final suggestions = buildShellHistorySuggestions([
        'codex --prompt="do something" --sandbox workspace-write',
      ], invocation);

      expect(suggestions.map((suggestion) => suggestion.label), ['--sandbox']);
      expect(suggestions.single.replacementStart, 29);
      expect(suggestions.single.replacement, '--sandbox');
    });

    test('history remote command reads the preferred shell history file', () {
      const invocation = ShellCompletionInvocation(
        commandLine: 'git c',
        cursorOffset: 5,
        token: 'c',
        tokenStart: 4,
        mode: ShellCompletionMode.argument,
        commandName: 'git',
        shellCommand: '/bin/zsh',
        words: ['git', 'c'],
        wordIndex: 1,
        workingDirectory: '/Users/depoll/project',
      );

      final command = buildShellHistoryRemoteCommand(invocation);

      expect(command, contains("FLUTTY_PREFERRED_SHELL='/bin/zsh'"));
      expect(command, contains(r'tail -n 1200 "$flutty_path"'));
      expect(command, contains(r'${HISTFILE:-$HOME/.zsh_history}'));
      expect(command, contains('__FLUTTY_HISTORY_DONE__'));
    });
  });

  test('escapeShellCompletionToken escapes shell metacharacters', () {
    expect(
      escapeShellCompletionToken('Project Files/(draft)'),
      r'Project\ Files/\(draft\)',
    );
  });

  test('remote command sources startup files through the user shell', () {
    const invocation = ShellCompletionInvocation(
      commandLine: 'gi',
      cursorOffset: 2,
      token: 'gi',
      tokenStart: 0,
      mode: ShellCompletionMode.command,
      shellCommand: '/bin/zsh',
      workingDirectory: '/Users/depoll/project',
    );

    final command = buildShellCompletionRemoteCommand(invocation);

    expect(
      command,
      contains(r'flutty_shell=${FLUTTY_PREFERRED_SHELL:-${SHELL:-}}'),
    );
    expect(command, contains("export FLUTTY_MODE='command' FLUTTY_TOKEN='gi'"));
    expect(command, contains("FLUTTY_COMMAND_LINE='gi'"));
    expect(command, contains('FLUTTY_CURSOR_OFFSET=2'));
    expect(command, contains('FLUTTY_WORD_INDEX=0'));
    expect(command, contains('FLUTTY_COMP_WORDS_ASSIGNMENT='));
    expect(command, contains("FLUTTY_PREFERRED_SHELL='/bin/zsh'"));
    expect(command, contains('FLUTTY_INCLUDE_CD_SHORTCUTS=0'));
    expect(command, contains("FLUTTY_CWD='/Users/depoll/project'"));
    expect(command, contains('FLUTTY_LIMIT=96'));
    expect(command, contains(r'FLUTTY_PROFILE_KIND=$flutty_profile_kind'));
    expect(command, contains(r'source_if_readable "$HOME/.zprofile"'));
    expect(command, contains(r'source_if_readable "$HOME/.zshrc"'));
    expect(command, contains('source_if_readable /etc/bash_completion'));
    expect(command, contains(r'eval "$FLUTTY_COMP_WORDS_ASSIGNMENT"'));
    expect(command, contains(r'_completion_loader "$cmd"'));
    expect(command, contains('emit_dynamic_argument_matches'));
    expect(command, isNot(contains('zpty -b')));
    expect(command, contains(r'''printf '%s\n' "$item"'''));
    expect(command, contains(r'source_if_readable "$HOME/.bash_profile"'));
    expect(command, contains(r'emit_line command "$item" || break'));
    expect(command, contains("FLUTTY_CWD='/Users/depoll/project'"));
  });

  test(
    'interactive zsh command drives zle completions through the active shell',
    () {
      const invocation = ShellCompletionInvocation(
        commandLine: 'git c',
        cursorOffset: 5,
        token: 'c',
        tokenStart: 4,
        mode: ShellCompletionMode.argument,
        commandName: 'git',
        shellCommand: 'zsh',
        words: ['git', 'c'],
        wordIndex: 1,
        workingDirectory: '/Users/depoll/project',
      );

      final command = buildInteractiveZshCompletionRemoteCommand(invocation);
      final input = buildInteractiveZshCompletionInput(invocation);

      expect(command, contains("FLUTTY_PREFERRED_SHELL='zsh'"));
      expect(
        command,
        contains(r'flutty_shell=${FLUTTY_PREFERRED_SHELL:-${SHELL:-}}'),
      );
      expect(command, contains('stty -echo'));
      expect(command, contains("FLUTTY_MODE='argument'"));
      expect(command, contains('flutty-zsh-completion.'));
      expect(command, contains(r'source_if_readable "$HOME/.zshrc"'));
      expect(command, contains('zle -C _flutty_complete'));
      expect(command, contains('bindkey "^I" _flutty_complete'));
      expect(command, contains(r'exec "$flutty_runner" -fi'));
      expect(input, contains(r'source "$FLUTTY_ZSH_COMPLETION_SETUP"'));
      expect(input, contains('git c\t'));
      expect(command, contains('__FLUTTY_ZSH_NATIVE_DONE__'));
      expect(command, contains(r'''printf 'argument\t%s\n' "$item"'''));
    },
  );
}

ShellCompletionInvocation _commandInvocation(String token, String cwd) =>
    ShellCompletionInvocation(
      commandLine: token,
      cursorOffset: token.length,
      token: token,
      tokenStart: 0,
      mode: ShellCompletionMode.command,
      words: [token],
      workingDirectory: cwd,
    );
