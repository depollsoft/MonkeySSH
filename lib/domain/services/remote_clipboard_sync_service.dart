import 'dart:convert';

import 'clipboard_sharing_service.dart';
import 'remote_file_service.dart';

/// Builds shell commands for syncing the remote machine clipboard over SSH.
///
/// Unlike OSC 52, these commands talk to clipboard utilities on the remote
/// host itself, allowing the app to mirror clipboard changes between the
/// client device and the remote machine when common clipboard tools exist.
class RemoteClipboardSyncService {
  /// Creates a new [RemoteClipboardSyncService].
  const RemoteClipboardSyncService();

  /// Marker emitted when the remote host does not expose a supported clipboard.
  static const unsupportedMarker = '__FLUTTY_REMOTE_CLIPBOARD_UNSUPPORTED__';

  /// Returns whether [text] is small enough to sync safely.
  static bool canSyncText(String text) =>
      utf8.encode(text).length <= ClipboardSharingService.maxPayloadBytes;

  /// Builds a remote command that reads the remote clipboard and prints it as
  /// a single base64 line. A trailing sentinel protects clipboard newlines
  /// from shell command substitution and is removed before encoding.
  static String buildReadCommand() =>
      '''
if command -v pbpaste >/dev/null 2>&1; then
  flutty_clipboard_data="\$(pbpaste 2>/dev/null; printf .)"
elif command -v wl-paste >/dev/null 2>&1; then
  flutty_clipboard_data="\$(wl-paste --no-newline 2>/dev/null; printf .)"
elif command -v xclip >/dev/null 2>&1; then
  flutty_clipboard_data="\$(xclip -selection clipboard -o 2>/dev/null; printf .)"
elif command -v xsel >/dev/null 2>&1; then
  flutty_clipboard_data="\$(xsel --clipboard --output 2>/dev/null; printf .)"
else
  printf %s ${shellEscapePosix(unsupportedMarker)}
  exit 0
fi
printf %s "\${flutty_clipboard_data%.}" | base64 | tr -d '\\r\\n'
''';

  /// Builds a remote command that writes [text] into the remote clipboard.
  static String buildWriteCommand(String text) {
    final payload = shellEscapePosix(
      ClipboardSharingService.encodePayload(text),
    );
    final unsupported = shellEscapePosix(unsupportedMarker);
    return '''
flutty_clipboard_payload=$payload
if command -v python3 >/dev/null 2>&1; then
  flutty_clipboard_data="\$(python3 -c 'import base64,sys;sys.stdout.write(base64.b64decode(sys.argv[1]).decode("utf-8","ignore"))' "\$flutty_clipboard_payload"; printf .)"
elif command -v base64 >/dev/null 2>&1; then
  flutty_clipboard_data="\$(printf %s "\$flutty_clipboard_payload" | base64 -d 2>/dev/null || printf %s "\$flutty_clipboard_payload" | base64 -D 2>/dev/null; printf .)"
else
  printf %s $unsupported
  exit 0
fi
if command -v pbcopy >/dev/null 2>&1; then
  printf %s "\${flutty_clipboard_data%.}" | pbcopy
elif command -v wl-copy >/dev/null 2>&1; then
  printf %s "\${flutty_clipboard_data%.}" | wl-copy
elif command -v xclip >/dev/null 2>&1; then
  printf %s "\${flutty_clipboard_data%.}" | xclip -selection clipboard
elif command -v xsel >/dev/null 2>&1; then
  printf %s "\${flutty_clipboard_data%.}" | xsel --clipboard --input
else
  printf %s $unsupported
fi
''';
  }

  /// Parses the stdout from [buildReadCommand].
  static ({bool supported, String text}) parseReadOutput(String output) {
    final trimmed = output.trim();
    if (trimmed == unsupportedMarker) {
      return (supported: false, text: '');
    }
    final decoded = ClipboardSharingService.decodePayload(trimmed);
    if (decoded == null) {
      return (supported: false, text: '');
    }
    return (supported: true, text: decoded);
  }

  /// Returns whether a remote write command reported an unsupported clipboard.
  static bool outputIndicatesUnsupported(String output) =>
      output.trim() == unsupportedMarker;
}
