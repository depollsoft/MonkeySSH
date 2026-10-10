// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/domain/services/host_agent_forwarding_service.dart';
import 'package:monkeyssh/domain/services/openssh_key_generator.dart';
import 'package:monkeyssh/domain/services/secure_transfer_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_agent_forwarding.dart';

import '../../helpers/recording_diagnostics_logger.dart';
import '../../helpers/ssh_key_fixtures.dart';

class _MockSshClient extends Mock implements SSHClient {}

class _FailingSaves extends SettingsService {
  _FailingSaves(super.db);

  @override
  Future<void> updateJson(
    String key,
    Map<String, dynamic>? Function(Map<String, dynamic>? current) update,
  ) => Future.error(const FormatException('disk full'));
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Host _host({int id = 3, String label = 'build box'}) => Host(
  id: id,
  label: label,
  hostname: 'build.example.com',
  port: 22,
  username: 'dev',
  isFavorite: false,
  autoConnectRequiresConfirmation: false,
  autoForwardPorts: false,
  sortOrder: 0,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

SshAgentSignatureRequest _request({
  Future<void>? connectionClosed,
  bool Function()? isConnectionClosed,
}) => SshAgentSignatureRequest(
  hostLabel: 'build box',
  keyLabel: 'GitHub',
  username: 'git',
  connectionClosed: connectionClosed ?? Completer<void>().future,
  isConnectionClosed: isConnectionClosed ?? () => false,
);

void main() {
  group('HostAgentForwardingService', () {
    late AppDatabase db;
    late SettingsService settings;
    late HostAgentForwardingService service;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      settings = SettingsService(db);
      service = HostAgentForwardingService(settings);
    });

    tearDown(() => db.close());

    test('is off for a host that never opted in', () async {
      expect(await service.getForHost(1), const HostAgentForwardingSettings());
    });

    test('saves each host on its own and drops default entries', () async {
      await service.setForHost(
        1,
        const HostAgentForwardingSettings(enabled: true),
      );
      await service.setForHost(
        2,
        const HostAgentForwardingSettings(
          enabled: true,
          confirmEachSignature: true,
        ),
      );

      expect(
        await service.getForHost(1),
        const HostAgentForwardingSettings(enabled: true),
      );
      expect((await service.getForHost(2)).confirmEachSignature, isTrue);

      await service.setForHost(1, const HostAgentForwardingSettings());
      await service.setForHost(2, const HostAgentForwardingSettings());

      expect(await settings.getString(SettingKeys.hostAgentForwarding), isNull);
    });

    test('treats anything but a literal true as off', () async {
      await settings.setJson(SettingKeys.hostAgentForwarding, {
        '1': {'enabled': 'true', 'confirmEachSignature': 1},
        '2': 'yes',
      });

      expect(await service.getForHost(1), const HostAgentForwardingSettings());
      expect(await service.getForHost(2), const HostAgentForwardingSettings());
    });
  });

  group('HostAgentForwardingService key choice and changes', () {
    late AppDatabase db;
    late HostAgentForwardingService service;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      service = HostAgentForwardingService(SettingsService(db));
    });

    tearDown(() async {
      await service.dispose();
      await db.close();
    });

    test('keeps the chosen key IDs and ignores anything else', () async {
      await service.setForHost(
        4,
        const HostAgentForwardingSettings(enabled: true, keyIds: [3, 1]),
      );
      expect((await service.getForHost(4)).keyIds, [3, 1]);

      expect(
        HostAgentForwardingSettings.fromJson(const {
          'enabled': true,
          'keyIds': [1, '2', 1, null, 3.5, 4],
        }).keyIds,
        [1, 4],
      );
    });

