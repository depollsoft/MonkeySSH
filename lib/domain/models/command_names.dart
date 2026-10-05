/// Shared helpers for reasoning about a process by its command line.
///
/// Several layers (tmux window metadata, shell completion, agent launch
/// presets, MonkeyMux control-report suppression) each used to carry their own
/// copy of "take the first token, strip the directory, lower-case it and drop
/// a Windows executable suffix". They disagreed on details such as login-shell
/// dashes and which suffixes count, so the shared versions live here.
library;

final _whitespacePattern = RegExp(r'\s+');
final _pathSeparatorPattern = RegExp(r'[\\/]');
final _executableSuffixPattern = RegExp(r'\.(?:exe|cmd|bat|ps1|com)$');

/// Normalizes a command line or executable path to its lower-cased basename.
///
/// Returns `null` for an empty input. A leading `-` (the login-shell marker
/// that tmux and MonkeyMux report for `-zsh`) is removed, as is a Windows
/// executable suffix such as `.exe`.
String? normalizeCommandBasename(String? command) {
  final trimmed = command?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  final token = trimmed.split(_whitespacePattern).first;
  var basename = token.split(_pathSeparatorPattern).last.toLowerCase();
  if (basename.startsWith('-')) {
    basename = basename.substring(1);
  }
  basename = basename.replaceFirst(_executableSuffixPattern, '');
  return basename.isEmpty ? null : basename;
}

/// Basenames of interactive shells the app treats as "a shell prompt".
const shellCommandBasenames = <String>{
  'ash',
  'bash',
  'cmd',
  'csh',
  'dash',
  'elvish',
  'fish',
  'ion',
  'ksh',
  'ksh93',
  'mksh',
  'nu',
  'oil',
  'osh',
  'powershell',
  'pwsh',
  'sh',
  'tcsh',
  'xonsh',
  'yash',
  'zsh',
};

/// Whether [command] (a command line, path or basename) names a shell.
bool isShellCommandBasename(String? command) =>
    shellCommandBasenames.contains(normalizeCommandBasename(command));
