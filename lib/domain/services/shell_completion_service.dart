import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'diagnostics_log_service.dart';
import 'remote_file_service.dart' show shellEscapePosix;
import 'ssh_exec_queue.dart';
import 'ssh_service.dart';
import 'windows_remote_powershell.dart';

final _urlEncodedShellWhitespacePattern = RegExp(
  '%(?:09|0a|0d|20)',
  caseSensitive: false,
);

/// Type of completion being requested from the side-channel shell.
enum ShellCompletionMode {
  /// Complete the first command word.
  command,

  /// Complete a command argument through installed shell completions.
  argument,

  /// Complete only directories.
  directory,
}

/// Type of a single shell completion suggestion.
enum ShellCompletionSuggestionKind {
  /// A command pattern from shell history.
  history,

  /// A command name.
  command,

  /// A directory path.
  directory,

  /// A regular file path.
  file,
}

/// Completion context resolved from the visible terminal prompt.
class ShellCompletionInvocation {
  /// Creates a shell completion invocation.
  const ShellCompletionInvocation({
    required this.commandLine,
    required this.cursorOffset,
    required this.token,
    required this.tokenStart,
    required this.mode,
    required this.workingDirectory,
    this.commandName,
    this.shellCommand,
    this.words = const <String>[],
    this.wordIndex = 0,
    this.maxSuggestions = 24,
  });

  /// Current command text without the prompt.
  final String commandLine;

  /// Cursor offset in [commandLine].
  final int cursorOffset;

  /// Current token before the cursor.
  final String token;

  /// Token start offset in [commandLine].
  final int tokenStart;

  /// Completion mode.
  final ShellCompletionMode mode;

  /// Parsed command name, when the cursor is in an argument.
  final String? commandName;

  /// Foreground shell command to use for shell-native completion, when known.
  final String? shellCommand;

  /// Parsed shell words before or at the cursor.
  final List<String> words;

  /// Index of [token] in [words], or the next word after trailing whitespace.
  final int wordIndex;

  /// Remote working directory to run completion lookups from.
  final String? workingDirectory;

  /// Maximum number of suggestions to keep.
  final int maxSuggestions;
}

/// A completion candidate that can be applied to the terminal line.
class ShellCompletionSuggestion {
  /// Creates a shell completion suggestion.
  const ShellCompletionSuggestion({
    required this.label,
    required this.replacement,
    required this.replacementStart,
    required this.replacementEnd,
    required this.kind,
    this.commitSuffix = '',
  });

  /// Text shown in the popup.
  final String label;

  /// Text to type after deleting [replacementStart] through [replacementEnd].
  final String replacement;

  /// Start offset in the command line to replace.
  final int replacementStart;

  /// End offset in the command line to replace.
  final int replacementEnd;

  /// Suggestion kind.
  final ShellCompletionSuggestionKind kind;

  /// Text to append after [replacement], such as a trailing command space.
  final String commitSuffix;
}

/// Resolves shell completions over a short-lived SSH exec side channel.
class ShellCompletionService {
  /// Creates a shell completion service.
  ShellCompletionService({
    this.timeout = const Duration(milliseconds: 1500),
    this.interactiveZshTimeout = const Duration(milliseconds: 1000),
    this.historyTimeout = const Duration(milliseconds: 800),
    this.maxOutputChars = 12000,
    this.maxHistoryOutputChars = 80000,
    this.cacheTtl = const Duration(seconds: 2),
    this.historyCacheTtl = const Duration(minutes: 5),
  });

  /// Maximum time to wait for a completion exec.
  final Duration timeout;

  /// Maximum time to wait for the PTY-backed zsh completion attempt.
  final Duration interactiveZshTimeout;

  /// Maximum time to wait while loading shell history.
  final Duration historyTimeout;

  /// Maximum stdout characters to buffer from the remote helper.
  final int maxOutputChars;

  /// Maximum stdout characters to buffer from the remote history helper.
  final int maxHistoryOutputChars;

  /// How long exact completion requests can be reused.
  final Duration cacheTtl;

  /// How long shell history snapshots can be reused.
  final Duration historyCacheTtl;

  final Map<String, _ShellCompletionCacheEntry> _cache =
      <String, _ShellCompletionCacheEntry>{};
  final Map<String, Future<List<ShellCompletionSuggestion>>> _inFlight =
      <String, Future<List<ShellCompletionSuggestion>>>{};
  final Map<String, _ShellHistoryCacheEntry> _historyCache =
      <String, _ShellHistoryCacheEntry>{};
  final Map<String, Future<List<_PreparedShellHistoryCommand>>>
  _historyInFlight = <String, Future<List<_PreparedShellHistoryCommand>>>{};

  /// Runs a completion query for [invocation].
  Future<List<ShellCompletionSuggestion>> complete(
    SshSession session,
    ShellCompletionInvocation invocation,
  ) async {
    final staticSuggestions = buildShellCompletionStaticSuggestions(invocation);
    if (staticSuggestions != null && invocation.token.isEmpty) {
      return staticSuggestions;
    }
    final allowShellFallback = invocation.token.isNotEmpty;

    final cacheKey = _shellCompletionCacheKey(session, invocation);
    final cached = _cache[cacheKey];
    final now = DateTime.now();
    if (cached != null && now.difference(cached.createdAt) <= cacheTtl) {
      return cached.suggestions;
    }

    final pending = _inFlight[cacheKey];
    if (pending != null) {
      return pending;
    }

    final future = _completeUncached(
      session,
      invocation,
      staticSuggestions,
      allowShellFallback: allowShellFallback,
    );
    _inFlight[cacheKey] = future;
    try {
      final suggestions = await future;
      _cache[cacheKey] = _ShellCompletionCacheEntry(
        createdAt: DateTime.now(),
        suggestions: List<ShellCompletionSuggestion>.unmodifiable(suggestions),
      );
      _trimCompletionCache(now);
      return suggestions;
    } finally {
      _inFlight.remove(cacheKey)?.ignore();
    }
  }

  /// Starts loading shell history for [invocation] without waiting for results.
  void primeHistory(SshSession session, ShellCompletionInvocation invocation) {
    unawaited(
      _loadShellHistory(session, invocation).onError<Object>((error, _) {
        DiagnosticsLogService.instance.debug(
          'shell_completion',
          'history_prime_unavailable',
          fields: {
            'connectionId': session.connectionId,
            'errorType': error.runtimeType,
          },
        );
        return const <_PreparedShellHistoryCommand>[];
      }),
    );
  }

  /// Returns host-cached shell history suggestions without opening SSH execs.
  List<ShellCompletionSuggestion> cachedHistorySuggestions(
    SshSession session,
    ShellCompletionInvocation invocation,
  ) {
    final cached = _validCachedHistory(session, invocation);
    if (cached == null) {
      return const <ShellCompletionSuggestion>[];
    }
    return _buildPreparedShellHistorySuggestions(cached.commands, invocation);
  }

  Future<List<ShellCompletionSuggestion>> _completeUncached(
    SshSession session,
    ShellCompletionInvocation invocation,
    List<ShellCompletionSuggestion>? staticSuggestions, {
    required bool allowShellFallback,
  }) async {
    final startedAt = DateTime.now();
    final historySuggestions = await _completeFromHistory(session, invocation);
    if (historySuggestions.isNotEmpty) {
      final duration = DateTime.now().difference(startedAt);
      if (duration >= const Duration(milliseconds: 350)) {
        DiagnosticsLogService.instance.debug(
          'shell_completion',
          'history_request_complete',
          fields: {
            'connectionId': session.connectionId,
            'mode': invocation.mode.name,
            'durationMs': duration.inMilliseconds,
            'suggestionCount': historySuggestions.length,
          },
        );
      }
      return historySuggestions;
    }
    if (!allowShellFallback) {
      return const <ShellCompletionSuggestion>[];
    }

    final output = await session
        .runQueuedExec(() => _runCompletionCommand(session, invocation))
        .onError<Object>((error, stackTrace) {
          if (staticSuggestions != null) {
            return '';
          }
          Error.throwWithStackTrace(error, stackTrace);
        });
    final suggestions = parseShellCompletionOutput(
      output,
      invocation,
      windows: session.remoteIsWindows,
    );
    final resolvedSuggestions = suggestions.isEmpty && staticSuggestions != null
        ? staticSuggestions
        : suggestions;
    final duration = DateTime.now().difference(startedAt);
    if (duration >= const Duration(milliseconds: 350)) {
      DiagnosticsLogService.instance.debug(
        'shell_completion',
        'request_complete',
        fields: {
          'connectionId': session.connectionId,
          'mode': invocation.mode.name,
          'durationMs': duration.inMilliseconds,
          'suggestionCount': resolvedSuggestions.length,
        },
      );
    }
    return resolvedSuggestions;
  }

