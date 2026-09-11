// ignore_for_file: public_member_api_docs

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/group_repository.dart';

void main() {
  late AppDatabase db;
  late GroupRepository repository;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = GroupRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('GroupRepository', () {
    test('getAll returns empty list initially', () async {
      final groups = await repository.getAll();
      expect(groups, isEmpty);
    });

    test('insert creates a new group', () async {
      final id = await repository.insert(
        GroupsCompanion.insert(name: 'Production'),
      );

      expect(id, greaterThan(0));

      final groups = await repository.getAll();
      expect(groups, hasLength(1));
      expect(groups.first.name, 'Production');
      expect(groups.first.sortOrder, 0);
    });

    test('insert appends groups by sort order', () async {
      await repository.insert(GroupsCompanion.insert(name: 'First'));
      await repository.insert(GroupsCompanion.insert(name: 'Second'));

      final groups = await repository.getAll();
      expect(groups.map((group) => group.sortOrder), [0, 1]);
      expect(groups.map((group) => group.name), ['First', 'Second']);
    });

    test('nested groups maintain hierarchy', () async {
      final level1 = await repository.insert(
        GroupsCompanion.insert(name: 'Level 1'),
      );
      final level2 = await repository.insert(
        GroupsCompanion.insert(name: 'Level 2', parentId: Value(level1)),
      );
      await repository.insert(
        GroupsCompanion.insert(name: 'Level 3', parentId: Value(level2)),
      );

      final roots = (await repository.getAll())
          .where((group) => group.parentId == null)
          .toList();
      expect(roots, hasLength(1));
      expect(roots.first.name, 'Level 1');

      final level1Children = (await repository.getAll())
          .where((group) => group.parentId == level1)
          .toList();
      expect(level1Children, hasLength(1));
      expect(level1Children.first.name, 'Level 2');

      final level2Children = (await repository.getAll())
          .where((group) => group.parentId == level2)
          .toList();
      expect(level2Children, hasLength(1));
      expect(level2Children.first.name, 'Level 3');
    });

    test('watchAll emits updates', () async {
      await repository.insert(GroupsCompanion.insert(name: 'New Group'));

      final stream = repository.watchAll();
      final firstValue = await stream.first;
      expect(firstValue, hasLength(1));
    });

    test('insert multiple groups', () async {
      await repository.insert(GroupsCompanion.insert(name: 'Group 1'));
      await repository.insert(GroupsCompanion.insert(name: 'Group 2'));
      await repository.insert(GroupsCompanion.insert(name: 'Group 3'));

      final groups = await repository.getAll();
      expect(groups, hasLength(3));
    });
  });
}
