import 'dart:async';

import '../models/monkeymux_acp_bridge.dart';
import 'acp_client.dart';
import 'acp_client_capability_service.dart';
import 'acp_json_rpc_connection.dart';
import 'monkeymux_acp_bridge_service.dart';
import 'monkeymux_installer_service.dart';
import 'remote_file_service.dart';
import 'ssh_service.dart';

/// The requested ACP working directory could not be resolved on the host.
final class AcpWorkingDirectoryException implements Exception {
  /// Creates a content-free working-directory error.
  const AcpWorkingDirectoryException();
}

/// Bundles the same-host filesystem and terminal implementations used to
/// answer ACP client-capability requests (`fs/*`, `terminal/*`).
///
/// New operations resolve the active SSH session for the same host, so these
/// bindings remain usable when a capability service survives an SSH reconnect.
final class AcpHostCapabilityBinding {
  /// Creates a capability binding.
  const AcpHostCapabilityBinding({
    required this.fileSystem,
    required this.terminalExecutor,
  });

  /// Same-host SFTP-backed filesystem.
  final AcpRemoteFileSystem fileSystem;

  /// Same-host non-PTY terminal executor.
  final AcpTerminalExecutor terminalExecutor;
}

/// A live bridge attachment: a typed ACP client plus the transport lifecycle
/// and error signals needed to drive session state.
///
/// This wraps whatever concrete transport a connector uses (in production, a
/// reconnecting MonkeyMux-over-SSH bridge transport). Closing it releases the
/// client, JSON-RPC connection, and transport deterministically.
final class AcpBridgeSession {
  /// Creates a bridge session.
  AcpBridgeSession({
    required this.client,
    required this.transportStates,
    required this.transportErrors,
    required Future<void> Function() onClose,
    bool Function()? skippedHistoricalReplay,
    int Function()? lastDeliveredSequence,
  }) : _onClose = onClose,
       _skippedHistoricalReplay = skippedHistoricalReplay,
       _lastDeliveredSequence = lastDeliveredSequence;

  /// Typed ACP client bound to the bridge transport.
  final AcpClient client;

  /// Transport lifecycle updates (connecting, reconnecting, exited, ...).
  final Stream<MonkeyMuxAcpTransportState> transportStates;

  /// Typed bridge/transport errors, kept separate from ACP payloads.
  final Stream<MonkeyMuxAcpBridgeException> transportErrors;

  final bool Function()? _skippedHistoricalReplay;
  final int Function()? _lastDeliveredSequence;

  /// Latest bridge output sequence delivered by this logical attachment.
  int get lastDeliveredSequence => _lastDeliveredSequence?.call() ?? 0;

  /// Whether fresh transport attach established a remote high-water baseline
  /// instead of downloading historical bridge output.
  bool get skippedHistoricalReplay => _skippedHistoricalReplay?.call() ?? false;

  final Future<void> Function() _onClose;
  Future<void>? _closeFuture;

  /// Releases the client, connection, and transport exactly once.
  Future<void> close() => _closeFuture ??= _onClose();
}

/// Abstraction over remote bridge lifecycle and ACP client construction.
///
/// The session manager depends only on this contract so it can be tested with
/// in-memory fakes and never has to construct an [SshSession] directly.
abstract interface class AcpBridgeConnector {
  /// Starts a new persistent provider bridge on [hostId] and returns its
  /// opaque identifier.
  Future<MonkeyMuxAcpBridgeStartResult> startBridge({
    required int hostId,
    required String providerId,
    required String providerLabel,
    required List<String> launchArgv,
    required String cwd,
    MonkeyMuxInstallConfirmation? confirmInstall,
  });

  /// Lists running bridges on [hostId], installing or updating MonkeyMux after
  /// [confirmInstall] approves when the current helper is unavailable.
  Future<List<MonkeyMuxAcpBridgeMetadata>> listBridges(
    int hostId, {
    MonkeyMuxInstallConfirmation? confirmInstall,
  });

  /// Resolves [cwd] to the canonical absolute path syntax expected by the
  /// provider running on [hostId].
  Future<String> resolveWorkingDirectory(
    int hostId,
    String cwd, {
    bool trustAbsolute = false,
  });

  /// Reads safe metadata for [bridgeId] on [hostId].
  Future<MonkeyMuxAcpBridgeMetadata> bridgeStatus(int hostId, String bridgeId);

  /// Explicitly stops the remote provider and bridge [bridgeId] on [hostId].
  Future<void> stopBridge(int hostId, String bridgeId);

  /// Attaches to an existing bridge, returning a live ACP client bound to a
  /// reconnecting transport.
  AcpBridgeSession connect({
    required int hostId,
    required String bridgeId,
    required String providerId,
    int lastAcknowledgedSequence = 0,
  });

  /// Resolves the same-host filesystem/terminal binding used to answer ACP
  /// client-capability requests, or `null` when no capability service should
  /// be advertised (for example, no active SSH session for [hostId]).
  Future<AcpHostCapabilityBinding?> resolveCapabilityBinding(int hostId);
}