  Future<List<ShellCompletionSuggestion>> _completeFromHistory(
    SshSession session,
    ShellCompletionInvocation invocation,
  ) async {
    try {
      final history = await _loadShellHistory(session, invocation);
      return _buildPreparedShellHistorySuggestions(history, invocation);
    } on Object catch (error) {
      DiagnosticsLogService.instance.debug(
        'shell_completion',
        'history_unavailable',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return const <ShellCompletionSuggestion>[];
    }
  }

  Future<List<_PreparedShellHistoryCommand>> _loadShellHistory(
    SshSession session,
    ShellCompletionInvocation invocation,
  ) async {
    final key = _shellHistoryCacheKey(session, invocation);
    final now = DateTime.now();
    final cached = _historyCache[key];
    if (cached != null &&
        cached.connectionId == session.connectionId &&
        now.difference(cached.createdAt) <= historyCacheTtl) {
      return cached.commands;
    }

    final inFlightKey = _shellHistoryInFlightKey(session, invocation);
    final pending = _historyInFlight[inFlightKey];
    if (pending != null) {
      return pending;
    }

    final future = session.runQueuedExec(
      () async => _prepareShellHistoryCommands(
        await _runHistoryCommand(session, invocation),
      ),
    );
    _historyInFlight[inFlightKey] = future;
    try {
      final commands = await future;
      _historyCache[key] = _ShellHistoryCacheEntry(
        createdAt: DateTime.now(),
        connectionId: session.connectionId,
        commands: List<_PreparedShellHistoryCommand>.unmodifiable(commands),
      );
      _trimHistoryCache(now);
      return commands;
    } finally {
      _historyInFlight.remove(inFlightKey)?.ignore();
    }
  }

  _ShellHistoryCacheEntry? _validCachedHistory(
    SshSession session,
    ShellCompletionInvocation invocation,
  ) {
    final cached = _historyCache[_shellHistoryCacheKey(session, invocation)];
    if (cached == null ||
        DateTime.now().difference(cached.createdAt) > historyCacheTtl) {
      return null;
    }
    return cached;
  }

  Future<String> _collectStdout(
    SSHSession exec, {
    required int outputLimit,
    required Duration timeout,
    Future<void> Function()? writeInput,
  }) async {
    try {
      final stdout = StringBuffer();
      final stdoutFuture = exec.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .forEach((chunk) {
            if (stdout.length >= outputLimit) {
              return;
            }
            final remaining = outputLimit - stdout.length;
            stdout.write(
              chunk.length <= remaining ? chunk : chunk.substring(0, remaining),
            );
          });
      final stderrFuture = exec.stderr.drain<void>();
      await Future.wait<void>([
        stdoutFuture,
        stderrFuture,
        exec.done,
        if (writeInput != null) writeInput(),
      ]).timeout(timeout);
      return stdout.toString();
    } finally {
      exec.close();
    }
  }

  Future<List<String>> _runHistoryCommand(
    SshSession session,
    ShellCompletionInvocation invocation,
  ) async {
    final command = session.remoteIsWindows
        ? buildWindowsPowerShellCommand(
            buildWindowsShellHistoryScript(invocation),
          )
        : buildShellHistoryRemoteCommand(invocation);
    try {
      final exec = await openSshExec(session.execute(command), historyTimeout);
      return parseShellHistoryOutput(
        await _collectStdout(
          exec,
          outputLimit: maxHistoryOutputChars,
          timeout: historyTimeout,
        ),
      );
    } on TimeoutException {
      DiagnosticsLogService.instance.debug(
        'shell_completion',
        'history_timeout',
        fields: {
          'connectionId': session.connectionId,
          'timeoutMs': historyTimeout.inMilliseconds,
        },
      );
      rethrow;
    }
  }

  Future<String> _runCompletionCommand(
    SshSession session,
    ShellCompletionInvocation invocation,
  ) async {
    if (!session.remoteIsWindows &&
        _shouldTryInteractiveZshCompletion(invocation)) {
      try {
        final result = await _runInteractiveZshCompletionCommand(
          session,
          invocation,
        );
        if (result.didComplete) {
          return result.output;
        }
      } on Object catch (error) {
        DiagnosticsLogService.instance.debug(
          'shell_completion',
          'interactive_zsh_unavailable',
          fields: {
            'connectionId': session.connectionId,
            'errorType': error.runtimeType,
          },
        );
      }
    }

    final command = session.remoteIsWindows
        ? buildWindowsPowerShellCommand(
            buildWindowsShellCompletionScript(invocation),
          )
        : buildShellCompletionRemoteCommand(invocation);
    try {
      final exec = await openSshExec(session.execute(command), timeout);
      return await _collectStdout(
        exec,
        outputLimit: maxOutputChars,
        timeout: timeout,
      );
    } on TimeoutException {
      DiagnosticsLogService.instance.warning(
        'shell_completion',
        'request_timeout',
        fields: {
          'connectionId': session.connectionId,
          'mode': invocation.mode.name,
          'timeoutMs': timeout.inMilliseconds,
        },
      );
      rethrow;
    }
  }

  Future<_InteractiveCompletionResult> _runInteractiveZshCompletionCommand(
    SshSession session,
    ShellCompletionInvocation invocation,
  ) async {
    final command = buildInteractiveZshCompletionRemoteCommand(invocation);
    final exec = await openSshExec(
      session.execute(command, pty: const SSHPtyConfig()),
      interactiveZshTimeout,
    );
    final output = await _collectStdout(
      exec,
      outputLimit: maxOutputChars,
      timeout: interactiveZshTimeout,
      writeInput: () async {
        exec.write(utf8.encode(buildInteractiveZshCompletionInput(invocation)));
        await exec.stdin.close();
      },
    );
    return _InteractiveCompletionResult(
      output: output,
      didComplete: _containsInteractiveZshCompletionDoneMarker(output),
    );
  }

  void _trimCompletionCache(DateTime now) {
    _cache.removeWhere(
      (key, value) => now.difference(value.createdAt) > cacheTtl,
    );
    const maxEntries = 64;
    if (_cache.length <= maxEntries) {
      return;
    }
    final overflow = _cache.length - maxEntries;
    final keysToRemove = _cache.keys.take(overflow).toList(growable: false);
    for (final key in keysToRemove) {
      _cache.remove(key);
    }
  }

  void _trimHistoryCache(DateTime now) {
    _historyCache.removeWhere(
      (key, value) => now.difference(value.createdAt) > historyCacheTtl,
    );
    const maxEntries = 24;
    if (_historyCache.length <= maxEntries) {
      return;
    }
    final overflow = _historyCache.length - maxEntries;
    final keysToRemove = _historyCache.keys
        .take(overflow)
        .toList(growable: false);
    for (final key in keysToRemove) {
      _historyCache.remove(key);
    }
  }
}

class _ShellCompletionCacheEntry {
  const _ShellCompletionCacheEntry({
    required this.createdAt,
    required this.suggestions,
  });

  final DateTime createdAt;
  final List<ShellCompletionSuggestion> suggestions;
}

class _InteractiveCompletionResult {
  const _InteractiveCompletionResult({
    required this.output,
    required this.didComplete,
  });

  final String output;
  final bool didComplete;
}

class _ShellHistoryCacheEntry {
  const _ShellHistoryCacheEntry({
    required this.createdAt,
    required this.connectionId,
    required this.commands,
  });

  final DateTime createdAt;
  final int connectionId;
  final List<_PreparedShellHistoryCommand> commands;
}

class _PreparedShellHistoryCommand {
  const _PreparedShellHistoryCommand({
    required this.command,
    required this.patternTokens,
    required this.tokenCount,
  });

