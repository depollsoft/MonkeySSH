/// Shared POSIX shell quoting, path escaping, and remote PATH/profile helpers.
library;

/// Quotes [value] as a single POSIX shell word using single quotes and `'\''`
/// for embedded apostrophes.
String shellEscapePosix(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// Quotes [value] as a single POSIX shell word using `'"'"'` for embedded
/// apostrophes (functionally identical to [shellEscapePosix] in POSIX `sh`,
/// preserved for command builders whose output is matched verbatim).
String shellEscapePosixArg(String value) =>
    "'${value.replaceAll("'", "'\"'\"'")}'";

/// Quotes a POSIX path, expanding only a leading `~` or `~/` to `"$HOME"`.
///
/// When [guardLeadingDash] is true, a relative path beginning with `-` is
/// prefixed with `./` so downstream tools do not parse it as an option.
/// When [slashOutsideQuotes] is true, `~/` emits `"$HOME"` and `~/foo` emits
/// `"$HOME"/'foo'` rather than `"$HOME"'/foo'`.
String shellEscapePosixPath(
  String path, {
  bool guardLeadingDash = false,
  bool slashOutsideQuotes = false,
}) {
  if (path == '~' || (slashOutsideQuotes && path == '~/')) {
    return r'"$HOME"';
  }
  if (path.startsWith('~/')) {
    return slashOutsideQuotes
        ? '"\$HOME"/${shellEscapePosix(path.substring(2))}'
        : r'"$HOME"' + shellEscapePosix(path.substring(1));
  }
  if (guardLeadingDash && path.startsWith('-')) {
    return shellEscapePosix('./$path');
  }
  return shellEscapePosix(path);
}

/// Fast PATH export that prepends common user and Homebrew tool directories
/// without sourcing interactive shell startup files.
const String remoteFastPathPrefix =
    r'export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$HOME/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/homebrew/bin:$HOME/homebrew/sbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"; ';

/// POSIX command prefix that sources login and interactive shell startup files
/// quietly and ensures [remoteFastPathPrefix] directories are on `PATH`.
const String remoteProfileSourcingPrefix =
    '$remoteFastPathPrefix'
    '{ . ~/.profile; . ~/.bash_profile; . ~/.zprofile; } >/dev/null 2>&1; '
    r'case "${SHELL##*/}" in '
    'zsh) { . ~/.zshrc; } >/dev/null 2>&1;; '
    'bash) { . ~/.bashrc; } >/dev/null 2>&1;; '
    'esac; '
    '$remoteFastPathPrefix';