/// Production [AcpBridgeConnector] backed by [MonkeyMuxAcpBridgeService] and
/// the typed ACP JSON-RPC client.
final class MonkeyMuxAcpBridgeConnector implements AcpBridgeConnector {
  /// Creates a connector.
  ///
  /// [sessionResolver] resolves the active [SshSession] for a saved host. It
  /// is invoked lazily so a bridge attachment can transparently reconnect
  /// through a freshly re-established SSH session.
  MonkeyMuxAcpBridgeConnector({
    required MonkeyMuxAcpBridgeService bridgeService,
    required Future<SshSession> Function(int hostId) sessionResolver,
    this.defaultRequestTimeout = const Duration(seconds: 60),
    this.capabilityLimits = const AcpClientCapabilityLimits(),
  }) : _bridgeService = bridgeService,
       _sessionResolver = sessionResolver;

  final MonkeyMuxAcpBridgeService _bridgeService;
  final Future<SshSession> Function(int hostId) _sessionResolver;

  /// Default per-request timeout applied to the ACP JSON-RPC connection.
  final Duration defaultRequestTimeout;

  /// Limits used when constructing same-host capability implementations.
  final AcpClientCapabilityLimits capabilityLimits;

  @override
  Future<MonkeyMuxAcpBridgeStartResult> startBridge({
    required int hostId,
    required String providerId,
    required String providerLabel,
    required List<String> launchArgv,
    required String cwd,
    MonkeyMuxInstallConfirmation? confirmInstall,
  }) async {
    final session = await _sessionResolver(hostId);
    return _bridgeService.start(
      session: session,
      providerId: providerId,
      providerLabel: providerLabel,
      launchArgv: launchArgv,
      cwd: cwd,
      confirmInstall: confirmInstall,
    );
  }

  @override
  Future<List<MonkeyMuxAcpBridgeMetadata>> listBridges(
    int hostId, {
    MonkeyMuxInstallConfirmation? confirmInstall,
  }) async {
    final session = await _sessionResolver(hostId);
    return _bridgeService.list(session, confirmInstall: confirmInstall);
  }

  @override
  Future<String> resolveWorkingDirectory(
    int hostId,
    String cwd, {
    bool trustAbsolute = false,
  }) async {
    final knownAbsolute = normalizeSftpAbsolutePath(cwd);
    if (trustAbsolute && knownAbsolute != null) {
      final root = sftpPathRoot(knownAbsolute);
      return remoteShellPathForSftpPath(
        knownAbsolute,
        windows: root != null && root != '/',
      );
    }
    final session = await _sessionResolver(hostId);
    final sftp = await session.sftp();
    final homeDirectory = normalizeSftpAbsolutePath(await sftp.absolute('.'));
    final candidate = resolveRequestedSftpPath(
      cwd,
      workingDirectory: homeDirectory,
      homeDirectory: homeDirectory,
    );
    if (candidate == null) {
      throw const AcpWorkingDirectoryException();
    }
    final canonical = normalizeSftpAbsolutePath(await sftp.absolute(candidate));
    if (canonical == null) {
      throw const AcpWorkingDirectoryException();
    }
    final root = sftpPathRoot(canonical);
    return remoteShellPathForSftpPath(
      canonical,
      windows: session.remoteIsWindows || (root != null && root != '/'),
    );
  }

  @override
  Future<MonkeyMuxAcpBridgeMetadata> bridgeStatus(
    int hostId,
    String bridgeId,
  ) async {
    final session = await _sessionResolver(hostId);
    return _bridgeService.status(session, bridgeId);
  }

  @override
  Future<void> stopBridge(int hostId, String bridgeId) async {
    final session = await _sessionResolver(hostId);
    await _bridgeService.stop(session, bridgeId);
  }

  @override
  AcpBridgeSession connect({
    required int hostId,
    required String bridgeId,
    required String providerId,
    int lastAcknowledgedSequence = 0,
  }) {
    // A replacement local attachment continues the same logical replay cursor.
    final transport = _bridgeService.connect(
      sessionProvider: () => _sessionResolver(hostId),
      bridgeId: bridgeId,
      providerId: providerId,
      lastAcknowledgedSequence: lastAcknowledgedSequence,
    );
    final connection = AcpJsonRpcConnection(
      transport: transport,
      defaultRequestTimeout: defaultRequestTimeout,
    );
    final client = AcpClient(connection);
    return AcpBridgeSession(
      client: client,
      transportStates: transport.states,
      transportErrors: transport.errors,
      skippedHistoricalReplay: transport.didSkipHistoricalReplay,
      lastDeliveredSequence: () => transport.lastDeliveredSequence,
      onClose: client.close,
    );
  }

  @override
  Future<AcpHostCapabilityBinding?> resolveCapabilityBinding(int hostId) async {
    final SshSession session;
    try {
      session = await _sessionResolver(hostId);
    } on Object {
      return null;
    }
    return AcpHostCapabilityBinding(
      fileSystem: AcpSftpRemoteFileSystem(
        () async => (await _sessionResolver(hostId)).sftp(),
      ),
      terminalExecutor: AcpSshTerminalExecutor(
        () => _sessionResolver(hostId),
        remoteIsWindows: session.remoteIsWindows,
        openTimeout: capabilityLimits.terminalOpenTimeout,
      ),
    );
  }
}
