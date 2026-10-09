// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/known_hosts_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/authorized_key_install_service.dart';
import 'package:monkeyssh/domain/services/host_key_prompt_handler_provider.dart';
import 'package:monkeyssh/domain/services/interactive_auth_prompt.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

import '../../helpers/mocks.dart';
import '../../helpers/recording_diagnostics_logger.dart';

const _ed25519 =
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICyzmuYFVXnOvGclmhCuS6X1QWypbVXqzlWgC5mOZJyp';
const _otherEd25519 =
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJMcXnb+sWojKNyzFyh3SeoBK6kRU2FZdvOxMHyn9SFK';

SshKey _key({
  String publicKey = _ed25519,
  String name = 'Phone key',
  String? passphrase,
}) => SshKey(
  id: 7,
  name: name,
  keyType: 'ssh-ed25519',
  publicKey: publicKey,
  privateKey: 'PRIVATE-KEY-MATERIAL',
  passphrase: passphrase,
  createdAt: DateTime(2026),
);

class _ShellResult {
  _ShellResult(this.output, this.home);

  final String output;
  final Directory home;

  File get authorizedKeys => File('${home.path}/.ssh/authorized_keys');

  int mode(String path) => FileStat.statSync(path).mode & 0x1ff;
}

/// Runs the install the way sshd does: [shell] stands in for the account's
/// login shell and parses only the fixed command line, and the script arrives
/// on stdin.
Future<({String stdout, String stderr})> _runAsLoginShell(
  String shell,
  String keyLine, {
  required Directory home,
  bool setHome = true,
}) async {
  final process = await Process.start(
    shell,
    ['-c', authorizedKeyInstallCommand],
    environment: {
      'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
      if (setHome) 'HOME': home.path,
    },
    includeParentEnvironment: false,
  );
  final stdout = process.stdout.transform(utf8.decoder).join();
  final stderr = process.stderr.transform(utf8.decoder).join();
  process.stdin.add(utf8.encode(buildAuthorizedKeyInstallScript(keyLine)));
  await process.stdin.close();
  await process.exitCode;
  return (stdout: await stdout, stderr: await stderr);
}

Future<_ShellResult> _runInstall(
  String shell,
  String keyLine, {
  required Directory home,
  bool setHome = true,
}) async {
  final result = await _runAsLoginShell(
    shell,
    keyLine,
    home: home,
    setHome: setHome,
  );
  expect(result.stderr, isEmpty, reason: 'stderr from $shell');
  return _ShellResult(result.stdout, home);
}

Host _savedHost({String username = 'secret-user'}) => Host(
  id: 3,
  label: 'target',
  hostname: 'secret-host.example.com',
  port: 2222,
  username: username,
  isFavorite: false,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  autoConnectRequiresConfirmation: false,
  autoForwardPorts: false,
  sortOrder: 0,
);

