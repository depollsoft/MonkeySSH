/// Remote terminal multiplexer backend configured for a host.
enum RemoteMuxBackend {
  /// Let MonkeySSH choose the best available backend.
  auto,

  /// Use the bundled MonkeyMux helper when possible.
  monkeyMux,

  /// Use the remote host's tmux installation.
  tmux,
}

/// Persistence and presentation helpers for [RemoteMuxBackend].
extension RemoteMuxBackendPresentation on RemoteMuxBackend {
  /// Stable database value.
  String get storageValue => switch (this) {
    RemoteMuxBackend.auto => 'auto',
    RemoteMuxBackend.monkeyMux => 'monkey_mux',
    RemoteMuxBackend.tmux => 'tmux',
  };

  /// Human-readable label used in host settings.
  String get label => switch (this) {
    RemoteMuxBackend.auto => 'Automatic',
    RemoteMuxBackend.monkeyMux => 'MonkeyMux',
    RemoteMuxBackend.tmux => 'tmux',
  };

  /// Parses a stored backend value.
  static RemoteMuxBackend? fromStorageValue(String? value) => switch (value
      ?.trim()) {
    'auto' => RemoteMuxBackend.auto,
    'monkey_mux' || 'monkeyMux' || 'monkeymux' => RemoteMuxBackend.monkeyMux,
    'tmux' => RemoteMuxBackend.tmux,
    _ => null,
  };
}

/// Resolves the remote multiplexer backend a host should use at startup.
RemoteMuxBackend resolveRemoteMuxBackendForStartup({
  String? storedBackend,
  String? tmuxExtraFlags,
}) {
  final parsedBackend = RemoteMuxBackendPresentation.fromStorageValue(
    storedBackend,
  );
  final hasTmuxExtraFlags =
      tmuxExtraFlags != null && tmuxExtraFlags.trim().isNotEmpty;
  if (parsedBackend != null && parsedBackend != RemoteMuxBackend.auto) {
    return parsedBackend;
  }
  if (hasTmuxExtraFlags) {
    return RemoteMuxBackend.tmux;
  }
  return parsedBackend ?? RemoteMuxBackend.auto;
}

/// Suggests a multiplexer session name for a host from its label (or its
/// hostname), so saved hosts that reach the same machine get sessions of
/// their own instead of sharing one by default.
///
/// The name is lowercase letters, digits and dashes, which both MonkeyMux
/// and tmux accept. [taken] holds the session names other saved hosts on the
/// same machine already use; a clash gets a numeric suffix.
String suggestMuxSessionName({
  required String label,
  required String hostname,
  Iterable<String> taken = const [],
}) {
  String slug(String value) => value
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  var base = slug(label);
  if (base.isEmpty) base = slug(hostname.split('.').first);
  if (base.isEmpty) base = 'main';
  if (base.length > 32) {
    base = base.substring(0, 32).replaceAll(RegExp(r'-+$'), '');
  }
  final used = {for (final name in taken) name.trim().toLowerCase()};
  if (!used.contains(base)) return base;
  for (var suffix = 2; ; suffix++) {
    final candidate = '$base-$suffix';
    if (!used.contains(candidate)) return candidate;
  }
}
