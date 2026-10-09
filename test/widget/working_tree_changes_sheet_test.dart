// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/git_working_tree.dart';
import 'package:monkeyssh/domain/services/git_working_tree_service.dart';
import 'package:monkeyssh/presentation/widgets/acp_diff.dart';
import 'package:monkeyssh/presentation/widgets/working_tree_changes_sheet.dart';

import '../support/fake_git_working_tree_service.dart';

final refreshedAt = DateTime(2026, 10, 9, 14, 3, 7);

GitWorkingTreeSnapshot readySnapshot({
  List<GitChangedFile> files = const [],
  bool truncated = false,
  DateTime? at,
}) => GitWorkingTreeSnapshot(
  state: GitWorkingTreeState.ready,
  refreshedAt: at ?? refreshedAt,
  files: files,
  repositoryRoot: '/home/dev/monkeyssh',
  branch: 'feat/changes',
  truncated: truncated,
);

const modifiedFile = GitChangedFile(
  path: 'lib/main.dart',
  group: GitChangeGroup.unstaged,
  kind: GitChangeKind.modified,
  counts: GitLineCounts(added: 12, removed: 3),
);

const stagedRename = GitChangedFile(
  path: 'docs/guide.md',
  originalPath: 'docs/old guide.md',
  group: GitChangeGroup.staged,
  kind: GitChangeKind.renamed,
  counts: GitLineCounts(added: 0, removed: 0),
);

const untrackedFile = GitChangedFile(
  path: 'notes.txt',
  group: GitChangeGroup.untracked,
  kind: GitChangeKind.untracked,
);

const binaryFile = GitChangedFile(
  path: 'assets/logo.png',
  group: GitChangeGroup.unstaged,
  kind: GitChangeKind.modified,
  counts: GitLineCounts.binary(),
);

const conflictFile = GitChangedFile(
  path: 'pubspec.lock',
  group: GitChangeGroup.conflicted,
  kind: GitChangeKind.conflicted,
  statusCode: 'UU',
);

GitFileDiff twoHunkDiff({bool truncated = false}) => GitFileDiff(
  headerLines: const [
    'diff --git a/lib/main.dart b/lib/main.dart',
    'index 1..2 100644',
    '--- a/lib/main.dart',
    '+++ b/lib/main.dart',
  ],
  hunks: [
    GitDiffHunk(
      header: '@@ -1,3 +1,4 @@ void main()',
      lines: const [' a', '-b', '+B', ' c', '+d'],
      oldStart: 1,
      oldCount: 3,
      newStart: 1,
      newCount: 4,
    ),
    GitDiffHunk(
      header: '@@ -40,2 +41,3 @@',
      lines: const [' x', '+y', ' z'],
      oldStart: 40,
      oldCount: 2,
      newStart: 41,
      newCount: 3,
    ),
  ],
  binary: false,
  truncated: truncated,
);

/// Hosts the sheet behind a button so tests can read the popped prompt.
class _Host extends StatefulWidget {
  const _Host({
    required this.service,
    required this.directory,
    this.unavailableMessage,
    this.canAskAgent = true,
  });

  final GitWorkingTreeService? service;
  final String? directory;
  final String? unavailableMessage;
  final bool canAskAgent;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  String? prompt;
  bool closed = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: () async {
              final result = await showWorkingTreeChangesSheet(
                context: context,
                service: widget.service,
                directory: widget.directory,
                unavailableMessage: widget.unavailableMessage,
                canAskAgent: widget.canAskAgent,
              );
              setState(() {
                prompt = result;
                closed = true;
              });
            },
            child: const Text('open'),
          ),
          if (closed) Text('prompt: ${prompt ?? 'none'}'),
        ],
      ),
    ),
  );
}

