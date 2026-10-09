import 'package:flutter/foundation.dart';

/// URL scheme MonkeySSH registers for its own links.
const monkeySshLinkScheme = 'monkeyssh';

/// Standard SSH URL scheme MonkeySSH also accepts from other apps.
const sshLinkScheme = 'ssh';

/// Longest link MonkeySSH parses. Real links are far shorter.
const maxAppLinkLength = 2048;

/// Longest opaque agent session identifier a chat link may carry.
const maxAppLinkSessionIdLength = 512;

const _defaultSshPort = 22;
const _maxHostnameLength = 253;
const _maxUsernameLength = 255;

/// Query keys understood by `monkeyssh://` links.
abstract final class AppLinkQueryKeys {
  /// Opaque app-local saved-host identifier.
  static const host = 'host';

  /// Remote multiplexer window index.
  static const window = 'window';

  /// Opaque agent (ACP) session identifier.
  static const session = 'session';

  /// Opaque launch-preset identifier.
  static const id = 'id';
}

/// What a link asks MonkeySSH to do.
enum AppLinkAction {
  /// Open a saved host, optionally focusing one remote window.
  open,

  /// Open a native agent chat.
  chat,

  /// Review, then launch, a host's agent launch preset.
  preset,

  /// Open or add a host named by a standard `ssh://` URL.
  ssh,
}

/// Why a link was refused. Names are safe to log; they carry no link content.
enum AppLinkRejection {
  /// The link is longer than [maxAppLinkLength].
  tooLong,

  /// The text is not a URL.
  malformed,

  /// The scheme is neither `monkeyssh` nor `ssh`.
  unsupportedScheme,

  /// The `monkeyssh://` action is not one MonkeySSH understands.
  unknownAction,

  /// The link carries a port, user, or path that the action does not use.
  unexpectedComponent,

  /// A required query parameter is missing.
  missingParameter,

  /// A query parameter has an invalid value.
  invalidParameter,

  /// A query parameter appears more than once, so its meaning is ambiguous.
  duplicateParameter,

  /// The link embeds a password or similar secret.
  embeddedCredentials,
}

/// A parsed `monkeyssh://` or `ssh://` link.
///
/// Every identifier is an opaque app-local id. Links never carry hostnames
/// for saved hosts, commands, or prompt text; an `ssh://` link names a host
/// only so the user can review it before it is saved.
@immutable
sealed class AppLink {
  const AppLink();

  /// Coarse category safe for diagnostics.
  String get diagnosticsAction;
}

/// Opens saved host [hostId], focusing remote window [windowIndex] if given.
final class OpenHostAppLink extends AppLink {
  /// Creates an open-host link.
  const OpenHostAppLink({required this.hostId, this.windowIndex});

  /// Saved host identifier.
  final int hostId;

  /// Remote multiplexer window index to focus, if any.
  final int? windowIndex;

  @override
  String get diagnosticsAction => AppLinkAction.open.name;

  @override
  bool operator ==(Object other) =>
      other is OpenHostAppLink &&
      other.hostId == hostId &&
      other.windowIndex == windowIndex;

  @override
  int get hashCode => Object.hash(hostId, windowIndex);
}

/// Opens native agent chat [sessionId] on saved host [hostId].
final class OpenChatAppLink extends AppLink {
  /// Creates an open-chat link.
  const OpenChatAppLink({required this.hostId, required this.sessionId});

  /// Saved host identifier.
  final int hostId;

  /// Opaque agent session identifier.
  final String sessionId;

  @override
  String get diagnosticsAction => AppLinkAction.chat.name;

  @override
  bool operator ==(Object other) =>
      other is OpenChatAppLink &&
      other.hostId == hostId &&
      other.sessionId == sessionId;

  @override
  int get hashCode => Object.hash(hostId, sessionId);
}

/// Asks to launch agent launch preset [presetId] after the user reviews it.
///
/// Launch presets are host-scoped, one per saved host, so a preset's id is
/// the id of the host it belongs to.
final class LaunchPresetAppLink extends AppLink {
  /// Creates a launch-preset link.
  const LaunchPresetAppLink({required this.presetId});

  /// Opaque preset identifier (the owning saved host's id).
  final int presetId;

  @override
  String get diagnosticsAction => AppLinkAction.preset.name;

  @override
  bool operator ==(Object other) =>
      other is LaunchPresetAppLink && other.presetId == presetId;

  @override
  int get hashCode => presetId.hashCode;
}

