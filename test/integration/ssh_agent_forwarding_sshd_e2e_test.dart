import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/repositories/known_hosts_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/host_agent_forwarding_service.dart';
import 'package:monkeyssh/domain/services/host_key_verification.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_agent_forwarding.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

// Runs the app's agent forwarding against a private OpenSSH sshd that the test
// starts on a free loopback port with throwaway keys. The phone side goes
// through SshService.connectToHost with real repositories and settings, then
// the host's own ssh(1) authenticates back to that sshd through the forwarded
// agent:
//
//   MONKEYSSH_AGENT_FORWARDING_E2E=1 flutter test \
//     test/integration/ssh_agent_forwarding_sshd_e2e_test.dart
//
// Needs sshd, ssh, ssh-add and ssh-keygen (stock on macOS); sshd runs as the
// current user, so no root and no system SSH configuration is involved.
const _sshd = '/usr/sbin/sshd';
const _sshKeygen = 'ssh-keygen';

final _enabled = Platform.environment['MONKEYSSH_AGENT_FORWARDING_E2E'] == '1';

Future<void> _keygen(String path, String type) async {
  final result = await Process.run(_sshKeygen, [
    '-q',
    '-t',
    type,
    if (type == 'rsa') ...['-b', '2048'],
    '-N',
    '',
    '-C',
    '',
    '-f',
    path,
  ]);
  if (result.exitCode != 0) {
    fail('ssh-keygen failed: ${result.stderr}');
  }
}

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<void> _waitForPort(int port) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    try {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      socket.destroy();
      return;
    } on SocketException {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  fail('sshd did not start listening on $port');
}

void main() {
  test(
    'a host authenticates onward with forwarded phone keys',
    () async {
      final user = Platform.environment['USER']!;
      final dir = await Directory.systemTemp.createTemp('monkeyssh-agent-');
      addTearDown(() => dir.delete(recursive: true));
      String path(String name) => '${dir.path}/$name';

      await _keygen(path('host_key'), 'ed25519');
      await _keygen(path('login'), 'ed25519');
      await _keygen(path('onward_ed25519'), 'ed25519');
      await _keygen(path('onward_rsa'), 'rsa');
      await _keygen(path('unchosen'), 'ed25519');
      await File(path('authorized_keys')).writeAsString(
        [
          for (final name in ['login', 'onward_ed25519', 'onward_rsa'])
            await File(path('$name.pub')).readAsString(),
        ].join(),
      );

      // The phone stores every key; the host only ever gets the agent, and
      // only for the keys chosen for it.
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final encryption = SecretEncryptionService.forTesting();
      final keys = KeyRepository(db, encryption);
      final hosts = HostRepository(db, encryption);
      Future<int> storeKey(String name, String file) async => keys.insert(
        SshKeysCompanion.insert(
          name: name,
          keyType: 'ed25519',
          publicKey: await File(path('$file.pub')).readAsString(),
          privateKey: await File(path(file)).readAsString(),
        ),
      );
      final loginKey = await storeKey('login', 'login');
      final ed25519Key = await storeKey('phone ed25519', 'onward_ed25519');
      final rsaKey = await storeKey('phone rsa', 'onward_rsa');
      await storeKey('unchosen', 'unchosen');
      for (final name in ['onward_ed25519', 'onward_rsa', 'unchosen']) {
        await File(path(name)).delete();
      }

      final port = await _freePort();
      await File(path('sshd_config')).writeAsString('''
Port $port
ListenAddress 127.0.0.1
HostKey ${path('host_key')}
AuthorizedKeysFile ${path('authorized_keys')}
PidFile ${path('sshd.pid')}
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
AllowAgentForwarding yes
''');
      final sshd = await Process.start(_sshd, [
        '-D',
        '-e',
        '-f',
        path('sshd_config'),
      ]);
      addTearDown(sshd.kill);
      unawaited(sshd.stdout.drain<void>());
      unawaited(sshd.stderr.drain<void>());
      await _waitForPort(port);

      final hostId = await hosts.insert(
        HostsCompanion.insert(
          label: 'local sshd',
          hostname: '127.0.0.1',
          port: Value(port),
          username: user,
          keyId: Value(loginKey),
        ),
      );
      final forwardingSettings = HostAgentForwardingService(
        SettingsService(db),
      );
      await forwardingSettings.setForHost(
        hostId,
        HostAgentForwardingSettings(
          enabled: true,
          confirmEachSignature: true,
          keyIds: [ed25519Key, rsaKey],
        ),
      );
      final requests = <SshAgentSignatureRequest>[];
      var approve = true;
      final keyLoader = ForwardedAgentKeyLoader(keys);
      final service = SshService(
        hostRepository: hosts,
        keyRepository: keys,
        knownHostsRepository: KnownHostsRepository(db),
        hostKeyPromptHandler: (_) async => HostKeyTrustDecision.trust,
        agentForwardingResolver: (host) => resolveHostAgentForwarding(
          host,
          loadSettings: forwardingSettings.getForHost,
          settingsChanges: forwardingSettings.changes,
          isUnlocked: () async => true,
          loadKeys: keyLoader.load,
          confirm: (request) async {
            requests.add(request);
            return approve
                ? SshAgentSignatureDecision.approved
                : SshAgentSignatureDecision.declined;
          },
        ),
      );
      addTearDown(service.disconnectAll);

      final result = await service.connectToHost(hostId);
      expect(result.success, isTrue, reason: result.error);
      final client = result.client!;
      final forwarding = service
          .getSession(result.connectionId!)!
          .config
          .agentForwarding!;

      Future<String> run(String command) async =>
          utf8.decode(await client.run(command), allowMalformed: true);
      String onward(String key) =>
          'ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=no '
          '-o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes '
          '-i ${path('$key.pub')} -p $port $user@127.0.0.1 echo onward-ok '
          '2>&1';

      final listed = await run('ssh-add -l');
      expect(listed, contains('phone ed25519'));
      expect(listed, contains('phone rsa'));
      expect(listed, isNot(contains('unchosen')));
      expect(listed, isNot(contains('login')));

      // Every later session on the connection must still work: sshd refuses
      // the repeated agent request, but SSH_AUTH_SOCK still reaches it.
      expect(await run(onward('onward_ed25519')), contains('onward-ok'));
      expect(await run(onward('onward_rsa')), contains('onward-ok'));
      expect(requests.map((request) => request.keyLabel), [
        'phone ed25519',
        'phone rsa',
      ]);
      expect(requests.every((request) => request.username == user), isTrue);
      expect(forwarding.status.value.signatureCount, 2);

      approve = false;
      final refused = await run(onward('onward_ed25519'));
      expect(refused, isNot(contains('onward-ok')));
      expect(refused, contains('Permission denied'));
      expect(forwarding.status.value.signatureCount, 2);

      // Turning forwarding off applies to the open connection.
      await forwardingSettings.setForHost(
        hostId,
        const HostAgentForwardingSettings(),
      );
      expect(await run('ssh-add -l 2>&1'), isNot(contains('phone')));
    },
    skip: _enabled && File(_sshd).existsSync()
        ? false
        : 'Set MONKEYSSH_AGENT_FORWARDING_E2E=1 on a machine with $_sshd.',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