void main() {
  group('buildAuthorizedKeyLine', () {
    test('adds a sanitized comment to a valid key', () {
      expect(
        buildAuthorizedKeyLine(_ed25519, comment: 'Phone key'),
        '$_ed25519 Phone-key',
      );
      expect(buildAuthorizedKeyLine('$_ed25519\n'), '$_ed25519 monkeyssh');
    });

    test('strips shell syntax and newlines from the comment', () {
      final line = buildAuthorizedKeyLine(
        _ed25519,
        comment: "x'; rm -rf ~ #\nssh-rsa AAAA evil",
      );
      expect(line, startsWith('$_ed25519 '));
      expect(line, isNot(contains("'")));
      expect(line, isNot(contains('\n')));
      expect(line, isNot(contains(';')));
      expect(line.split(' '), hasLength(3));
    });

    test('caps long comments', () {
      final line = buildAuthorizedKeyLine(_ed25519, comment: 'k' * 200);
      expect(line.split(' ').last.length, 64);
    });

    test('rejects unknown types, bad base64, and mismatched blobs', () {
      for (final value in [
        '',
        'ssh-ed25519',
        'ssh-foo AAAAC3NzaC1lZDI1NTE5AAAAICyz',
        'ssh-ed25519 not*base64',
        // An ed25519 blob labelled as RSA.
        'ssh-rsa AAAAC3NzaC1lZDI1NTE5AAAAICyzmuYFVXnOvGclmhCuS6X1QWypbVXqzlWgC5mOZJyp',
      ]) {
        expect(
          () => buildAuthorizedKeyLine(value),
          throwsFormatException,
          reason: value,
        );
      }
    });
  });

  group('install command', () {
    test('the login shell only ever sees a fixed command line', () {
      expect(authorizedKeyInstallCommand, 'exec /bin/sh -s');
      final keyLine = buildAuthorizedKeyLine(
        _ed25519,
        comment: "x'; \$(rm -rf ~) `id` \"q\" \\ #\nssh-rsa AAAA evil",
      );
      final script = buildAuthorizedKeyInstallScript(keyLine);
      // The key travels in the stdin script, quoted for /bin/sh.
      expect(script, startsWith("key='$keyLine'\n"));
      expect(script, contains(authorizedKeyInstallScriptBody));
      expect(
        authorizedKeyInstallCommand,
        isNot(contains(_ed25519.split(' ')[1])),
      );
    });

    test('parses the marker after login noise', () {
      expect(
        parseAuthorizedKeyInstallOutput(
          'Welcome!\n$authorizedKeyInstallMarker=added\n',
        ),
        AuthorizedKeyInstallOutcome.added,
      );
      expect(
        parseAuthorizedKeyInstallOutput('$authorizedKeyInstallMarker=present'),
        AuthorizedKeyInstallOutcome.alreadyPresent,
      );
      expect(
        parseAuthorizedKeyInstallOutput(
          '$authorizedKeyInstallMarker=write_failed\r\n',
        ),
        AuthorizedKeyInstallOutcome.fileNotWritable,
      );
      expect(
        parseAuthorizedKeyInstallOutput('This account is restricted.'),
        AuthorizedKeyInstallOutcome.unexpectedOutput,
      );
      expect(
        parseAuthorizedKeyInstallOutput(
          'echo $authorizedKeyInstallMarker=added in text',
        ),
        AuthorizedKeyInstallOutcome.unexpectedOutput,
      );
    });
  });

  final shells = [
    '/bin/sh',
    '/bin/bash',
    '/bin/zsh',
    '/bin/dash',
    '/bin/ksh',
    '/bin/tcsh',
    '/bin/csh',
    '/usr/bin/fish',
    '/opt/homebrew/bin/fish',
  ].where((path) => !Platform.isWindows && File(path).existsSync());

  group('install script in a real shell', () {
    late Directory home;
    final keyLine = buildAuthorizedKeyLine(_ed25519, comment: 'phone');

    setUp(() {
      home = Directory.systemTemp.createTempSync('monkeyssh-key-install-');
    });

    tearDown(() {
      if (home.existsSync()) home.deleteSync(recursive: true);
    });

    for (final shell in shells) {
      test('$shell creates ~/.ssh with private modes', () async {
        final result = await _runInstall(shell, keyLine, home: home);
        expect(
          parseAuthorizedKeyInstallOutput(result.output),
          AuthorizedKeyInstallOutcome.added,
        );
        expect(result.authorizedKeys.readAsStringSync(), '$keyLine\n');
        expect(result.mode('${home.path}/.ssh'), 0x1c0); // 0700
        expect(result.mode(result.authorizedKeys.path), 0x180); // 0600
      });
    }

    test('does not duplicate a key, even with another comment', () async {
      final shell = shells.first;
      await _runInstall(shell, keyLine, home: home);
      final again = await _runInstall(
        shell,
        buildAuthorizedKeyLine(_ed25519, comment: 'renamed'),
        home: home,
      );
      expect(
        parseAuthorizedKeyInstallOutput(again.output),
        AuthorizedKeyInstallOutcome.alreadyPresent,
      );
      expect(again.authorizedKeys.readAsStringSync(), '$keyLine\n');
    });

    test('appends without clobbering and repairs a missing newline', () async {
      final shell = shells.first;
      final ssh = Directory('${home.path}/.ssh')..createSync();
      final file = File('${ssh.path}/authorized_keys')
        ..writeAsStringSync('from="10.0.0.1" $_otherEd25519 laptop');
      final result = await _runInstall(shell, keyLine, home: home);
      expect(
        parseAuthorizedKeyInstallOutput(result.output),
        AuthorizedKeyInstallOutcome.added,
      );
      expect(
        file.readAsStringSync(),
        'from="10.0.0.1" $_otherEd25519 laptop\n$keyLine\n',
      );
    });

    for (final options in [
      'command="/usr/bin/rrsync -ro /backup",restrict',
      'from="10.0.0.0/8"',
      'cert-authority',
    ]) {
      test('a copy behind "$options" is reported, not reused', () async {
        final shell = shells.first;
        final ssh = Directory('${home.path}/.ssh')..createSync();
        final original = '$options $keyLine\n';
        final file = File('${ssh.path}/authorized_keys')
          ..writeAsStringSync(original);
        final result = await _runInstall(shell, keyLine, home: home);
        expect(
          parseAuthorizedKeyInstallOutput(result.output),
          AuthorizedKeyInstallOutcome.restrictedCopy,
        );
        expect(file.readAsStringSync(), original);
      });
    }

    test(
      'an unrestricted copy with another comment counts as present',
      () async {
        final shell = shells.first;
        final ssh = Directory('${home.path}/.ssh')..createSync();
        File(
          '${ssh.path}/authorized_keys',
        ).writeAsStringSync('$_otherEd25519 laptop\n  $_ed25519 old-comment\n');
        final result = await _runInstall(shell, keyLine, home: home);
        expect(
          parseAuthorizedKeyInstallOutput(result.output),
          AuthorizedKeyInstallOutcome.alreadyPresent,
        );
      },
    );

    test('a commented-out copy does not count as installed', () async {
      final shell = shells.first;
      final ssh = Directory('${home.path}/.ssh')..createSync();
      File('${ssh.path}/authorized_keys').writeAsStringSync('  # $keyLine\n');
      final result = await _runInstall(shell, keyLine, home: home);
      expect(
        parseAuthorizedKeyInstallOutput(result.output),
        AuthorizedKeyInstallOutcome.added,
      );
      expect(result.authorizedKeys.readAsLinesSync(), [
        '  # $keyLine',
        keyLine,
      ]);
    });

    test('removes group and world write bits from existing files', () async {
      final shell = shells.first;
      final ssh = Directory('${home.path}/.ssh')..createSync();
      final file = File('${ssh.path}/authorized_keys')
        ..writeAsStringSync('$_otherEd25519\n');
      await Process.run('chmod', ['777', ssh.path]);
      await Process.run('chmod', ['666', file.path]);
      final result = await _runInstall(shell, keyLine, home: home);
      expect(result.mode(ssh.path) & 0x12, 0); // no g+w / o+w
      expect(result.mode(file.path) & 0x12, 0);
    });

    test('reports a missing home directory', () async {
      final shell = shells.first;
      home.deleteSync(recursive: true);
      final result = await _runInstall(shell, keyLine, home: home);
      expect(
        parseAuthorizedKeyInstallOutput(result.output),
        AuthorizedKeyInstallOutcome.noHomeDirectory,
      );
    });

    for (final shell in shells) {
      Future<void> runManual(String command) async {
        final result = await Process.run(
          shell,
          ['-c', command],
          environment: {'PATH': '/usr/bin:/bin', 'HOME': home.path},
          includeParentEnvironment: false,
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }

      test('$shell runs the manual one-liner idempotently', () async {
        final ssh = Directory('${home.path}/.ssh')..createSync();
        final file = File('${ssh.path}/authorized_keys')
          ..writeAsStringSync('$_otherEd25519 laptop\n');
        final command = buildManualAuthorizedKeyCommand(keyLine);
        await runManual(command);
        await runManual(command);
        expect(file.readAsLinesSync().where((line) => line.isNotEmpty), [
          '$_otherEd25519 laptop',
          keyLine,
        ]);
        expect(FileStat.statSync(file.path).mode & 0x1ff, 0x180);
      });

      test('$shell manual one-liner starts a new line', () async {
        final ssh = Directory('${home.path}/.ssh')..createSync();
        final file = File('${ssh.path}/authorized_keys')
          ..writeAsStringSync('$_otherEd25519 laptop');
        final command = buildManualAuthorizedKeyCommand(keyLine);
        await runManual(command);
        await runManual(command);
        expect(file.readAsLinesSync().where((line) => line.isNotEmpty), [
          '$_otherEd25519 laptop',
          keyLine,
        ]);
      });

      test('$shell manual one-liner ignores commented-out copies', () async {
        final ssh = Directory('${home.path}/.ssh')..createSync();
        final file = File('${ssh.path}/authorized_keys')
          ..writeAsStringSync('# $keyLine\n');
        await runManual(buildManualAuthorizedKeyCommand(keyLine));
        expect(file.readAsLinesSync().where((line) => line.isNotEmpty), [
          '# $keyLine',
          keyLine,
        ]);
      });
    }

    test('reports a read-only authorized_keys', () async {
      final uid = (await Process.run('id', ['-u'])).stdout.toString().trim();
      if (uid == '0') {
        markTestSkipped('root can write read-only files');
        return;
      }
      final ssh = Directory('${home.path}/.ssh')..createSync();
      final file = File('${ssh.path}/authorized_keys')
        ..writeAsStringSync('$_otherEd25519\n');
      await Process.run('chmod', ['400', file.path]);
      final result = await _runAsLoginShell(shells.first, keyLine, home: home);
      expect(
        parseAuthorizedKeyInstallOutput(result.stdout),
        AuthorizedKeyInstallOutcome.fileNotWritable,
      );
      await Process.run('chmod', ['600', file.path]);
      expect(file.readAsStringSync(), '$_otherEd25519\n');
    });
  }, skip: shells.isEmpty ? 'No POSIX shell available' : null);

  group('AuthorizedKeyInstallService', () {
    late AppDatabase db;
    late HostRepository hosts;
    late RecordingDiagnosticsLogger diagnostics;
    late MockSshSession session;
    SshConnectionConfig? capturedConfig;
    late SshConnectionResult nextResult;
    late AuthorizedKeyInstallService service;

    setUpAll(() {
      registerFallbackValue(() async => '');
    });

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      hosts = HostRepository(db, SecretEncryptionService.forTesting());
      diagnostics = RecordingDiagnosticsLogger();
      session = MockSshSession();
      capturedConfig = null;
      nextResult = const SshConnectionResult(success: false, error: 'nope');
      when(() => session.hostId).thenReturn(3);
      when(() => session.connectionId).thenReturn(11);
      when(() => session.remoteIsWindows).thenReturn(false);
      when(() => session.config).thenReturn(
        const SshConnectionConfig(
          hostname: 'secret-host.example.com',
          port: 2222,
          username: 'secret-user',
          password: 'hunter2',
          jumpHost: SshConnectionConfig(
            hostname: 'jump.example.com',
            port: 22,
            username: 'jumper',
          ),
        ),
      );
      service = AuthorizedKeyInstallService(
        hostRepository: hosts,
        connectKeyOnly: (config) async {
          capturedConfig = config;
          return nextResult;
        },
        diagnostics: diagnostics,
      );
    });

    tearDown(() => db.close());

    final stdinBytes = <int>[];

    void stubExec(String stdout, {void Function(String)? onCommand}) {
      stdinBytes.clear();
      when(() => session.runQueuedExec<String>(any())).thenAnswer((invocation) {
        final operation =
            invocation.positionalArguments.first as Future<String> Function();
        return operation();
      });
      when(() => session.execute(any())).thenAnswer((invocation) async {
        onCommand?.call(invocation.positionalArguments.first as String);
        final exec = MockSSHSession();
        when(() => exec.stdout).thenAnswer(
          (_) => Stream.value(Uint8List.fromList(utf8.encode(stdout))),
        );
        when(() => exec.stderr).thenAnswer((_) => const Stream.empty());
        when(() => exec.done).thenAnswer((_) async {});
        when(exec.close).thenReturn(null);
        // The service closes stdin itself, which closes this controller.
        // ignore: close_sinks
        final stdin = StreamController<Uint8List>();
        stdin.stream.listen(stdinBytes.addAll);
        when(() => exec.stdin).thenReturn(stdin.sink);
        return exec;
      });
    }

    test('runs the install command and reports the outcome', () async {
      String? command;
      stubExec(
        'motd\n$authorizedKeyInstallMarker=added\n',
        onCommand: (value) => command = value,
      );
      final outcome = await service.installKey(
        session,
        _key(name: r"Phone key'; $(touch /tmp/pwned) `id`"),
      );
      expect(outcome, AuthorizedKeyInstallOutcome.added);
      // Nothing user-controlled reaches the login shell's command line.
      expect(command, authorizedKeyInstallCommand);
      final script = utf8.decode(stdinBytes);
      expect(
        script,
        startsWith("key='$_ed25519 Phone-key-touch-tmp-pwned-id'\n"),
      );
      expect(script, endsWith(authorizedKeyInstallScriptBody));
      final event = diagnostics.events.single;
      expect(event.fields['outcome'], 'added');
      expect(event.searchableText, isNot(contains('AAAA')));
      expect(event.searchableText, isNot(contains('secret')));
    });

    test('refuses Windows hosts without running anything', () async {
      when(() => session.remoteIsWindows).thenReturn(true);
      final outcome = await service.installKey(session, _key());
      expect(outcome, AuthorizedKeyInstallOutcome.unsupportedPlatform);
      verifyNever(() => session.execute(any()));
    });

    MockSshClient connectedClient({required String output}) {
      final client = MockSshClient();
      when(client.close).thenAnswer((_) async {});
      when(() => client.run(any(), stderr: any(named: 'stderr')))
          .thenAnswer((_) async => Uint8List.fromList(utf8.encode(output)));
      return client;
    }

    test('verifies the saved host with only the key and no password', () async {
      final client = connectedClient(output: '$keyLoginVerifiedMarker\n');
      nextResult = SshConnectionResult(success: true, client: client);
      final verification = await service.verifyKeyOnlyLogin(
        session,
        _key(passphrase: 'pp'),
        savedHost: _savedHost(),
      );
      expect(verification.success, isTrue);
      final config = capturedConfig!;
      expect(config.password, isNull);
      expect(config.identityKeys, isNull);
      expect(config.privateKey, 'PRIVATE-KEY-MATERIAL');
      expect(config.passphrase, 'pp');
      expect(config.hostname, 'secret-host.example.com');
      expect(config.port, 2222);
      expect(config.username, 'secret-user');
      expect(config.jumpHost!.hostname, 'jump.example.com');
      // A fixed command; nothing user-controlled reaches the login shell.
      verify(
        () => client.run(
          'echo $keyLoginVerifiedMarker',
          stderr: any(named: 'stderr'),
        ),
      ).called(1);
      verify(client.close).called(1);
      for (final event in diagnostics.events) {
        expect(event.searchableText, isNot(contains('secret')));
        expect(event.searchableText, isNot(contains('PRIVATE')));
      }
    });

    test('reports a rejected key', () async {
      nextResult = const SshConnectionResult(
        success: false,
        error: 'Authentication failed: All authentication methods failed',
      );
      final verification = await service.verifyKeyOnlyLogin(
        session,
        _key(),
        savedHost: _savedHost(),
      );
      expect(verification.success, isFalse);
      expect(verification.error, contains('Authentication failed'));
    });

    test('a forced command or restricted login fails verification', () async {
      final client = connectedClient(output: 'This key only runs backups.\n');
      nextResult = SshConnectionResult(success: true, client: client);
      final verification = await service.verifyKeyOnlyLogin(
        session,
        _key(),
        savedHost: _savedHost(),
      );
      expect(verification.success, isFalse);
      expect(verification.error, contains('normal shell'));
      verify(client.close).called(1);
    });

    test(
      'verifies the account saved now, not the one the session used',
      () async {
        final client = connectedClient(output: '$keyLoginVerifiedMarker\n');
        nextResult = SshConnectionResult(success: true, client: client);
        await service.verifyKeyOnlyLogin(
          session,
          _key(),
          savedHost: _savedHost(username: 'deploy'),
        );
        expect(capturedConfig!.username, 'deploy');
      },
    );

    test(
      'a session only counts when its endpoints match the saved host',
      () async {
        final bastionId = await hosts.insert(
          HostsCompanion.insert(
            label: 'jump',
            hostname: 'JUMP.example.com',
            username: 'jumper',
          ),
        );
        final targetId = await hosts.insert(
          HostsCompanion.insert(
            label: 'target',
            hostname: 'secret-host.example.com',
            port: const Value(2222),
            username: 'secret-user',
            jumpHostId: Value(bastionId),
          ),
        );
        final target = (await hosts.getById(targetId))!;
        expect(await service.sessionMatchesSavedHost(session, target), isTrue);
        expect(
          await service.sessionMatchesSavedHost(
            session,
            target.copyWith(username: 'deploy'),
          ),
          isFalse,
        );
        expect(
          await service.sessionMatchesSavedHost(
            session,
            target.copyWith(jumpHostId: const Value(null)),
          ),
          isFalse,
        );
      },
    );

    test('reuses only a session that matches the saved host', () async {
      final targetId = await hosts.insert(
        HostsCompanion.insert(
          label: 'target',
          hostname: 'secret-host.example.com',
          port: const Value(2222),
          username: 'deploy',
        ),
      );
      final target = (await hosts.getById(targetId))!;
      // The open session is logged in as secret-user via a jump host.
      expect(await service.reusableSessionFor(target, [session]), isNull);
    });

    test('the verifier never falls back to a password prompt', () async {
      final container = ProviderContainer(
        overrides: [
          knownHostsRepositoryProvider.overrideWithValue(
            KnownHostsRepository(db),
          ),
          hostKeyPromptHandlerProvider.overrideWithValue(null),
          interactiveAuthPromptHandlerProvider.overrideWithValue(
            (_) async => ['hunter2'],
          ),
        ],
      );
      addTearDown(container.dispose);
      final verifier = container.read(keyOnlyVerifierSshServiceProvider);
      expect(verifier.interactiveAuthPromptHandler, isNull);
      expect(verifier.hostRepository, isNull);
      expect(verifier.keyRepository, isNull);
    });

    test('switches the host to the key and removes the password', () async {
      final keyId = await db
          .into(db.sshKeys)
          .insert(
            SshKeysCompanion.insert(
              name: 'k',
              keyType: 'ssh-ed25519',
              publicKey: _ed25519,
              privateKey: 'x',
            ),
          );
      final hostId = await hosts.insert(
        HostsCompanion.insert(
          label: 'h',
          hostname: 'h',
          username: 'u',
          password: const Value('hunter2'),
        ),
      );

      await service.switchHostToKey(hostId, keyId, removePassword: false);
      var host = (await hosts.getById(hostId))!;
      expect(host.keyId, keyId);
      expect(host.password, 'hunter2');

      await service.switchHostToKey(hostId, keyId, removePassword: true);
      host = (await hosts.getById(hostId))!;
      expect(host.keyId, keyId);
      expect(host.password, isNull);
      expect(diagnostics.events.last.fields['passwordRemoved'], isTrue);
    });
  });
}