  final String command;
  final List<String>? patternTokens;
  final int tokenCount;
}

String _shellCompletionCacheKey(
  SshSession session,
  ShellCompletionInvocation invocation,
) => [
  session.connectionId,
  invocation.mode.name,
  invocation.workingDirectory ?? '',
  invocation.shellCommand ?? '',
  invocation.commandLine,
  invocation.cursorOffset,
  invocation.tokenStart,
  invocation.token,
  invocation.maxSuggestions,
].join('\u001f');

String _shellHistoryCacheKey(
  SshSession session,
  ShellCompletionInvocation invocation,
) => [session.hostId, invocation.shellCommand ?? ''].join('\u001f');

String _shellHistoryInFlightKey(
  SshSession session,
  ShellCompletionInvocation invocation,
) => [session.connectionId, invocation.shellCommand ?? ''].join('\u001f');

/// Provider for [ShellCompletionService].
final shellCompletionServiceProvider = Provider<ShellCompletionService>(
  (ref) => ShellCompletionService(),
);

/// Builds a completion invocation from a rendered terminal line snapshot.
ShellCompletionInvocation? buildShellCompletionInvocation({
  required String terminalText,
  required int terminalCursorOffset,
  String? promptPrefix,
  String? workingDirectory,
  String? shellCommand,
  int maxSuggestions = 24,
}) {
  final commandSnapshot = resolveShellCompletionCommandLine(
    terminalText: terminalText,
    terminalCursorOffset: terminalCursorOffset,
    promptPrefix: promptPrefix,
  );
  final invocation = _buildShellCompletionInvocationFromCommandSnapshot(
    commandSnapshot: commandSnapshot,
    workingDirectory: workingDirectory,
    shellCommand: shellCommand,
    maxSuggestions: maxSuggestions,
  );
  if (promptPrefix == null ||
      commandSnapshot == null ||
      commandSnapshot.commandLine.trim().isEmpty) {
    return invocation;
  }

  final fallbackSnapshot = resolveShellCompletionCommandLine(
    terminalText: terminalText,
    terminalCursorOffset: terminalCursorOffset,
  );
  if (fallbackSnapshot == null ||
      fallbackSnapshot.cursorOffset <= commandSnapshot.cursorOffset ||
      terminalCursorOffset - fallbackSnapshot.cursorOffset <= 0) {
    return invocation;
  }

  final fallbackInvocation = _buildShellCompletionInvocationFromCommandSnapshot(
    commandSnapshot: fallbackSnapshot,
    workingDirectory: workingDirectory,
    shellCommand: shellCommand,
    maxSuggestions: maxSuggestions,
  );
  return fallbackInvocation ?? invocation;
}

ShellCompletionInvocation? _buildShellCompletionInvocationFromCommandSnapshot({
  required ({String commandLine, int cursorOffset})? commandSnapshot,
  required String? workingDirectory,
  required String? shellCommand,
  required int maxSuggestions,
}) {
  if (commandSnapshot == null) {
    return null;
  }

  final commandLine = commandSnapshot.commandLine;
  final cursorOffset = commandSnapshot.cursorOffset;
  if (cursorOffset != commandLine.length || commandLine.length > 512) {
    return null;
  }
  if (commandLine.trim().isEmpty) {
    return null;
  }

  final tokenState = parseShellCompletionToken(commandLine, cursorOffset);
  if (tokenState == null || _containsShellQuote(tokenState.token)) {
    return null;
  }

  final commandName = tokenState.words.isEmpty
      ? null
      : normalizeShellCompletionToken(tokenState.words.first);
  final mode = tokenState.wordIndex == 0
      ? ShellCompletionMode.command
      : _shellCompletionArgumentMode(
          commandName: commandName,
          wordIndex: tokenState.wordIndex,
        );
  final normalizedToken = normalizeShellCompletionToken(tokenState.token);

  if (mode == ShellCompletionMode.command && normalizedToken.length < 2) {
    return null;
  }

  final normalizedWords = tokenState.words
      .map(normalizeShellCompletionToken)
      .toList(growable: false);

  return ShellCompletionInvocation(
    commandLine: commandLine,
    cursorOffset: cursorOffset,
    token: normalizedToken,
    tokenStart: tokenState.tokenStart,
    mode: mode,
    commandName: commandName,
    shellCommand: shellCommand,
    words: normalizedWords,
    wordIndex: tokenState.wordIndex,
    workingDirectory: workingDirectory,
    maxSuggestions: maxSuggestions,
  );
}

ShellCompletionMode _shellCompletionArgumentMode({
  required String? commandName,
  required int wordIndex,
}) {
  if (commandName == 'cd') {
    return ShellCompletionMode.directory;
  }
  return ShellCompletionMode.argument;
}

/// Builds local static suggestions for completion modes that do not need SSH.
///
/// Returns `null` when no static provider owns [invocation], and an empty list
/// when a provider exists but the current token has no matches.
List<ShellCompletionSuggestion>? buildShellCompletionStaticSuggestions(
  ShellCompletionInvocation invocation,
) {
  if (invocation.mode != ShellCompletionMode.argument ||
      invocation.wordIndex != 1) {
    return null;
  }

  final commandName = _normalizeShellCompletionCommandName(
    invocation.commandName,
  );
  final subcommands = _staticSubcommandsFor(commandName);
  if (commandName == null || subcommands == null) {
    return null;
  }

  final suggestions = <ShellCompletionSuggestion>[];
  for (final subcommand in subcommands) {
    if (!subcommand.startsWith(invocation.token)) {
      continue;
    }
    suggestions.add(
      ShellCompletionSuggestion(
        label: '$commandName $subcommand',
        replacement: escapeShellCompletionToken(subcommand),
        replacementStart: invocation.tokenStart,
        replacementEnd: invocation.cursorOffset,
        kind: ShellCompletionSuggestionKind.command,
        commitSuffix: ' ',
      ),
    );
    if (suggestions.length >= invocation.maxSuggestions) {
      break;
    }
  }

  return suggestions;
}

/// Builds command-line suggestions from normalized shell history patterns.
@visibleForTesting
List<ShellCompletionSuggestion> buildShellHistorySuggestions(
  List<String> historyCommands,
  ShellCompletionInvocation invocation,
) => _buildPreparedShellHistorySuggestions(
  _prepareShellHistoryCommands(historyCommands),
  invocation,
);

List<ShellCompletionSuggestion> _buildPreparedShellHistorySuggestions(
  List<_PreparedShellHistoryCommand> historyCommands,
  ShellCompletionInvocation invocation,
) {
  final typedCommand = invocation.commandLine.substring(
    0,
    invocation.cursorOffset,
  );
  if (typedCommand.trim().isEmpty) {
    return const <ShellCompletionSuggestion>[];
  }
  final currentPatternTokens = _normalizeShellHistoryCommandPatternTokens(
    typedCommand,
  );
  final currentTokenParticipatesInPattern =
      invocation.token.isEmpty ||
      _doesShellHistoryCurrentTokenParticipateInPattern(
        invocation: invocation,
        currentPatternTokens: currentPatternTokens,
      );

  final tokenSuggestions = <String, _RankedShellHistorySuggestion>{};
  final exactSuggestions = <String, _RankedShellHistorySuggestion>{};
  var recencyRank = 0;
  for (final historyCommand in historyCommands.reversed) {
    final patternToken = _nextShellHistoryPatternToken(
      historyPatternTokens: historyCommand.patternTokens,
      currentPatternTokens: currentPatternTokens,
      currentTokenParticipatesInPattern: currentTokenParticipatesInPattern,
      hasCurrentToken: invocation.token.isNotEmpty,
    );
    if (patternToken != null) {
      tokenSuggestions.update(
        patternToken,
        (ranked) => ranked.incrementFrequency(),
        ifAbsent: () => _RankedShellHistorySuggestion(
          suggestion: ShellCompletionSuggestion(
            label: patternToken,
            replacement: escapeShellCompletionToken(patternToken),
            replacementStart: invocation.tokenStart,
            replacementEnd: invocation.cursorOffset,
            kind: ShellCompletionSuggestionKind.history,
            commitSuffix: ' ',
          ),
          tokenCount: 1,
          frequency: 1,
          recencyRank: recencyRank,
        ),
      );
    }

    final exactCommand = historyCommand.command;
    if (exactCommand != typedCommand &&
        exactCommand.startsWith(typedCommand) &&
        !tokenSuggestions.containsKey(exactCommand)) {
      exactSuggestions.update(
        exactCommand,
        (ranked) => ranked.incrementFrequency(),
        ifAbsent: () => _RankedShellHistorySuggestion(
          suggestion: ShellCompletionSuggestion(
            label: exactCommand,
            replacement: exactCommand,
            replacementStart: 0,
            replacementEnd: invocation.cursorOffset,
            kind: ShellCompletionSuggestionKind.history,
          ),
          tokenCount: historyCommand.tokenCount,
          frequency: 1,
          recencyRank: recencyRank,
        ),
      );
    }

    recencyRank += 1;
  }

  final sortedTokenSuggestions = tokenSuggestions.values.toList()
    ..sort(_compareRankedShellHistorySuggestions);
  final sortedExactSuggestions = exactSuggestions.values.toList()
    ..sort(_compareRankedShellHistorySuggestions);
  final seenSuggestionLabels = <String>{};
  final suggestions = <ShellCompletionSuggestion>[];
  for (final ranked in sortedTokenSuggestions) {
    final suggestion = ranked.suggestion;
    if (seenSuggestionLabels.add(suggestion.label)) {
      suggestions.add(suggestion);
    }
  }
  for (final ranked in sortedExactSuggestions) {
    final suggestion = ranked.suggestion;
    if (seenSuggestionLabels.add(suggestion.label)) {
      suggestions.add(suggestion);
    }
  }
  return suggestions.length <= invocation.maxSuggestions
      ? suggestions
      : suggestions.sublist(0, invocation.maxSuggestions);
}

class _RankedShellHistorySuggestion {
  const _RankedShellHistorySuggestion({
    required this.suggestion,
    required this.tokenCount,
    required this.frequency,
    required this.recencyRank,
  });

  final ShellCompletionSuggestion suggestion;
  final int tokenCount;
  final int frequency;
  final int recencyRank;

