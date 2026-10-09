// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:monkeyssh/domain/models/git_working_tree.dart';
import 'package:monkeyssh/domain/services/git_working_tree_service.dart';

/// Serves canned snapshots and diffs, recording what the sheet asked for.
class FakeGitWorkingTreeService extends GitWorkingTreeService {
  FakeGitWorkingTreeService({
    required this.snapshots,
    this.diffs = const {},
    this.untrackedCounts = const {},
  }) : super(
         (command, {required maxBytes, required timeout}) =>
             throw UnimplementedError(),
       );

  /// Returned in order by [loadStatus]; the last one repeats.
  final List<Object> snapshots;
  final Map<String, Object> diffs;
  final Map<String, GitLineCounts> untrackedCounts;
  final statusDirectories = <String>[];
  final diffRequests = <String>[];
  Completer<void>? untrackedGate;

  @override
  Future<GitWorkingTreeSnapshot> loadStatus(String directory) async {
    statusDirectories.add(directory);
    final index = (statusDirectories.length - 1).clamp(0, snapshots.length - 1);
    final next = snapshots[index];
    if (next is GitWorkingTreeSnapshot) {
      return next;
    }
    if (next is Exception) {
      throw next;
    }
    throw StateError('unexpected snapshot $next');
  }

  @override
  Future<Map<String, GitLineCounts>> loadUntrackedCounts(
    String repositoryRoot,
    List<String> paths,
  ) async {
    await untrackedGate?.future;
    return untrackedCounts;
  }

  @override
  Future<GitFileDiff> loadDiff(
    String repositoryRoot,
    GitChangedFile file,
  ) async {
    diffRequests.add('${file.group.name}:${file.path}');
    final diff = diffs[file.path];
    if (diff is GitFileDiff) {
      return diff;
    }
    if (diff is Exception) {
      throw diff;
    }
    throw StateError('no diff');
  }
}
