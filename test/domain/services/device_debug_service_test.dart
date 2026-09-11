import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/device_debug_service.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

import '../../helpers/mock_ssh_exec_session.dart';

class _MockSshSession extends Mock implements SshSession {}

class _MockSshClient extends Mock implements SSHClient {}

class _MockExecChannel extends MockSessionWithChannel {}

class _FakeAndroidDeviceDebugPlatform implements AndroidDeviceDebugPlatform {
  final endpoints = <AndroidAdbServiceKind, AndroidAdbEndpoint?>{};
  Completer<AndroidAdbEndpoint?>? pendingConnectEndpoint;
  bool wirelessDebuggingSupported = true;
  bool pairingPromptAllowed = true;
  bool returnToAppSucceeds = true;
  final returnToAppCalls = <String>[];
  int returnPromptHiddenCount = 0;
  final events = <String>[];
  final pairingPromptStatuses = <String>[];
  int pairingPromptHiddenCount = 0;
  // ignore: close_sinks
  final pairingCodes = StreamController<String>.broadcast();

  @override
  Stream<String> get submittedPairingCodes => pairingCodes.stream;

  @override
  Future<bool> showPairingCodePrompt({
    required String status,
    bool busy = false,
  }) async {
    pairingPromptStatuses.add(status);
    return pairingPromptAllowed;
  }

  @override
  Future<void> hidePairingCodePrompt() async {
    pairingPromptHiddenCount++;
    events.add('hide');
  }

  @override
  Future<bool> returnToApp({required String status}) async {
    events.add('return');
    returnToAppCalls.add(status);
    return returnToAppSucceeds;
  }

  @override
  Future<void> hideReturnPrompt() async {
    events.add('hideReturn');
    returnPromptHiddenCount++;
  }

  @override
  bool get supported => true;

  @override
  Future<bool> isWirelessDebuggingSupported() async =>
      wirelessDebuggingSupported;

  @override
  Future<AndroidAdbEndpoint?> discoverEndpoint(
    AndroidAdbServiceKind kind, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    if (pendingConnectEndpoint case final pending?
        when kind == AndroidAdbServiceKind.connect) {
      return pending.future;
    }
    return endpoints[kind];
  }

  @override
  Future<bool> openDeveloperOptions() async => true;
}

class _FakeRemoteAdbCommandRunner implements RemoteAdbCommandRunner {
  bool available = true;
  bool pairingSupported = true;
  RemoteListenerScope listenerScopeResult = RemoteListenerScope.loopback;
  DeviceDebugException? listenerScopeError;
  DeviceDebugException? connectError;
  Exception? disconnectError;
  Completer<RemoteAdbCommandResult>? pendingConnect;
  Completer<RemoteAdbCommandResult>? pendingPair;
  Completer<RemoteAdbCommandResult>? pendingDisconnect;
  final connectResults = <RemoteAdbCommandResult>[];
  RemoteAdbCommandResult pairResult = const RemoteAdbCommandResult(
    exitCode: 0,
    output: 'Successfully paired to 127.0.0.1:41001',
  );
  final pairedCodes = <String>[];
  final connectAddresses = <String>[];
  final disconnectAddresses = <String>[];

  @override
  Future<RemoteAdbCommandResult> connect(
    SshSession session, {
    required String address,
  }) async {
    connectAddresses.add(address);
    if (connectError case final error?) {
      throw error;
    }
    if (pendingConnect case final pending?) {
      return pending.future;
    }
    return connectResults.removeAt(0);
  }

  @override
  Future<RemoteAdbCommandResult> disconnect(
    SshSession session, {
    required String address,
  }) async {
    disconnectAddresses.add(address);
    if (disconnectError case final error?) {
      throw error;
    }
    if (pendingDisconnect case final pending?) {
      return pending.future;
    }
    return const RemoteAdbCommandResult(exitCode: 0, output: 'disconnected');
  }

  @override
  Future<bool> isAvailable(SshSession session) async => available;

  @override
  Future<RemoteListenerScope> listenerScope(
    SshSession session,
    int port,
  ) async {
    if (listenerScopeError case final error?) {
      throw error;
    }
    return listenerScopeResult;
  }

  @override
  Future<bool> supportsPairing(SshSession session) async => pairingSupported;

  @override
  Future<RemoteAdbCommandResult> pair(
    SshSession session, {
    required String address,
    required String pairingCode,
  }) async {
    pairedCodes.add(pairingCode);
    if (pendingPair case final pending?) {
      return pending.future;
    }
    return pairResult;
  }
}

const _connected = RemoteAdbCommandResult(
  exitCode: 0,
  output: 'connected to 127.0.0.1:41002',
);