  _RankedShellHistorySuggestion incrementFrequency() =>
      _RankedShellHistorySuggestion(
        suggestion: suggestion,
        tokenCount: tokenCount,
        frequency: frequency + 1,
        recencyRank: recencyRank,
      );
}

int _compareRankedShellHistorySuggestions(
  _RankedShellHistorySuggestion a,
  _RankedShellHistorySuggestion b,
) {
  final tokenCountComparison = a.tokenCount.compareTo(b.tokenCount);
  if (tokenCountComparison != 0) {
    return tokenCountComparison;
  }
  final frequencyComparison = b.frequency.compareTo(a.frequency);
  if (frequencyComparison != 0) {
    return frequencyComparison;
  }
  return a.recencyRank.compareTo(b.recencyRank);
}

bool _doesShellHistoryCurrentTokenParticipateInPattern({
  required ShellCompletionInvocation invocation,
  required List<String>? currentPatternTokens,
}) {
  if (currentPatternTokens == null || currentPatternTokens.isEmpty) {
    return false;
  }
  final patternToken =
      _trimShellHistoryOptionValue(invocation.token) ??
      normalizeShellCompletionToken(invocation.token);
  return currentPatternTokens.last == patternToken;
}

String? _nextShellHistoryPatternToken({
  required List<String>? historyPatternTokens,
  required List<String>? currentPatternTokens,
  required bool currentTokenParticipatesInPattern,
  required bool hasCurrentToken,
}) {
  if (historyPatternTokens == null ||
      currentPatternTokens == null ||
      historyPatternTokens.isEmpty ||
      currentPatternTokens.isEmpty) {
    return null;
  }

  if (hasCurrentToken) {
    if (!currentTokenParticipatesInPattern ||
        currentPatternTokens.length > historyPatternTokens.length) {
      return null;
    }
    final prefixLength = currentPatternTokens.length - 1;
    if (!_shellHistoryPatternPrefixMatches(
      historyPatternTokens,
      currentPatternTokens,
      prefixLength,
    )) {
      return null;
    }
    final candidate = historyPatternTokens[prefixLength];
    final currentToken = currentPatternTokens.last;
    if (candidate == currentToken || !candidate.startsWith(currentToken)) {
      return null;
    }
    return candidate;
  }

  if (currentPatternTokens.length >= historyPatternTokens.length ||
      !_shellHistoryPatternPrefixMatches(
        historyPatternTokens,
        currentPatternTokens,
        currentPatternTokens.length,
      )) {
    return null;
  }
  return historyPatternTokens[currentPatternTokens.length];
}

bool _shellHistoryPatternPrefixMatches(
  List<String> historyPatternTokens,
  List<String> currentPatternTokens,
  int length,
) {
  if (currentPatternTokens.length < length ||
      historyPatternTokens.length < length) {
    return false;
  }
  for (var index = 0; index < length; index++) {
    if (historyPatternTokens[index] != currentPatternTokens[index]) {
      return false;
    }
  }
  return true;
}

List<String>? _staticSubcommandsFor(String? commandName) =>
    _shellCompletionStaticSubcommands[_normalizeShellCompletionCommandName(
      commandName,
    )];

String? _normalizeShellCompletionCommandName(String? commandName) {
  var normalized = commandName?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  normalized = normalized.replaceAll(r'\', '/').split('/').last;
  if (normalized.startsWith('-')) {
    normalized = normalized.substring(1);
  }
  normalized = normalized.toLowerCase();
  if (normalized.endsWith('.exe')) {
    normalized = normalized.substring(0, normalized.length - 4);
  }
  return normalized;
}

const _shellCompletionStaticSubcommands = <String, List<String>>{
  'tmux': <String>[
    'attach',
    'attach-session',
    'new',
    'new-session',
    'ls',
    'list-sessions',
    'new-window',
    'split-window',
    'kill-pane',
    'kill-session',
    'kill-window',
    'switch-client',
    'detach',
    'detach-client',
    'source-file',
    'rename-session',
    'rename-window',
    'display-message',
    'list-windows',
    'list-panes',
    'select-window',
    'select-pane',
    'send-keys',
    'copy-mode',
  ],
};

/// Resolves command text from a terminal snapshot by removing the prompt.
@visibleForTesting
({String commandLine, int cursorOffset})? resolveShellCompletionCommandLine({
  required String terminalText,
  required int terminalCursorOffset,
  String? promptPrefix,
}) {
  if (terminalCursorOffset < 0 || terminalCursorOffset > terminalText.length) {
    return null;
  }

  final beforeCursor = terminalText.substring(0, terminalCursorOffset);
  final afterCursor = terminalText.substring(terminalCursorOffset);
  if (afterCursor.trimRight().isNotEmpty) {
    return null;
  }

  final promptEnd = _resolvePromptEnd(beforeCursor, promptPrefix);
  if (promptEnd > beforeCursor.length) {
    return null;
  }

  return (
    commandLine: beforeCursor.substring(promptEnd) + afterCursor,
    cursorOffset: beforeCursor.length - promptEnd,
  );
}

int _resolvePromptEnd(String beforeCursor, String? promptPrefix) {
  if (promptPrefix != null &&
      promptPrefix.isNotEmpty &&
      beforeCursor.startsWith(promptPrefix)) {
    return promptPrefix.length;
  }

  return _findLikelyPromptEnd(beforeCursor);
}

int _findLikelyPromptEnd(String beforeCursor) {
  const maxPromptSearchLength = 96;
  final searchText = beforeCursor.length > maxPromptSearchLength
      ? beforeCursor.substring(0, maxPromptSearchLength)
      : beforeCursor;
  final markerPattern = RegExp(r'(?:^|\s)(?:\S{1,80}\s+)?[#$%>]\s+');
  var promptEnd = 0;
  for (final match in markerPattern.allMatches(searchText)) {
    promptEnd = match.end;
  }
  return promptEnd;
}

/// Parsed token state for the command text before the cursor.
@visibleForTesting
class ShellCompletionTokenState {
  /// Creates a token state.
  const ShellCompletionTokenState({
    required this.words,
    required this.wordIndex,
    required this.token,
    required this.tokenStart,
  });

  /// Words before or at the cursor.
  final List<String> words;

  /// Index of [token] in [words], or the next word after trailing whitespace.
  final int wordIndex;

  /// Current token before the cursor.
  final String token;

  /// Token start offset in the command line.
  final int tokenStart;
}

/// Parses the token being edited at [cursorOffset].
@visibleForTesting
ShellCompletionTokenState? parseShellCompletionToken(
  String commandLine,
  int cursorOffset,
) {
  if (cursorOffset < 0 || cursorOffset > commandLine.length) {
    return null;
  }

  final beforeCursor = commandLine.substring(0, cursorOffset);
  final words = <String>[];
  var tokenStart = 0;
  var token = '';
  var inWord = false;
  var quote = '';
  var escaped = false;
  var sawWhitespace = false;

  for (var index = 0; index < beforeCursor.length; index++) {
    final char = beforeCursor[index];
    if (escaped) {
      escaped = false;
      if (!inWord) {
        inWord = true;
        tokenStart = index - 1;
      }
      continue;
    }
    if (char == r'\') {
      if (!inWord) {
        inWord = true;
        tokenStart = index;
      }
      escaped = true;
      continue;
    }
    if (quote.isNotEmpty) {
      if (char == quote) {
        quote = '';
      }
      continue;
    }
    if (char == "'" || char == '"') {
      if (!inWord) {
        inWord = true;
        tokenStart = index;
      }
      quote = char;
      continue;
    }
    if (_isShellCompletionWhitespace(char)) {
      sawWhitespace = true;
      if (inWord) {
        words.add(beforeCursor.substring(tokenStart, index));
        inWord = false;
      }
      continue;
    }
    if (!inWord) {
      inWord = true;
      tokenStart = index;
    }
  }

  if (escaped || quote.isNotEmpty) {
    return null;
  }

  if (inWord) {
    token = beforeCursor.substring(tokenStart);
    words.add(token);
    return ShellCompletionTokenState(
      words: words,
      wordIndex: words.length - 1,
      token: token,
      tokenStart: tokenStart,
    );
  }

  return ShellCompletionTokenState(
    words: words,
    wordIndex: sawWhitespace ? words.length : 0,
    token: '',
    tokenStart: beforeCursor.length,
  );
}

bool _isShellCompletionWhitespace(String char) =>
    char == ' ' || char == '\t' || char == '\n' || char == '\r';

bool _containsShellQuote(String token) =>
    token.contains("'") || token.contains('"');

/// Normalizes a shell history command into a reusable command pattern.
String? normalizeShellHistoryCommandPattern(String command) {
  final patternTokens = _normalizeShellHistoryCommandPatternTokens(command);
  if (patternTokens == null) {
    return null;
  }

  final pattern = patternTokens
      .where((token) => token.isNotEmpty)
      .map(escapeShellCompletionToken)
      .join(' ')
      .trim();
  return pattern.isEmpty || pattern.length > 512 ? null : pattern;
}

List<String>? _normalizeShellHistoryCommandPatternTokens(String command) {
  final decoded = _decodeShellHistoryCommand(command).trim();
  if (!_isSafeHistoryCommand(decoded)) {
    return null;
  }

  final tokens = _parseShellHistoryCommandTokens(decoded);
  if (tokens == null || tokens.isEmpty) {
    return null;
  }
  return _normalizeShellHistoryCommandPatternTokensFromTokens(tokens);
}

List<String>? _normalizeShellHistoryCommandPatternTokensFromTokens(
  List<_ShellHistoryToken> tokens,
) {
  final patternTokens = <String>[];
  var trimNextOptionArgument = false;
  for (var index = 0; index < tokens.length; index++) {
    final token = tokens[index];
    final tokenValue = token.value;
    if (trimNextOptionArgument) {
      trimNextOptionArgument = false;
      if (!_isShellHistoryOptionToken(tokenValue)) {
        continue;
      }
    }
    final optionPattern = _trimShellHistoryOptionValue(token.value);
    if (optionPattern != null) {
      patternTokens.add(optionPattern);
      continue;
    }
    if (_isShellHistoryOptionToken(tokenValue)) {
      patternTokens.add(tokenValue);
      trimNextOptionArgument = true;
      continue;
    }
    if (token.wasQuoted && index > 0) {
      continue;
    }
    patternTokens.add(tokenValue);
  }

  if (patternTokens.isEmpty) {
    return null;
  }
  return patternTokens;
}

List<_PreparedShellHistoryCommand> _prepareShellHistoryCommands(
  List<String> commands,
) {
  final preparedCommands = <_PreparedShellHistoryCommand>[];
  for (final command in commands) {
    final preparedCommand = _prepareShellHistoryCommand(command);
    if (preparedCommand != null) {
      preparedCommands.add(preparedCommand);
    }
  }
  return List<_PreparedShellHistoryCommand>.unmodifiable(preparedCommands);
}

_PreparedShellHistoryCommand? _prepareShellHistoryCommand(String command) {
  final decoded = _decodeShellHistoryCommand(command).trim();
  if (!_isSafeHistoryCommand(decoded)) {
    return null;
  }
  final tokens = _parseShellHistoryCommandTokens(decoded);
  if (tokens == null || tokens.isEmpty) {
    return null;
  }
  return _PreparedShellHistoryCommand(
    command: decoded,
    patternTokens: _normalizeShellHistoryCommandPatternTokensFromTokens(tokens),
    tokenCount: tokens.length,
  );
}

String _decodeShellHistoryCommand(String command) {
  if (command.startsWith(': ')) {
    final separatorIndex = command.indexOf(';');
    if (separatorIndex >= 0 && separatorIndex + 1 < command.length) {
      return command.substring(separatorIndex + 1);
    }
  }
  return command;
}

bool _isSafeHistoryCommand(String command) {
  if (command.isEmpty || command.length > 1024) {
    return false;
  }
  if (_looksLikeUrlEncodedShellCommand(command)) {
    return false;
  }
  for (var index = 0; index < command.length; index++) {
    final codeUnit = command.codeUnitAt(index);
    if (codeUnit < 0x20 || codeUnit == 0x7F) {
      return false;
    }
  }
  return true;
}

bool _looksLikeUrlEncodedShellCommand(String command) {
  var end = 0;
  while (end < command.length && !_isShellCompletionWhitespace(command[end])) {
    end += 1;
  }
  final firstToken = command.substring(0, end);
  return _urlEncodedShellWhitespacePattern.hasMatch(firstToken);
}

String? _trimShellHistoryOptionValue(String token) {
  if (!_isShellHistoryOptionToken(token)) {
    return null;
  }
  final separatorIndex = token.indexOf('=');
  if (separatorIndex <= 1) {
    return null;
  }
  return token.substring(0, separatorIndex);
}

bool _isShellHistoryOptionToken(String token) =>
    token.startsWith('-') && token != '-' && token != '--';

class _ShellHistoryToken {
  const _ShellHistoryToken({required this.value, required this.wasQuoted});

  final String value;
  final bool wasQuoted;
}

List<_ShellHistoryToken>? _parseShellHistoryCommandTokens(String command) {
  final tokens = <_ShellHistoryToken>[];
  final builder = StringBuffer();
  var inWord = false;
  var quote = '';
  var escaped = false;
  var tokenWasQuoted = false;

  void finishToken() {
    if (!inWord) {
      return;
    }
    tokens.add(
      _ShellHistoryToken(value: builder.toString(), wasQuoted: tokenWasQuoted),
    );
    builder.clear();
    inWord = false;
    tokenWasQuoted = false;
  }

  for (var index = 0; index < command.length; index++) {
    final char = command[index];
    if (escaped) {
      builder.write(char);
      escaped = false;
      continue;
    }
    if (char == r'\') {
      inWord = true;
      escaped = true;
      continue;
    }
    if (quote.isNotEmpty) {
      if (char == quote) {
        quote = '';
      } else {
        builder.write(char);
      }
      continue;
    }
    if (char == "'" || char == '"') {
      inWord = true;
      quote = char;
      tokenWasQuoted = true;
      continue;
    }
    if (_isShellCompletionWhitespace(char)) {
      finishToken();
      continue;
    }
    inWord = true;
    builder.write(char);
  }

  if (escaped || quote.isNotEmpty) {
    return null;
  }
  finishToken();
  return tokens;
}

/// Removes simple backslash escapes from a shell token.
String normalizeShellCompletionToken(String token) {
  final builder = StringBuffer();
  var escaped = false;
  for (var index = 0; index < token.length; index++) {
    final char = token[index];
    if (escaped) {
      builder.write(char);
      escaped = false;
    } else if (char == r'\') {
      escaped = true;
    } else {
      builder.write(char);
    }
  }
  if (escaped) {
    builder.write(r'\');
  }
  return builder.toString();
}

/// Parses side-channel completion helper output.
///
/// When [windows] is true, replacement text is quoted for cmd.exe/PowerShell
/// (double quotes) rather than POSIX backslash escaping.
@visibleForTesting
List<ShellCompletionSuggestion> parseShellCompletionOutput(
  String output,
  ShellCompletionInvocation invocation, {
  bool windows = false,
}) {
  final suggestions = <ShellCompletionSuggestion>[];
  final seen = <String>{};
  var scannedLineCount = 0;

  for (final rawLine in const LineSplitter().convert(output)) {
    scannedLineCount += 1;
    if (scannedLineCount > 1200) {
      break;
    }
    final separatorIndex = rawLine.indexOf('\t');
    if (separatorIndex <= 0) {
      continue;
    }

    final rawKind = rawLine.substring(0, separatorIndex);
    final value = rawLine.substring(separatorIndex + 1).trimRight();
    if (!_isSafeCompletionValue(value)) {
      continue;
    }

    final suggestion = _suggestionFromRemoteValue(
      rawKind: rawKind,
      value: value,
      invocation: invocation,
      windows: windows,
    );
    if (suggestion == null) {
      continue;
    }

    final key =
        '${suggestion.kind.name}\u0000${suggestion.replacementStart}'
        '\u0000${suggestion.replacement}\u0000${suggestion.label}';
    if (seen.add(key)) {
      suggestions.add(suggestion);
    }
  }

  suggestions.sort(_compareShellCompletionSuggestions);
  return suggestions.length <= invocation.maxSuggestions
      ? suggestions
      : suggestions.sublist(0, invocation.maxSuggestions);
}

ShellCompletionSuggestion? _suggestionFromRemoteValue({
  required String rawKind,
  required String value,
  required ShellCompletionInvocation invocation,
  required bool windows,
}) {
  final kind = switch (rawKind) {
    'command' => ShellCompletionSuggestionKind.command,
    'argument' => ShellCompletionSuggestionKind.command,
    'directory' || 'cd_directory' => ShellCompletionSuggestionKind.directory,
    'file' => ShellCompletionSuggestionKind.file,
    _ => null,
  };
  if (kind == null) {
    return null;
  }

  final escape = windows
      ? escapeWindowsCompletionToken
      : escapeShellCompletionToken;
  final escapedValue = escape(value);
  final directoryValue = _formatDirectoryCompletion(value);
  final escapedDirectoryValue = escape(directoryValue);

  if (rawKind == 'cd_directory') {
    return ShellCompletionSuggestion(
      label: 'cd ${_formatDirectoryCompletionLabel(value)}',
      replacement: 'cd $escapedDirectoryValue',
      replacementStart: 0,
      replacementEnd: invocation.cursorOffset,
      kind: ShellCompletionSuggestionKind.directory,
    );
  }

  if (rawKind == 'argument') {
    final commandName = _normalizeShellCompletionCommandName(
      invocation.commandName,
    );
    return ShellCompletionSuggestion(
      label: commandName == null ? value : '$commandName $value',
      replacement: escapedValue,
      replacementStart: invocation.tokenStart,
      replacementEnd: invocation.cursorOffset,
      kind: kind,
      commitSuffix: ' ',
    );
  }

  if (kind == ShellCompletionSuggestionKind.command) {
    return ShellCompletionSuggestion(
      label: value,
      replacement: escapedValue,
      replacementStart: invocation.tokenStart,
      replacementEnd: invocation.cursorOffset,
      kind: kind,
      commitSuffix: ' ',
    );
  }

  final labelPrefix = invocation.commandName == 'cd' ? 'cd ' : '';
  final replacement = kind == ShellCompletionSuggestionKind.directory
      ? escapedDirectoryValue
      : escapedValue;
  return ShellCompletionSuggestion(
    label:
        '$labelPrefix${kind == ShellCompletionSuggestionKind.directory ? _formatDirectoryCompletionLabel(value) : value}',
    replacement: replacement,
    replacementStart: invocation.tokenStart,
    replacementEnd: invocation.cursorOffset,
    kind: kind,
    commitSuffix: kind == ShellCompletionSuggestionKind.file ? ' ' : '',
  );
}

int _compareShellCompletionSuggestions(
  ShellCompletionSuggestion a,
  ShellCompletionSuggestion b,
) {
  final scoreA = _completionSuggestionScore(a);
  final scoreB = _completionSuggestionScore(b);
  if (scoreA != scoreB) {
    return scoreA.compareTo(scoreB);
  }
  return a.label.toLowerCase().compareTo(b.label.toLowerCase());
}

int _completionSuggestionScore(ShellCompletionSuggestion suggestion) {
  if (suggestion.kind == ShellCompletionSuggestionKind.command &&
      suggestion.label == 'cd') {
    return 0;
  }
  if (suggestion.label.startsWith('cd ')) {
    return 1;
  }
  return switch (suggestion.kind) {
    ShellCompletionSuggestionKind.history => 2,
    ShellCompletionSuggestionKind.command => 3,
    ShellCompletionSuggestionKind.directory => 4,
    ShellCompletionSuggestionKind.file => 5,
  };
}

bool _isSafeCompletionValue(String value) {
  if (value.isEmpty || value.length > 240) {
    return false;
  }
  for (var index = 0; index < value.length; index++) {
    final codeUnit = value.codeUnitAt(index);
    if (codeUnit < 0x20 || codeUnit == 0x7F) {
      return false;
    }
  }
  return true;
}

String _formatDirectoryCompletion(String value) {
  if (value == '..' || value.endsWith('/')) {
    return value;
  }
  return '$value/';
}

String _formatDirectoryCompletionLabel(String value) {
  if (value == '..') {
    return value;
  }
  return _formatDirectoryCompletion(value);
}

/// Escapes a token so it can be typed safely into a POSIX-like shell.
@visibleForTesting
String escapeShellCompletionToken(String value) {
  final builder = StringBuffer();
  for (var index = 0; index < value.length; index++) {
    final char = value[index];
    if (_isUnescapedShellTokenChar(char)) {
      builder.write(char);
    } else {
      builder
        ..write(r'\')
        ..write(char);
    }
  }
  return builder.toString();
}

bool _isUnescapedShellTokenChar(String char) {
  final codeUnit = char.codeUnitAt(0);
  return (codeUnit >= 0x30 && codeUnit <= 0x39) ||
      (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
      (codeUnit >= 0x61 && codeUnit <= 0x7A) ||
      char == '_' ||
      char == '-' ||
      char == '.' ||
      char == '/' ||
      char == '~';
}

/// Quotes a completion [value] for insertion into a Windows shell (cmd.exe or
/// PowerShell).
///
/// POSIX backslash escaping (`Program\ Files`) is invalid on Windows shells, so
/// values containing a space or a shell metacharacter are wrapped in double
/// quotes instead (valid in both cmd.exe and PowerShell). Simple values are
/// returned unchanged. Windows file names cannot contain `"`, so double-quote
/// wrapping is always safe.
@visibleForTesting
String escapeWindowsCompletionToken(String value) {
  if (value.isEmpty) {
    return '""';
  }
  final needsQuoting = value.contains(RegExp(r'[ \t&|<>^()";,%!]'));
  if (!needsQuoting) {
    return value;
  }
  return '"${value.replaceAll('"', '')}"';
}

const _interactiveZshCompletionDoneMarker = '__FLUTTY_ZSH_NATIVE_DONE__';
const _shellHistoryDoneMarker = '__FLUTTY_HISTORY_DONE__';

bool _shouldTryInteractiveZshCompletion(ShellCompletionInvocation invocation) =>
    invocation.mode != ShellCompletionMode.command;

bool _containsInteractiveZshCompletionDoneMarker(String output) {
  for (final rawLine in const LineSplitter().convert(output)) {
    if (rawLine.replaceAll('\r', '').trim() ==
        _interactiveZshCompletionDoneMarker) {
      return true;
    }
  }
  return false;
}

/// Builds the remote command that reads recent shell history.
@visibleForTesting
String buildShellHistoryRemoteCommand(ShellCompletionInvocation invocation) {
  final preferredShell = invocation.shellCommand?.trim() ?? '';
  return '''
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; export FLUTTY_PREFERRED_SHELL=${shellEscapePosix(preferredShell)}; flutty_shell=\${FLUTTY_PREFERRED_SHELL:-\${SHELL:-}}; flutty_shell_name=\${flutty_shell##*/}; emit_history_file() { flutty_source=\$1; flutty_path=\$2; [ -r "\$flutty_path" ] || return 0; tail -n 1200 "\$flutty_path" 2>/dev/null | while IFS= read -r flutty_line; do printf '%s\\t%s\\n' "\$flutty_source" "\$flutty_line"; done; }; printf '__FLUTTY_HISTORY_START__\\n'; case "\$flutty_shell_name" in zsh) emit_history_file zsh "\${HISTFILE:-\$HOME/.zsh_history}";; bash) emit_history_file bash "\${HISTFILE:-\$HOME/.bash_history}";; fish) emit_history_file fish "\${XDG_DATA_HOME:-\$HOME/.local/share}/fish/fish_history";; *) emit_history_file zsh "\$HOME/.zsh_history"; emit_history_file bash "\$HOME/.bash_history"; emit_history_file fish "\${XDG_DATA_HOME:-\$HOME/.local/share}/fish/fish_history";; esac; printf '$_shellHistoryDoneMarker\\n'
''';
}

/// Parses recent shell history emitted by [buildShellHistoryRemoteCommand].
@visibleForTesting
List<String> parseShellHistoryOutput(String output) {
  final commands = <String>[];
  var scannedLineCount = 0;
  for (final rawLine in const LineSplitter().convert(output)) {
    scannedLineCount += 1;
    if (scannedLineCount > 1600) {
      break;
    }
    final line = rawLine.replaceAll('\r', '');
    if (line.isEmpty ||
        line == '__FLUTTY_HISTORY_START__' ||
        line == _shellHistoryDoneMarker) {
      continue;
    }
    final separatorIndex = line.indexOf('\t');
    if (separatorIndex <= 0) {
      continue;
    }
    final source = line.substring(0, separatorIndex);
    final value = line.substring(separatorIndex + 1);
    final command = _historyCommandFromSource(source, value);
    if (command != null) {
      commands.add(command);
    }
  }
  return commands;
}

String? _historyCommandFromSource(String source, String value) {
  final command = switch (source) {
    'zsh' => _decodeShellHistoryCommand(value),
    'bash' => value,
    'fish' => _decodeFishHistoryCommand(value),
    _ => null,
  };
  if (command == null) {
    return null;
  }
  final trimmed = command.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _decodeFishHistoryCommand(String value) {
  const prefix = '- cmd: ';
  if (!value.startsWith(prefix)) {
    return null;
  }
  return value.substring(prefix.length).replaceAll(r'\n', ' ');
}

/// Builds the remote command that starts a PTY-backed zsh completion shell.
@visibleForTesting
String buildInteractiveZshCompletionRemoteCommand(
  ShellCompletionInvocation invocation,
) {
  final cwd = invocation.workingDirectory?.trim();
  final preferredShell = invocation.shellCommand?.trim() ?? '';
  final mode = invocation.mode.name;
  final setupScript = _interactiveZshCompletionSetupScript();
  return '''
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; stty -echo 2>/dev/null || :; export FLUTTY_CWD=${shellEscapePosix(cwd ?? '')} FLUTTY_PREFERRED_SHELL=${shellEscapePosix(preferredShell)} FLUTTY_MODE=${shellEscapePosix(mode)}; flutty_shell=\${FLUTTY_PREFERRED_SHELL:-\${SHELL:-}}; flutty_shell_name=\${flutty_shell##*/}; case "\$flutty_shell_name" in zsh) if [ -x "\$flutty_shell" ]; then flutty_runner=\$flutty_shell; else flutty_runner=\$(command -v zsh 2>/dev/null || :); fi;; *) exit 78;; esac; [ -n "\$flutty_runner" ] || exit 78; if [ -n "\$FLUTTY_CWD" ]; then cd -- "\$FLUTTY_CWD" 2>/dev/null || cd -- "\$HOME" 2>/dev/null || :; fi; flutty_setup=\$(mktemp "\${TMPDIR:-/tmp}/flutty-zsh-completion.XXXXXX") || exit 78; cat >"\$flutty_setup" <<'__FLUTTY_ZSH_COMPLETION_SETUP__'
$setupScript
__FLUTTY_ZSH_COMPLETION_SETUP__
export FLUTTY_ZSH_COMPLETION_SETUP="\$flutty_setup"; exec "\$flutty_runner" -fi
''';
}

/// Builds stdin sent to the PTY-backed zsh completion shell.
@visibleForTesting
String buildInteractiveZshCompletionInput(
  ShellCompletionInvocation invocation,
) {
  final commandLine = invocation.commandLine;
  return '''
source "\$FLUTTY_ZSH_COMPLETION_SETUP" >/dev/null 2>&1 || exit 78
$commandLine\t''';
}

String _interactiveZshCompletionSetupScript() =>
    '''
source_if_readable() {
  [ -r "\$1" ] || return 0
  . "\$1" >/dev/null 2>&1 || :
}
TRAPEXIT() {
  rm -f "\${FLUTTY_ZSH_COMPLETION_SETUP:-}" 2>/dev/null || :
}
source_if_readable "\$HOME/.zprofile"
source_if_readable "\$HOME/.zshrc"
autoload -Uz compinit
compinit -C >/dev/null 2>&1 || compinit -u >/dev/null 2>&1 || :
zstyle ':completion:*' verbose no
zstyle ':completion:*' group-name ''
zstyle ':completion:*' format ''
emit_native_completion_item() {
  local item=\$1
  case "\$FLUTTY_MODE" in
    directory)
      [ -d "\$item" ] && printf 'directory\\t%s\\n' "\$item"
      ;;
    path)
      if [ -d "\$item" ]; then
        printf 'directory\\t%s\\n' "\$item"
      elif [ -e "\$item" ]; then
        printf 'file\\t%s\\n' "\$item"
      fi
      ;;
    *)
      if [ -d "\$item" ]; then
        printf 'directory\\t%s\\n' "\$item"
      elif [ -e "\$item" ]; then
        printf 'file\\t%s\\n' "\$item"
      else
        printf 'argument\\t%s\\n' "\$item"
      fi
      ;;
  esac
}
_flutty_dump_completions() {
  typeset -ga _flutty_matches
  _flutty_matches=()
  compadd() {
    local -a original_args capture_args out
    original_args=("\$@")
    while (( \$# )); do
      case "\$1" in
        -O|-A)
          shift 2
          ;;
        -O*|-A*)
          shift
          ;;
        *)
          capture_args+=("\$1")
          shift
          ;;
      esac
    done
    builtin compadd -O out "\${capture_args[@]}" 2>/dev/null || :
    _flutty_matches+=("\${out[@]}")
    builtin compadd "\${original_args[@]}" 2>/dev/null
    local status=\$?
    return \$status
  }
  _main_complete >/dev/null 2>&1 || :
  print -r -- __FLUTTY_ZSH_NATIVE_START__
  local item
  for item in "\${_flutty_matches[@]}"; do
    emit_native_completion_item "\$item"
  done
  print -r -- $_interactiveZshCompletionDoneMarker
  exit 0
}
zle -C _flutty_complete complete-word _flutty_dump_completions
bindkey "^I" _flutty_complete
''';

/// Builds the remote shell helper command for a completion invocation.
@visibleForTesting
String buildShellCompletionRemoteCommand(ShellCompletionInvocation invocation) {
  final cwd = invocation.workingDirectory?.trim();
  final mode = invocation.mode.name;
  final token = invocation.token;
  final limit = invocation.maxSuggestions * 4;
  final commandName =
      _normalizeShellCompletionCommandName(invocation.commandName) ?? '';
  final compWordsAssignment = _bashCompWordsAssignment(invocation);
  final preferredShell = invocation.shellCommand?.trim() ?? '';
  final includeCdShortcuts =
      invocation.mode == ShellCompletionMode.command &&
      'cd'.startsWith(invocation.token);

  return '''
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; export FLUTTY_MODE=${shellEscapePosix(mode)} FLUTTY_TOKEN=${shellEscapePosix(token)} FLUTTY_COMMAND_NAME=${shellEscapePosix(commandName)} FLUTTY_COMMAND_LINE=${shellEscapePosix(invocation.commandLine)} FLUTTY_CURSOR_OFFSET=${invocation.cursorOffset} FLUTTY_WORD_INDEX=${invocation.wordIndex} FLUTTY_COMP_WORDS_ASSIGNMENT=${shellEscapePosix(compWordsAssignment)} FLUTTY_INCLUDE_CD_SHORTCUTS=${includeCdShortcuts ? '1' : '0'} FLUTTY_CWD=${shellEscapePosix(cwd ?? '')} FLUTTY_LIMIT=$limit FLUTTY_PREFERRED_SHELL=${shellEscapePosix(preferredShell)}; flutty_shell=\${FLUTTY_PREFERRED_SHELL:-\${SHELL:-}}; flutty_shell_name=\${flutty_shell##*/}; case "\$flutty_shell_name" in bash|zsh|ksh|sh) if [ -x "\$flutty_shell" ]; then flutty_runner=\$flutty_shell; else flutty_runner=\$(command -v "\$flutty_shell_name" 2>/dev/null || printf %s "\$flutty_shell_name"); fi; flutty_profile_kind=\$flutty_shell_name;; *) flutty_runner=sh; flutty_profile_kind=sh;; esac; [ -n "\$flutty_runner" ] || flutty_runner=sh; FLUTTY_PROFILE_KIND=\$flutty_profile_kind "\$flutty_runner" -s <<'__FLUTTY_COMPLETION__'
case "\$FLUTTY_MODE:\$FLUTTY_PROFILE_KIND" in
  command:*|argument:bash)
    source_if_readable() {
      [ -r "\$1" ] || return 0
      . "\$1" >/dev/null 2>&1 || :
    }
    case "\$FLUTTY_PROFILE_KIND" in
      zsh) source_if_readable "\$HOME/.zprofile"; source_if_readable "\$HOME/.zshrc" ;;
      bash) source_if_readable "\$HOME/.bash_profile"; source_if_readable "\$HOME/.bash_login"; source_if_readable "\$HOME/.profile"; source_if_readable "\$HOME/.bashrc" ;;
      *) source_if_readable "\$HOME/.profile" ;;
    esac
    ;;
esac
emulate -L sh >/dev/null 2>&1 || :
set +f
if [ -n "\$FLUTTY_CWD" ]; then
  cd -- "\$FLUTTY_CWD" 2>/dev/null || cd -- "\$HOME" 2>/dev/null || :
fi

can_emit() {
  flutty_emit_limit=\${FLUTTY_LIMIT:-96}
  flutty_emit_count=\${flutty_emit_count:-0}
  [ "\$flutty_emit_count" -lt "\$flutty_emit_limit" ] 2>/dev/null
}

emit_line() {
  can_emit || return 1
  kind=\$1
  item=\$2
  case "\$item" in
    *'
'*|*'	'*) return 0 ;;
  esac
  [ -n "\$item" ] || return 0
  flutty_emit_count=\$((flutty_emit_count + 1))
  printf '%s\\t%s\\n' "\$kind" "\$item"
  can_emit
}

emit_bash_matches() {
  mode=\$1
  token=\$2
  if [ -n "\${BASH_VERSION:-}" ] && command -v compgen >/dev/null 2>&1; then
    case "\$mode" in
      command) compgen -c -- "\$token" ;;
      directory) compgen -d -- "\$token" ;;
      path) compgen -f -- "\$token" ;;
    esac
    return
  fi
  FLUTTY_BASH_MODE=\$mode FLUTTY_BASH_TOKEN=\$token bash --noprofile --norc -c '
    case "\$FLUTTY_BASH_MODE" in
      command) compgen -c -- "\$FLUTTY_BASH_TOKEN" ;;
      directory) compgen -d -- "\$FLUTTY_BASH_TOKEN" ;;
      path) compgen -f -- "\$FLUTTY_BASH_TOKEN" ;;
    esac
  '
}

emit_zsh_command_matches() {
  token=\$1
  [ -n "\${ZSH_VERSION:-}" ] || return 1
  command -v whence >/dev/null 2>&1 || return 1
  whence -wm "\$token*" 2>/dev/null | while IFS= read -r line; do
    case "\$line" in
      *:*) item=\${line%%:*} ;;
      *) item=\$line ;;
    esac
    printf '%s\\n' "\$item"
  done
}

emit_command_fallback() {
  token=\$1
  for builtin in cd ls cat grep find git ssh scp sftp mkdir rm mv cp touch pwd; do
    can_emit || return
    case "\$builtin" in
      "\$token"*) emit_line command "\$builtin" || return ;;
    esac
  done
  old_ifs=\$IFS
  IFS=:
  for dir in \$PATH; do
    can_emit || break
    [ -d "\$dir" ] || continue
    for candidate in "\$dir"/"\$token"*; do
      can_emit || break
      [ -f "\$candidate" ] && [ -x "\$candidate" ] || continue
      emit_line command "\${candidate##*/}" || break
    done
  done
  IFS=\$old_ifs
}

emit_path_fallback() {
  mode=\$1
  token=\$2
  case "\$token" in
    */*) search_dir=\${token%/*}; base=\${token##*/}; prefix="\$search_dir/" ;;
    *) search_dir=.; base=\$token; prefix= ;;
  esac
  [ -d "\$search_dir" ] || return
  for candidate in "\$search_dir"/"\$base"*; do
    can_emit || break
    [ -e "\$candidate" ] || continue
    name=\${candidate##*/}
    item="\$prefix\$name"
    if [ -d "\$candidate" ]; then
      emit_line directory "\$item" || break
    elif [ "\$mode" = path ]; then
      emit_line file "\$item" || break
    fi
  done
}

emit_path_matches() {
  mode=\$1
  token=\$2
  if command -v bash >/dev/null 2>&1; then
    emit_bash_matches "\$mode" "\$token" 2>/dev/null | while IFS= read -r item; do
      [ -n "\$item" ] || continue
      if [ -d "\$item" ]; then
        emit_line directory "\$item" || break
      elif [ "\$mode" = path ]; then
        emit_line file "\$item" || break
      fi
    done
    return
  fi
  emit_path_fallback "\$mode" "\$token"
}

emit_bash_programmable_argument_matches() {
  command -v bash >/dev/null 2>&1 || return 1
  bash --noprofile --norc -s <<'__FLUTTY_BASH_COMPLETION__'
source_if_readable() {
  [ -r "\$1" ] || return 0
  . "\$1" >/dev/null 2>&1 || :
}

source_if_readable "\$HOME/.bash_profile"
source_if_readable "\$HOME/.bash_login"
source_if_readable "\$HOME/.profile"
source_if_readable "\$HOME/.bashrc"
source_if_readable /etc/bash_completion
source_if_readable /usr/share/bash-completion/bash_completion
source_if_readable /opt/homebrew/etc/profile.d/bash_completion.sh
source_if_readable /usr/local/etc/profile.d/bash_completion.sh
source_if_readable /opt/local/etc/profile.d/bash_completion.sh

eval "\$FLUTTY_COMP_WORDS_ASSIGNMENT" 2>/dev/null || exit 1
COMP_LINE=\${FLUTTY_COMMAND_LINE:-}
COMP_POINT=\${FLUTTY_CURSOR_OFFSET:-0}
COMP_TYPE=9
COMP_KEY=9
COMP_CWORD=\${FLUTTY_WORD_INDEX:-0}
cur=\${COMP_WORDS[\$COMP_CWORD]:-}
prev=
if [ "\$COMP_CWORD" -gt 0 ] 2>/dev/null; then
  prev=\${COMP_WORDS[\$((COMP_CWORD - 1))]:-}
fi
cmd=\${FLUTTY_COMMAND_NAME:-\${COMP_WORDS[0]:-}}
[ -n "\$cmd" ] || exit 1

if ! complete -p "\$cmd" >/dev/null 2>&1; then
  if declare -F _completion_loader >/dev/null 2>&1; then
    _completion_loader "\$cmd" >/dev/null 2>&1 || :
  fi
fi
spec=\$(complete -p "\$cmd" 2>/dev/null || complete -p -D 2>/dev/null) ||
  exit 1

set -f
eval "set -- \$spec" 2>/dev/null || exit 1
comp_function=
comp_command=
comp_words=
comp_action=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -F)
      shift
      comp_function=\${1:-}
      ;;
    -C)
      shift
      comp_command=\${1:-}
      ;;
    -W)
      shift
      comp_words=\${1:-}
      ;;
    -A)
      shift
      comp_action=\${1:-}
      ;;
  esac
  shift || break
done

if [ -n "\$comp_function" ] && declare -F "\$comp_function" >/dev/null 2>&1; then
  COMPREPLY=()
  "\$comp_function" "\$cmd" "\$cur" "\$prev" >/dev/null 2>&1 || :
  [ "\${#COMPREPLY[@]}" -gt 0 ] || exit 1
  printf '%s\n' "\${COMPREPLY[@]}"
elif [ -n "\$comp_command" ] && command -v "\$comp_command" >/dev/null 2>&1; then
  "\$comp_command" "\$cmd" "\$cur" "\$prev" 2>/dev/null
elif [ -n "\$comp_words" ]; then
  compgen -W "\$comp_words" -- "\$cur"
elif [ -n "\$comp_action" ]; then
  compgen -A "\$comp_action" -- "\$cur"
else
  exit 1
fi
__FLUTTY_BASH_COMPLETION__
}

emit_dynamic_argument_matches() {
  dynamic_output=\$(emit_bash_programmable_argument_matches 2>/dev/null)
  [ -n "\$dynamic_output" ] || return 1
  printf '%s\\n' "\$dynamic_output" | while IFS= read -r item; do
    [ -n "\$item" ] || continue
    if [ -d "\$item" ]; then
      emit_line directory "\$item" || break
    elif [ -e "\$item" ]; then
      emit_line file "\$item" || break
    else
      emit_line argument "\$item" || break
    fi
  done
}

case "\$FLUTTY_MODE" in
  command)
    if [ -n "\${BASH_VERSION:-}" ] && command -v compgen >/dev/null 2>&1; then
      emit_bash_matches command "\$FLUTTY_TOKEN" 2>/dev/null | while IFS= read -r item; do
        emit_line command "\$item" || break
      done
    elif [ -n "\${ZSH_VERSION:-}" ] && command -v whence >/dev/null 2>&1; then
      emit_zsh_command_matches "\$FLUTTY_TOKEN" 2>/dev/null | while IFS= read -r item; do
        emit_line command "\$item" || break
      done
    elif command -v bash >/dev/null 2>&1; then
      emit_bash_matches command "\$FLUTTY_TOKEN" 2>/dev/null | while IFS= read -r item; do
        emit_line command "\$item" || break
      done
    else
      emit_command_fallback "\$FLUTTY_TOKEN"
    fi
    if [ "\$FLUTTY_INCLUDE_CD_SHORTCUTS" = 1 ]; then
      emit_line cd_directory ..
      emit_path_matches directory ''
    fi
    ;;
  argument)
    if ! emit_dynamic_argument_matches && [ -n "\$FLUTTY_TOKEN" ]; then
      emit_path_matches path "\$FLUTTY_TOKEN"
    fi
    ;;
  directory)
    emit_path_matches directory "\$FLUTTY_TOKEN"
    ;;
esac
__FLUTTY_COMPLETION__
''';
}

String _bashCompWordsAssignment(ShellCompletionInvocation invocation) {
  final words = invocation.words.isEmpty && invocation.commandName != null
      ? <String>[normalizeShellCompletionToken(invocation.commandName!)]
      : invocation.words.toList(growable: true);
  while (words.length <= invocation.wordIndex) {
    words.add('');
  }
  if (invocation.wordIndex >= 0 && invocation.wordIndex < words.length) {
    words[invocation.wordIndex] = invocation.token;
  }
  return 'COMP_WORDS=(${words.map(shellEscapePosix).join(' ')})';
}

/// PowerShell logic that normalizes the active Windows shell name into `cmd`,
/// `powershell`, `pwsh`, or an empty string.
///
/// When a mux pane reports its foreground command, Dart assigns `$__flShell`
/// before this script runs. For plain Windows OpenSSH sessions, that foreground
/// command is not observable from the side channel, so this falls back to the
/// OpenSSH `DefaultShell` registry value. Missing `DefaultShell` means OpenSSH is
/// using its default `cmd.exe` shell.
const _windowsShellDetectionLogic = r'''
function __flNormalizeShellName([string]$value){
if(!$value){return ''}
$value=[System.IO.Path]::GetFileNameWithoutExtension($value).ToLowerInvariant()
while($value.StartsWith('-')){$value=$value.Substring(1)}
if($value -eq 'cmd' -or $value -eq 'powershell' -or $value -eq 'pwsh'){return $value}
return ''
}
function __flResolveShellName(){
$__flResolved=__flNormalizeShellName $__flShell
if($__flResolved){return $__flResolved}
try{$__flDefault=(Get-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -ErrorAction Stop).DefaultShell}catch{$__flDefault=''}
$__flResolved=__flNormalizeShellName $__flDefault
if($__flResolved){return $__flResolved}
return 'cmd'
}
''';

/// Static PowerShell logic for [buildWindowsShellCompletionScript]. Reads the
/// `$__flMode`/`$__flToken`/`$__flCwd`/`$__flLimit` parameters assigned by the
/// caller and appends `<kind>\t<value>` lines to `$__flOut`, matching
/// [parseShellCompletionOutput]. Paths use forward slashes and are relative to
/// the token, like the POSIX completion fallback.
const _windowsCompletionLogic = r'''
$__flShell=__flResolveShellName
if($__flCwd){Set-Location -LiteralPath $__flCwd -ErrorAction SilentlyContinue}
function __flEmit([string]$kind,[string]$value){
if(!$value -or $__flEmitCount -ge $__flLimit){return $false}
if($value.IndexOf([char]9) -ge 0 -or $value.IndexOf([char]10) -ge 0 -or $value.IndexOf([char]13) -ge 0){return $true}
$script:__flEmitCount++
[void]$__flOut.Append($kind);[void]$__flOut.Append([char]9);[void]$__flOut.Append($value);[void]$__flOut.Append([char]10)
return ($__flEmitCount -lt $__flLimit)
}
function __flNormalizeCompletionText([string]$value){
if(!$value){return ''}
$value=$value.TrimEnd()
if($value.Length -ge 2){
$first=$value[0];$last=$value[$value.Length-1]
if(($first -eq "'" -and $last -eq "'") -or ($first -eq '"' -and $last -eq '"')){
$value=$value.Substring(1,$value.Length-2)
if($first -eq "'"){$value=$value -replace "''","'"}
else{$value=$value -replace '`(.)','$1' -replace '""','"'}
}
}
return ($value -replace '\\','/')
}
function __flTryTabExpansion(){
if($__flShell -eq 'cmd'){return $false}
if(!(Get-Command TabExpansion2 -ErrorAction SilentlyContinue)){return $false}
$__flCompletion=TabExpansion2 $__flCommandLine $__flCursorOffset
if(!$__flCompletion -or !$__flCompletion.CompletionMatches){return $false}
$__flAny=$false
foreach($__m in $__flCompletion.CompletionMatches){
if($__flEmitCount -ge $__flLimit){break}
$__flText=__flNormalizeCompletionText ([string]$__m.CompletionText)
if(!$__flText){$__flText=__flNormalizeCompletionText ([string]$__m.ListItemText)}
if(!$__flText){continue}
$__flType=[string]$__m.ResultType
$__flKind='argument'
if($__flType -eq 'Command'){$__flKind='command'}
elseif($__flType -eq 'ProviderContainer'){$__flKind='directory'}
elseif($__flType -eq 'ProviderItem'){$__flKind='file'}
if($__flMode -eq 'argument' -and $__flKind -eq 'command'){continue}
if($__flMode -eq 'directory' -and $__flKind -ne 'directory'){continue}
$__flAny=$true
if(!(__flEmit $__flKind $__flText)){break}
}
return $__flAny
}
if($__flMode -eq 'command'){
$__flPat=[System.Management.Automation.WildcardPattern]::Escape($__flToken)+'*'
$__flCmds=@(Get-Command -Name $__flPat -ErrorAction SilentlyContinue|Select-Object -First $__flLimit)
foreach($__c in $__flCmds){
$__n=$__c.Name
if($__c.CommandType -eq 'Application'){$__n=[System.IO.Path]::GetFileNameWithoutExtension($__n)}
if($__n){if(!(__flEmit 'command' $__n)){break}}
}
}else{
$__flUsePathFallback=$true
if($__flMode -eq 'argument' -and (__flTryTabExpansion)){$__flUsePathFallback=$false}
if($__flUsePathFallback){
$__flPrefix=($__flToken -replace '[^/]*$','')
$__flBase=($__flToken -replace '.*/','')
if($__flPrefix){$__flDir=($__flPrefix -replace '/$','');if($__flDir -match '^[A-Za-z]:$'){$__flDir="$__flDir/"}}
else{$__flDir='.'}
$__flPat=[System.Management.Automation.WildcardPattern]::Escape($__flBase)+'*'
$__flItems=@(Get-ChildItem -LiteralPath $__flDir -ErrorAction SilentlyContinue|Where-Object {$_.Name -like $__flPat}|Select-Object -First $__flLimit)
foreach($__it in $__flItems){
$__nm=$__it.Name;$__val="$__flPrefix$__nm"
if($__it.PSIsContainer){if(!(__flEmit 'directory' $__val)){break}}
elseif($__flMode -ne 'directory'){if(!(__flEmit 'file' $__val)){break}}
}
}
}''';

/// Builds a PowerShell script that emits completion candidates for [invocation]
/// on a Windows remote, matching the `<kind>\t<value>` format that
/// [parseShellCompletionOutput] parses.
///
/// Command mode lists matching commands via `Get-Command` (executable extensions
/// stripped); argument mode asks PowerShell's native `TabExpansion2` completer;
/// directory mode enumerates the token's directory.
@visibleForTesting
String buildWindowsShellCompletionScript(ShellCompletionInvocation invocation) {
  final limit = invocation.maxSuggestions * 4;
  final shellCommand = _normalizeShellCompletionCommandName(
    invocation.shellCommand,
  );
  final assignments = StringBuffer()
    ..write(r'$__flMode=')
    ..write(powerShellSingleQuote(invocation.mode.name))
    ..write(';')
    ..write(r'$__flToken=')
    ..write(powerShellSingleQuote(invocation.token))
    ..write(';')
    ..write(r'$__flCwd=')
    ..write(powerShellSingleQuote(invocation.workingDirectory?.trim() ?? ''))
    ..write(';')
    ..write(r'$__flCommandLine=')
    ..write(powerShellSingleQuote(invocation.commandLine))
    ..write(';')
    ..write('\$__flCursorOffset=${invocation.cursorOffset};')
    ..write(r'$__flShell=')
    ..write(powerShellSingleQuote(shellCommand ?? ''))
    ..write(';')
    ..write(r'$__flEmitCount=0;')
    ..write('\$__flLimit=$limit;');
  return powerShellUtf8OutputScript(
    '$assignments$_windowsShellDetectionLogic$_windowsCompletionLogic',
  );
}

/// Builds a PowerShell script that emits recent PowerShell command history on a
/// Windows remote, matching [parseShellHistoryOutput].
///
/// Reads the PSReadLine `ConsoleHost_history.txt` file (the source of the
/// interactive shell's history) and emits each recent line as a `bash`-sourced
/// command so the existing parser treats it as a literal command string.
@visibleForTesting
String buildWindowsShellHistoryScript(ShellCompletionInvocation invocation) {
  final shellCommand = _normalizeShellCompletionCommandName(
    invocation.shellCommand,
  );
  final body = StringBuffer()
    ..write(r'$__flShell=')
    ..write(powerShellSingleQuote(shellCommand ?? ''))
    ..write(';')
    ..write(_windowsShellDetectionLogic)
    ..write(r'$__flShell=__flResolveShellName;')
    ..write(
      r'$__flHistPaths=New-Object System.Collections.Generic.List[string];',
    )
    ..write(
      r'try{$__flOpt=Get-PSReadLineOption -ErrorAction Stop;if($__flOpt.HistorySavePath){$__flHistPaths.Add($__flOpt.HistorySavePath)}}catch{}',
    )
    ..write(r'$__flFallbacks=@(')
    ..write(
      r"(Join-Path $env:APPDATA 'Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt'),",
    )
    ..write(
      r"(Join-Path $env:APPDATA 'Microsoft\PowerShell\PSReadLine\ConsoleHost_history.txt')",
    )
    ..write(');')
    ..write(
      r'foreach($__flFb in $__flFallbacks){if($__flFb -and !$__flHistPaths.Contains($__flFb)){$__flHistPaths.Add($__flFb)}}',
    )
    ..write(r'[void]$__flOut.Append(')
    ..write(powerShellSingleQuote('__FLUTTY_HISTORY_START__'))
    ..write(r');[void]$__flOut.Append([char]10);')
    ..write(r"if($__flShell -ne 'cmd'){")
    ..write(
      r'foreach($__flHist in $__flHistPaths){if(Test-Path -LiteralPath $__flHist -PathType Leaf){$__flLines=@(Get-Content -LiteralPath $__flHist -Tail 1200 -Encoding UTF8 -ErrorAction SilentlyContinue);',
    )
    ..write(
      r"foreach($__l in $__flLines){[void]$__flOut.Append('bash');[void]$__flOut.Append([char]9);[void]$__flOut.Append($__l);[void]$__flOut.Append([char]10)}break}}}",
    )
    ..write(r'[void]$__flOut.Append(')
    ..write(powerShellSingleQuote(_shellHistoryDoneMarker))
    ..write(r');[void]$__flOut.Append([char]10);');
  return powerShellUtf8OutputScript(body.toString());
}
