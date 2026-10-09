// ignore_for_file: public_member_api_docs

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/port_forward_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/ssh_config_import_planner.dart';
import 'package:monkeyssh/domain/services/ssh_config_import_service.dart';
import 'package:monkeyssh/domain/services/ssh_config_parser.dart';
import 'package:monkeyssh/domain/services/telemetry_service.dart';

import '../../helpers/recording_diagnostics_logger.dart';

class _RecordingAnalyticsClient implements TelemetryAnalyticsClient {
  final events = <(String, Map<String, Object>)>[];

  @override
  Future<void> logEvent({
    required String name,
    required Map<String, Object> parameters,
  }) async => events.add((name, parameters));

  @override
  Future<void> resetAnalyticsData() async {}

  @override
  Future<void> setCollectionEnabled({required bool enabled}) async {}
}

SshConfigImportPlan _plan(String text) =>
    buildSshConfigImportPlan(parseSshConfig(text));

String _idFor(SshConfigImportPlan plan, String label) =>
    plan.entries.singleWhere((entry) => entry.label == label).id;

void main() {
  late AppDatabase db;
  late HostRepository hosts;
  late PortForwardRepository forwards;
  late _RecordingAnalyticsClient analytics;
  late RecordingDiagnosticsLogger diagnostics;
  late SshConfigImportService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    hosts = HostRepository(db, SecretEncryptionService.forTesting());
    forwards = PortForwardRepository(db);
    analytics = _RecordingAnalyticsClient();
    diagnostics = RecordingDiagnosticsLogger();
    service = SshConfigImportService(
      db: db,
      hostRepository: hosts,
      portForwardRepository: forwards,
      telemetry: TelemetryService(
        status: TelemetryServiceStatus.ready,
        collectionEnabled: true,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
        analyticsClient: analytics,
      ),
      diagnostics: diagnostics,
    );
  });

  tearDown(() => db.close());

  test('imports hosts, jump chains, and forwards', () async {
    final plan = _plan('''
Host bastion
  HostName bastion.example.com
  User jump
Host app
  HostName 10.0.0.2
  User deploy
  Port 2222
  ProxyJump bastion
  LocalForward 8080 localhost:80
  RemoteForward 9000 127.0.0.1:3000
''');
    final result = await service.importEntries(
      plan,
      selectedIds: {_idFor(plan, 'app')},
      defaultUsername: '',
    );

    expect(result.createdHostIds.keys, {
      _idFor(plan, 'bastion'),
      _idFor(plan, 'app'),
    });
    expect(result.forwardCount, 2);
    final saved = await hosts.getAll();
    final bastion = saved.singleWhere((host) => host.label == 'bastion');
    final app = saved.singleWhere((host) => host.label == 'app');
    expect(bastion.hostname, 'bastion.example.com');
    expect(bastion.username, 'jump');
    expect(app.port, 2222);
    expect(app.jumpHostId, bastion.id);
    expect(app.password, isNull);
    expect(app.keyId, isNull);

    final appForwards = await forwards.getByHostId(app.id);
    final local = appForwards.singleWhere((f) => f.forwardType == 'local');
    expect(local.localHost, '127.0.0.1');
    expect(local.localPort, 8080);
    expect(local.remoteHost, 'localhost');
    expect(local.remotePort, 80);
    expect(local.autoStart, isTrue);
    final remote = appForwards.singleWhere((f) => f.forwardType == 'remote');
    expect(remote.remoteHost, 'localhost');
    expect(remote.remotePort, 9000);
    expect(remote.localHost, '127.0.0.1');
    expect(remote.localPort, 3000);
    expect(await forwards.getByHostId(bastion.id), isEmpty);
  });

  test('saves a multi-hop chain as nested jump hosts', () async {
    final plan = _plan('''
Host target
  User me
  ProxyJump me@outer,me@inner
''');
    await service.importEntries(
      plan,
      selectedIds: {_idFor(plan, 'target')},
      defaultUsername: '',
    );
    final saved = await hosts.getAll();
    final target = saved.singleWhere((host) => host.label == 'target');
    final inner = saved.singleWhere((host) => host.id == target.jumpHostId);
    final outer = saved.singleWhere((host) => host.id == inner.jumpHostId);
    expect(inner.hostname, 'inner');
    expect(outer.hostname, 'outer');
    expect(outer.jumpHostId, isNull);
  });

  test('does not auto-start forwards that listen beyond loopback', () async {
    final plan = _plan('''
Host web
  User me
  LocalForward *:8080 localhost:80
''');
    await service.importEntries(
      plan,
      selectedIds: {plan.entries.single.id},
      defaultUsername: '',
    );
    final forward = (await forwards.getAll()).single;
    expect(forward.localHost, '0.0.0.0');
    expect(forward.autoStart, isFalse);
  });

  test('fills a missing User from the default username', () async {
    final plan = _plan('Host web\n  HostName web.example.com\n');
    final entry = plan.entries.single;
    expect(
      sshConfigEntryBlockReason(plan, entry, defaultUsername: ' '),
      contains('no User'),
    );
    expect(
      sshConfigEntryBlockReason(plan, entry, defaultUsername: 'alice'),
      isNull,
    );
    await expectLater(
      service.importEntries(plan, selectedIds: {entry.id}, defaultUsername: ''),
      throwsStateError,
    );
    await service.importEntries(
      plan,
      selectedIds: {entry.id},
      defaultUsername: ' alice ',
    );
    expect((await hosts.getAll()).single.username, 'alice');
  });

  test('blocks a host whose jump host lacks a username', () {
    final plan = _plan('''
Host app
  User me
  ProxyJump gateway
''');
    final app = plan.entries.singleWhere((entry) => entry.label == 'app');
    expect(
      sshConfigEntryBlockReason(plan, app, defaultUsername: ''),
      contains('Jump host gateway'),
    );
  });

  test('reuses hosts that are already saved', () async {
    final existingId = await hosts.insert(
      HostsCompanion.insert(
        label: 'My bastion',
        hostname: 'BASTION.example.com',
        username: 'jump',
      ),
    );
    final plan = _plan('''
Host bastion
  HostName bastion.example.com
  User jump
Host app
  User deploy
  ProxyJump bastion
''');
    final result = await service.importEntries(
      plan,
      selectedIds: {_idFor(plan, 'app'), _idFor(plan, 'bastion')},
      defaultUsername: '',
    );
    expect(result.reusedHostCount, 1);
    expect(result.createdHostIds.keys, {_idFor(plan, 'app')});
    final saved = await hosts.getAll();
    expect(saved, hasLength(2));
    expect(
      saved.singleWhere((host) => host.label == 'app').jumpHostId,
      existingId,
    );
  });

  test('records key-needed hosts in notes', () async {
    final plan = _plan('''
Host web
  User me
  IdentityFile ~/.ssh/id_web
''');
    await service.importEntries(
      plan,
      selectedIds: {plan.entries.single.id},
      defaultUsername: '',
    );
    expect((await hosts.getAll()).single.notes, contains('id_web'));
  });

  test('logs telemetry and diagnostics without user content', () async {
    final plan = _plan('''
Host secret-alias
  HostName secret.example.com
  User secretuser
  ProxyJump hidden-gateway
''');
    await service.importEntries(
      plan,
      selectedIds: {_idFor(plan, 'secret-alias')},
      defaultUsername: 'fallback-user',
    );
    expect(analytics.events, hasLength(2));
    for (final (name, parameters) in analytics.events) {
      expect(name, 'host_created');
      expect(parameters['method'], sshConfigHostCreationMethod);
    }
    expect(
      analytics.events.map((event) => event.$2['has_jump_host']),
      containsAll(<Object>[0, 1]),
    );
    final event = diagnostics.events.single;
    expect(event.fields['createdCount'], 2);
    for (final secret in ['secret', 'hidden', 'fallback', 'example.com']) {
      expect(event.searchableText, isNot(contains(secret)));
      for (final (_, parameters) in analytics.events) {
        expect(parameters.values.join(' '), isNot(contains(secret)));
      }
    }
  });

  test('closure adds the jump hosts a selection needs', () {
    final plan = _plan('''
Host a
Host b
  ProxyJump a
Host c
  ProxyJump b
''');
    expect(sshConfigImportClosure(plan, {_idFor(plan, 'c')}), {
      _idFor(plan, 'a'),
      _idFor(plan, 'b'),
      _idFor(plan, 'c'),
    });
    expect(sshConfigImportClosure(plan, {_idFor(plan, 'a')}), {
      _idFor(plan, 'a'),
    });
  });

  test('long labels are truncated to the column limit', () async {
    final alias = 'x' * 300;
    final plan = _plan('Host $alias\n  HostName h\n  User u\n');
    await service.importEntries(
      plan,
      selectedIds: {plan.entries.single.id},
      defaultUsername: '',
    );
    expect((await hosts.getAll()).single.label.length, 255);
  });

  test('existing rows are matched on port and jump host too', () async {
    await hosts.insert(
      HostsCompanion.insert(
        label: 'other port',
        hostname: 'web',
        username: 'me',
        port: const Value(2200),
      ),
    );
    final plan = _plan('Host web\n  User me\n');
    final result = await service.importEntries(
      plan,
      selectedIds: {plan.entries.single.id},
      defaultUsername: '',
    );
    expect(result.reusedHostCount, 0);
    expect(await hosts.getAll(), hasLength(2));
  });
}