const _notPaired = RemoteAdbCommandResult(
  exitCode: 1,
  output: "failed to connect to '127.0.0.1:41002'",
);

void main() {
  testWidgets(
    'ADB channel opening times out, releases queue and closes late channel',
    (tester) async {
      final client = _MockSshClient();
      when(
        () => client.remoteVersion,
      ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');
      final session = _adbSession(
        client,
        connectionId: 88002,
        hostId: 1,
        hostname: 'example.com',
        username: 'tester',
      );
      final opening = Completer<SSHSession>();
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) => opening.future);
      const runner = SshRemoteAdbCommandRunner();
      final result = expectLater(
        runner.connect(session, address: '127.0.0.1:41002'),
        throwsA(
          isA<DeviceDebugException>().having(
            (error) => error.kind,
            'kind',
            DeviceDebugErrorKind.remoteCommandFailed,
          ),
        ),
      );
      await tester.pump();
      final blocker = Completer<void>();
      final blocked = session.runQueuedExec(() => blocker.future);
      var nextRan = false;
      final next = session.runQueuedExec(() async {
        nextRan = true;
      });
      expect(pendingQueuedSshExecCountForTesting(session.connectionId), 1);
      await tester.pump(const Duration(seconds: 21));
      expect(nextRan, isTrue);
      await result;
      await next;
      final lateChannel = _MockExecChannel();
      opening.complete(lateChannel);
      await tester.pump();
      verify(lateChannel.channel.destroy).called(1);
      verify(() => client.execute(any(), pty: any(named: 'pty'))).called(1);
      blocker.complete();
      await blocked;
    },
  );

  TestWidgetsFlutterBinding.ensureInitialized();

  group('remote ADB resolution', () {
    tearDown(resetQueuedSshExecsForTesting);

    test('never sources profiles inline, which would exit a POSIX shell', () {
      final command = buildRemoteAdbResolutionCommand();

      expect(command, isNot(contains('. ~/.profile')));
      expect(command, isNot(contains('. ~/.zprofile')));
      expect(command, contains('command -v adb'));
      expect(command, contains('-lic'));
      expect(command, contains('-ic'));
      expect(
        command,
        contains(r'"$HOME/Library/Android/sdk/platform-tools/adb"'),
      );
      expect(command, contains('"/opt/homebrew/bin/adb"'));
    });

    test('parses the resolved path out of noisy login-shell output', () {
      expect(
        parseResolvedAdbPath(
          'Welcome to macOS\n'
          'MOTD greeting noise\n'
          '/opt/homebrew/bin/adb\n',
        ),
        '/opt/homebrew/bin/adb',
      );
      expect(
        parseResolvedAdbPath('/usr/bin/adb\n/Users/dev/Library/adb\n'),
        '/Users/dev/Library/adb',
      );
      expect(parseResolvedAdbPath('adb: aliased to /opt/adb\n'), isNull);
      expect(parseResolvedAdbPath('adb\nnot found\n'), isNull);
      expect(parseResolvedAdbPath(''), isNull);
      expect(
        parseResolvedAdbPath('/Users/dev/Android Sdk/platform-tools/adb\n'),
        '/Users/dev/Android Sdk/platform-tools/adb',
        reason: 'SDK paths often contain spaces and are quoted before use',
      );
    });

    test('runs ADB through the resolved path and caches it', () async {
      final client = _MockSshClient();
      final executedCommands = <String>[];
      when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.6');
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        final command = invocation.positionalArguments.single as String;
        executedCommands.add(command);
        return _adbExec(
          command.contains('command -v adb')
              ? 'MOTD greeting noise\n/opt/homebrew/bin/adb\n'
              : 'Android Debug Bridge version 1.0.41',
        );
      });
      final session = _adbSession(client, connectionId: 91);
      const runner = SshRemoteAdbCommandRunner();

      expect(await runner.isAvailable(session), isTrue);
      await runner.connect(session, address: '127.0.0.1:41002');

      expect(executedCommands, hasLength(3));
      expect(executedCommands.first, contains('command -v adb'));
      expect(executedCommands[1], "'/opt/homebrew/bin/adb' version");
      expect(
        executedCommands[2],
        "'/opt/homebrew/bin/adb' connect 127.0.0.1:41002",
      );
    });

    test(
      'isolates cached paths by session and clears failed validation',
      () async {
        final client = _MockSshClient();
        final executedCommands = <String>[];
        var resolvedPath = '/opt/homebrew/bin/adb';
        var valid = true;
        when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.6');
        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
          invocation,
        ) async {
          final command = invocation.positionalArguments.single as String;
          executedCommands.add(command);
          return _adbExec(
            command.contains('command -v adb')
                ? '$resolvedPath\n'
                : valid
                ? 'Android Debug Bridge version 1.0.41'
                : 'missing',
          );
        });
        final session = _adbSession(client, connectionId: 91);
        const runner = SshRemoteAdbCommandRunner();

        expect(await runner.isAvailable(session), isTrue);
        executedCommands.clear();
        resolvedPath = '/usr/local/bin/adb';
        final replacement = SshSession(
          connectionId: session.connectionId,
          hostId: session.hostId,
          client: client,
          config: session.config,
        );
        expect(await runner.isAvailable(replacement), isTrue);
        expect(executedCommands.first, contains('command -v adb'));
        expect(executedCommands.last, "'/usr/local/bin/adb' version");
        await runner.connect(session, address: '127.0.0.1:41002');
        expect(
          executedCommands.last,
          "'/opt/homebrew/bin/adb' connect 127.0.0.1:41002",
        );

        valid = false;
        expect(await runner.isAvailable(session), isFalse);
        valid = true;
        resolvedPath = '/opt/android/adb';
        executedCommands.clear();
        expect(await runner.isAvailable(session), isTrue);
        expect(executedCommands.first, contains('command -v adb'));
        expect(executedCommands.last, "'/opt/android/adb' version");
        await runner.connect(replacement, address: '127.0.0.1:41002');
        expect(
          executedCommands.last,
          "'/usr/local/bin/adb' connect 127.0.0.1:41002",
        );
      },
    );

    test('reports ADB as unavailable when resolution finds nothing', () async {
      final client = _MockSshClient();
      final executedCommands = <String>[];
      when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.6');
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        executedCommands.add(invocation.positionalArguments.single as String);
        return _adbExec('');
      });
      final session = _adbSession(client, connectionId: 92);
      const runner = SshRemoteAdbCommandRunner();

      expect(await runner.isAvailable(session), isFalse);

      expect(executedCommands, hasLength(1));
      expect(executedCommands.single, contains('command -v adb'));
    });
  });

  test('parses a valid Android ADB endpoint', () {
    final endpoint = AndroidAdbEndpoint.fromPlatformValue(const {
      'serviceName': 'adb-device',
      'host': '192.0.2.10',
      'port': 37123,
    });

    expect(endpoint.serviceName, 'adb-device');
    expect(endpoint.host, '192.0.2.10');
    expect(endpoint.port, 37123);
  });

  test('rejects malformed Android ADB endpoints', () {
    expect(
      () => AndroidAdbEndpoint.fromPlatformValue(const {
        'serviceName': 'adb-device',
        'host': '',
        'port': 0,
      }),
      throwsFormatException,
    );
  });

  test('classifies Linux and Windows loopback listeners', () {
    expect(
      classifyRemoteListenerScope(
        'LISTEN 0 128 127.0.0.1:41002 0.0.0.0:*\n'
        'TCP [::1]:41002 [::]:0 LISTENING\n'
        '$remoteListenerProbeDoneMarker',
        41002,
      ),
      RemoteListenerScope.loopback,
    );
  });

  test('treats truncated or unavailable listener probes as unknown', () {
    expect(
      classifyRemoteListenerScope(
        'LISTEN 0 128 127.0.0.1:41002 0.0.0.0:*',
        41002,
      ),
      RemoteListenerScope.unknown,
      reason: 'output without the completion marker may be truncated',
    );
    expect(
      classifyRemoteListenerScope(
        '$remoteListenerProbeUnavailableMarker\n'
        '$remoteListenerProbeDoneMarker',
        41002,
      ),
      RemoteListenerScope.unknown,
    );
  });

  test('builds locale-stable, port-filtered listener probes', () {
    final posix = buildPosixListenerProbeCommand(41002);
    expect(posix, contains('LC_ALL=C'));
    expect(posix, contains('ss -ltn'));
    expect(posix, contains('netstat -an'));
    expect(posix, contains('41002'));
    expect(posix, contains(remoteListenerProbeDoneMarker));
    expect(posix, contains(remoteListenerProbeUnavailableMarker));

    final windows = buildWindowsListenerProbeCommand(41002);
    expect(windows, contains('-EncodedCommand'));
    final encodedScript = windows.split('-EncodedCommand ').last.trim();
    final decodedScript = String.fromCharCodes(
      // PowerShell encodes the script as UTF-16LE before base64.
      Uint8List.fromList(base64Decode(encodedScript)).buffer.asUint16List(),
    );
    expect(decodedScript, contains('Get-NetTCPConnection'));
    expect(decodedScript, contains('-State Listen'));
    expect(decodedScript, contains('41002'));
    expect(decodedScript, isNot(contains('netstat')));
    expect(decodedScript, contains(remoteListenerProbeDoneMarker));
  });

  test('classifies wildcard and non-loopback listeners as exposed', () {
    expect(
      classifyRemoteListenerScope(
        'LISTEN 0 128 0.0.0.0:41002 0.0.0.0:*\n'
        '$remoteListenerProbeDoneMarker',
        41002,
      ),
      RemoteListenerScope.exposed,
    );
    expect(
      classifyRemoteListenerScope(
        'tcp4 0 0 192.0.2.20.41002 *.* LISTEN\n'
        '$remoteListenerProbeDoneMarker',
        41002,
      ),
      RemoteListenerScope.exposed,
    );
  });

  test('serializes Android NSD requests across sessions', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('xyz.depollsoft.monkeyssh/device_debug'),
            null,
          );
    });
    const channel = MethodChannel('xyz.depollsoft.monkeyssh/device_debug');
    final pendingResponses = <Completer<Object?>>[];
    var discoveryCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
          if (call.method != 'discoverAdbEndpoint') {
            return null;
          }
          discoveryCalls++;
          final response = Completer<Object?>();
          pendingResponses.add(response);
          return response.future;
        });
    final platform = MethodChannelAndroidDeviceDebugPlatform();

    final first = platform.discoverEndpoint(AndroidAdbServiceKind.connect);
    await Future<void>.delayed(Duration.zero);
    final second = platform.discoverEndpoint(AndroidAdbServiceKind.pairing);
    await Future<void>.delayed(Duration.zero);

    expect(discoveryCalls, 1);
    pendingResponses.first.complete(null);
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(discoveryCalls, 2);
    pendingResponses.last.complete(null);
    await second;
  });

  group('DeviceDebugSessionController', () {
    late _MockSshSession session;
    late _FakeAndroidDeviceDebugPlatform platform;
    late _FakeRemoteAdbCommandRunner remoteRunner;
    late List<ActiveTunnelInfo> activeTunnels;
    late List<int> stoppedTunnelIds;
    late Completer<void> closedCompleter;

    const connectEndpoint = AndroidAdbEndpoint(
      serviceName: 'adb-connect',
      host: '192.0.2.10',
      port: 37123,
    );
    const pairingEndpoint = AndroidAdbEndpoint(
      serviceName: 'adb-pairing',
      host: '192.0.2.10',
      port: 38947,
    );

    setUp(() {
      session = _MockSshSession();
      platform = _FakeAndroidDeviceDebugPlatform();
      remoteRunner = _FakeRemoteAdbCommandRunner();
      activeTunnels = [];
      stoppedTunnelIds = [];
      closedCompleter = Completer<void>();

      when(() => session.connectionId).thenReturn(7);
      when(() => session.closed).thenAnswer((_) => closedCompleter.future);
      when(() => session.activeTunnels).thenAnswer((_) => activeTunnels);
      when(() => session.stopForward(any())).thenAnswer((invocation) async {
        final tunnelId = invocation.positionalArguments.single as int;
        stoppedTunnelIds.add(tunnelId);
        activeTunnels.removeWhere((tunnel) => tunnel.portForwardId == tunnelId);
      });
      when(
        () => session.startRemoteForward(
          portForwardId: any(named: 'portForwardId'),
          remoteHost: any(named: 'remoteHost'),
          remotePort: any(named: 'remotePort'),
          localHost: any(named: 'localHost'),
          localPort: any(named: 'localPort'),
        ),
      ).thenAnswer((invocation) async {
        final tunnelId = invocation.namedArguments[#portForwardId]! as int;
        final remotePort = tunnelId == -2147483001 ? 41001 : 41002;
        activeTunnels.add(
          ActiveTunnelInfo(
            portForwardId: tunnelId,
            localHost: invocation.namedArguments[#localHost]! as String,
            localPort: invocation.namedArguments[#localPort]! as int,
            remoteHost: '127.0.0.1',
            remotePort: remotePort,
            isLocal: false,
          ),
        );
        return true;
      });
    });

    DeviceDebugSessionController buildController() {
      final controller = DeviceDebugSessionController(
        session: session,
        platform: platform,
        remoteRunner: remoteRunner,
      );
      addTearDown(controller.dispose);
      return controller;
    }

    test('connects an already-paired SSH host and tears it down', () async {
      platform.endpoints[AndroidAdbServiceKind.connect] = connectEndpoint;
      remoteRunner.connectResults.add(_connected);
      final controller = buildController();

      await controller.enable();

      expect(controller.state.phase, DeviceDebugPhase.active);
      expect(controller.state.remoteAddress, '127.0.0.1:41002');
      verify(
        () => session.startRemoteForward(
          portForwardId: -2147483002,
          remoteHost: '127.0.0.1',
          remotePort: 0,
          localHost: connectEndpoint.host,
          localPort: connectEndpoint.port,
        ),
      ).called(1);

      await controller.stop();

      expect(controller.state.phase, DeviceDebugPhase.off);
      expect(remoteRunner.disconnectAddresses, ['127.0.0.1:41002']);
      expect(stoppedTunnelIds, contains(-2147483002));
    });

    test('pairs the remote ADB identity before connecting', () async {
      platform.endpoints
        ..[AndroidAdbServiceKind.connect] = connectEndpoint
        ..[AndroidAdbServiceKind.pairing] = pairingEndpoint;
      remoteRunner.connectResults.addAll([
        const RemoteAdbCommandResult(
          exitCode: 1,
          output: 'failed to authenticate to 127.0.0.1:41002',
        ),
        _connected,
      ]);
      final controller = buildController();

      await controller.enable();

      expect(controller.state.phase, DeviceDebugPhase.waitingForPairingCode);

      await controller.pair('123456');

      expect(controller.state.phase, DeviceDebugPhase.active);
      expect(remoteRunner.pairedCodes, ['123456']);
      expect(stoppedTunnelIds, contains(-2147483001));
      expect(remoteRunner.connectAddresses, [
        '127.0.0.1:41002',
        '127.0.0.1:41002',
      ]);
    });

    test(
      'waits for Wireless debugging when no endpoint is advertised',
      () async {
        platform.endpoints[AndroidAdbServiceKind.connect] = null;
        final controller = buildController();

        await controller.enable();

        expect(
          controller.state.phase,
          DeviceDebugPhase.waitingForWirelessDebugging,
        );
      },
    );

    test('shows an actionable error when remote adb is unavailable', () async {
      remoteRunner.available = false;
      final controller = buildController();

      await controller.enable();

      expect(controller.state.phase, DeviceDebugPhase.error);
      expect(controller.state.errorKind, DeviceDebugErrorKind.adbUnavailable);
    });

    test('requires a pairing-capable remote adb version', () async {
      remoteRunner.pairingSupported = false;
      final controller = buildController();

      await controller.enable();

      expect(controller.state.phase, DeviceDebugPhase.error);
      expect(
        controller.state.message,
        contains('too old for Wireless debugging'),
      );
    });

    test('closes the connect tunnel when remote adb throws', () async {
      platform.endpoints[AndroidAdbServiceKind.connect] = connectEndpoint;
      remoteRunner.connectError = const DeviceDebugException(
        kind: DeviceDebugErrorKind.remoteCommandFailed,
        message: 'ADB failed.',
      );
      final controller = buildController();

      await controller.enable();

      expect(controller.state.phase, DeviceDebugPhase.error);
      expect(stoppedTunnelIds, contains(-2147483002));
      expect(
        activeTunnels.where((tunnel) => tunnel.portForwardId == -2147483002),
        isEmpty,
      );
    });

    test('fails closed when the SSH server widens the listener', () async {
      platform.endpoints[AndroidAdbServiceKind.connect] = connectEndpoint;
      remoteRunner.listenerScopeResult = RemoteListenerScope.exposed;
      final controller = buildController();

      await controller.enable();

      expect(controller.state.phase, DeviceDebugPhase.error);
      expect(
        controller.state.errorKind,
        DeviceDebugErrorKind.remoteForwardExposed,
      );
      expect(stoppedTunnelIds, contains(-2147483002));
    });

    test('closes the tunnel when listener verification fails', () async {
      platform.endpoints[AndroidAdbServiceKind.connect] = connectEndpoint;
      remoteRunner.listenerScopeError = const DeviceDebugException(
        kind: DeviceDebugErrorKind.remoteCommandFailed,
        message: 'Could not inspect listeners.',
      );
      final controller = buildController();

      await controller.enable();

      expect(controller.state.phase, DeviceDebugPhase.error);
      expect(stoppedTunnelIds, contains(-2147483002));
      expect(
        activeTunnels.where((tunnel) => tunnel.portForwardId == -2147483002),
        isEmpty,
      );
    });

    test('waits for connect cleanup before allowing a restart', () async {
      platform.endpoints[AndroidAdbServiceKind.connect] = connectEndpoint;
      final pendingConnect = Completer<RemoteAdbCommandResult>();
      remoteRunner.pendingConnect = pendingConnect;
      final controller = buildController();

      final enableFuture = controller.enable();
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.phase, DeviceDebugPhase.connecting);

      var stopCompleted = false;
      final stopFuture = controller.stop();
      unawaited(stopFuture.then((_) => stopCompleted = true));
      expect(identical(controller.stop(), stopFuture), isTrue);
      await controller.enable();
      await controller.pair('123456');
      expect(controller.state.phase, DeviceDebugPhase.stopping);
      expect(stopCompleted, isFalse);
      expect(activeTunnels, isEmpty);
      expect(remoteRunner.connectAddresses, hasLength(1));
      expect(remoteRunner.pairedCodes, isEmpty);

      final pendingDisconnect = Completer<RemoteAdbCommandResult>();
      remoteRunner.pendingDisconnect = pendingDisconnect;
      pendingConnect.complete(_connected);
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.phase, DeviceDebugPhase.stopping);
      expect(stopCompleted, isFalse);
      expect(remoteRunner.disconnectAddresses, ['127.0.0.1:41002']);
      pendingDisconnect.complete(
        const RemoteAdbCommandResult(exitCode: 0, output: 'disconnected'),
      );
      await enableFuture;
      await stopFuture;

      expect(controller.state.phase, DeviceDebugPhase.off);
      expect(
        activeTunnels.where((tunnel) => tunnel.portForwardId == -2147483002),
        isEmpty,
      );

      remoteRunner.pendingConnect = null;
      remoteRunner.connectResults.add(_connected);
      await controller.enable();
      expect(controller.state.phase, DeviceDebugPhase.active);
      expect(activeTunnels.single.portForwardId, -2147483002);
    });

    test(
      'offers pairing when adb reports a plain connection failure',
      () async {
        platform.endpoints[AndroidAdbServiceKind.connect] = connectEndpoint;
        remoteRunner.connectResults.add(_notPaired);
        final controller = buildController();

        await controller.enable();

        expect(controller.state.phase, DeviceDebugPhase.waitingForPairingCode);
        expect(controller.state.message, contains('not paired'));
        expect(stoppedTunnelIds, contains(-2147483002));
      },
    );

    test('reports Android versions without Wireless debugging', () async {
      platform.wirelessDebuggingSupported = false;
      final controller = buildController();

      await controller.enable();

      expect(controller.state.phase, DeviceDebugPhase.error);
      expect(controller.state.errorKind, DeviceDebugErrorKind.unsupported);
      expect(controller.state.message, contains('Android 11'));
      expect(remoteRunner.connectAddresses, isEmpty);
    });

    test('stops cleanly when the remote disconnect throws', () async {
      platform.endpoints[AndroidAdbServiceKind.connect] = connectEndpoint;
      remoteRunner.connectResults.add(_connected);
      final controller = buildController();
      await controller.enable();
      expect(controller.state.phase, DeviceDebugPhase.active);

      remoteRunner.disconnectError = const FormatException('bad output');
      await controller.stop();

      expect(controller.state.phase, DeviceDebugPhase.off);
      expect(stoppedTunnelIds, contains(-2147483002));
      expect(activeTunnels, isEmpty);
    });

    test('waits for pairing cleanup before allowing a restart', () async {
      platform.endpoints
        ..[AndroidAdbServiceKind.connect] = connectEndpoint
        ..[AndroidAdbServiceKind.pairing] = pairingEndpoint;
      remoteRunner.connectResults.add(
        const RemoteAdbCommandResult(
          exitCode: 1,
          output: 'failed to authenticate to 127.0.0.1:41002',
        ),
      );
      final controller = buildController();
      await controller.enable();
      expect(controller.state.phase, DeviceDebugPhase.waitingForPairingCode);

      final pendingPair = Completer<RemoteAdbCommandResult>();
      remoteRunner.pendingPair = pendingPair;
      final pairFuture = controller.pair('123456');
      await Future<void>.delayed(Duration.zero);

      final stopFuture = controller.stop();
      expect(identical(controller.stop(), stopFuture), isTrue);
      await controller.pair('654321');
      await controller.enable();
      expect(controller.state.phase, DeviceDebugPhase.stopping);
      expect(remoteRunner.pairedCodes, ['123456']);
      expect(activeTunnels, isEmpty);
      pendingPair.complete(
        const RemoteAdbCommandResult(exitCode: 1, output: 'rejected'),
      );
      await pairFuture;
      await stopFuture;

      expect(controller.state.phase, DeviceDebugPhase.off);
      expect(stoppedTunnelIds, contains(-2147483001));
      final replacementPair = Completer<RemoteAdbCommandResult>();
      remoteRunner.pendingPair = replacementPair;
      remoteRunner.connectResults.add(_connected);
      final restartFuture = controller.pair('654321');
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.phase, DeviceDebugPhase.pairing);
      expect(activeTunnels.single.portForwardId, -2147483001);
      replacementPair.complete(remoteRunner.pairResult);
      await restartFuture;
      expect(controller.state.phase, DeviceDebugPhase.active);
      expect(activeTunnels.single.portForwardId, -2147483002);
    });

    for (final discoveredEndpoint in [null, connectEndpoint]) {
      test(
        'ignores discovery after pairing is stopped: $discoveredEndpoint',
        () async {
          platform.endpoints[AndroidAdbServiceKind.pairing] = pairingEndpoint;
          final pendingEndpoint = Completer<AndroidAdbEndpoint?>();
          platform.pendingConnectEndpoint = pendingEndpoint;
          final controller = buildController();
          final pairFuture = controller.pair('123456');
          await Future<void>.delayed(Duration.zero);
          expect(remoteRunner.pairedCodes, ['123456']);
          expect(activeTunnels, isEmpty);

          final phases = <DeviceDebugPhase>[];
          controller.addListener(() => phases.add(controller.state.phase));
          final stopFuture = controller.stop();
          await Future<void>.delayed(Duration.zero);
          expect(controller.state.phase, DeviceDebugPhase.stopping);
          pendingEndpoint.complete(discoveredEndpoint);
          await pairFuture;
          await stopFuture;

          expect(phases, [DeviceDebugPhase.stopping, DeviceDebugPhase.off]);
          expect(remoteRunner.connectAddresses, isEmpty);
          expect(activeTunnels, isEmpty);
        },
      );
    }

    test('publishes the off state when the SSH session closes', () async {
      final controller = DeviceDebugSessionController(
        session: session,
        platform: platform,
        remoteRunner: remoteRunner,
      );
      var notifications = 0;
      controller
        ..addListener(() => notifications++)
        ..handleSessionClosed();

      expect(notifications, 1);
      expect(controller.state.phase, DeviceDebugPhase.off);
    });

    test('pairs from a code replied to the notification prompt', () async {
      platform.endpoints
        ..[AndroidAdbServiceKind.connect] = connectEndpoint
        ..[AndroidAdbServiceKind.pairing] = pairingEndpoint;
      remoteRunner.connectResults.addAll([_notPaired, _connected]);
      final controller = buildController();

      await controller.enable();
      expect(controller.state.phase, DeviceDebugPhase.waitingForPairingCode);

      // The prompt only appears once Android's pairing screen is advertising.
      await Future<void>.delayed(Duration.zero);
      expect(platform.pairingPromptStatuses, isNotEmpty);
      expect(platform.pairingPromptStatuses.last, contains('6-digit code'));
      expect(controller.pairingPromptUnavailable, isFalse);

      platform.pairingCodes.add('123456');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(remoteRunner.pairedCodes, ['123456']);
      expect(controller.state.phase, DeviceDebugPhase.active);
      expect(platform.pairingPromptHiddenCount, greaterThan(0));
    });

    test('reports when the pairing notification cannot be posted', () async {
      platform.endpoints
        ..[AndroidAdbServiceKind.connect] = connectEndpoint
        ..[AndroidAdbServiceKind.pairing] = pairingEndpoint;
      platform.pairingPromptAllowed = false;
      remoteRunner.connectResults.add(_notPaired);
      final controller = buildController();

      await controller.enable();
      await Future<void>.delayed(Duration.zero);

      expect(controller.pairingPromptUnavailable, isTrue);
    });

    test('hides the pairing prompt when device debugging stops', () async {
      platform.endpoints
        ..[AndroidAdbServiceKind.connect] = connectEndpoint
        ..[AndroidAdbServiceKind.pairing] = pairingEndpoint;
      remoteRunner.connectResults.add(_notPaired);
      final controller = buildController();
      await controller.enable();
      await Future<void>.delayed(Duration.zero);
      expect(platform.pairingPromptStatuses, isNotEmpty);

      await controller.stop();

      expect(platform.pairingPromptHiddenCount, greaterThan(0));
      expect(controller.state.phase, DeviceDebugPhase.off);
    });

    test('routes a replied code to the newest waiting session only', () async {
      platform.endpoints
        ..[AndroidAdbServiceKind.connect] = connectEndpoint
        ..[AndroidAdbServiceKind.pairing] = pairingEndpoint;
      remoteRunner.connectResults.addAll([_notPaired, _notPaired, _connected]);
      final first = DeviceDebugSessionController(
        session: session,
        platform: platform,
        remoteRunner: remoteRunner,
      );
      addTearDown(first.dispose);
      final second = DeviceDebugSessionController(
        session: session,
        platform: platform,
        remoteRunner: remoteRunner,
      );
      addTearDown(second.dispose);

      await first.enable();
      await second.enable();
      await Future<void>.delayed(Duration.zero);
      expect(first.state.phase, DeviceDebugPhase.waitingForPairingCode);
      expect(second.state.phase, DeviceDebugPhase.waitingForPairingCode);

      platform.pairingCodes.add('123456');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      // Only the session that owns Android's single pairing dialog may pair.
      expect(remoteRunner.pairedCodes, ['123456']);
      expect(second.state.phase, DeviceDebugPhase.active);
      expect(first.state.phase, DeviceDebugPhase.waitingForPairingCode);
    });

    test('returns to the app after pairing from the notification', () async {
      platform.endpoints
        ..[AndroidAdbServiceKind.connect] = connectEndpoint
        ..[AndroidAdbServiceKind.pairing] = pairingEndpoint;
      remoteRunner.connectResults.addAll([_notPaired, _connected]);
      final controller = buildController();
      await controller.enable();
      await Future<void>.delayed(Duration.zero);

      platform.pairingCodes.add('123456');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.phase, DeviceDebugPhase.active);
      expect(platform.returnToAppCalls, hasLength(1));
      // Cancelling the pairing prompt must land before the return prompt,
      // otherwise it would cancel the notification the user taps.
      expect(platform.events.last, 'return');
    });

    test('does not force the foreground when pairing was not needed', () async {
      platform.endpoints[AndroidAdbServiceKind.connect] = connectEndpoint;
      remoteRunner.connectResults.add(_connected);
      final controller = buildController();

      await controller.enable();

      expect(controller.state.phase, DeviceDebugPhase.active);
      expect(platform.returnToAppCalls, isEmpty);
    });

    test('returns to the app even when connecting later fails', () async {
      platform.endpoints
        ..[AndroidAdbServiceKind.connect] = connectEndpoint
        ..[AndroidAdbServiceKind.pairing] = pairingEndpoint;
      remoteRunner.connectResults.addAll([_notPaired, _notPaired]);
      final controller = buildController();
      await controller.enable();
      await Future<void>.delayed(Duration.zero);

      platform.pairingCodes.add('123456');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      // Pairing is the only step needing Settings, so the user must be brought
      // back even though the follow-up connect failed.
      expect(remoteRunner.pairedCodes, ['123456']);
      expect(platform.returnToAppCalls, hasLength(1));
      expect(controller.state.phase, DeviceDebugPhase.error);
    });

    test('cancels the return prompt when debugging stops', () async {
      platform.endpoints
        ..[AndroidAdbServiceKind.connect] = connectEndpoint
        ..[AndroidAdbServiceKind.pairing] = pairingEndpoint;
      remoteRunner.connectResults.addAll([_notPaired, _connected]);
      final controller = buildController();
      await controller.enable();
      await Future<void>.delayed(Duration.zero);
      platform.pairingCodes.add('123456');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(platform.returnToAppCalls, hasLength(1));

      await controller.stop();

      expect(platform.returnPromptHiddenCount, greaterThan(0));
    });

    test('ignores a stale reply once debugging is active', () async {
      platform.endpoints[AndroidAdbServiceKind.connect] = connectEndpoint;
      remoteRunner.connectResults.add(_connected);
      final controller = buildController();
      await controller.enable();
      expect(controller.state.phase, DeviceDebugPhase.active);

      // A duplicate or malformed reply must not tear the UI out of the active
      // state while the tunnel and serial are still live.
      await controller.pair('not-a-code');

      expect(controller.state.phase, DeviceDebugPhase.active);
      expect(controller.state.remoteAddress, '127.0.0.1:41002');
    });

    test('rejects pairing codes that are not six digits', () async {
      final controller = buildController();

      await controller.pair('123');

      expect(controller.state.phase, DeviceDebugPhase.waitingForPairingCode);
      expect(
        controller.state.errorKind,
        DeviceDebugErrorKind.pairingCodeInvalid,
      );
      expect(remoteRunner.pairedCodes, isEmpty);
    });
  });
}

SSHSession _adbExec(String output) {
  final channel = _MockExecChannel();
  when(
    () => channel.stdout,
  ).thenAnswer((_) => Stream.value(Uint8List.fromList(utf8.encode(output))));
  when(() => channel.stderr).thenAnswer((_) => const Stream<Uint8List>.empty());
  when(() => channel.done).thenAnswer((_) async {});
  when(() => channel.exitCode).thenReturn(0);
  when(channel.close).thenReturn(null);
  return channel;
}

SshSession _adbSession(
  SSHClient client, {
  required int connectionId,
  int hostId = 3,
  String hostname = 'mac-mini.example',
  String username = 'dev',
}) => SshSession(
  connectionId: connectionId,
  hostId: hostId,
  client: client,
  config: SshConnectionConfig(hostname: hostname, port: 22, username: username),
);
