import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';

/// Repository for managing groups.
class GroupRepository {
  /// Creates a new [GroupRepository].
  GroupRepository(this._db);

  final AppDatabase _db;

  /// Get all groups.
  Future<List<Group>> getAll() => _orderedGroupsQuery().get();

  /// Watch all groups.
  Stream<List<Group>> watchAll() => _orderedGroupsQuery().watch();

  /// Insert a new group.
  Future<int> insert(GroupsCompanion group) async {
    final sortOrder = group.sortOrder.present
        ? group.sortOrder
        : Value(await _nextSortOrder());
    return _db.into(_db.groups).insert(group.copyWith(sortOrder: sortOrder));
  }

  SimpleSelectStatement<$GroupsTable, Group> _orderedGroupsQuery() =>
      _db.select(_db.groups)..orderBy([
        (g) => OrderingTerm.asc(g.sortOrder),
        (g) => OrderingTerm.asc(g.id),
      ]);

  Future<int> _nextSortOrder() async {
    final expression = _db.groups.sortOrder.max();
    final row = await (_db.selectOnly(
      _db.groups,
    )..addColumns([expression])).getSingleOrNull();
    return (row?.read(expression) ?? -1) + 1;
  }
}

/// Provider for [GroupRepository].
final groupRepositoryProvider = Provider<GroupRepository>(
  (ref) => GroupRepository(ref.watch(databaseProvider)),
);