Future<_HostState> _pumpSheet(
  WidgetTester tester, {
  required GitWorkingTreeService? service,
  String? directory = '/home/dev/monkeyssh/lib',
  String? unavailableMessage,
  bool canAskAgent = true,
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size, disableAnimations: true),
        child: _Host(
          service: service,
          directory: directory,
          unavailableMessage: unavailableMessage,
          canAskAgent: canAskAgent,
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return tester.state<_HostState>(find.byType(_Host));
}

void main() {
  test('formats the refresh time in 12- and 24-hour clocks', () {
    expect(
      formatWorkingTreeRefreshTime(refreshedAt, use24HourFormat: true),
      '14:03:07',
    );
    expect(
      formatWorkingTreeRefreshTime(refreshedAt, use24HourFormat: false),
      '2:03:07 PM',
    );
    expect(
      formatWorkingTreeRefreshTime(
        DateTime(2026, 1, 1, 0, 5, 9),
        use24HourFormat: false,
      ),
      '12:05:09 AM',
    );
  });

  testWidgets('lists changes by group with counts and refresh time', (
    tester,
  ) async {
    final service = FakeGitWorkingTreeService(
      snapshots: [
        readySnapshot(
          files: [
            conflictFile,
            stagedRename,
            binaryFile,
            modifiedFile,
            untrackedFile,
          ],
        ),
      ],
      untrackedCounts: {'notes.txt': const GitLineCounts(added: 7, removed: 0)},
    );
    await _pumpSheet(tester, service: service);

    expect(service.statusDirectories, ['/home/dev/monkeyssh/lib']);
    expect(find.text('Working tree changes'), findsOneWidget);
    expect(find.text('monkeyssh · feat/changes'), findsOneWidget);
    expect(find.text('refreshed 2:03:07 PM'), findsOneWidget);
    expect(find.text('conflicts · 1'), findsOneWidget);
    expect(find.text('staged · 1'), findsOneWidget);
    expect(find.text('unstaged · 2'), findsOneWidget);
    expect(find.text('untracked · 1'), findsOneWidget);
    expect(find.text('guide.md'), findsOneWidget);
    expect(find.text('from docs/old guide.md'), findsOneWidget);
    expect(find.text('bin'), findsOneWidget);
    expect(find.text('+12 −3'), findsOneWidget);
    // Untracked counts arrive after the list.
    expect(find.text('+7 −0'), findsOneWidget);
    expect(
      find.bySemanticsLabel('lib/main.dart, modified, 12 added, 3 removed'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('pubspec.lock, conflict UU'), findsOneWidget);
    // Never claims authorship.
    expect(find.textContaining('agent changed'), findsNothing);
  });

  testWidgets('opens a file into hunks and asks the agent about one', (
    tester,
  ) async {
    final service = FakeGitWorkingTreeService(
      snapshots: [
        readySnapshot(files: [modifiedFile]),
      ],
      diffs: {'lib/main.dart': twoHunkDiff()},
    );
    final host = await _pumpSheet(tester, service: service);

    await tester.tap(find.text('main.dart'));
    await tester.pumpAndSettle();

    expect(service.diffRequests, ['unstaged:lib/main.dart']);
    expect(find.text('unstaged · lib'), findsOneWidget);
    expect(find.byType(AcpDiffView), findsNWidgets(2));
    expect(find.text('@@ -1,3 +1,4 @@ void main()'), findsOneWidget);
    expect(find.text('+B'), findsOneWidget);
    // Lines 5-40 of the new file are collapsed between the hunks.
    expect(find.text('36 unchanged lines'), findsOneWidget);
    // The redundant diff/index/---/+++ lines are not repeated.
    expect(find.text('index 1..2 100644'), findsNothing);

    await tester.tap(find.text('Ask agent').first);
    await tester.pumpAndSettle();

    expect(find.byType(WorkingTreeChangesSheet), findsNothing);
    expect(
      host.prompt,
      'About this hunk in lib/main.dart (an unstaged change in the working '
      'tree):\n\n```diff\n@@ -1,3 +1,4 @@ void main()\n a\n-b\n+B\n c\n+d\n'
      '```\n\n',
    );
  });

  testWidgets('back returns from a diff to the file list', (tester) async {
    final service = FakeGitWorkingTreeService(
      snapshots: [
        readySnapshot(files: [modifiedFile]),
      ],
      diffs: {'lib/main.dart': twoHunkDiff(truncated: true)},
    );
    await _pumpSheet(tester, service: service);
    await tester.tap(find.text('main.dart'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Diff cut off at 512 KB'), findsOneWidget);

    await tester.tap(find.byTooltip('Back to changed files'));
    await tester.pumpAndSettle();
    expect(find.text('Working tree changes'), findsOneWidget);
    expect(find.text('unstaged · 1'), findsOneWidget);

    // System back also leaves the diff before closing the sheet.
    await tester.tap(find.text('main.dart'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('unstaged · 1'), findsOneWidget);
  });

  testWidgets('hides Ask agent when there is nowhere to send it', (
    tester,
  ) async {
    final service = FakeGitWorkingTreeService(
      snapshots: [
        readySnapshot(files: [modifiedFile]),
      ],
      diffs: {'lib/main.dart': twoHunkDiff()},
    );
    await _pumpSheet(tester, service: service, canAskAgent: false);
    await tester.tap(find.text('main.dart'));
    await tester.pumpAndSettle();
    expect(find.byType(AcpDiffView), findsNWidgets(2));
    expect(find.text('Ask agent'), findsNothing);
  });

  testWidgets('binary and rename-only files explain the missing diff', (
    tester,
  ) async {
    final service = FakeGitWorkingTreeService(
      snapshots: [
        readySnapshot(files: [stagedRename, binaryFile]),
      ],
      diffs: {
        'assets/logo.png': GitFileDiff(
          headerLines: const ['Binary files a/x and b/x differ'],
          hunks: const [],
          binary: true,
          truncated: false,
        ),
        'docs/guide.md': GitFileDiff(
          headerLines: const [
            'diff --git a/docs/old guide.md b/docs/guide.md',
            'similarity index 100%',
            'rename from docs/old guide.md',
            'rename to docs/guide.md',
          ],
          hunks: const [],
          binary: false,
          truncated: false,
        ),
      },
    );
    await _pumpSheet(tester, service: service);

    await tester.tap(find.text('logo.png'));
    await tester.pumpAndSettle();
    expect(find.text('binary file'), findsOneWidget);

    await tester.tap(find.byTooltip('Back to changed files'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('guide.md'));
    await tester.pumpAndSettle();
    expect(find.text('rename from docs/old guide.md'), findsOneWidget);
    expect(
      find.text('No text changes beyond the lines above.'),
      findsOneWidget,
    );
  });

  for (final (state, title) in [
    (GitWorkingTreeState.notRepository, 'not a git repository'),
    (GitWorkingTreeState.missingDirectory, 'directory not found'),
    (GitWorkingTreeState.gitUnavailable, 'git not found'),
    (GitWorkingTreeState.unsafeRepository, 'repository not trusted'),
    (GitWorkingTreeState.failed, 'git status failed'),
  ]) {
    testWidgets('shows a clear state for $state', (tester) async {
      final service = FakeGitWorkingTreeService(
        snapshots: [
          GitWorkingTreeSnapshot(state: state, refreshedAt: refreshedAt),
        ],
      );
      await _pumpSheet(tester, service: service);
      expect(find.text(title), findsOneWidget);
    });
  }

  testWidgets('a clean tree says so', (tester) async {
    final service = FakeGitWorkingTreeService(snapshots: [readySnapshot()]);
    await _pumpSheet(tester, service: service);
    expect(find.text('nothing to commit'), findsOneWidget);
  });

  testWidgets('warns when the list was cut off', (tester) async {
    final service = FakeGitWorkingTreeService(
      snapshots: [
        readySnapshot(files: [modifiedFile], truncated: true),
      ],
    );
    await _pumpSheet(tester, service: service);
    expect(find.textContaining('Too many changes'), findsOneWidget);
  });

  testWidgets('a failed read offers retry, and refresh rereads', (
    tester,
  ) async {
    final service = FakeGitWorkingTreeService(
      snapshots: [
        const GitWorkingTreeTimeoutException(),
        readySnapshot(files: [modifiedFile]),
        readySnapshot(
          files: [modifiedFile, untrackedFile],
          at: DateTime(2026, 10, 9, 14, 5),
        ),
      ],
    );
    await _pumpSheet(tester, service: service);
    expect(find.text("couldn't read git status"), findsOneWidget);
    expect(find.textContaining('took too long'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('unstaged · 1'), findsOneWidget);

    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('untracked · 1'), findsOneWidget);
    expect(find.text('refreshed 2:05:00 PM'), findsOneWidget);
    expect(service.statusDirectories, hasLength(3));
  });

  testWidgets('a failed refresh keeps the last result and says so', (
    tester,
  ) async {
    final service = FakeGitWorkingTreeService(
      snapshots: [
        readySnapshot(files: [modifiedFile]),
        const GitWorkingTreeTimeoutException(),
      ],
      diffs: {'lib/main.dart': twoHunkDiff()},
    );
    await _pumpSheet(tester, service: service);

    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('unstaged · 1'), findsOneWidget);
    expect(find.text('Refresh failed'), findsOneWidget);
    expect(
      find.textContaining('Showing results from 2:03:07 PM'),
      findsOneWidget,
    );

    // The warning follows the user into a file's diff.
    await tester.tap(find.text('main.dart'));
    await tester.pumpAndSettle();
    expect(find.text('Refresh failed'), findsOneWidget);
    expect(find.byType(AcpDiffView), findsNWidgets(2));
  });

  testWidgets('a failed refresh of a clean tree does not claim it is clean', (
    tester,
  ) async {
    final service = FakeGitWorkingTreeService(
      snapshots: [readySnapshot(), const GitWorkingTreeTimeoutException()],
    );
    await _pumpSheet(tester, service: service);
    expect(find.text('nothing to commit'), findsOneWidget);

    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('Refresh failed'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pumpAndSettle();
    expect(service.statusDirectories, hasLength(3));
  });

  testWidgets('keeps leading and trailing spaces in the directory', (
    tester,
  ) async {
    final service = FakeGitWorkingTreeService(snapshots: [readySnapshot()]);
    await _pumpSheet(tester, service: service, directory: ' /srv/project ');
    expect(service.statusDirectories, [' /srv/project ']);
  });

  testWidgets('an untracked directory explains why it has no diff', (
    tester,
  ) async {
    final service = FakeGitWorkingTreeService(
      snapshots: [
        readySnapshot(
          files: const [
            GitChangedFile(
              path: 'vendor/plugin/',
              group: GitChangeGroup.untracked,
              kind: GitChangeKind.untracked,
            ),
          ],
        ),
      ],
    );
    await _pumpSheet(tester, service: service);
    await tester.tap(find.text('plugin'));
    await tester.pumpAndSettle();
    expect(find.text('untracked directory'), findsOneWidget);
    expect(service.diffRequests, isEmpty);
  });

  testWidgets('without a directory or connection it explains why', (
    tester,
  ) async {
    final service = FakeGitWorkingTreeService(snapshots: [readySnapshot()]);
    await _pumpSheet(tester, service: service, directory: null);
    expect(find.text('no working directory'), findsOneWidget);
    expect(service.statusDirectories, isEmpty);
    expect(find.byTooltip('Refresh'), findsNothing);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('prompt: none'), findsOneWidget);

    await _pumpSheet(
      tester,
      service: null,
      unavailableMessage: 'Connect to the host to read its working tree.',
    );
    expect(find.text('changes unavailable'), findsOneWidget);
    expect(
      find.text('Connect to the host to read its working tree.'),
      findsOneWidget,
    );
  });

  testWidgets('fits a small phone in light and dark themes', (tester) async {
    for (final theme in [ThemeData.light(), ThemeData.dark()]) {
      final service = FakeGitWorkingTreeService(
        snapshots: [
          readySnapshot(
            files: [
              const GitChangedFile(
                path:
                    'packages/a/very/deeply/nested/directory/with_a_long_'
                    'file_name_that_needs_ellipsis.dart',
                group: GitChangeGroup.unstaged,
                kind: GitChangeKind.modified,
                counts: GitLineCounts(added: 12345, removed: 6789),
              ),
            ],
          ),
        ],
        diffs: {
          'packages/a/very/deeply/nested/directory/with_a_long_file_name_'
                  'that_needs_ellipsis.dart':
              twoHunkDiff(),
        },
      );
      tester.view.physicalSize = const Size(320, 568) * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: _Host(service: service, directory: '/srv'),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(InkWell).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Ask agent'), findsNWidgets(2));
      final askSize = tester.getSize(
        find.ancestor(
          of: find.text('Ask agent').first,
          matching: find.byType(TextButton),
        ),
      );
      expect(askSize.height, greaterThanOrEqualTo(44));
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