/// A standard `ssh://[user@]host[:port]` URL with any credentials refused.
final class SshHostAppLink extends AppLink {
  /// Creates an ssh host link.
  const SshHostAppLink({required this.hostname, this.port, this.username});

  /// Target hostname or IP address.
  final String hostname;

  /// Explicit port, if the URL named one.
  final int? port;

  /// Login username, if the URL named one.
  final String? username;

  /// Port the connection would use.
  int get effectivePort => port ?? _defaultSshPort;

  /// Rebuilds the URL from the validated parts only, so nothing else from the
  /// original text (paths, queries, parameters) reaches the host form.
  String toSanitizedUrl() => Uri(
    scheme: sshLinkScheme,
    userInfo: username,
    host: hostname,
    port: port,
  ).toString();

  @override
  String get diagnosticsAction => AppLinkAction.ssh.name;

  @override
  bool operator ==(Object other) =>
      other is SshHostAppLink &&
      other.hostname == hostname &&
      other.port == port &&
      other.username == username;

  @override
  int get hashCode => Object.hash(hostname, port, username);
}

/// A link MonkeySSH refused, with the reason.
final class RejectedAppLink extends AppLink {
  /// Creates a rejected link.
  const RejectedAppLink(this.reason);

  /// Why the link was refused.
  final AppLinkRejection reason;

  @override
  String get diagnosticsAction => 'rejected';

  @override
  bool operator ==(Object other) =>
      other is RejectedAppLink && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;
}

/// Whether [uri] uses a scheme MonkeySSH handles as an app link.
bool isAppLinkUri(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  return scheme == monkeySshLinkScheme || scheme == sshLinkScheme;
}

/// Parses raw link text from the platform.
AppLink parseAppLinkString(String raw) {
  if (raw.length > maxAppLinkLength) {
    return const RejectedAppLink(AppLinkRejection.tooLong);
  }
  final uri = Uri.tryParse(raw.trim());
  if (uri == null) {
    return const RejectedAppLink(AppLinkRejection.malformed);
  }
  return parseAppLink(uri);
}

/// Parses a `monkeyssh://` or `ssh://` link.
///
/// Parsing is strict: every recognised parameter must appear at most once
/// and hold a well-formed value. Parameters MonkeySSH does not use, such as
/// a `prompt`, are ignored, so a link can never inject text into a session.
AppLink parseAppLink(Uri uri) {
  if (uri.toString().length > maxAppLinkLength) {
    return const RejectedAppLink(AppLinkRejection.tooLong);
  }
  return switch (uri.scheme.toLowerCase()) {
    monkeySshLinkScheme => _parseMonkeySshLink(uri),
    sshLinkScheme => _parseSshLink(uri),
    _ => const RejectedAppLink(AppLinkRejection.unsupportedScheme),
  };
}

AppLink _parseMonkeySshLink(Uri uri) {
  if (uri.userInfo.isNotEmpty) {
    return RejectedAppLink(
      uri.userInfo.contains(':')
          ? AppLinkRejection.embeddedCredentials
          : AppLinkRejection.unexpectedComponent,
    );
  }
  if (uri.hasPort) {
    return const RejectedAppLink(AppLinkRejection.unexpectedComponent);
  }
  final action = _monkeySshAction(uri);
  if (action == null) {
    return const RejectedAppLink(AppLinkRejection.unexpectedComponent);
  }
  if (action.isEmpty) {
    return const RejectedAppLink(AppLinkRejection.unknownAction);
  }

  final Map<String, List<String>> query;
  try {
    query = uri.queryParametersAll;
  } on Object {
    return const RejectedAppLink(AppLinkRejection.invalidParameter);
  }

  switch (action) {
    case 'open':
      final host = _readParameter(query, AppLinkQueryKeys.host, _readId);
      final window = _readParameter(
        query,
        AppLinkQueryKeys.window,
        _readWindowIndex,
        required: false,
      );
      return _firstRejection([host, window]) ??
          OpenHostAppLink(hostId: host.value!, windowIndex: window.value);
    case 'chat':
      final host = _readParameter(query, AppLinkQueryKeys.host, _readId);
      final session = _readParameter(
        query,
        AppLinkQueryKeys.session,
        _readSessionId,
      );
      return _firstRejection([host, session]) ??
          OpenChatAppLink(hostId: host.value!, sessionId: session.value!);
    case 'preset':
      final id = _readParameter(query, AppLinkQueryKeys.id, _readId);
      return _firstRejection([id]) ?? LaunchPresetAppLink(presetId: id.value!);
    default:
      return const RejectedAppLink(AppLinkRejection.unknownAction);
  }
}

