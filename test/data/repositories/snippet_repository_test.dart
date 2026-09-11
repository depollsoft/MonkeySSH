// ignore_for_file: public_member_api_docs

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/snippet_repository.dart';

void main() {
  late AppDatabase db;
  late SnippetRepository repository;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = SnippetRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('SnippetRepository - Snippets', () {
    test('getAll returns empty list initially', () async {
      final snippets = await repository.getAll();
      expect(snippets, isEmpty);
    });

    test('insert creates a new snippet', () async {
      final id = await repository.insert(
        SnippetsCompanion.insert(name: 'List Files', command: 'ls -la'),
      );

      expect(id, greaterThan(0));

      final snippets = await repository.getAll();
      expect(snippets, hasLength(1));
      expect(snippets.first.name, 'List Files');
      expect(snippets.first.command, 'ls -la');
      expect(snippets.first.usageCount, 0);
      expect(snippets.first.sortOrder, 0);
    });

    test('insert appends snippets by sort order', () async {
      await repository.insert(
        SnippetsCompanion.insert(name: 'First', command: 'echo first'),
      );
      await repository.insert(
        SnippetsCompanion.insert(name: 'Second', command: 'echo second'),
      );

      final snippets = await repository.getAll();
      expect(snippets.map((snippet) => snippet.sortOrder), [0, 1]);
      expect(snippets.map((snippet) => snippet.name), ['First', 'Second']);
    });

    test('reorderByIds persists snippet order', () async {
      final firstId = await repository.insert(
        SnippetsCompanion.insert(name: 'First', command: 'echo first'),
      );
      final secondId = await repository.insert(
        SnippetsCompanion.insert(name: 'Second', command: 'echo second'),
      );
      final thirdId = await repository.insert(
        SnippetsCompanion.insert(name: 'Third', command: 'echo third'),
      );

      await repository.reorderByIds([thirdId, firstId, secondId]);

      final snippets = await repository.getAll();
      expect(snippets.map((snippet) => snippet.name), [
        'Third',
        'First',
        'Second',
      ]);
      expect(snippets.map((snippet) => snippet.sortOrder), [0, 1, 2]);
    });

    test('getById returns snippet when exists', () async {
      final id = await repository.insert(
        SnippetsCompanion.insert(name: 'Disk Usage', command: 'df -h'),
      );

      final snippet = await repository.getById(id);

      expect(snippet, isNotNull);
      expect(snippet!.id, id);
      expect(snippet.name, 'Disk Usage');
    });

    test('getById returns null when not exists', () async {
      final snippet = await repository.getById(999);
      expect(snippet, isNull);
    });

    test('update modifies existing snippet', () async {
      final id = await repository.insert(
        SnippetsCompanion.insert(name: 'Original', command: 'ls'),
      );

      final snippet = await repository.getById(id);
      final success = await repository.update(
        snippet!.copyWith(name: 'Updated', command: 'ls -la'),
      );

      expect(success, isTrue);

      final updated = await repository.getById(id);
      expect(updated!.name, 'Updated');
      expect(updated.command, 'ls -la');
    });

    test('delete removes snippet', () async {
      final id = await repository.insert(
        SnippetsCompanion.insert(name: 'To Delete', command: 'rm -rf /'),
      );

      final deleted = await repository.delete(id);
      expect(deleted, 1);

      final snippet = await repository.getById(id);
      expect(snippet, isNull);
    });

    test('delete returns 0 when snippet not exists', () async {
      final deleted = await repository.delete(999);
      expect(deleted, 0);
    });

    test('incrementUsage increases usage count', () async {
      final id = await repository.insert(
        SnippetsCompanion.insert(name: 'Test Snippet', command: 'echo hello'),
      );

      var snippet = await repository.getById(id);
      expect(snippet!.usageCount, 0);
      expect(snippet.lastUsedAt, isNull);

      await repository.incrementUsage(id);

      snippet = await repository.getById(id);
      expect(snippet!.usageCount, 1);
      expect(snippet.lastUsedAt, isNotNull);

      await repository.incrementUsage(id);

      snippet = await repository.getById(id);
      expect(snippet!.usageCount, 2);
    });

    test('concurrent usage increments each take effect', () async {
      final id = await repository.insert(
        SnippetsCompanion.insert(name: 'List Files', command: 'ls'),
      );
      expect(
        await Future.wait(
          List.generate(10, (_) => repository.incrementUsage(id)),
        ),
        everyElement(isTrue),
      );
      final snippet = (await repository.getById(id))!;
      expect(snippet.usageCount, 10);
      expect(snippet.lastUsedAt, isNotNull);
      expect(snippet.name, 'List Files');
      expect(snippet.command, 'ls');
    });

    test('incrementUsage returns false when snippet not exists', () async {
      final result = await repository.incrementUsage(999);
      expect(result, isFalse);
    });

    test('watchAll emits updates', () async {
      await repository.insert(
        SnippetsCompanion.insert(name: 'New Snippet', command: 'test'),
      );

      final stream = repository.watchAll();
      final firstValue = await stream.first;
      expect(firstValue, hasLength(1));
    });
  });

  group('SnippetRepository - Folders', () {
    test('getAllFolders returns empty list initially', () async {
      final folders = await repository.getAllFolders();
      expect(folders, isEmpty);
    });

    test('insertFolder creates a new folder', () async {
      final id = await repository.insertFolder(
        SnippetFoldersCompanion.insert(name: 'My Folder'),
      );

      expect(id, greaterThan(0));

      final folders = await repository.getAllFolders();
      expect(folders, hasLength(1));
      expect(folders.first.name, 'My Folder');
      expect(folders.first.sortOrder, 0);
    });

    test('insertFolder appends folders by sort order', () async {
      await repository.insertFolder(
        SnippetFoldersCompanion.insert(name: 'First Folder'),
      );
      await repository.insertFolder(
        SnippetFoldersCompanion.insert(name: 'Second Folder'),
      );

      final folders = await repository.getAllFolders();
      expect(folders.map((folder) => folder.sortOrder), [0, 1]);
      expect(folders.map((folder) => folder.name), [
        'First Folder',
        'Second Folder',
      ]);
    });

    test('deleteFolder removes folder', () async {
      final id = await repository.insertFolder(
        SnippetFoldersCompanion.insert(name: 'To Delete'),
      );

      final deleted = await repository.deleteFolder(id);
      expect(deleted, 1);

      final folders = await repository.getAllFolders();
      expect(folders, isEmpty);
    });

    test('deleteFolder moves snippets to no folder', () async {
      final folderId = await repository.insertFolder(
        SnippetFoldersCompanion.insert(name: 'Deploy'),
      );
      await repository.insert(
        SnippetsCompanion.insert(
          name: 'Restart API',
          command: 'systemctl restart api',
          folderId: Value(folderId),
        ),
      );

      final deleted = await repository.deleteFolder(folderId);
      expect(deleted, 1);

      final snippets = await repository.getAll();
      expect(snippets.single.folderId, isNull);
      expect(
        (await repository.getAll())
            .where((snippet) => snippet.folderId == null)
            .toList(),
        hasLength(1),
      );
    });

    test('deleteFolder clears child folder parents', () async {
      final parentId = await repository.insertFolder(
        SnippetFoldersCompanion.insert(name: 'Parent'),
      );
      await repository.insertFolder(
        SnippetFoldersCompanion.insert(
          name: 'Child',
          parentId: Value(parentId),
        ),
      );

      final deleted = await repository.deleteFolder(parentId);
      expect(deleted, 1);

      final child = (await repository.getAllFolders()).single;
      expect(child.parentId, isNull);
    });

    test('deleteFolder returns 0 when folder not exists', () async {
      final deleted = await repository.deleteFolder(999);
      expect(deleted, 0);
    });

    test('watchAllFolders emits updates', () async {
      await repository.insertFolder(
        SnippetFoldersCompanion.insert(name: 'New Folder'),
      );

      final stream = repository.watchAllFolders();
      final firstValue = await stream.first;
      expect(firstValue, hasLength(1));
    });

    test('nested folders work with parentId', () async {
      final parentId = await repository.insertFolder(
        SnippetFoldersCompanion.insert(name: 'Parent'),
      );
      await repository.insertFolder(
        SnippetFoldersCompanion.insert(
          name: 'Child',
          parentId: Value(parentId),
        ),
      );

      final folders = await repository.getAllFolders();
      expect(folders, hasLength(2));

      final child = folders.firstWhere((f) => f.name == 'Child');
      expect(child.parentId, parentId);
    });
  });
}