    test('turning off applies at once and even if the save fails', () async {
      final failing = HostAgentForwardingService(_FailingSaves(db));
      addTearDown(failing.dispose);
      await SettingsService(db).setJson(SettingKeys.hostAgentForwarding, {
        '6': const HostAgentForwardingSettings(
          enabled: true,
          keyIds: [1],
        ).toJson(),
      });
      expect((await failing.getForHost(6)).enabled, isTrue);

      await expectLater(failing.turnOff(6), throwsA(isA<FormatException>()));
      expect((await failing.getForHost(6)).enabled, isFalse);

      // A failed attempt to turn it back on keeps it off.
      await expectLater(
        failing.setForHost(
          6,
          const HostAgentForwardingSettings(enabled: true, keyIds: [1]),
        ),
        throwsA(isA<FormatException>()),
      );
      expect((await failing.getForHost(6)).enabled, isFalse);
    });

    test('turning forwarding back on clears a turn-off', () async {
      await service.setForHost(
        6,
        const HostAgentForwardingSettings(enabled: true, keyIds: [1]),
      );
      final pending = service.turnOff(6);
      // Off before the save has landed.
      expect((await service.getForHost(6)).enabled, isFalse);
      await pending;
      expect(
        await service.getForHost(6),
        const HostAgentForwardingSettings(keyIds: [1]),
      );

      await service.setForHost(
        6,
        const HostAgentForwardingSettings(enabled: true, keyIds: [1]),
      );
      expect((await service.getForHost(6)).enabled, isTrue);
    });

