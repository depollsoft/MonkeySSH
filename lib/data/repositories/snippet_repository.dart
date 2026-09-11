import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';

/// Repository for managing snippets.
class SnippetRepository {
  /// Creates a new [SnippetRepository].
  SnippetRepository(this._db);

  final AppDatabase _db;

  /// Get all snippets.
  Future<List<Snippet>> getAll() => _orderedSnippetsQuery().get();

  /// Watch all snippets.
  Stream<List<Snippet>> watchAll() => _orderedSnippetsQuery().watch();

  /// Get a snippet by ID.
  Future<Snippet?> getById(int id) => (_db.select(
    _db.snippets,
  )..where((s) => s.id.equals(id))).getSingleOrNull();

  /// Insert a new snippet.
  Future<int> insert(SnippetsCompanion snippet) async {
    final sortOrder = snippet.sortOrder.present
        ? snippet.sortOrder
        : Value(await _nextSnippetSortOrder());
    return _db
        .into(_db.snippets)
        .insert(snippet.copyWith(sortOrder: sortOrder));
  }

  /// Reorders all snippets to match [orderedIds].
  Future<void> reorderByIds(List<int> orderedIds) async {
    if (orderedIds.isEmpty) {
      return;
    }

    await _db.transaction(() async {
      for (var index = 0; index < orderedIds.length; index += 1) {
        await (_db.update(_db.snippets)
              ..where((s) => s.id.equals(orderedIds[index])))
            .write(SnippetsCompanion(sortOrder: Value(index)));
      }
    });
  }

  /// Update an existing snippet.
  Future<bool> update(Snippet snippet) =>
      _db.update(_db.snippets).replace(snippet);

  /// Delete a snippet.
  Future<int> delete(int id) =>
      (_db.delete(_db.snippets)..where((s) => s.id.equals(id))).go();

  /// Increment usage count.
  Future<bool> incrementUsage(int id) async {
    final updated =
        await (_db.update(_db.snippets)..where((s) => s.id.equals(id))).write(
          SnippetsCompanion.custom(
            usageCount: _db.snippets.usageCount + const Constant(1),
            lastUsedAt: Variable(DateTime.now()),
          ),
        );
    return updated > 0;
  }

  // Snippet folders

  /// Get all folders.
  Future<List<SnippetFolder>> getAllFolders() => _orderedFoldersQuery().get();

  /// Watch all folders.
  Stream<List<SnippetFolder>> watchAllFolders() =>
      _orderedFoldersQuery().watch();

  /// Insert a folder.
  Future<int> insertFolder(SnippetFoldersCompanion folder) async {
    final sortOrder = folder.sortOrder.present
        ? folder.sortOrder
        : Value(await _nextFolderSortOrder());
    return _db
        .into(_db.snippetFolders)
        .insert(folder.copyWith(sortOrder: sortOrder));
  }

  /// Delete a folder, moving its snippets back to No folder.
  Future<int> deleteFolder(int id) => _db.transaction(() async {
    await (_db.update(_db.snippets)..where((s) => s.folderId.equals(id))).write(
      const SnippetsCompanion(folderId: Value<int?>(null)),
    );
    await (_db.update(_db.snippetFolders)..where((f) => f.parentId.equals(id)))
        .write(const SnippetFoldersCompanion(parentId: Value<int?>(null)));
    return (_db.delete(_db.snippetFolders)..where((f) => f.id.equals(id))).go();
  });

  SimpleSelectStatement<$SnippetsTable, Snippet> _orderedSnippetsQuery() =>
      _db.select(_db.snippets)..orderBy([
        (s) => OrderingTerm.asc(s.sortOrder),
        (s) => OrderingTerm.asc(s.id),
      ]);

  SimpleSelectStatement<$SnippetFoldersTable, SnippetFolder>
  _orderedFoldersQuery() => _db.select(_db.snippetFolders)
    ..orderBy([
      (f) => OrderingTerm.asc(f.sortOrder),
      (f) => OrderingTerm.asc(f.id),
    ]);

  Future<int> _nextSnippetSortOrder() async {
    final expression = _db.snippets.sortOrder.max();
    final row = await (_db.selectOnly(
      _db.snippets,
    )..addColumns([expression])).getSingleOrNull();
    return (row?.read(expression) ?? -1) + 1;
  }

  Future<int> _nextFolderSortOrder() async {
    final expression = _db.snippetFolders.sortOrder.max();
    final row = await (_db.selectOnly(
      _db.snippetFolders,
    )..addColumns([expression])).getSingleOrNull();
    return (row?.read(expression) ?? -1) + 1;
  }
}

/// Provider for [SnippetRepository].
final snippetRepositoryProvider = Provider<SnippetRepository>(
  (ref) => SnippetRepository(ref.watch(databaseProvider)),
);
