import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/agent_session_discovery_service.dart';
import 'package:monkeyssh/domain/services/shell_completion_service.dart';
import 'package:monkeyssh/domain/services/windows_remote_powershell.dart';

/// Decodes a UTF-16LE `-EncodedCommand` payload back to its script text.
String _decodeUtf16le(String base64Text) {
  final bytes = base64.decode(base64Text);
  final buffer = StringBuffer();
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    buffer.writeCharCode(bytes[i] | (bytes[i + 1] << 8));
  }
  return buffer.toString();
}

void main() {
  group('encodePowerShellCommand', () {
    test('round-trips through UTF-16LE base64', () {
      const script = 'Write-Output "café — 1 + 2 = 3"';
      expect(_decodeUtf16le(encodePowerShellCommand(script)), script);
    });

    test(
      'buildWindowsPowerShellCommand wraps an EncodedCommand invocation',
      () {
        const script = "Get-ChildItem 'x'";
        final command = buildWindowsPowerShellCommand(script);
        expect(command, startsWith('powershell -NoProfile -NonInteractive '));
        expect(command, contains('-EncodedCommand '));
        final encoded = command.split('-EncodedCommand ').last;
        expect(_decodeUtf16le(encoded), script);
      },
    );
  });

  group('buildCompactWindowsPowerShellCommand', () {
    test('leaves small scripts unchanged', () {
      const script = "Write-Output 'hello'";
      expect(
        buildCompactWindowsPowerShellCommand(script),
        buildWindowsPowerShellCommand(script),
      );
    });

    test(
      'transport boundary matches encoded size including UTF-16 surrogates',
      () {
        for (final value in ['x', 'é', '🐒']) {
          for (var count = 1380; count <= 2820; count++) {
            final script = value * count;
            final encoded = buildWindowsPowerShellCommand(script);
            final compact = buildCompactWindowsPowerShellCommand(script);
            if (encoded.length < 7500) {
              expect(compact, encoded);
            } else {
              expect(compact, contains('GZipStream'));
            }
          }
        }
      },
    );

    test('round-trips large Unicode scripts without shell interpolation', () {
      final script = "Write-Output 'café 🐒';\n" * 2000;
      final command = buildCompactWindowsPowerShellCommand(script);
      expect(command.length, lessThan(7500));
      expect(command, isNot(contains(r'$')));
      expect(command, isNot(contains('`')));
      final payload = RegExp(
        r"FromBase64String\('([^']+)'\)",
      ).firstMatch(command)![1]!;
      expect(utf8.decode(gzip.decode(base64.decode(payload))), script);
    });
  });

  test('profile probes suppress progress before loading modules', () {
    expect(
      powerShellProfilePathPreamble,
      startsWith(r"$ProgressPreference = 'SilentlyContinue';"),
    );
  });

  test(
    'Windows PATH refresh discovers new user entries without duplicates',
    () async {
      // Exercise the exact refresh fragment without loading real user profiles or
      // changing the registry. The literal represents a freshly read User PATH.
      final refresh = powerShellProfilePathPreamble
          .split(r'$__flProfilePaths')
          .first
          .replaceFirst(
            "[Environment]::GetEnvironmentVariable('Path','User')",
            r"'C:\existing;%LOCALAPPDATA%\agy\bin;;C:\new tools'",
          );
      final script =
          r"$env:Path='C:\existing';$env:LOCALAPPDATA='C:\Local';" +
          refresh +
          refresh +
          r'[Console]::WriteLine($env:Path);';
      final command = buildWindowsPowerShellCommand(script);
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        command,
      ]).timeout(const Duration(seconds: 20));
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        (result.stdout as String).trim(),
        r'C:\existing;C:\Local\agy\bin;C:\new tools',
      );
    },
    skip: !Platform.isWindows,
  );

  for (final large in [false, true]) {
    test(
      'Windows output is plain text and retains errors, large=$large',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'powershell-output-',
        );
        addTearDown(() => root.delete(recursive: true));
        // No user profiles or real installers: exercise small and large scripts
        // with the same progress, success, PowerShell error and native error streams.
        final script =
            r'''
$ProgressPreference = 'SilentlyContinue';
Write-Progress -Activity 'Preparing modules for first use' -Status 'fixture';
Write-Output 'installer stdout';
Write-Error 'installer PowerShell error' -ErrorAction Continue;
[Console]::Error.WriteLine('installer native stderr');
exit 7;
''' +
            (large ? '# padding\n' * 1500 : '');
        final command = buildCompactWindowsPowerShellCommand(
          script,
          plainTextOutput: true,
        );
        expect(command, contains('-OutputFormat Text'));
        expect(command, contains('GZipStream'));
        final batch = File('${root.path}/probe.cmd');
        await batch.writeAsString('@echo off\r\n$command\r\n');
        final result = await Process.run('cmd.exe', [
          '/d',
          '/c',
          batch.path,
        ]).timeout(const Duration(seconds: 20));
        expect(result.exitCode, 7);
        expect(result.stdout, contains('installer stdout'));
        expect(result.stderr, contains('installer PowerShell error'));
        expect(result.stderr, contains('installer native stderr'));
        final output = '${result.stdout}\n${result.stderr}';
        expect(output, isNot(contains('#< CLIXML')));
        expect(output, isNot(contains('<Objs')));
        expect(output, isNot(contains('<PR ')));
      },
      skip: !Platform.isWindows,
    );
  }

  group('powerShellSingleQuote', () {
    test('wraps in single quotes and doubles embedded quotes', () {
      expect(powerShellSingleQuote('plain'), "'plain'");
      expect(powerShellSingleQuote("it's"), "'it''s'");
    });

    test('doubles every PowerShell single-quote variant (injection-safe)', () {
      // U+2018/2019/201A/201B are also single-quote delimiters in PowerShell's
      // tokenizer; a lone one would otherwise let the remainder execute.
      expect(powerShellSingleQuote('a\u2019b'), "'a\u2019\u2019b'");
      expect(powerShellSingleQuote('a\u2018b'), "'a\u2018\u2018b'");
      expect(powerShellSingleQuote('a\u201ab'), "'a\u201a\u201ab'");
      expect(powerShellSingleQuote('a\u201bb'), "'a\u201b\u201bb'");
      final payload = powerShellSingleQuote('\u2019; Write-Output x; \u2018');
      expect(payload, "'\u2019\u2019; Write-Output x; \u2018\u2018'");
    });
  });

  group('windowsSnapshotPathBatches', () {
    test('bounds each batch by path-length and count', () {
      final paths = List.generate(
        60,
        (i) =>
            'C:/Users/x/.codex/sessions/2026/07/05/rollout-$i-'
            '${'a' * 40}.jsonl',
      );
      final batches = windowsSnapshotPathBatches(paths);
      expect(batches.length, greaterThan(1));
      for (final batch in batches) {
        expect(batch.length, lessThanOrEqualTo(40));
        final chars = batch.fold<int>(0, (sum, p) => sum + p.length + 4);
        expect(chars, lessThanOrEqualTo(1800));
      }
      expect(batches.expand((b) => b).toList(), paths);
    });

    test('keeps a single over-long path in its own batch', () {
      final paths = ['C:/${'a' * 3000}.jsonl'];
      final batches = windowsSnapshotPathBatches(paths);
      expect(batches, hasLength(1));
      expect(batches.first, paths);
    });
  });

  group('windowsListNewestFilesScript', () {
    test('filters by name via Where-Object, not -Include (5.1 safe)', () {
      final script = windowsListNewestFilesScript(
        relativeRoot: '.codex/sessions',
        includeGlobs: const ['rollout-*.jsonl'],
        limit: 120,
      );
      // -Include is silently ignored with -LiteralPath on Windows PowerShell
      // 5.1, so it must never be used for name filtering.
      expect(script, isNot(contains('-Include ')));
      expect(script, contains('Get-ChildItem -LiteralPath'));
      expect(script, contains(r"$__flN -like 'rollout-*.jsonl'"));
      expect(script, contains('Sort-Object LastWriteTimeUtc -Descending'));
      expect(script, contains('Select-Object -First 120'));
      expect(script, contains("'.codex/sessions'"));
      // Emits forward-slash paths.
      expect(script, contains(r"-replace '\\','/'"));
    });

    test('includes path-like filters when provided', () {
      final script = windowsListNewestFilesScript(
        relativeRoot: '.gemini/tmp',
        includeGlobs: const ['session-*.json', 'session-*.jsonl'],
        limit: 40,
        pathLikeFilters: const ['*/chats/*'],
      );
      expect(script, contains(r"$__flN -like 'session-*.json'"));
      expect(script, contains(r"$__flN -like 'session-*.jsonl'"));
      expect(script, contains(r"$__flFn -like '*/chats/*'"));
    });

    test('can search app-data roots and additional relative roots', () {
      final script = windowsListNewestFilesScript(
        relativeRoot: '.local/share/opencode/storage/session',
        additionalRelativeRoots: const ['opencode/storage/session'],
        includeGlobs: const ['*.json'],
        limit: 24,
        rootEnvironmentVariables: const [
          'USERPROFILE',
          'LOCALAPPDATA',
          'APPDATA',
        ],
      );

      expect(script, contains(r'$env:USERPROFILE'));
      expect(script, contains(r'$env:LOCALAPPDATA'));
      expect(script, contains(r'$env:APPDATA'));
      expect(script, contains("'.local/share/opencode/storage/session'"));
      expect(script, contains("'opencode/storage/session'"));
      expect(script, contains(r'$__flSeen.ContainsKey($__flPath)'));
    });

    test('uses a non-empty environment override instead of fallback roots', () {
      final script = windowsListNewestFilesScript(
        relativeRoot: '.grok/sessions',
        includeGlobs: const ['summary.json'],
        limit: 40,
        overrideRootEnvironmentVariable: 'GROK_HOME',
        overrideRelativeRoot: 'sessions',
      );

      expect(script, contains(r'$__flRootBases=@($env:USERPROFILE);'));
      expect(script, contains(r'$__flOverrideBase=$env:GROK_HOME;'));
      expect(
        script,
        contains(
          r'if(![string]::IsNullOrWhiteSpace([string]$__flOverrideBase)){',
        ),
      );
      expect(script, contains(r"$__flRelRoots=@('sessions');"));
      expect(script, contains(r'$__flRootBases=@($__flOverrideBase)}'));
    });
  });

  group('windowsFindFilesByNameScript', () {
    test('matches each exact name via Where-Object', () {
      final script = windowsFindFilesByNameScript(
        relativeRoot: '.claude/projects',
        names: const ['abc-123.jsonl', 'def-456.jsonl'],
      );
      expect(script, isNot(contains('-Include ')));
      expect(script, contains(r"$__flN -like 'abc-123.jsonl'"));
      expect(script, contains(r"$__flN -like 'def-456.jsonl'"));
    });
  });

  group('windowsTailFileScript', () {
    test('reads the last N lines of a USERPROFILE-relative file', () {
      final script = windowsTailFileScript(
        relativePath: '.claude/history.jsonl',
        lines: 200,
      );
      expect(script, contains(r'Join-Path $env:USERPROFILE'));
      expect(script, contains("'.claude/history.jsonl'"));
      expect(
        script,
        contains(
          r'Get-Content -LiteralPath $__flPath -Tail 200 -Encoding UTF8',
        ),
      );
    });
  });

  group('windowsOpenCodeSessionListScript', () {
    test('runs the native CLI session list command when available', () {
      final script = windowsOpenCodeSessionListScript(12);

      expect(script, contains('Get-Command opencode'));
      expect(script, contains('opencode session list --format json -n 12'));
      expect(script, contains(r'$__flOut.Append([string]$__flL)'));
    });
  });

  group('windowsFileSnapshotScript', () {
    test('emits the SEP-delimited snapshot format', () {
      final script = windowsFileSnapshotScript(const ['C:/x/y.jsonl']);
      expect(script, contains(r'$SEP=[char]0x1f'));
      expect(script, contains("'C:/x/y.jsonl'"));
      expect(script, contains('ReadAllBytes'));
      expect(script, contains('ToBase64String'));
    });

    test('reads the first N bytes for maxBytes', () {
      final script = windowsFileSnapshotScript(const [
        'C:/x/y.json',
      ], maxBytes: 65536);
      expect(script, contains('New-Object byte[] 65536'));
      expect(script, contains(r'$fs.Read($buf,0,$buf.Length)'));
    });

    test('reads head or tail lines for maxLines', () {
      final head = windowsFileSnapshotScript(const [
        'C:/x/y.jsonl',
      ], maxLines: 80);
      expect(head, contains('-TotalCount 80 -Encoding UTF8'));
      final tail = windowsFileSnapshotScript(
        const ['C:/x/y.jsonl'],
        maxLines: 80,
        tail: true,
      );
      expect(tail, contains('-Tail 80 -Encoding UTF8'));
    });
  });

  group('buildWindowsShellCompletionScript', () {
    test('command mode queries Get-Command with the token', () {
      const invocation = ShellCompletionInvocation(
        commandLine: 'gi',
        cursorOffset: 2,
        token: 'gi',
        tokenStart: 0,
        mode: ShellCompletionMode.command,
        workingDirectory: r'C:\Users\x',
      );
      final script = buildWindowsShellCompletionScript(invocation);
      expect(script, contains(r"$__flMode='command'"));
      expect(script, contains(r"$__flToken='gi'"));
      expect(script, contains('Get-Command -Name'));
      expect(script, contains(r"__flEmit 'command' $__n"));
    });

    test('argument mode uses native PowerShell TabExpansion2', () {
      const invocation = ShellCompletionInvocation(
        commandLine: 'git ch',
        cursorOffset: 6,
        token: 'ch',
        tokenStart: 4,
        mode: ShellCompletionMode.argument,
        commandName: 'git',
        shellCommand: 'PWSH.EXE',
        words: ['git', 'ch'],
        wordIndex: 1,
        workingDirectory: r'C:\Users\x',
      );
      final script = buildWindowsShellCompletionScript(invocation);
      expect(script, contains(r"$__flMode='argument'"));
      expect(script, contains(r"$__flCommandLine='git ch'"));
      expect(script, contains(r'$__flCursorOffset=6'));
      expect(script, contains(r"$__flShell='pwsh'"));
      expect(script, contains('Get-Command TabExpansion2'));
      expect(script, contains(r'TabExpansion2 $__flCommandLine'));
      expect(script, contains(r'$__m.CompletionText'));
      expect(script, contains(r'__flEmit $__flKind $__flText'));
      expect(script, isNot(contains('(__flTryTabExpansion)){return}')));
    });

    test('argument mode does not use PowerShell completers for cmd panes', () {
      const invocation = ShellCompletionInvocation(
        commandLine: 'git ch',
        cursorOffset: 6,
        token: 'ch',
        tokenStart: 4,
        mode: ShellCompletionMode.argument,
        commandName: 'git',
        shellCommand: 'cmd.exe',
        words: ['git', 'ch'],
        wordIndex: 1,
        workingDirectory: r'C:\Users\x',
      );
      final script = buildWindowsShellCompletionScript(invocation);
      expect(script, contains(r"$__flShell='cmd'"));
      expect(script, contains(r"if($__flShell -eq 'cmd'){return $false}"));
    });

    for (final shell in ['cmd.exe', 'pwsh.exe']) {
      test('$shell argument fallback emits directories and regular files', () {
        final invocation = buildShellCompletionInvocation(
          terminalText: r'C:\Users\x>type rea',
          terminalCursorOffset: r'C:\Users\x>type rea'.length,
          promptPrefix: r'C:\Users\x>',
          shellCommand: shell,
          workingDirectory: r'C:\Users\x',
        )!;
        expect(invocation.mode, ShellCompletionMode.argument);
        final script = buildWindowsShellCompletionScript(invocation);
        expect(script, contains(r"$__flMode='argument'"));
        expect(script, contains(r"$__flToken='rea'"));
        expect(script, contains(r"if($__flShell -eq 'cmd'){return $false}"));
        expect(script, contains('Get-ChildItem -LiteralPath'));
        expect(script, contains(r"__flEmit 'directory' $__val"));
        expect(
          script,
          contains(
            r"elseif($__flMode -ne 'directory'){if(!(__flEmit 'file' $__val)){break}}",
          ),
        );
      });
    }

    test('escapes wildcard tokens and handles drive roots', () {
      const invocation = ShellCompletionInvocation(
        commandLine: 'type C:/Us',
        cursorOffset: 10,
        token: 'C:/Us',
        tokenStart: 5,
        mode: ShellCompletionMode.argument,
        workingDirectory: r'C:\Users\x',
      );
      final script = buildWindowsShellCompletionScript(invocation);
      // Wildcard chars in the token must be escaped before -like/-Name.
      expect(script, contains('WildcardPattern]::Escape'));
      expect(script, isNot(contains(r"-like ($__flBase+'*')")));
      // A drive-letter directory must keep its trailing slash for Get-ChildItem.
      expect(script, contains(r"$__flDir -match '^[A-Za-z]:$'"));
    });
  });

  group('escapeWindowsCompletionToken', () {
    test('quotes only values with spaces or metacharacters', () {
      expect(escapeWindowsCompletionToken('git'), 'git');
      expect(escapeWindowsCompletionToken('src/main.dart'), 'src/main.dart');
      expect(
        escapeWindowsCompletionToken('C:/Program Files'),
        '"C:/Program Files"',
      );
      expect(escapeWindowsCompletionToken(''), '""');
    });
  });

  group('windows working-directory + resume', () {
    test('normalizes Windows working directories for comparison', () {
      expect(
        normalizeWorkingDirectoryForComparison(r'C:\Proj\App'),
        normalizeWorkingDirectoryForComparison('C:/proj/app'),
      );
      expect(normalizeWorkingDirectoryForComparison('/C:/Proj'), 'c:/proj');
      // POSIX paths keep their case.
      expect(
        normalizeWorkingDirectoryForComparison('/home/User/Proj'),
        '/home/User/Proj',
      );
    });

    test('buildResumeCommand omits cd for Windows working directories', () {
      final service = AgentSessionDiscoveryService();
      final windows = ToolSessionInfo(
        toolName: 'Codex',
        sessionId: 's',
        workingDirectory: r'C:\proj',
        summary: 'x',
        lastActive: DateTime(2026),
      );
      expect(service.buildResumeCommand(windows), isNot(contains('cd ')));
      final posix = ToolSessionInfo(
        toolName: 'Codex',
        sessionId: 's',
        workingDirectory: '/home/u/proj',
        summary: 'x',
        lastActive: DateTime(2026),
      );
      expect(service.buildResumeCommand(posix), startsWith('cd '));
    });
  });

  group('buildWindowsShellHistoryScript', () {
    test('reads PSReadLine history and emits bash-sourced lines', () {
      const invocation = ShellCompletionInvocation(
        commandLine: '',
        cursorOffset: 0,
        token: '',
        tokenStart: 0,
        mode: ShellCompletionMode.command,
        shellCommand: 'powershell.exe',
        workingDirectory: r'C:\Users\x',
      );
      final script = buildWindowsShellHistoryScript(invocation);
      expect(script, contains(r"$__flShell='powershell'"));
      expect(script, contains('DefaultShell'));
      expect(script, contains(r"if($__flShell -ne 'cmd')"));
      expect(script, contains('Get-PSReadLineOption'));
      expect(script, contains('HistorySavePath'));
      expect(script, contains('ConsoleHost_history.txt'));
      expect(script, contains(r'Microsoft\PowerShell\PSReadLine'));
      expect(script, contains("Append('__FLUTTY_HISTORY_START__')"));
      expect(script, contains("Append('__FLUTTY_HISTORY_DONE__')"));
      expect(script, contains("Append('bash')"));
      expect(
        script,
        contains(
          r'Get-Content -LiteralPath $__flHist -Tail 1200 -Encoding UTF8',
        ),
      );
    });

    test('detects cmd shells before deciding whether to read PSReadLine', () {
      const invocation = ShellCompletionInvocation(
        commandLine: '',
        cursorOffset: 0,
        token: '',
        tokenStart: 0,
        mode: ShellCompletionMode.command,
        shellCommand: 'cmd.exe',
        workingDirectory: r'C:\Users\x',
      );
      final script = buildWindowsShellHistoryScript(invocation);
      expect(script, contains(r"$__flShell='cmd'"));
      expect(script, contains(r"if($__flShell -ne 'cmd')"));
    });
  });
}