/// The action is the authority (`monkeyssh://open`) or, for links written
/// without one, the single path segment (`monkeyssh:open`).
///
/// Returns an empty string when the link names no action and `null` when it
/// carries a path the action does not use.
String? _monkeySshAction(Uri uri) {
  final path = uri.path;
  if (uri.host.isNotEmpty) {
    return path.isEmpty || path == '/' ? uri.host.toLowerCase() : null;
  }
  final segments = uri.pathSegments
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);
  return switch (segments.length) {
    0 => '',
    1 => segments.single.toLowerCase(),
    _ => null,
  };
}

AppLink _parseSshLink(Uri uri) {
  final userInfo = uri.userInfo;
  // `ssh://user:secret@host` carries a password. Refuse the whole link
  // instead of trimming it, so the secret is never stored or displayed.
  if (userInfo.contains(':')) {
    return const RejectedAppLink(AppLinkRejection.embeddedCredentials);
  }
  // RFC draft connection parameters (`user;fingerprint=...@host`) are not
  // supported and could smuggle other secrets.
  if (userInfo.contains(';')) {
    return const RejectedAppLink(AppLinkRejection.invalidParameter);
  }
  String? username;
  if (userInfo.isNotEmpty) {
    try {
      username = Uri.decodeComponent(userInfo);
    } on Object {
      return const RejectedAppLink(AppLinkRejection.invalidParameter);
    }
    if (username.isEmpty ||
        username.length > _maxUsernameLength ||
        _whitespaceOrControl.hasMatch(username) ||
        username.contains(':') ||
        username.contains('@')) {
      return const RejectedAppLink(AppLinkRejection.invalidParameter);
    }
  }

  final hostname = uri.host;
  if (hostname.isEmpty) {
    return const RejectedAppLink(AppLinkRejection.missingParameter);
  }
  if (hostname.length > _maxHostnameLength ||
      !(_hostnamePattern.hasMatch(hostname) ||
          _ipv6Pattern.hasMatch(hostname))) {
    return const RejectedAppLink(AppLinkRejection.invalidParameter);
  }

  int? port;
  if (uri.hasPort) {
    port = uri.port;
    if (port < 1 || port > 65535) {
      return const RejectedAppLink(AppLinkRejection.invalidParameter);
    }
  }

  return SshHostAppLink(hostname: hostname, port: port, username: username);
}

final class _ParameterRead<T> {
  const _ParameterRead.value(this.value) : rejection = null;

  const _ParameterRead.rejected(AppLinkRejection this.rejection) : value = null;

  final T? value;
  final AppLinkRejection? rejection;
}

_ParameterRead<T> _readParameter<T>(
  Map<String, List<String>> query,
  String key,
  T? Function(String value) read, {
  bool required = true,
}) {
  final values = query[key];
  if (values == null || values.isEmpty) {
    return required
        ? const _ParameterRead.rejected(AppLinkRejection.missingParameter)
        : const _ParameterRead.value(null);
  }
  if (values.length > 1) {
    return const _ParameterRead.rejected(AppLinkRejection.duplicateParameter);
  }
  final value = read(values.single);
  return value == null
      ? const _ParameterRead.rejected(AppLinkRejection.invalidParameter)
      : _ParameterRead.value(value);
}

RejectedAppLink? _firstRejection(List<_ParameterRead<Object>> reads) {
  for (final read in reads) {
    if (read.rejection case final reason?) {
      return RejectedAppLink(reason);
    }
  }
  return null;
}

final _idPattern = RegExp(r'^[1-9][0-9]{0,17}$');
final _windowIndexPattern = RegExp(r'^(0|[1-9][0-9]{0,5})$');
final _whitespaceOrControl = RegExp(r'[\s\x00-\x1F\x7F]');
final _hostnamePattern = RegExp(
  r'^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$',
);
final _ipv6Pattern = RegExp(r'^[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]*$');

int? _readId(String value) =>
    _idPattern.hasMatch(value) ? int.parse(value) : null;

int? _readWindowIndex(String value) =>
    _windowIndexPattern.hasMatch(value) ? int.parse(value) : null;

String? _readSessionId(String value) {
  if (value.isEmpty ||
      value.length > maxAppLinkSessionIdLength ||
      _whitespaceOrControl.hasMatch(value)) {
    return null;
  }
  return value;
}
