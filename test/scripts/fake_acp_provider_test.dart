import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_authentication.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_json.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';
import 'package:monkeyssh/domain/services/acp_client.dart';
import 'package:monkeyssh/domain/services/acp_json_rpc_connection.dart';
import 'package:monkeyssh/domain/services/acp_transport.dart';

final class _ProcessTransport implements AcpTransport {
  _ProcessTransport(this.process) {
    _stdoutSubscription = process.stdout.listen(
      _incoming.add,
      onError: _incoming.addError,
    );
  }

  final Process process;
  final _incoming = StreamController<List<int>>();
  late final StreamSubscription<List<int>> _stdoutSubscription;

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  @override
  Future<void> write(List<int> bytes) async {
    process.stdin.add(bytes);
    await process.stdin.flush();
  }

  @override
  Future<void> close() async {
    await process.stdin.close();
    if (await process.exitCode != 0) {
      throw StateError('Fake ACP provider exited unsuccessfully');
    }
    await _stdoutSubscription.cancel();
    await _incoming.close();
  }
}

void main() {
  test('fake provider exercises deterministic ACP v1 fixtures', () async {
    final process = await Process.start('python3', const [
      'scripts/fake_acp_provider.py',
    ]);
    final stderr = process.stderr.transform(utf8.decoder).join();
    final connection = AcpJsonRpcConnection(
      transport: _ProcessTransport(process),
      defaultRequestTimeout: const Duration(seconds: 5),
    );
    final client = AcpClient(connection);
    final updates = client.updates.asBroadcastStream();
    final requests = client.serverRequests.asBroadcastStream();
    final seenKinds = <String>[];
    final subscription = updates.listen(
      (notification) => seenKinds.add(notification.update.kind),
    );

    final initialization = await client.initialize();
    expect(initialization.protocolVersion, 1);
    expect(initialization.agentInfo?.name, 'monkeyssh-fake-acp');
    expect(initialization.authMethods.single.id, 'fake-local');
    expect(initialization.agentCapabilities.prompt.image, isTrue);
    expect(initialization.agentCapabilities.prompt.embeddedContext, isTrue);
    expect(initialization.agentCapabilities.session.list, isTrue);
    expect(initialization.agentCapabilities.session.resume, isTrue);
    expect(initialization.agentCapabilities.session.close, isTrue);
    await client.authenticate('fake-local');

    final commandsFuture = updates.firstWhere(
      (value) => value.update is AcpAvailableCommandsUpdate,
    );
    final session = await client.newSession(cwd: '.');
    final sessionId = session.sessionId!;
    expect(session.configOptions, hasLength(2));
    final commands =
        (await commandsFuture).update as AcpAvailableCommandsUpdate;
    expect(commands.commands.map((command) => command.name), [
      'echo',
      'fixtures',
      'wait',
    ]);
    expect((await client.listSessions()).sessions.single.sessionId, sessionId);

    final permissionFuture = requests
        .where((request) => request.method == 'session/request_permission')
        .first;
    final imageFuture = updates.firstWhere(
      (value) =>
          value.update is AcpContentChunkUpdate &&
          (value.update as AcpContentChunkUpdate).content is AcpImageContent,
    );
    final resourceFuture = updates.firstWhere(
      (value) =>
          value.update is AcpContentChunkUpdate &&
          (value.update as AcpContentChunkUpdate).content is AcpResourceContent,
    );
    final prompt = client.prompt(
      sessionId: sessionId,
      content: const [AcpTextContent('/fixtures')],
    );
    final permission = await permissionFuture;
    expect(
      AcpPermissionRequest.fromJson(AcpJson.object(permission.params)!).options
          .map((option) => (option.id, option.name, option.kind.value)),
      [
        ('allow-once', 'Allow once', 'allow_once'),
        ('allow-always', 'Always allow', 'allow_always'),
        ('reject-once', 'Reject once', 'reject_once'),
        ('reject-always', 'Always reject', 'reject_always'),
      ],
    );
    await permission.respond({
      'outcome': const AcpSelectedPermissionOutcome('allow-once').toJson(),
    });
    expect((await prompt).stopReason, AcpStopReason.endTurn);

    final image =
        ((await imageFuture).update as AcpContentChunkUpdate).content
            as AcpImageContent;
    expect(base64Decode(image.data).length, lessThan(1024));
    final resource =
        ((await resourceFuture).update as AcpContentChunkUpdate).content
            as AcpResourceContent;
    expect((resource.resource as AcpTextResource).text.length, lessThan(1024));
    expect(
      seenKinds,
      containsAll([
        'user_message_chunk',
        'agent_message_chunk',
        'agent_thought_chunk',
        'plan',
        'tool_call',
        'tool_call_update',
        'usage_update',
      ]),
    );

    final config = await client.setConfigOption(
      sessionId: sessionId,
      configId: 'safeMode',
      value: false,
    );
    expect(
      config.whereType<AcpBooleanConfigOption>().single.currentValue,
      isFalse,
    );

    final replayed = <AcpContentChunkUpdate>[];
    final replaySubscription = updates.listen((notification) {
      final update = notification.update;
      if (update is AcpContentChunkUpdate && update.meta['replayed'] == true) {
        replayed.add(update);
      }
    });
    await client.loadSession(sessionId: sessionId, cwd: '.');
    await Future<void>.delayed(Duration.zero);
    expect(
      replayed.map((update) => update.kind),
      containsAll([
        'user_message_chunk',
        'agent_message_chunk',
        'agent_thought_chunk',
      ]),
    );
    await replaySubscription.cancel();
    await client.resumeSession(sessionId: sessionId, cwd: '.');

    final cancelThought = updates.firstWhere(
      (value) => value.update.kind == 'agent_thought_chunk',
    );
    final cancelPrompt = client.prompt(
      sessionId: sessionId,
      content: const [AcpTextContent('/wait')],
    );
    await cancelThought;
    await client.cancel(sessionId);
    expect((await cancelPrompt).stopReason, AcpStopReason.cancelled);
    await client.closeSession(sessionId);

    await subscription.cancel();
    await client.close();
    expect(await stderr, isEmpty);
  });

  group('auth-required mode', () {
    late Directory stateDir;
    late String authFile;

    setUp(() async {
      stateDir = await Directory.systemTemp.createTemp('fake-acp-auth');
      authFile = '${stateDir.path}/auth';
    });

    tearDown(() => stateDir.delete(recursive: true));

    Future<(AcpClient, Future<String>)> startProvider() async {
      final process = await Process.start(
        'python3',
        const ['scripts/fake_acp_provider.py', '--require-auth'],
        environment: {'FAKE_ACP_AUTH_FILE': authFile},
      );
      final stderr = process.stderr.transform(utf8.decoder).join();
      final client = AcpClient(
        AcpJsonRpcConnection(
          transport: _ProcessTransport(process),
          defaultRequestTimeout: const Duration(seconds: 5),
        ),
      );
      return (client, stderr);
    }

    Matcher authRequired() => isA<AcpRemoteException>().having(
      (error) => error.code,
      'code',
      acpAuthRequiredErrorCode,
    );

    test('agent method signs in over ACP and logout signs out', () async {
      final (client, stderr) = await startProvider();
      final initialization = await client.initialize(
        capabilities: const AcpClientCapabilities(terminalAuth: true),
      );
      final methods = initialization.authMethods;
      expect(methods.map((method) => method.id), [
        'fake-agent-login',
        'fake-terminal-login',
      ]);
      expect(methods.first.isAgent, isTrue);
      final terminal = methods.last;
      expect(terminal.isTerminal, isTrue);
      expect(terminal.args, ['--login']);
      expect(terminal.env, {'FAKE_ACP_LOGIN': '1'});
      expect(isUsableAcpAuthMethod(terminal), isTrue);
      expect(initialization.agentCapabilities.auth.logout, isTrue);

      await expectLater(client.newSession(cwd: '.'), throwsA(authRequired()));
      await expectLater(
        client.authenticate('fake-terminal-login'),
        throwsA(isA<AcpRemoteException>()),
      );
      await client.authenticate('fake-agent-login');
      expect((await client.newSession(cwd: '.')).sessionId, isNotNull);

      await client.logout();
      await expectLater(client.newSession(cwd: '.'), throwsA(authRequired()));
      await client.close();
      expect(await stderr, isEmpty);
    });

    test(
      'terminal method is offered only with the client capability',
      () async {
        final (client, stderr) = await startProvider();
        final initialization = await client.initialize();
        expect(initialization.authMethods.map((method) => method.id), [
          'fake-agent-login',
        ]);
        await client.close();
        expect(await stderr, isEmpty);
      },
    );

    test('terminal login applies the method env, exits 0, and a fresh '
        'provider is then signed in', () async {
      final missingEnv = await Process.run(
        'python3',
        const ['scripts/fake_acp_provider.py', '--require-auth', '--login'],
        environment: {'FAKE_ACP_AUTH_FILE': authFile},
      );
      expect(missingEnv.exitCode, 2);

      final login = await Process.start(
        'python3',
        const ['scripts/fake_acp_provider.py', '--require-auth', '--login'],
        environment: {'FAKE_ACP_AUTH_FILE': authFile, 'FAKE_ACP_LOGIN': '1'},
      );
      final output = login.stdout.transform(utf8.decoder).join();
      login.stdin.writeln();
      await login.stdin.close();
      expect(await login.exitCode, 0);
      expect(await output, contains('https://example.invalid/fake-device'));

      final (client, stderr) = await startProvider();
      await client.initialize(
        capabilities: const AcpClientCapabilities(terminalAuth: true),
      );
      expect((await client.newSession(cwd: '.')).sessionId, isNotNull);
      await client.close();
      expect(await stderr, isEmpty);
    });
  });
}
