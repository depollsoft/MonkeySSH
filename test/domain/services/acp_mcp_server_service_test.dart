// ignore_for_file: public_member_api_docs

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/models/acp_mcp_server.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/models/acp_session_workspace.dart';
import 'package:monkeyssh/domain/services/acp_mcp_server_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

AcpMcpServerConfig _stdio({
  String id = 'mcp-1',
  String name = 'filesystem',
  bool useByDefault = true,
  List<AcpMcpNameValue> env = const [
    AcpMcpNameValue(name: 'API_KEY', value: 'sk-secret-123'),
  ],
}) => AcpMcpServerConfig(
  id: id,
  name: name,
  transport: AcpMcpServerTransport.stdio,
  command: '/usr/local/bin/mcp-fs',
  args: const ['--root', '/srv'],
  env: env,
  useByDefault: useByDefault,
);

AcpMcpServerConfig _remote(
  AcpMcpServerTransport transport, {
  String id = 'mcp-2',
  String name = 'github',
  bool hasUnreadableSecrets = false,
}) => AcpMcpServerConfig(
  id: id,
  name: name,
  transport: transport,
  url: 'https://mcp.example.com/mcp',
  headers: const [
    AcpMcpNameValue(name: 'Authorization', value: 'Bearer token-xyz'),
  ],
  hasUnreadableSecrets: hasUnreadableSecrets,
);

AcpAgentCapabilities _caps({
  bool http = false,
  bool sse = false,
  bool directories = false,
}) => AcpAgentCapabilities(
  mcp: AcpMcpCapabilities(http: http, sse: sse),
  session: AcpSessionCapabilities(additionalDirectories: directories),
);

