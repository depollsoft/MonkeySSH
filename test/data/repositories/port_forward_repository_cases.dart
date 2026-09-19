// ignore_for_file: public_member_api_docs

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/port_forward_repository.dart';

void registerPortForwardRepositoryTests() {
  group('port_forward_repository', () {
    late AppDatabase db;
    late PortForwardRepository repository;
    late int testHostId;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repository = PortForwardRepository(db);

      // Create a test host for port forwards
      testHostId = await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Test Server',
              hostname: '192.168.1.1',
              username: 'admin',
            ),
          );
    });

    tearDown(() async {
      await db.close();
    });

    group('PortForwardRepository', () {
      test('getAll returns empty list initially', () async {
        final forwards = await repository.getAll();
        expect(forwards, isEmpty);
      });

      test('insert creates a new port forward', () async {
        final id = await repository.insert(
          PortForwardsCompanion.insert(
            name: 'MySQL Tunnel',
            hostId: testHostId,
            forwardType: 'local',
            localPort: 3307,
            remoteHost: 'localhost',
            remotePort: 3306,
          ),
        );

        expect(id, greaterThan(0));

        final forwards = await repository.getAll();
        expect(forwards, hasLength(1));
        expect(forwards.first.name, 'MySQL Tunnel');
        expect(forwards.first.localPort, 3307);
        expect(forwards.first.remotePort, 3306);
      });

      test('getById returns port forward when exists', () async {
        final id = await repository.insert(
          PortForwardsCompanion.insert(
            name: 'Redis Tunnel',
            hostId: testHostId,
            forwardType: 'local',
            localPort: 6380,
            remoteHost: 'localhost',
            remotePort: 6379,
          ),
        );

        final forward = await repository.getById(id);

        expect(forward, isNotNull);
        expect(forward!.id, id);
        expect(forward.name, 'Redis Tunnel');
      });

      test('getById returns null when not exists', () async {
        final forward = await repository.getById(999);
        expect(forward, isNull);
      });

      test('update modifies existing port forward', () async {
        final id = await repository.insert(
          PortForwardsCompanion.insert(
            name: 'Original Tunnel',
            hostId: testHostId,
            forwardType: 'local',
            localPort: 8080,
            remoteHost: 'localhost',
            remotePort: 80,
          ),
        );

        final forward = await repository.getById(id);
        final success = await repository.update(
          forward!.copyWith(name: 'Updated Tunnel', localPort: 9090),
        );

        expect(success, isTrue);

        final updated = await repository.getById(id);
        expect(updated!.name, 'Updated Tunnel');
        expect(updated.localPort, 9090);
      });

      test('delete removes port forward', () async {
        final id = await repository.insert(
          PortForwardsCompanion.insert(
            name: 'To Delete',
            hostId: testHostId,
            forwardType: 'local',
            localPort: 8080,
            remoteHost: 'localhost',
            remotePort: 80,
          ),
        );

        final deleted = await repository.delete(id);
        expect(deleted, 1);

        final forward = await repository.getById(id);
        expect(forward, isNull);
      });

      test('delete returns 0 when port forward not exists', () async {
        final deleted = await repository.delete(999);
        expect(deleted, 0);
      });

      test('getByHostId returns forwards for specific host', () async {
        await repository.insert(
          PortForwardsCompanion.insert(
            name: 'Tunnel 1',
            hostId: testHostId,
            forwardType: 'local',
            localPort: 8080,
            remoteHost: 'localhost',
            remotePort: 80,
          ),
        );
        await repository.insert(
          PortForwardsCompanion.insert(
            name: 'Tunnel 2',
            hostId: testHostId,
            forwardType: 'local',
            localPort: 8443,
            remoteHost: 'localhost',
            remotePort: 443,
          ),
        );

        final forwards = await repository.getByHostId(testHostId);
        expect(forwards, hasLength(2));
      });

      test('getByHostId returns empty for non-existent host', () async {
        final forwards = await repository.getByHostId(999);
        expect(forwards, isEmpty);
      });

      test('local forward type is stored correctly', () async {
        final id = await repository.insert(
          PortForwardsCompanion.insert(
            name: 'Local Forward',
            hostId: testHostId,
            forwardType: 'local',
            localPort: 8080,
            remoteHost: 'remote.server.com',
            remotePort: 80,
          ),
        );

        final forward = await repository.getById(id);
        expect(forward!.forwardType, 'local');
      });

      test('remote forward type is stored correctly', () async {
        final id = await repository.insert(
          PortForwardsCompanion.insert(
            name: 'Remote Forward',
            hostId: testHostId,
            forwardType: 'remote',
            localPort: 3000,
            remoteHost: '0.0.0.0',
            remotePort: 3000,
          ),
        );

        final forward = await repository.getById(id);
        expect(forward!.forwardType, 'remote');
      });

      test('autoStart defaults to false', () async {
        final id = await repository.insert(
          PortForwardsCompanion.insert(
            name: 'Test Forward',
            hostId: testHostId,
            forwardType: 'local',
            localPort: 8080,
            remoteHost: 'localhost',
            remotePort: 80,
          ),
        );

        final forward = await repository.getById(id);
        expect(forward!.autoStart, isFalse);
      });

      test('autoStart can be set to true', () async {
        final id = await repository.insert(
          PortForwardsCompanion.insert(
            name: 'Auto Start Forward',
            hostId: testHostId,
            forwardType: 'local',
            localPort: 8080,
            remoteHost: 'localhost',
            remotePort: 80,
            autoStart: const Value(true),
          ),
        );

        final forward = await repository.getById(id);
        expect(forward!.autoStart, isTrue);
      });

      test('watchAll emits updates', () async {
        await repository.insert(
          PortForwardsCompanion.insert(
            name: 'Watched Forward',
            hostId: testHostId,
            forwardType: 'local',
            localPort: 8080,
            remoteHost: 'localhost',
            remotePort: 80,
          ),
        );

        final stream = repository.watchAll();
        final firstValue = await stream.first;
        expect(firstValue, hasLength(1));
      });

      test('watchByHostId emits updates', () async {
        await repository.insert(
          PortForwardsCompanion.insert(
            name: 'Host Forward',
            hostId: testHostId,
            forwardType: 'local',
            localPort: 8080,
            remoteHost: 'localhost',
            remotePort: 80,
          ),
        );

        final stream = repository.watchByHostId(testHostId);
        final firstValue = await stream.first;
        expect(firstValue, hasLength(1));
      });

      test('insert multiple port forwards for same host', () async {
        for (var i = 0; i < 5; i++) {
          await repository.insert(
            PortForwardsCompanion.insert(
              name: 'Tunnel $i',
              hostId: testHostId,
              forwardType: 'local',
              localPort: 8080 + i,
              remoteHost: 'localhost',
              remotePort: 80 + i,
            ),
          );
        }

        final forwards = await repository.getByHostId(testHostId);
        expect(forwards, hasLength(5));
      });

      test('update returns false when port forward not exists', () async {
        final fakeForward = PortForward(
          id: 999,
          name: 'Fake Forward',
          hostId: testHostId,
          forwardType: 'local',
          localHost: '127.0.0.1',
          localPort: 8080,
          remoteHost: 'localhost',
          remotePort: 80,
          autoStart: false,
          createdAt: DateTime.now(),
        );

        final success = await repository.update(fakeForward);
        expect(success, isFalse);
      });
    });
  });
}
