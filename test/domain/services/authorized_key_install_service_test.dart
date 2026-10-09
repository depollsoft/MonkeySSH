// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/authorized_key_install_service.dart';
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

Future<_ShellResult> _runInstall(
  String shell,
  String keyLine, {
  required Directory home,
  bool setHome = true,
}) async {
  final result = await Process.run(
    shell,
    ['-c', buildAuthorizedKeyInstallCommand(keyLine)],
    environment: {
      'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
      if (setHome) 'HOME': home.path,
    },
    includeParentEnvironment: false,
  );
  expect(
    result.stderr,
    isEmpty,
    reason: 'stderr from $shell: ${result.stderr}',
  );
  return _ShellResult(result.stdout as String, home);
}

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
    test('passes the script and key as separately quoted arguments', () {
      final command = buildAuthorizedKeyInstallCommand('$_ed25519 phone');
      expect(command, startsWith("/bin/sh -c '"));
      expect(command, endsWith(" monkeyssh-key-install '$_ed25519 phone'"));
      expect(authorizedKeyInstallScript, isNot(contains("'")));
      expect(authorizedKeyInstallScript, isNot(contains(r'\')));
      expect(authorizedKeyInstallScript, isNot(contains('\n')));
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
      final result = await Process.run(
        shells.first,
        ['-c', buildAuthorizedKeyInstallCommand(keyLine)],
        environment: {'PATH': '/usr/bin:/bin', 'HOME': home.path},
        includeParentEnvironment: false,
      );
      expect(
        parseAuthorizedKeyInstallOutput(result.stdout as String),
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

    void stubExec(String stdout, {void Function(String)? onCommand}) {
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
        return exec;
      });
    }

    test('runs the install command and reports the outcome', () async {
      String? command;
      stubExec(
        'motd\n$authorizedKeyInstallMarker=added\n',
        onCommand: (value) => command = value,
      );
      final outcome = await service.installKey(session, _key());
      expect(outcome, AuthorizedKeyInstallOutcome.added);
      expect(command, contains("'$_ed25519 Phone-key'"));
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

    test('verifies with only the key and no password', () async {
      nextResult = SshConnectionResult(success: true, client: MockSshClient());
      when(() => nextResult.client!.close()).thenAnswer((_) async {});
      final verification = await service.verifyKeyOnlyLogin(
        session,
        _key(passphrase: 'pp'),
      );
      expect(verification.success, isTrue);
      final config = capturedConfig!;
      expect(config.password, isNull);
      expect(config.identityKeys, isNull);
      expect(config.privateKey, 'PRIVATE-KEY-MATERIAL');
      expect(config.passphrase, 'pp');
      expect(config.hostname, 'secret-host.example.com');
      expect(config.port, 2222);
      expect(config.jumpHost!.hostname, 'jump.example.com');
      verify(() => nextResult.client!.close()).called(1);
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
      final verification = await service.verifyKeyOnlyLogin(session, _key());
      expect(verification.success, isFalse);
      expect(verification.error, contains('Authentication failed'));
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