void main() {
  group('AcpMcpServerConfig.toAcpJson', () {
    test('encodes stdio servers per ACP McpServerStdio', () {
      expect(_stdio().toAcpJson(), {
        'name': 'filesystem',
        'command': '/usr/local/bin/mcp-fs',
        'args': ['--root', '/srv'],
        'env': [
          {'name': 'API_KEY', 'value': 'sk-secret-123'},
        ],
      });
    });

    test('encodes HTTP and SSE servers with their type tag', () {
      for (final transport in [
        AcpMcpServerTransport.http,
        AcpMcpServerTransport.sse,
      ]) {
        expect(_remote(transport).toAcpJson(), {
          'type': transport.storageValue,
          'name': 'github',
          'url': 'https://mcp.example.com/mcp',
          'headers': [
            {'name': 'Authorization', 'value': 'Bearer token-xyz'},
          ],
        });
      }
    });

    test('never includes secrets, names, or URLs in toString', () {
      final text = '${_stdio()} ${_remote(AcpMcpServerTransport.http)}';
      expect(text, isNot(contains('secret')));
      expect(text, isNot(contains('token')));
      expect(text, isNot(contains('filesystem')));
      expect(text, isNot(contains('example.com')));
    });
  });

  group('AcpMcpServerValidation', () {
    test('requires unique, non-empty names', () {
      expect(AcpMcpServerValidation.name('  '), isNotNull);
      expect(
        AcpMcpServerValidation.name('GitHub', otherNames: ['github']),
        isNotNull,
      );
      expect(
        AcpMcpServerValidation.name('github', otherNames: ['linear']),
        isNull,
      );
    });

    test('accepts only http(s) URLs with a host', () {
      expect(AcpMcpServerValidation.url('https://mcp.example.com'), isNull);
      expect(AcpMcpServerValidation.url('http://10.0.0.2:3000/mcp'), isNull);
      expect(AcpMcpServerValidation.url('ftp://example.com'), isNotNull);
      expect(AcpMcpServerValidation.url('example.com'), isNotNull);
      expect(AcpMcpServerValidation.url(''), isNotNull);
    });

    test('requires a single-line command', () {
      expect(AcpMcpServerValidation.command('npx'), isNull);
      expect(AcpMcpServerValidation.command(''), isNotNull);
      expect(AcpMcpServerValidation.command('a\nb'), isNotNull);
    });

    test('validates env names and header names and values', () {
      expect(AcpMcpServerValidation.envName('API_KEY'), isNull);
      expect(AcpMcpServerValidation.envName('1BAD'), isNotNull);
      expect(AcpMcpServerValidation.headerName('X-Api-Key'), isNull);
      expect(AcpMcpServerValidation.headerName('Bad Header'), isNotNull);
      expect(
        AcpMcpServerValidation.secretValue('a\r\nb', header: true),
        isNotNull,
      );
      expect(AcpMcpServerValidation.secretValue('a\nb', header: false), isNull);
    });
  });

  group('planAcpSessionWorkspaceSetup', () {
    final servers = [
      _stdio(),
      _remote(AcpMcpServerTransport.http),
      _remote(AcpMcpServerTransport.sse, id: 'mcp-3', name: 'events'),
    ];

    test('sends stdio always and skips unadvertised transports', () {
      final setup = planAcpSessionWorkspaceSetup(
        mcpServers: servers,
        additionalDirectories: const ['/shared'],
        capabilities: _caps(),
      );
      expect(setup.mcpServers.map((server) => server['name']), ['filesystem']);
      expect(setup.unsupportedMcpServerCount, 2);
      expect(setup.additionalDirectories, isEmpty);
      expect(setup.additionalDirectoriesUnsupported, isTrue);
      expect(setup.notice, contains('2 MCP servers were skipped'));
      expect(setup.notice, contains('additional directories'));
    });

    test('sends everything the agent advertises without a notice', () {
      final setup = planAcpSessionWorkspaceSetup(
        mcpServers: servers,
        additionalDirectories: const ['/shared'],
        capabilities: _caps(http: true, sse: true, directories: true),
      );
      expect(setup.mcpServers, hasLength(3));
      expect(setup.additionalDirectories, ['/shared']);
      expect(setup.notice, isNull);
    });

    test('skips servers whose secrets could not be decrypted', () {
      final setup = planAcpSessionWorkspaceSetup(
        mcpServers: [
          _remote(AcpMcpServerTransport.http, hasUnreadableSecrets: true),
        ],
        additionalDirectories: const [],
        capabilities: _caps(http: true),
      );
      expect(setup.mcpServers, isEmpty);
      expect(setup.unreadableMcpServerCount, 1);
      expect(setup.notice, contains('could not be read'));
    });

    test('requested nothing means no notice', () {
      final setup = planAcpSessionWorkspaceSetup(
        mcpServers: const [],
        additionalDirectories: const [],
        capabilities: _caps(),
      );
      expect(setup.notice, isNull);
    });
  });

  group('AcpMcpServerService', () {
    late AppDatabase database;
    late SettingsService settings;
    late AcpMcpServerService service;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      settings = SettingsService(database);
      service = AcpMcpServerService(
        settings,
        SecretEncryptionService.forTesting(),
      );
    });

    tearDown(() async {
      await database.close();
    });

    test('round-trips servers and encrypts secret values at rest', () async {
      await service.saveServer(_stdio());
      await service.saveServer(_remote(AcpMcpServerTransport.http));

      final raw = await settings.getString(SettingKeys.acpMcpServers);
      expect(raw, isNotNull);
      expect(raw, isNot(contains('sk-secret-123')));
      expect(raw, isNot(contains('token-xyz')));
      expect(raw, contains('ENCv1:'));

      final servers = await service.listServers();
      expect(servers, [_stdio(), _remote(AcpMcpServerTransport.http)]);
    });

    test('rejects invalid and duplicate servers', () async {
      await service.saveServer(_stdio());
      await expectLater(
        service.saveServer(_stdio(id: 'other', name: 'FILESYSTEM')),
        throwsA(isA<AcpMcpServerValidationException>()),
      );
      await expectLater(
        service.saveServer(
          AcpMcpServerConfig(
            id: 'bad',
            name: 'bad',
            transport: AcpMcpServerTransport.http,
            url: 'not a url',
          ),
        ),
        throwsA(isA<AcpMcpServerValidationException>()),
      );
      expect(await service.listServers(), hasLength(1));
    });

    test('updates in place by id and deletes', () async {
      await service.saveServer(_stdio());
      await service.saveServer(_stdio(name: 'fs'));
      expect((await service.listServers()).single.name, 'fs');
      await service.deleteServer('mcp-1');
      expect(await service.listServers(), isEmpty);
      expect(await settings.getString(SettingKeys.acpMcpServers), isNull);
    });

    test('toggling the default keeps the stored ciphertext', () async {
      await service.saveServer(_stdio());
      final before = await settings.getString(SettingKeys.acpMcpServers);
      await service.setUseByDefault('mcp-1', enabled: false);
      final after = await settings.getString(SettingKeys.acpMcpServers);
      String envValue(String? raw) =>
          ((((jsonDecode(raw!) as List).single as Map)['env'] as List).single
                  as Map)['value']
              as String;
      expect(envValue(after), envValue(before));
      expect((await service.listServers()).single.useByDefault, isFalse);
    });

    test('flags servers whose secrets cannot be decrypted', () async {
      await service.saveServer(_stdio());
      // Another device's key cannot open this device's ciphertext.
      final otherDevice = AcpMcpServerService(
        settings,
        SecretEncryptionService.forTesting(),
      );
      final server = (await otherDevice.listServers()).single;
      expect(server.hasUnreadableSecrets, isTrue);
      expect(server.env.single.value, isEmpty);
    });

    test('an unrelated edit keeps a secret that cannot be decrypted', () async {
      await service.saveServer(_stdio());
      String storedEnvValue(String? raw) =>
          ((((jsonDecode(raw!) as List).single as Map)['env'] as List).single
                  as Map)['value']
              as String;
      final original = storedEnvValue(
        await settings.getString(SettingKeys.acpMcpServers),
      );
      final otherDevice = AcpMcpServerService(
        settings,
        SecretEncryptionService.forTesting(),
      );
      final unreadable = (await otherDevice.listServers()).single;

      // Renaming saves the blank value the editor was given.
      await otherDevice.saveServer(unreadable.copyWith(name: 'renamed'));
      expect(
        storedEnvValue(await settings.getString(SettingKeys.acpMcpServers)),
        original,
      );
      final renamed = (await otherDevice.listServers()).single;
      expect(renamed.name, 'renamed');
      expect(renamed.hasUnreadableSecrets, isTrue);
      expect((await service.listServers()).single.env, _stdio().env);

      // Entering a value replaces it.
      await otherDevice.saveServer(
        renamed.copyWith(
          env: const [AcpMcpNameValue(name: 'API_KEY', value: 'new-key')],
        ),
      );
      final replaced = (await otherDevice.listServers()).single;
      expect(replaced.hasUnreadableSecrets, isFalse);
      expect(replaced.env.single.value, 'new-key');
    });

    test('skips malformed entries', () async {
      await settings.setString(
        SettingKeys.acpMcpServers,
        '[{"id":"x"},{"id":"ok","name":"ok","transport":"stdio",'
        '"command":"/bin/ok","args":["a",1],"useByDefault":true},5]',
      );
      final servers = await service.listServers();
      expect(servers, hasLength(1));
      expect(servers.single.args, ['a']);
      expect(servers.single.useByDefault, isTrue);
    });

    test('watchServers re-emits after changes', () async {
      final emissions = service.watchServers().take(2).toList();
      await Future<void>.delayed(Duration.zero);
      await service.saveServer(_stdio());
      final values = await emissions;
      expect(values.first, isEmpty);
      expect(values.last.single.name, 'filesystem');
    });
  });
}