    test('reports each saved host so open connections can follow', () async {
      final changed = <int>[];
      final subscription = service.changes.listen(changed.add);
      addTearDown(subscription.cancel);

      await service.setForHost(
        2,
        const HostAgentForwardingSettings(enabled: true),
      );
      await service.setForHost(2, const HostAgentForwardingSettings());
      await pumpEventQueue();

      expect(changed, [2, 2]);
    });
  });

  group('resolveHostAgentForwarding', () {
    test(
      'stays off without asking about Pro for hosts that did not opt in',
      () async {
        var proChecks = 0;
        final forwarding = await resolveHostAgentForwarding(
          _host(),
          loadSettings: (_) async => const HostAgentForwardingSettings(),
          isUnlocked: () async {
            proChecks++;
            return true;
          },
          loadKeys: (_) async => const [],
          confirm: (_) async => SshAgentSignatureDecision.approved,
          diagnostics: RecordingDiagnosticsLogger(),
        );

        expect(forwarding, isNull);
        expect(proChecks, 0);
      },
    );

    test('stays off without Pro', () async {
      final forwarding = await resolveHostAgentForwarding(
        _host(),
        loadSettings: (_) async =>
            const HostAgentForwardingSettings(enabled: true),
        isUnlocked: () async => false,
        loadKeys: (_) async => const [],
        confirm: (_) async => SshAgentSignatureDecision.approved,
        diagnostics: RecordingDiagnosticsLogger(),
      );

      expect(forwarding, isNull);
    });

    test('stays off when the settings cannot be read', () async {
      final forwarding = await resolveHostAgentForwarding(
        _host(),
        loadSettings: (_) async => throw const FormatException('corrupt'),
        isUnlocked: () async => true,
        loadKeys: (_) async => const [],
        confirm: (_) async => SshAgentSignatureDecision.approved,
        diagnostics: RecordingDiagnosticsLogger(),
      );

      expect(forwarding, isNull);
    });

    test('serves an opted-in Pro host with its confirmation choice', () async {
      final requestedHosts = <int>[];
      final diagnostics = RecordingDiagnosticsLogger();
      final forwarding = await resolveHostAgentForwarding(
        _host(id: 9, label: 'secret label'),
        loadSettings: (hostId) async {
          requestedHosts.add(hostId);
          return const HostAgentForwardingSettings(
            enabled: true,
            confirmEachSignature: true,
          );
        },
        isUnlocked: () async => true,
        loadKeys: (_) async => const [],
        confirm: (_) async => SshAgentSignatureDecision.approved,
        diagnostics: diagnostics,
      );

      expect(requestedHosts, [9]);
      expect(forwarding, isNotNull);
      expect(forwarding!.hostId, 9);
      expect(forwarding.hostLabel, 'secret label');
      expect(forwarding.confirmEachSignature, isTrue);
      expect(
        diagnostics.events.map((event) => event.searchableText).join(),
        isNot(contains('secret label')),
      );
    });

    test('deny and turn off turns forwarding off for the host', () async {
      final turnedOff = <int>[];
      (await resolveHostAgentForwarding(
        _host(),
        loadSettings: (_) async =>
            const HostAgentForwardingSettings(enabled: true),
        turnOff: (hostId) async => turnedOff.add(hostId),
        isUnlocked: () async => true,
        loadKeys: (_) async => const [],
        confirm: (_) async => SshAgentSignatureDecision.approved,
        diagnostics: RecordingDiagnosticsLogger(),
      ))!.stop();
      await pumpEventQueue();

      expect(turnedOff, [_host().id]);
    });

    test('follows the host settings on an open connection', () async {
      var settings = const HostAgentForwardingSettings(
        enabled: true,
        keyIds: [1],
      );
      final changes = StreamController<int>.broadcast();
      addTearDown(changes.close);
      final requestedKeys = <List<int>>[];
      final forwarding = (await resolveHostAgentForwarding(
        _host(),
        loadSettings: (_) async => settings,
        settingsChanges: changes.stream,
        isUnlocked: () async => true,
        loadKeys: (keyIds) async {
          requestedKeys.add(keyIds);
          return const [];
        },
        confirm: (_) async => SshAgentSignatureDecision.approved,
        diagnostics: RecordingDiagnosticsLogger(),
      ))!;
      final client = _MockSshClient();
      when(() => client.done).thenAnswer((_) => Completer<void>().future);
      forwarding.attachClient(client);

      await forwarding.handleRequest(Uint8List.fromList([11]));
      expect(requestedKeys, [
        [1],
      ]);

      settings = const HostAgentForwardingSettings(
        enabled: true,
        confirmEachSignature: true,
        keyIds: [1, 2],
      );
      changes
        ..add(99)
        ..add(_host().id);
      await pumpEventQueue();

      expect(requestedKeys.last, [1, 2]);
      expect(forwarding.status.value.confirmEachSignature, isTrue);

      settings = const HostAgentForwardingSettings();
      changes.add(_host().id);
      await pumpEventQueue();

      expect(forwarding.status.value.serving, isFalse);
      expect(await forwarding.handleRequest(Uint8List.fromList([11])), [5]);
    });
  });

  group('SshAgentSignatureConfirmations', () {
    test('refuses without prompting while the app cannot prompt', () async {
      var prompts = 0;
      final confirmations = SshAgentSignatureConfirmations(
        canPrompt: () => false,
        promptHandler: () => (_, {required timeout}) async {
          prompts++;
          return SshAgentSignatureDecision.approved;
        },
      );

      expect(
        await confirmations.confirm(_request()),
        SshAgentSignatureDecision.unavailable,
      );
      expect(prompts, 0);
    });

    test('refuses without a prompt handler', () async {
      final confirmations = SshAgentSignatureConfirmations(
        canPrompt: () => true,
        promptHandler: () => null,
      );

      expect(
        await confirmations.confirm(_request()),
        SshAgentSignatureDecision.unavailable,
      );
    });

    test('passes the answer and the timeout through', () async {
      Duration? shownTimeout;
      for (final (answer, decision) in [
        (
          SshAgentSignatureDecision.approved,
          SshAgentSignatureDecision.approved,
        ),
        (
          SshAgentSignatureDecision.declined,
          SshAgentSignatureDecision.declined,
        ),
        (
          SshAgentSignatureDecision.stopForwarding,
          SshAgentSignatureDecision.stopForwarding,
        ),
        // A prompt that could not show counts as a refusal.
        (
          SshAgentSignatureDecision.unavailable,
          SshAgentSignatureDecision.declined,
        ),
      ]) {
        final confirmations = SshAgentSignatureConfirmations(
          canPrompt: () => true,
          promptHandler: () => (_, {required timeout}) async {
            shownTimeout = timeout;
            return answer;
          },
          timeout: const Duration(seconds: 30),
        );

        expect(await confirmations.confirm(_request()), decision);
      }
      expect(shownTimeout, const Duration(seconds: 30));
    });

    test('shows one prompt at a time and re-checks before each', () async {
      var canPrompt = true;
      final first = Completer<SshAgentSignatureDecision>();
      var prompts = 0;
      final confirmations = SshAgentSignatureConfirmations(
        canPrompt: () => canPrompt,
        promptHandler: () => (_, {required timeout}) {
          prompts++;
          return first.future;
        },
      );

      final firstDecision = confirmations.confirm(_request());
      final secondDecision = confirmations.confirm(_request());
      await pumpEventQueue();
      expect(prompts, 1);

      canPrompt = false;
      first.complete(SshAgentSignatureDecision.approved);

      expect(await firstDecision, SshAgentSignatureDecision.approved);
      expect(await secondDecision, SshAgentSignatureDecision.unavailable);
      expect(prompts, 1);
    });

    test('gives up when the connection closes', () async {
      final closed = Completer<void>();
      final confirmations = SshAgentSignatureConfirmations(
        canPrompt: () => true,
        promptHandler: () =>
            (_, {required timeout}) =>
                Completer<SshAgentSignatureDecision>().future,
      );

      final decision = confirmations.confirm(
        _request(connectionClosed: closed.future),
      );
      closed.complete();

      expect(await decision, SshAgentSignatureDecision.unavailable);
      expect(
        await confirmations.confirm(_request(isConnectionClosed: () => true)),
        SshAgentSignatureDecision.unavailable,
      );
    });

    test('refuses a prompt that never answers', () {
      fakeAsync((async) {
        final confirmations = SshAgentSignatureConfirmations(
          canPrompt: () => true,
          promptHandler: () =>
              (_, {required timeout}) =>
                  Completer<SshAgentSignatureDecision>().future,
        );
        SshAgentSignatureDecision? decision;
        unawaited(
          confirmations.confirm(_request()).then((value) => decision = value),
        );

        async.elapse(const Duration(seconds: 64));
        expect(decision, isNull);
        async.elapse(const Duration(seconds: 2));
        expect(decision, SshAgentSignatureDecision.declined);
      });
    });
  });

  test('prompts only in the foreground while unlocked', () {
    for (final lifecycle in AppLifecycleState.values) {
      for (final auth in AuthState.values) {
        expect(
          canPromptForAgentSignature(
            lifecycleState: lifecycle,
            authState: auth,
          ),
          lifecycle == AppLifecycleState.resumed &&
              (auth == AuthState.unlocked || auth == AuthState.notConfigured),
          reason: '$lifecycle $auth',
        );
      }
    }
    expect(
      canPromptForAgentSignature(
        lifecycleState: null,
        authState: AuthState.unlocked,
      ),
      isFalse,
    );
  });

  group('with a database', () {
    late AppDatabase db;
    late KeyRepository keyRepository;
    late HostRepository hostRepository;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      final encryption = SecretEncryptionService.forTesting();
      keyRepository = KeyRepository(db, encryption);
      hostRepository = HostRepository(db, encryption);
    });

    tearDown(() => db.close());

    test('loads only the chosen readable keys, in the chosen order', () async {
      final ed25519 = SSHKeyPair.fromPem(sshEd25519PrivateKey).single;
      final rsa = SSHKeyPair.fromPem(sshRsaPrivateKey).single;
      Future<int> insert(
        String name,
        String privateKey, {
        String? passphrase,
      }) => keyRepository.insert(
        SshKeysCompanion.insert(
          name: name,
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA',
          privateKey: privateKey,
          passphrase: Value(passphrase),
        ),
      );
      final plain = await insert('plain', sshEd25519PrivateKey);
      final publicOnly = await insert('public only', '');
      final garbage = await insert('garbage', 'not a key');
      final encrypted = await insert(
        'encrypted',
        sshEd25519EncryptedPrivateKey,
        passphrase: sshKeyFixturePassphrase,
      );
      final wrongPassphrase = await insert(
        'wrong passphrase',
        sshEd25519EncryptedPrivateKey,
        passphrase: 'nope',
      );
      final deploy = await insert('deploy', sshRsaPrivateKey);
      await insert('not chosen', sshRsaPrivateKey);
      final loader = ForwardedAgentKeyLoader(keyRepository);

      final keys = await loader.load([
        deploy,
        plain,
        publicOnly,
        garbage,
        encrypted,
        wrongPassphrase,
        9999,
      ]);

      expect(keys.map((key) => key.label), ['deploy', 'plain', 'encrypted']);
      expect(keys[0].publicKeyBlob, rsa.toPublicKey().encode());
      expect(keys[1].publicKeyBlob, ed25519.toPublicKey().encode());
    });

    test('drops a key deleted in the app on the next load', () async {
      final id = await keyRepository.insert(
        SshKeysCompanion.insert(
          name: 'GitHub',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA',
          privateKey: sshEd25519PrivateKey,
        ),
      );
      final loader = ForwardedAgentKeyLoader(keyRepository);
      expect(await loader.load([id]), hasLength(1));

      await keyRepository.delete(id);

      expect(await loader.load([id]), isEmpty);
    });

    test('a load keeps the keys it needs while another load prunes', () async {
      Future<int> insert(String name) => keyRepository.insert(
        SshKeysCompanion.insert(
          name: name,
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA',
          privateKey: sshEd25519PrivateKey,
        ),
      );
      final first = await insert('GitHub');
      final second = await insert('deploy');
      final parsing = <Completer<void>>[];
      final loader = ForwardedAgentKeyLoader(
        keyRepository,
        parse: (keys) async {
          final gate = Completer<void>();
          parsing.add(gate);
          await gate.future;
          return parseOpenSshPrivateKeys(keys);
        },
      );
      final warmUp = loader.load([first]);
      await _until(() => parsing.isNotEmpty);
      parsing.single.complete();
      expect(await warmUp, hasLength(1));

      // This load reuses the cached first key and waits on parsing the second.
      final both = loader.load([first, second]);
      await _until(() => parsing.length == 2);
      // Meanwhile the host's key choice shrinks to nothing.
      expect(await loader.load(const []), isEmpty);
      parsing[1].complete();

      expect((await both).map((key) => key.label), ['GitHub', 'deploy']);
    });

    test('migration data never carries agent forwarding opt-ins', () async {
      final transfer = SecureTransferService(db, keyRepository, hostRepository);
      final settings = SettingsService(db);
      await settings.setString('theme_mode', 'dark');
      await HostAgentForwardingService(settings)
          .setForHost(1, const HostAgentForwardingSettings(enabled: true));

      final exported = await transfer.createMigrationData();
      final exportedSettings = exported['settings'] as Map<String, String>;
      expect(exportedSettings, contains('theme_mode'));
      expect(
        exportedSettings,
        isNot(contains(SettingKeys.hostAgentForwarding)),
      );

      await transfer.importMigrationData(
        data: {
          ...exported,
          'settings': {
            ...exportedSettings,
            SettingKeys.hostAgentForwarding: jsonEncode({
              '1': {'enabled': true},
              '2': {'enabled': true},
            }),
          },
        },
        mode: MigrationImportMode.replace,
      );

      expect(await settings.getString(SettingKeys.hostAgentForwarding), isNull);
      expect(await settings.getString('theme_mode'), 'dark');
    });
  });
}
