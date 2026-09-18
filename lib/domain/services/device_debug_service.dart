import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'diagnostics_log_service.dart';
import 'ssh_exec_queue.dart';
import 'ssh_service.dart';
import 'windows_remote_powershell.dart';

/// Native Android service used to discover Wireless ADB endpoints.
final androidDeviceDebugPlatformProvider = Provider<AndroidDeviceDebugPlatform>(
  (ref) => MethodChannelAndroidDeviceDebugPlatform(),
);

/// Runner for ADB commands executed on the connected SSH host.
final remoteAdbCommandRunnerProvider = Provider<RemoteAdbCommandRunner>(
  (ref) => const SshRemoteAdbCommandRunner(),
);

/// Registry for device-debug controllers scoped to active SSH sessions.
final deviceDebugSessionServiceProvider = Provider<DeviceDebugSessionRegistry>((
  ref,
) {
  final service = DeviceDebugSessionService(
    platform: ref.watch(androidDeviceDebugPlatformProvider),
    remoteRunner: ref.watch(remoteAdbCommandRunnerProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// Whether this device can expose Wireless ADB to an SSH host.
///
/// Secure Wireless debugging requires Android 11 (API 30), so older devices
/// never see the terminal action.
final deviceDebugSupportedProvider = FutureProvider<bool>((ref) async {
  final platform = ref.watch(androidDeviceDebugPlatformProvider);
  if (!platform.supported) {
    return false;
  }
  return platform.isWirelessDebuggingSupported();
});

/// Wireless ADB endpoint category advertised over mDNS.
enum AndroidAdbServiceKind {
  /// Temporary endpoint used with a six-digit pairing code.
  pairing,

  /// TLS endpoint used for normal ADB connections after pairing.
  connect,
}

/// A Wireless ADB endpoint discovered on the current Android device.
@immutable
class AndroidAdbEndpoint {
  /// Creates a discovered endpoint.
  const AndroidAdbEndpoint({
    required this.serviceName,
    required this.host,
    required this.port,
  });

  /// Creates an endpoint from a platform-channel value.
  @visibleForTesting
  factory AndroidAdbEndpoint.fromPlatformValue(Object? value) {
    if (value is! Map<Object?, Object?>) {
      throw const FormatException('ADB endpoint was not a map');
    }
    final serviceName = value['serviceName'];
    final host = value['host'];
    final port = value['port'];
    if (serviceName is! String ||
        serviceName.isEmpty ||
        host is! String ||
        host.isEmpty ||
        port is! int ||
        port < 1 ||
        port > 65535) {
      throw const FormatException('ADB endpoint fields were invalid');
    }
    return AndroidAdbEndpoint(serviceName: serviceName, host: host, port: port);
  }

  /// mDNS service instance name.
  final String serviceName;

  /// Device-local address resolved from mDNS.
  final String host;

  /// Ephemeral Wireless ADB port.
  final int port;
}

/// Platform boundary for Android Wireless ADB discovery and settings.
abstract interface class AndroidDeviceDebugPlatform {
  /// Whether Android device debugging is available on this platform.
  bool get supported;

  /// Whether this Android version supports secure Wireless debugging.
  Future<bool> isWirelessDebuggingSupported();

  /// Shows or updates the notification that collects the pairing code.
  ///
  /// Returns `false` when notifications are disabled, since the prompt is the
  /// only way to type the code without pausing Android's pairing screen.
  Future<bool> showPairingCodePrompt({
    required String status,
    bool busy = false,
  });

  /// Removes the pairing-code notification.
  Future<void> hidePairingCodePrompt();

  /// Brings MonkeySSH back to the foreground after pairing succeeds.
  ///
  /// Returns `false` when Android blocked the direct return; a tappable
  /// notification is always posted as the reliable way back.
  Future<bool> returnToApp({required String status});

  /// Cancels the "tap to return" notification.
  Future<void> hideReturnPrompt();

  /// Pairing codes submitted from the notification reply field.
  Stream<String> get submittedPairingCodes;

  /// Opens Android Developer options.
  Future<bool> openDeveloperOptions();

  /// Discovers the current device's endpoint for [kind].
  Future<AndroidAdbEndpoint?> discoverEndpoint(
    AndroidAdbServiceKind kind, {
    Duration timeout = const Duration(seconds: 6),
  });
}

/// Method-channel implementation of [AndroidDeviceDebugPlatform].
class MethodChannelAndroidDeviceDebugPlatform
    implements AndroidDeviceDebugPlatform {
  /// Creates the Android platform bridge.
  MethodChannelAndroidDeviceDebugPlatform({
    MethodChannel channel = const MethodChannel(
      'xyz.depollsoft.monkeyssh/device_debug',
    ),
  }) : _channel = channel {
    _channel.setMethodCallHandler(_handlePlatformCall);
  }

  final MethodChannel _channel;
  Future<void> _discoveryTail = Future<void>.value();
  final _pairingCodes = StreamController<String>.broadcast();

  @override
  Stream<String> get submittedPairingCodes => _pairingCodes.stream;

  Future<void> _handlePlatformCall(MethodCall call) async {
    if (call.method != 'pairingCodeSubmitted') {
      return;
    }
    final code = call.arguments;
    if (code is String && code.isNotEmpty && !_pairingCodes.isClosed) {
      _pairingCodes.add(code);
    }
  }

  @override
  Future<bool> showPairingCodePrompt({
    required String status,
    bool busy = false,
  }) async {
    if (!supported) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('showPairingCodePrompt', {
            'status': status,
            'busy': busy,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> hidePairingCodePrompt() async {
    if (!supported) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('hidePairingCodePrompt');
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }

  @override
  Future<bool> returnToApp({required String status}) async {
    if (!supported) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('returnToApp', {
            'status': status,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> hideReturnPrompt() async {
    if (!supported) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('hideReturnPrompt');
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }

  @override
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<bool> isWirelessDebuggingSupported() async {
    if (!supported) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>(
            'isWirelessDebuggingSupported',
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<bool> openDeveloperOptions() async {
    if (!supported) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('openDeveloperOptions') ?? false;
    } on PlatformException catch (error) {
      throw DeviceDebugException(
        kind: DeviceDebugErrorKind.settingsUnavailable,
        message: error.message ?? 'Could not open Android Developer options.',
      );
    } on MissingPluginException {
      throw const DeviceDebugException(
        kind: DeviceDebugErrorKind.settingsUnavailable,
        message: 'Android Developer options are unavailable in this build.',
      );
    }
  }

  @override
  Future<AndroidAdbEndpoint?> discoverEndpoint(
    AndroidAdbServiceKind kind, {
    Duration timeout = const Duration(seconds: 6),
  }) {
    final previous = _discoveryTail;
    final release = Completer<void>();
    _discoveryTail = release.future;
    return _discoverEndpointAfter(
      previous,
      kind,
      timeout: timeout,
    ).whenComplete(release.complete);
  }

  Future<AndroidAdbEndpoint?> _discoverEndpointAfter(
    Future<void> previous,
    AndroidAdbServiceKind kind, {
    required Duration timeout,
  }) async {
    await previous;
    if (!supported) {
      throw const DeviceDebugException(
        kind: DeviceDebugErrorKind.unsupported,
        message: 'Device debugging is only available on Android.',
      );
    }
    try {
      final value = await _channel.invokeMethod<Object?>(
        'discoverAdbEndpoint',
        <String, Object>{
          'kind': kind.name,
          'timeoutMs': timeout.inMilliseconds,
        },
      );
      if (value == null) {
        return null;
      }
      return AndroidAdbEndpoint.fromPlatformValue(value);
    } on FormatException catch (error) {
      throw DeviceDebugException(
        kind: DeviceDebugErrorKind.discoveryFailed,
        message: error.message,
      );
    } on PlatformException catch (error) {
      if (error.code == 'unsupported_android_version') {
        throw const DeviceDebugException(
          kind: DeviceDebugErrorKind.unsupported,
          message:
              'Device debugging needs Wireless debugging, which requires '
              'Android 11 or newer.',
        );
      }
      throw DeviceDebugException(
        kind: DeviceDebugErrorKind.discoveryFailed,
        message: error.message ?? 'Wireless ADB discovery failed.',
      );
    } on MissingPluginException {
      throw const DeviceDebugException(
        kind: DeviceDebugErrorKind.discoveryFailed,
        message: 'Wireless ADB discovery is unavailable in this build.',
      );
    }
  }
}

/// Failure categories surfaced by the device-debug experience.
enum DeviceDebugErrorKind {
  /// The current platform cannot provide the feature.
  unsupported,

  /// Android mDNS discovery could not run.
  discoveryFailed,

  /// Android Developer options could not be opened.
  settingsUnavailable,

  /// ADB is not installed or available on the SSH host.
  adbUnavailable,

  /// A remote ADB command could not be executed.
  remoteCommandFailed,

  /// The SSH server denied or failed the reverse port forward.
  remoteForwardDenied,

  /// The SSH server exposed the reverse forward beyond loopback.
  remoteForwardExposed,

  /// The pairing code was not six digits.
  pairingCodeInvalid,

  /// ADB rejected the pairing request.
  pairingFailed,

  /// ADB could not connect through the reverse tunnel.
  connectionFailed,
}

/// Typed error shown through the device-debug UI.
class DeviceDebugException implements Exception {
  /// Creates a device-debug error.
  const DeviceDebugException({required this.kind, required this.message});

  /// Error category.
  final DeviceDebugErrorKind kind;

  /// User-facing explanation.
  final String message;

  @override
  String toString() => message;
}

/// Current session state of the Android device-debug bridge.
enum DeviceDebugPhase {
  /// No bridge is active.
  off,

  /// Looking for ADB and the device endpoint.
  searching,

  /// Wireless debugging has not been detected yet.
  waitingForWirelessDebugging,

  /// The SSH host needs a pairing code.
  waitingForPairingCode,

  /// Pairing the SSH host with Android.
  pairing,

  /// Connecting the SSH host's ADB client.
  connecting,

  /// Remote ADB is connected through the reverse tunnel.
  active,

  /// Disconnecting ADB and closing the reverse tunnels.
  stopping,

  /// The latest operation failed.
  error,
}

/// Immutable state published by [DeviceDebugSessionController].
@immutable
class DeviceDebugState {
  /// Creates device-debug state.
  const DeviceDebugState({
    required this.phase,
    required this.message,
    this.errorKind,
    this.remoteAddress,
  });

  /// Initial inactive state.
  static const off = DeviceDebugState(
    phase: DeviceDebugPhase.off,
    message: 'Device debugging is off.',
  );

  /// Current lifecycle phase.
  final DeviceDebugPhase phase;

  /// User-facing status or recovery guidance.
  final String message;

  /// Latest failure category, when applicable.
  final DeviceDebugErrorKind? errorKind;

  /// Loopback ADB serial exposed on the SSH host.
  final String? remoteAddress;

  /// Whether the bridge is ready for remote ADB commands.
  bool get isActive => phase == DeviceDebugPhase.active;

  /// Whether an operation is currently running.
  bool get isBusy =>
      phase == DeviceDebugPhase.searching ||
      phase == DeviceDebugPhase.pairing ||
      phase == DeviceDebugPhase.connecting ||
      phase == DeviceDebugPhase.stopping;
}

/// Result of one ADB command executed on the SSH host.
@immutable
class RemoteAdbCommandResult {
  /// Creates an ADB command result.
  const RemoteAdbCommandResult({required this.exitCode, required this.output});

  /// Remote process exit code.
  final int? exitCode;

  /// Combined bounded stdout and stderr.
  final String output;

  /// Whether the remote command exited successfully.
  bool get succeeded => exitCode == 0;
}

/// Effective bind scope reported for a remote SSH listener.
enum RemoteListenerScope {
  /// Every matching listener is bound to a loopback address.
  loopback,

  /// At least one matching listener is bound to a non-loopback address.
  exposed,

  /// The remote host could not report the listener scope.
  unknown,
}

/// Marker printed after a successful remote listener probe.
///
/// Bounded command output can be truncated, so the classifier only trusts a
/// probe that reported this marker.
@visibleForTesting
const remoteListenerProbeDoneMarker = '__monkeyssh_listener_done__';

/// Marker printed when the remote host cannot enumerate listeners.
@visibleForTesting
const remoteListenerProbeUnavailableMarker =
    '__monkeyssh_listener_unavailable__';

/// Builds the POSIX probe that reports listeners bound to [port].
///
/// The probe forces `LC_ALL=C` so state columns stay in English, filters to
/// the requested port so output cannot be truncated away, and always ends with
/// a completion marker.
@visibleForTesting
String buildPosixListenerProbeCommand(int port) =>
    'LC_ALL=C; export LC_ALL; '
    'if command -v ss >/dev/null 2>&1; then '
    r'__monkeyssh_listeners=$(ss -ltn 2>/dev/null); '
    r'__monkeyssh_status=$?; '
    'elif command -v netstat >/dev/null 2>&1; then '
    r'__monkeyssh_listeners=$(netstat -an 2>/dev/null); '
    r'__monkeyssh_status=$?; '
    'else '
    "printf '%s\\n' '$remoteListenerProbeUnavailableMarker'; "
    "printf '%s\\n' '$remoteListenerProbeDoneMarker'; exit 0; fi; "
    r'if [ "$__monkeyssh_status" -ne 0 ]; then '
    "printf '%s\\n' '$remoteListenerProbeUnavailableMarker'; "
    "printf '%s\\n' '$remoteListenerProbeDoneMarker'; exit 0; fi; "
    r"printf '%s\n' "
    r'"$__monkeyssh_listeners" | '
    "grep -E '[:.]$port([^0-9]|\$)' || true; "
    "printf '%s\\n' '$remoteListenerProbeDoneMarker'";

/// Builds the Windows probe that reports listeners bound to [port].
///
/// `Get-NetTCPConnection` returns structured data, so the result does not
/// depend on the host's display language the way `netstat` output does.
@visibleForTesting
String buildWindowsListenerProbeCommand(int port) {
  final body =
      'try{Get-NetTCPConnection -State Listen -LocalPort $port '
      '-ErrorAction Stop | ForEach-Object { '
      r"[void]$__flOut.AppendLine('LISTEN ' + $_.LocalAddress + ':' + "
      r'[string]$_.LocalPort) }} catch { '
      r'[void]$__flOut.AppendLine('
      "'$remoteListenerProbeUnavailableMarker')}; "
      r'[void]$__flOut.AppendLine('
      "'$remoteListenerProbeDoneMarker');";
  return buildWindowsPowerShellCommand(powerShellUtf8OutputScript(body));
}

/// Classifies the effective bind scope for [port] from a listener probe.
@visibleForTesting
RemoteListenerScope classifyRemoteListenerScope(String output, int port) {
  final lines = const LineSplitter().convert(output);
  final completed = lines.any(
    (line) => line.trim() == remoteListenerProbeDoneMarker,
  );
  if (!completed) {
    // Truncated or failed output cannot prove the listener is private.
    return RemoteListenerScope.unknown;
  }
  if (lines.any(
    (line) => line.trim() == remoteListenerProbeUnavailableMarker,
  )) {
    return RemoteListenerScope.unknown;
  }

  var foundLoopback = false;
  for (final line in lines) {
    final normalizedLine = line.toUpperCase();
    if (!normalizedLine.contains('LISTEN')) {
      continue;
    }
    for (final token in line.trim().split(RegExp(r'\s+'))) {
      final host = _listenerHostForPort(token, port);
      if (host == null) {
        continue;
      }
      final normalizedHost = host.toLowerCase();
      if (normalizedHost == '*' ||
          normalizedHost == '0.0.0.0' ||
          normalizedHost == '::') {
        return RemoteListenerScope.exposed;
      }
      if (normalizedHost == 'localhost' ||
          normalizedHost == '::1' ||
          normalizedHost.startsWith('127.') ||
          normalizedHost.startsWith('::ffff:127.')) {
        foundLoopback = true;
        continue;
      }
      return RemoteListenerScope.exposed;
    }
  }
  return foundLoopback
      ? RemoteListenerScope.loopback
      : RemoteListenerScope.unknown;
}

/// Coarse outcome of an `adb connect` attempt, used for diagnostics only.
@visibleForTesting
String classifyAdbConnectOutcome(String output) {
  final normalized = output.toLowerCase();
  if (normalized.contains('connected to')) {
    return 'connected';
  }
  if (normalized.contains('authenticate') ||
      normalized.contains('unauthorized') ||
      normalized.contains('pair')) {
    return 'auth_required';
  }
  if (normalized.contains('refused')) {
    return 'refused';
  }
  if (normalized.contains('timed out') || normalized.contains('timeout')) {
    return 'timeout';
  }
  if (normalized.contains('unable to connect') ||
      normalized.contains('failed to connect') ||
      normalized.contains('no route')) {
    return 'unreachable';
  }
  return normalized.isEmpty ? 'empty' : 'unknown';
}

String? _listenerHostForPort(String token, int port) {
  final colonSuffix = ':$port';
  final dotSuffix = '.$port';
  late final String host;
  if (token.endsWith(colonSuffix)) {
    host = token.substring(0, token.length - colonSuffix.length);
  } else if (token.endsWith(dotSuffix)) {
    host = token.substring(0, token.length - dotSuffix.length);
  } else {
    return null;
  }
  return host.replaceAll('[', '').replaceAll(']', '');
}

/// Boundary for ADB commands executed on the SSH host.
abstract interface class RemoteAdbCommandRunner {
  /// Returns whether `adb` is installed and runnable.
  Future<bool> isAvailable(SshSession session);

  /// Returns whether the installed ADB supports secure wireless pairing.
  Future<bool> supportsPairing(SshSession session);

  /// Reports the effective bind scope of the remote listener on [port].
  Future<RemoteListenerScope> listenerScope(SshSession session, int port);

  /// Pairs the remote ADB identity using [pairingCode].
  Future<RemoteAdbCommandResult> pair(
    SshSession session, {
    required String address,
    required String pairingCode,
  });

  /// Connects remote ADB to [address].
  Future<RemoteAdbCommandResult> connect(
    SshSession session, {
    required String address,
  });

  /// Disconnects the remote ADB serial at [address].
  Future<RemoteAdbCommandResult> disconnect(
    SshSession session, {
    required String address,
  });
}

/// Candidate ADB locations probed when the remote `PATH` does not resolve it.
///
/// SSH exec channels only see a minimal `PATH`, so Homebrew and Android SDK
/// installs that an interactive shell resolves are otherwise invisible.
const _adbFallbackPaths = <String>[
  r'$ANDROID_HOME/platform-tools/adb',
  r'$ANDROID_SDK_ROOT/platform-tools/adb',
  r'$HOME/Library/Android/sdk/platform-tools/adb',
  r'$HOME/Android/Sdk/platform-tools/adb',
  r'$HOME/homebrew/bin/adb',
  '/opt/homebrew/bin/adb',
  '/usr/local/bin/adb',
  '/usr/bin/adb',
  '/opt/android-sdk/platform-tools/adb',
];

/// Builds the POSIX script that resolves the remote host's `adb` binary.
///
/// Resolution order mirrors how a developer's own shell finds ADB:
/// the exec-channel `PATH`, then the user's login+interactive shell (where
/// Homebrew and Android SDK exports usually live), then well-known SDK
/// locations. The login shell is invoked as a child process rather than by
/// sourcing profiles inline, because a missing or failing `.` (dot) command
/// terminates a non-interactive POSIX shell outright.
@visibleForTesting
String buildRemoteAdbResolutionCommand() {
  final candidates = _adbFallbackPaths
      .map((candidate) => '"$candidate"')
      .join(' ');
  return r'__monkeyssh_adb=$(command -v adb 2>/dev/null || true); '
      r'if [ -z "$__monkeyssh_adb" ]; then '
      r'__monkeyssh_adb=$("${SHELL:-/bin/sh}" -lic '
      "'command -v adb' 2>/dev/null || true); "
      'fi; '
      r'if [ -z "$__monkeyssh_adb" ]; then '
      r'__monkeyssh_adb=$("${SHELL:-/bin/sh}" -ic '
      "'command -v adb' 2>/dev/null || true); "
      'fi; '
      r'if [ -z "$__monkeyssh_adb" ]; then '
      'for __monkeyssh_candidate in $candidates; do '
      r'if [ -x "$__monkeyssh_candidate" ]; then '
      r'__monkeyssh_adb=$__monkeyssh_candidate; break; fi; '
      'done; fi; '
      r'if [ -n "$__monkeyssh_adb" ]; then '
      r"printf '%s\n' "
      r'"$__monkeyssh_adb"; fi';
}

/// Extracts the resolved ADB path from [output].
///
/// Login profiles and interactive shells can print greetings, so only absolute
/// paths that name an `adb` binary are accepted, and the last match wins.
/// Paths may contain spaces; the caller quotes them and validates the binary
/// with an `adb version` probe.
@visibleForTesting
String? parseResolvedAdbPath(String output) {
  String? resolved;
  for (final line in const LineSplitter().convert(output)) {
    final candidate = line.trim();
    if (!candidate.startsWith('/') ||
        !(candidate.endsWith('/adb') || candidate.endsWith('/adb.exe'))) {
      continue;
    }
    resolved = candidate;
  }
  return resolved;
}

/// SSH exec implementation of [RemoteAdbCommandRunner].
class SshRemoteAdbCommandRunner implements RemoteAdbCommandRunner {
  /// Creates the remote command runner.
  const SshRemoteAdbCommandRunner();

  static const _commandTimeout = Duration(seconds: 20);
  static const _maxOutputCharacters = 8192;

  /// Resolved ADB binary paths retained only for the lifetime of each session.
  static final _adbPathCache = Expando<String>();

  @override
  Future<bool> isAvailable(SshSession session) async {
    final binary = await _resolveAdbBinary(session);
    if (binary == null) {
      return false;
    }
    final result = await _run(session, '$binary version');
    if (result.succeeded &&
        result.output.toLowerCase().contains('android debug bridge')) {
      return true;
    }
    _adbPathCache[session] = null;
    return false;
  }

  @override
  Future<bool> supportsPairing(SshSession session) async {
    final binary = await _resolveAdbBinary(session);
    if (binary == null) {
      return false;
    }
    // `adb help` exits non-zero on some releases, so trust the usage text.
    final result = await _run(session, '$binary help');
    final output = result.output.toLowerCase();
    return output.contains('pair host[:port]') &&
        output.contains('secure tcp/ip communication');
  }

  /// Resolves the remote ADB binary, quoted for the remote shell.
  Future<String?> _resolveAdbBinary(SshSession session) async {
    if (session.remoteIsWindows) {
      // Windows exec channels inherit the system PATH, which is where the
      // Android SDK installer puts platform-tools.
      return 'adb';
    }
    final cached = _adbPathCache[session];
    if (cached != null) {
      return cached;
    }

    final result = await _run(session, buildRemoteAdbResolutionCommand());
    final resolvedPath = parseResolvedAdbPath(result.output);
    DiagnosticsLogService.instance.info(
      'device_debug',
      'adb_resolution',
      fields: {
        'connectionId': session.connectionId,
        'resolved': resolvedPath != null,
        'exitStatus': result.exitCode,
      },
    );
    if (resolvedPath == null) {
      return null;
    }
    final quotedPath = _shellQuote(resolvedPath);
    _adbPathCache[session] = quotedPath;
    return quotedPath;
  }

  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", "'\"'\"'")}'";

  @override
  Future<RemoteListenerScope> listenerScope(
    SshSession session,
    int port,
  ) async {
    final command = session.remoteIsWindows
        ? buildWindowsListenerProbeCommand(port)
        : buildPosixListenerProbeCommand(port);
    final result = await _run(session, command);
    if (!result.succeeded) {
      return RemoteListenerScope.unknown;
    }
    return classifyRemoteListenerScope(result.output, port);
  }

  @override
  Future<RemoteAdbCommandResult> pair(
    SshSession session, {
    required String address,
    required String pairingCode,
  }) => _runAdb(session, 'pair $address', input: pairingCode);

  @override
  Future<RemoteAdbCommandResult> connect(
    SshSession session, {
    required String address,
  }) => _runAdb(session, 'connect $address');

  @override
  Future<RemoteAdbCommandResult> disconnect(
    SshSession session, {
    required String address,
  }) => _runAdb(session, 'disconnect $address');

  Future<RemoteAdbCommandResult> _runAdb(
    SshSession session,
    String arguments, {
    String? input,
  }) async {
    final binary = await _resolveAdbBinary(session);
    if (binary == null) {
      throw const DeviceDebugException(
        kind: DeviceDebugErrorKind.adbUnavailable,
        message:
            'MonkeySSH could not run ADB on the SSH host. Install Android '
            'platform tools, or add adb to the PATH your login shell sets, '
            'then try again.',
      );
    }
    return _run(session, '$binary $arguments', input: input);
  }

  Future<RemoteAdbCommandResult> _run(
    SshSession session,
    String command, {
    String? input,
    SshExecPriority priority = SshExecPriority.normal,
  }) => session.runQueuedExec(() async {
    SSHSession? execSession;
    try {
      final commandSession = await openSshExec(
        session.execute(command),
        _commandTimeout,
      );
      execSession = commandSession;
      final stdoutFuture = _collectOutput(commandSession.stdout);
      final stderrFuture = _collectOutput(commandSession.stderr);
      if (input != null) {
        commandSession.write(utf8.encode('$input\n'));
      }
      final values = await Future.wait<Object?>([
        stdoutFuture,
        stderrFuture,
        commandSession.done.then<int?>((_) => commandSession.exitCode),
      ]).timeout(_commandTimeout);
      final stdout = values[0]! as String;
      final stderr = values[1]! as String;
      return RemoteAdbCommandResult(
        exitCode: values[2] as int?,
        output: [
          stdout.trim(),
          stderr.trim(),
        ].where((part) => part.isNotEmpty).join('\n'),
      );
    } on TimeoutException {
      throw const DeviceDebugException(
        kind: DeviceDebugErrorKind.remoteCommandFailed,
        message: 'The remote ADB command timed out.',
      );
    } on SSHError {
      throw const DeviceDebugException(
        kind: DeviceDebugErrorKind.remoteCommandFailed,
        message: 'The SSH host could not run the ADB command.',
      );
    } on SocketException {
      throw const DeviceDebugException(
        kind: DeviceDebugErrorKind.remoteCommandFailed,
        message: 'The SSH connection closed while running ADB.',
      );
    } on Object catch (error) {
      // Callers rely on every runner failure being a DeviceDebugException so
      // reverse tunnels are always cleaned up on the fail-closed paths.
      if (error is DeviceDebugException) {
        rethrow;
      }
      DiagnosticsLogService.instance.warning(
        'device_debug',
        'remote_command_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType.toString(),
        },
      );
      throw const DeviceDebugException(
        kind: DeviceDebugErrorKind.remoteCommandFailed,
        message: 'The SSH host could not complete the ADB command.',
      );
    } finally {
      execSession?.close();
    }
  }, priority: priority);

  Future<String> _collectOutput(Stream<Uint8List> stream) async {
    final output = StringBuffer();
    // Remote tools can emit non-UTF-8 bytes; never fail the probe on decoding.
    await for (final chunk in stream.cast<List<int>>().transform(
      const Utf8Decoder(allowMalformed: true),
    )) {
      final remaining = _maxOutputCharacters - output.length;
      if (remaining <= 0) {
        continue;
      }
      output.write(
        chunk.length <= remaining ? chunk : chunk.substring(0, remaining),
      );
    }
    return output.toString();
  }
}

/// Registry that keeps one controller alive for each connected SSH session.
abstract interface class DeviceDebugSessionRegistry {
  /// Returns the controller owned by [session].
  DeviceDebugSessionController controllerFor(SshSession session);
}

/// Default implementation of [DeviceDebugSessionRegistry].
class DeviceDebugSessionService implements DeviceDebugSessionRegistry {
  /// Creates a device-debug session registry.
  DeviceDebugSessionService({
    required AndroidDeviceDebugPlatform platform,
    required RemoteAdbCommandRunner remoteRunner,
  }) : _platform = platform,
       _remoteRunner = remoteRunner;

  final AndroidDeviceDebugPlatform _platform;
  final RemoteAdbCommandRunner _remoteRunner;
  final Map<int, DeviceDebugSessionController> _controllers = {};

  @override
  DeviceDebugSessionController controllerFor(SshSession session) {
    final existing = _controllers[session.connectionId];
    if (existing != null) {
      return existing;
    }
    final controller = DeviceDebugSessionController(
      session: session,
      platform: _platform,
      remoteRunner: _remoteRunner,
    );
    _controllers[session.connectionId] = controller;
    unawaited(
      session.closed.then((_) {
        final removed = _controllers.remove(session.connectionId);
        removed?.handleSessionClosed();
      }),
    );
    return controller;
  }

  /// Disposes every retained controller.
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _controllers.clear();
  }
}

/// Owns Wireless ADB discovery, pairing, reverse forwarding, and cleanup.
class DeviceDebugSessionController extends ChangeNotifier {
  /// Creates a controller for one SSH [session].
  DeviceDebugSessionController({
    required SshSession session,
    required AndroidDeviceDebugPlatform platform,
    required RemoteAdbCommandRunner remoteRunner,
  }) : _session = session,
       _platform = platform,
       _remoteRunner = remoteRunner;

  static const _pairingTunnelId = -2147483001;
  static const _connectTunnelId = -2147483002;
  static const _pairingWatchTimeout = Duration(minutes: 3);
  static final _pairingCodePattern = RegExp(r'^[0-9]{6}$');

  /// Controller currently owning Android's single pairing prompt.
  ///
  /// Only one Settings pairing dialog can exist at a time, and the reply
  /// notification carries no session identity, so exactly one controller may
  /// consume submitted codes.
  static DeviceDebugSessionController? _pairingPromptOwner;

  final SshSession _session;
  final AndroidDeviceDebugPlatform _platform;
  final RemoteAdbCommandRunner _remoteRunner;

  DeviceDebugState _state = DeviceDebugState.off;
  AndroidAdbEndpoint? _connectEndpoint;
  String? _remoteSerial;
  int _operationGeneration = 0;
  Completer<void>? _operation;
  Future<void>? _stopFuture;
  int _pairingWatchGeneration = 0;
  StreamSubscription<String>? _pairingCodeSubscription;
  bool _pairingPromptVisible = false;
  bool _pairingPromptUnavailable = false;
  bool _pairedFromNotification = false;
  bool _returnPromptVisible = false;
  Future<void>? _pairingPromptHide;
  bool _disposed = false;

  /// Current observable bridge state.
  DeviceDebugState get state => _state;

  /// Whether the pairing-code notification could not be posted.
  ///
  /// Android cancels pairing when Settings pauses, so the notification is the
  /// only way to type the code; without it the flow cannot complete.
  bool get pairingPromptUnavailable => _pairingPromptUnavailable;

  /// Opens Android Developer options.
  Future<bool> openDeveloperOptions() async {
    try {
      return await _platform.openDeveloperOptions();
    } on DeviceDebugException catch (error) {
      _setError(error);
      return false;
    }
  }

  /// Discovers and connects to Wireless ADB, requesting pairing when needed.
  Future<void> enable() async {
    if (_disposed ||
        _operation != null ||
        _stopFuture != null ||
        _state.isBusy ||
        _state.isActive) {
      return;
    }
    final generation = ++_operationGeneration;
    final operation = _operation = Completer<void>();
    _setState(
      const DeviceDebugState(
        phase: DeviceDebugPhase.searching,
        message: 'Checking ADB on the SSH host…',
      ),
    );
    try {
      if (!await _platform.isWirelessDebuggingSupported()) {
        throw const DeviceDebugException(
          kind: DeviceDebugErrorKind.unsupported,
          message:
              'Device debugging needs Wireless debugging, which requires '
              'Android 11 or newer.',
        );
      }
      if (!_owns(generation)) {
        return;
      }
      if (!await _remoteRunner.isAvailable(_session)) {
        throw const DeviceDebugException(
          kind: DeviceDebugErrorKind.adbUnavailable,
          message:
              'MonkeySSH could not run ADB on the SSH host. Install Android '
              'platform tools, or add adb to the PATH your login shell sets, '
              'then try again.',
        );
      }
      if (!_owns(generation)) {
        return;
      }
      if (!await _remoteRunner.supportsPairing(_session)) {
        throw const DeviceDebugException(
          kind: DeviceDebugErrorKind.adbUnavailable,
          message:
              'ADB on the SSH host is too old for Wireless debugging. Upgrade '
              'Android platform tools, then try again.',
        );
      }
      if (!_owns(generation)) {
        return;
      }
      _setState(
        const DeviceDebugState(
          phase: DeviceDebugPhase.searching,
          message: 'Looking for Wireless debugging on this device…',
        ),
      );
      final endpoint = await _platform.discoverEndpoint(
        AndroidAdbServiceKind.connect,
      );
      if (!_owns(generation)) {
        return;
      }
      if (endpoint == null) {
        _setState(
          const DeviceDebugState(
            phase: DeviceDebugPhase.waitingForWirelessDebugging,
            message:
                'Turn on Wireless debugging in Android Developer options, '
                'then search again.',
          ),
        );
        return;
      }
      _connectEndpoint = endpoint;
      await _connect(endpoint, generation: generation, canRequestPairing: true);
    } on DeviceDebugException catch (error) {
      if (_owns(generation)) {
        _setError(error);
      }
    } finally {
      _operation = null;
      operation.complete();
    }
  }

  /// Pairs the SSH host using Android's six-digit [pairingCode].
  Future<void> pair(String pairingCode) async {
    // Guard the state first: a delayed or duplicate notification reply must
    // never rewrite an active session back into the pairing flow, which would
    // leave the tunnel live while the UI showed debugging as off.
    if (_disposed ||
        _operation != null ||
        _stopFuture != null ||
        _state.isBusy ||
        _state.isActive) {
      return;
    }
    final normalizedCode = pairingCode.trim();
    if (!_pairingCodePattern.hasMatch(normalizedCode)) {
      _setState(
        const DeviceDebugState(
          phase: DeviceDebugPhase.waitingForPairingCode,
          message: 'Enter the six-digit code shown by Android.',
          errorKind: DeviceDebugErrorKind.pairingCodeInvalid,
        ),
      );
      return;
    }
    final generation = ++_operationGeneration;
    final operation = _operation = Completer<void>();
    _setState(
      const DeviceDebugState(
        phase: DeviceDebugPhase.pairing,
        message: 'Finding Android’s pairing endpoint…',
      ),
    );
    try {
      final pairingEndpoint = await _platform.discoverEndpoint(
        AndroidAdbServiceKind.pairing,
        timeout: const Duration(seconds: 8),
      );
      if (!_owns(generation)) {
        return;
      }
      if (pairingEndpoint == null) {
        _setState(
          const DeviceDebugState(
            phase: DeviceDebugPhase.waitingForPairingCode,
            message:
                'Keep “Pair device with pairing code” open in Android, '
                'then try again.',
          ),
        );
        return;
      }
      final remotePairingPort = await _startReverseTunnel(
        tunnelId: _pairingTunnelId,
        endpoint: pairingEndpoint,
      );
      try {
        if (!_owns(generation)) {
          return;
        }
        _setState(
          const DeviceDebugState(
            phase: DeviceDebugPhase.pairing,
            message: 'Pairing the SSH host with Android…',
          ),
        );
        final result = await _remoteRunner.pair(
          _session,
          address: '127.0.0.1:$remotePairingPort',
          pairingCode: normalizedCode,
        );
        if (!_owns(generation)) {
          return;
        }
        if (!result.succeeded || !_pairingSucceeded(result.output)) {
          _setState(
            const DeviceDebugState(
              phase: DeviceDebugPhase.waitingForPairingCode,
              message:
                  'Android rejected the pairing request. Check the code and '
                  'keep the pairing screen open.',
              errorKind: DeviceDebugErrorKind.pairingFailed,
            ),
          );
          return;
        }
      } finally {
        await _stopTunnelQuietly(_pairingTunnelId);
      }
      if (!_owns(generation)) {
        return;
      }
      // Pairing is the only step that requires the user to stand in Android
      // Settings, so bring MonkeySSH back now rather than after connecting;
      // otherwise a connect failure would strand them in Settings.
      await _returnToAppAfterPairing();
      if (!_owns(generation)) {
        return;
      }
      final connectEndpoint =
          _connectEndpoint ??
          await _platform.discoverEndpoint(AndroidAdbServiceKind.connect);
      if (!_owns(generation)) {
        return;
      }
      if (connectEndpoint == null) {
        _setState(
          const DeviceDebugState(
            phase: DeviceDebugPhase.waitingForWirelessDebugging,
            message:
                'Pairing succeeded, but Android stopped advertising the '
                'connection port. Keep Wireless debugging on and search again.',
          ),
        );
        return;
      }
      _connectEndpoint = connectEndpoint;
      await _connect(
        connectEndpoint,
        generation: generation,
        canRequestPairing: false,
      );
    } on DeviceDebugException catch (error) {
      if (_owns(generation)) {
        _setError(error);
      }
    } finally {
      _operation = null;
      operation.complete();
    }
  }

  /// Disconnects remote ADB and closes the internal reverse tunnels.
  ///
  /// Waits for any cancelled operation and its cleanup before allowing restart.
  /// Concurrent callers share the same stop future.
  Future<void> stop() {
    if (_stopFuture case final pending?) {
      return pending;
    }
    if (_disposed || _state.phase == DeviceDebugPhase.off) {
      return Future<void>.value();
    }
    final completion = Completer<void>();
    _stopFuture = completion.future;
    unawaited(
      _stop().then(
        completion.complete,
        onError: (Object error, StackTrace stackTrace) {
          _stopFuture = null;
          completion.completeError(error, stackTrace);
        },
      ),
    );
    return completion.future;
  }

  Future<void> _stop() async {
    ++_operationGeneration;
    final operation = _operation;
    _setState(
      const DeviceDebugState(
        phase: DeviceDebugPhase.stopping,
        message: 'Turning off device debugging…',
      ),
    );
    final remoteSerial = _remoteSerial;
    try {
      if (remoteSerial != null) {
        final result = await _remoteRunner.disconnect(
          _session,
          address: remoteSerial,
        );
        if (!result.succeeded) {
          DiagnosticsLogService.instance.warning(
            'device_debug',
            'adb_disconnect_rejected',
            fields: {'connectionId': _session.connectionId},
          );
        }
      }
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'device_debug',
        'adb_disconnect_failed',
        fields: {
          'connectionId': _session.connectionId,
          'errorType': error is DeviceDebugException
              ? error.kind.name
              : error.runtimeType.toString(),
        },
      );
    } finally {
      // The tunnels must close even when the remote disconnect fails, so the
      // controller never stays stuck in `stopping` with a live reverse forward.
      await _stopTunnelQuietly(_pairingTunnelId);
      await _stopTunnelQuietly(_connectTunnelId);
      // Fixed tunnel IDs cannot be reused until the old operation has finished
      // every cleanup step, including disconnecting a late ADB connection.
      await operation?.future;
      await _hideReturnPrompt();
      _connectEndpoint = null;
      _remoteSerial = null;
      _pairedFromNotification = false;
      _stopFuture = null;
      if (!_disposed) {
        _setState(DeviceDebugState.off);
      }
    }
  }

  /// Stops [tunnelId] without letting cleanup failures escape.
  Future<void> _stopTunnelQuietly(int tunnelId) async {
    try {
      await _session.stopForward(tunnelId);
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'device_debug',
        'tunnel_cleanup_failed',
        fields: {
          'connectionId': _session.connectionId,
          'errorType': error.runtimeType.toString(),
        },
      );
    }
  }

  /// Drops a remote ADB serial that outlived the operation that created it.
  Future<void> _disconnectSupersededSerial(String remoteSerial) async {
    try {
      await _remoteRunner.disconnect(_session, address: remoteSerial);
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'device_debug',
        'superseded_disconnect_failed',
        fields: {
          'connectionId': _session.connectionId,
          'errorType': error is DeviceDebugException
              ? error.kind.name
              : error.runtimeType.toString(),
        },
      );
    }
  }

  Future<void> _connect(
    AndroidAdbEndpoint endpoint, {
    required int generation,
    required bool canRequestPairing,
  }) async {
    if (!_owns(generation)) {
      return;
    }
    _setState(
      const DeviceDebugState(
        phase: DeviceDebugPhase.connecting,
        message: 'Opening a private ADB tunnel on the SSH host…',
      ),
    );
    if (!_owns(generation)) {
      return;
    }
    await _session.stopForward(_connectTunnelId);
    if (!_owns(generation)) {
      return;
    }
    final remotePort = await _startReverseTunnel(
      tunnelId: _connectTunnelId,
      endpoint: endpoint,
    );
    if (!_owns(generation)) {
      await _session.stopForward(_connectTunnelId);
      return;
    }
    final remoteSerial = '127.0.0.1:$remotePort';
    _setState(
      const DeviceDebugState(
        phase: DeviceDebugPhase.connecting,
        message: 'Connecting remote ADB to this Android device…',
      ),
    );
    if (!_owns(generation)) {
      await _stopTunnelQuietly(_connectTunnelId);
      return;
    }
    late final RemoteAdbCommandResult result;
    try {
      result = await _remoteRunner.connect(_session, address: remoteSerial);
    } on Object {
      await _session.stopForward(_connectTunnelId);
      rethrow;
    }
    DiagnosticsLogService.instance.info(
      'device_debug',
      'adb_connect_result',
      fields: {
        'connectionId': _session.connectionId,
        'exitStatus': result.exitCode,
        'outcome': classifyAdbConnectOutcome(result.output),
        'canRequestPairing': canRequestPairing,
      },
    );
    if (!_owns(generation)) {
      // A stop raced this connect. The remote ADB server would otherwise keep
      // a stale (offline) serial registered, so drop it before closing up.
      if (result.succeeded && _connectSucceeded(result.output)) {
        await _disconnectSupersededSerial(remoteSerial);
      }
      await _stopTunnelQuietly(_connectTunnelId);
      return;
    }
    if (result.succeeded && _connectSucceeded(result.output)) {
      _remoteSerial = remoteSerial;
      _setState(
        DeviceDebugState(
          phase: DeviceDebugPhase.active,
          message: 'The SSH host can now debug this Android device.',
          remoteAddress: remoteSerial,
        ),
      );
      await _returnToAppAfterPairing();
      return;
    }
    await _stopTunnelQuietly(_connectTunnelId);
    if (!_owns(generation)) {
      return;
    }
    if (canRequestPairing) {
      // ADB reports an unpaired host in several ways depending on version and
      // on whether the TLS handshake or the authentication step fails, so any
      // first-attempt failure routes to pairing — the only in-app remedy.
      _setState(
        const DeviceDebugState(
          phase: DeviceDebugPhase.waitingForPairingCode,
          message:
              'This SSH host is not paired with the device yet. In Wireless '
              'debugging, tap “Pair device with pairing code.”',
        ),
      );
      return;
    }
    throw const DeviceDebugException(
      kind: DeviceDebugErrorKind.connectionFailed,
      message:
          'Remote ADB could not connect through the tunnel. Keep Wireless '
          'debugging on and try again.',
    );
  }

  /// Brings MonkeySSH forward after a notification-driven pairing succeeds.
  ///
  /// Only runs when the code came from the notification, because that is the
  /// case where the user is still standing in Android Settings.
  Future<void> _returnToAppAfterPairing() async {
    if (!_pairedFromNotification) {
      return;
    }
    _pairedFromNotification = false;
    final generation = _operationGeneration;
    // Pairing is finished, so retire its prompt before posting the return one.
    _endPairingCodeCapture();
    await _pairingPromptHide;
    _pairingPromptHide = null;
    if (_disposed || generation != _operationGeneration) {
      return;
    }
    final returned = await _platform.returnToApp(
      status: 'Paired. Tap to return to MonkeySSH.',
    );
    _returnPromptVisible = true;
    if (_disposed || generation != _operationGeneration) {
      // A stop raced the return; never leave a stale prompt behind.
      await _hideReturnPrompt();
    }
    DiagnosticsLogService.instance.info(
      'device_debug',
      'foreground_return',
      fields: {'connectionId': _session.connectionId, 'returned': returned},
    );
  }

  /// Cancels the "tap to return" notification when one is showing.
  Future<void> _hideReturnPrompt() async {
    if (!_returnPromptVisible) {
      return;
    }
    _returnPromptVisible = false;
    await _platform.hideReturnPrompt();
  }

  Future<int> _startReverseTunnel({
    required int tunnelId,
    required AndroidAdbEndpoint endpoint,
  }) async {
    final started = await _session.startRemoteForward(
      portForwardId: tunnelId,
      remoteHost: '127.0.0.1',
      remotePort: 0,
      localHost: endpoint.host,
      localPort: endpoint.port,
    );
    if (!started) {
      throw const DeviceDebugException(
        kind: DeviceDebugErrorKind.remoteForwardDenied,
        message:
            'The SSH server denied the private reverse tunnel. Enable remote '
            'TCP forwarding on the server, then try again.',
      );
    }
    for (final tunnel in _session.activeTunnels) {
      if (tunnel.portForwardId == tunnelId && tunnel.remotePort > 0) {
        final remotePort = tunnel.remotePort;
        late final RemoteListenerScope scope;
        try {
          scope = await _remoteRunner.listenerScope(_session, remotePort);
        } on Object {
          // Listener verification is the fail-closed boundary: never leave an
          // unverified reverse forward alive.
          await _session.stopForward(tunnelId);
          rethrow;
        }
        if (scope == RemoteListenerScope.loopback) {
          return remotePort;
        }
        await _session.stopForward(tunnelId);
        if (scope == RemoteListenerScope.exposed) {
          throw const DeviceDebugException(
            kind: DeviceDebugErrorKind.remoteForwardExposed,
            message:
                'The SSH server exposed the device-debug tunnel beyond '
                'localhost. Set GatewayPorts to no or clientspecified, then '
                'try again.',
          );
        }
        throw const DeviceDebugException(
          kind: DeviceDebugErrorKind.remoteForwardDenied,
          message:
              'MonkeySSH could not verify that the device-debug tunnel is '
              'private. Install ss or netstat on the SSH host, then try again.',
        );
      }
    }
    await _session.stopForward(tunnelId);
    throw const DeviceDebugException(
      kind: DeviceDebugErrorKind.remoteForwardDenied,
      message: 'The SSH server did not assign a port for device debugging.',
    );
  }

  bool _owns(int generation) =>
      !_disposed && generation == _operationGeneration;

  void _setError(DeviceDebugException error) {
    _setState(
      DeviceDebugState(
        phase: DeviceDebugPhase.error,
        message: error.message,
        errorKind: error.kind,
      ),
    );
  }

  void _setState(DeviceDebugState state) {
    if (_disposed) {
      return;
    }
    _state = state;
    notifyListeners();
    _syncPairingCodeCapture(state);
  }

  /// Starts or stops the notification-based pairing-code capture.
  ///
  /// Android tears pairing down in `onPause`, so the code can only be typed
  /// somewhere that keeps Settings resumed — an inline notification reply.
  void _syncPairingCodeCapture(DeviceDebugState state) {
    if (state.phase == DeviceDebugPhase.waitingForPairingCode) {
      if (!identical(_pairingPromptOwner, this)) {
        // Another session was collecting a code; Android only supports one
        // pairing dialog, so the newest request takes over the prompt.
        _pairingPromptOwner?._endPairingCodeCapture();
        _pairingPromptOwner = this;
      }
      _pairingCodeSubscription ??= _platform.submittedPairingCodes.listen((
        code,
      ) {
        if (identical(_pairingPromptOwner, this)) {
          // The user is standing in Android Settings, so a successful pair
          // should pull MonkeySSH back to the front afterwards.
          _pairedFromNotification = true;
          unawaited(pair(code));
        }
      });
      if (_pairingPromptVisible) {
        unawaited(
          _showPairingPrompt(
            _pairingPromptStatus(state),
            _pairingWatchGeneration,
          ),
        );
        return;
      }
      unawaited(_watchForPairingScreen(++_pairingWatchGeneration, state));
      return;
    }
    if (state.phase == DeviceDebugPhase.pairing) {
      return;
    }
    _endPairingCodeCapture();
  }

  /// Waits for Android's pairing screen, then posts the reply prompt.
  Future<void> _watchForPairingScreen(
    int watchGeneration,
    DeviceDebugState state,
  ) async {
    final deadline = DateTime.now().add(_pairingWatchTimeout);
    var backoff = const Duration(seconds: 1);
    while (!_disposed &&
        watchGeneration == _pairingWatchGeneration &&
        _state.phase == DeviceDebugPhase.waitingForPairingCode) {
      if (DateTime.now().isAfter(deadline)) {
        // Bound the mDNS polling so an abandoned attempt cannot keep scanning
        // for the life of the SSH session.
        _endPairingCodeCapture();
        _setError(
          const DeviceDebugException(
            kind: DeviceDebugErrorKind.pairingFailed,
            message:
                'MonkeySSH stopped waiting for the pairing screen. Try again '
                'and keep Wireless debugging open.',
          ),
        );
        return;
      }
      AndroidAdbEndpoint? pairingEndpoint;
      try {
        pairingEndpoint = await _platform.discoverEndpoint(
          AndroidAdbServiceKind.pairing,
          timeout: const Duration(seconds: 4),
        );
        backoff = const Duration(seconds: 1);
      } on DeviceDebugException {
        // Discovery can fail transiently (Wi-Fi change, NSD churn); keep
        // watching with backoff instead of stranding the flow.
        backoff = backoff * 2 > const Duration(seconds: 8)
            ? const Duration(seconds: 8)
            : backoff * 2;
      }
      if (_disposed || watchGeneration != _pairingWatchGeneration) {
        return;
      }
      if (pairingEndpoint != null) {
        await _showPairingPrompt(_pairingPromptStatus(_state), watchGeneration);
        return;
      }
      await Future<void>.delayed(backoff);
    }
  }

  Future<void> _showPairingPrompt(String status, int watchGeneration) async {
    final shown = await _platform.showPairingCodePrompt(status: status);
    if (_disposed || watchGeneration != _pairingWatchGeneration) {
      if (shown) {
        // Ownership changed while the prompt was posting; never leave an
        // orphaned ongoing notification behind.
        unawaited(_platform.hidePairingCodePrompt());
      }
      return;
    }
    _pairingPromptVisible = shown;
    if (_pairingPromptUnavailable == !shown) {
      return;
    }
    _pairingPromptUnavailable = !shown;
    notifyListeners();
  }

  String _pairingPromptStatus(DeviceDebugState state) =>
      switch (state.errorKind) {
        DeviceDebugErrorKind.pairingFailed =>
          'Android rejected that code. Reply with the code now on screen.',
        DeviceDebugErrorKind.pairingCodeInvalid =>
          'Reply with the six digits exactly as shown.',
        _ =>
          'Reply with the 6-digit code shown in Wireless debugging. Stay on '
              'that screen — leaving it cancels pairing.',
      };

  void _endPairingCodeCapture() {
    _pairingWatchGeneration++;
    if (identical(_pairingPromptOwner, this)) {
      _pairingPromptOwner = null;
    }
    unawaited(_pairingCodeSubscription?.cancel());
    _pairingCodeSubscription = null;
    _pairingPromptUnavailable = false;
    if (_pairingPromptVisible) {
      _pairingPromptVisible = false;
      _pairingPromptHide = _platform.hidePairingCodePrompt();
      unawaited(_pairingPromptHide);
    }
  }

  bool _pairingSucceeded(String output) =>
      output.toLowerCase().contains('successfully paired');

  bool _connectSucceeded(String output) {
    final normalized = output.toLowerCase();
    return normalized.contains('connected to') ||
        normalized.contains('already connected to');
  }

  /// Marks this controller closed after its SSH session begins shutting down.
  void handleSessionClosed() {
    if (_disposed) {
      return;
    }
    // Publish the off state before disposing so an open sheet can rebuild.
    _setState(DeviceDebugState.off);
    dispose();
  }

  @override
  void dispose() {
    _disposed = true;
    _endPairingCodeCapture();
    unawaited(_hideReturnPrompt());
    super.dispose();
  }
}
