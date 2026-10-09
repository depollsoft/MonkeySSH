import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../domain/models/git_working_tree.dart';
import '../../domain/services/diagnostics_log_service.dart';
import '../../domain/services/git_working_tree_service.dart';
import '../../domain/services/ssh_service.dart';
import '../models/acp_timeline.dart';
import 'acp_diff.dart';
import 'brand_empty_state.dart';
import 'brand_error_state.dart';
import 'cursor_block.dart';
import 'terminal_overlay_focus.dart';

/// Opens the read-only "Working tree changes" sheet for [directory].
///
/// [service] is null when the window has no connection that can run git;
/// [unavailableMessage] then explains why. When [canAskAgent] is true each
/// hunk offers "Ask agent", and the future completes with the quoted prompt
/// for the caller to insert. It completes with null otherwise.
Future<String?> showWorkingTreeChangesSheet({
  required BuildContext context,
  required GitWorkingTreeService? service,
  required String? directory,
  String? unavailableMessage,
  bool canAskAgent = false,
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  requestFocus: terminalOverlayRouteRequestFocus(context),
  builder: (context) => DraggableScrollableSheet(
    initialChildSize: 0.75,
    minChildSize: 0.4,
    maxChildSize: 0.95,
    expand: false,
    builder: (context, scrollController) => WorkingTreeChangesSheet(
      service: service,
      directory: directory,
      unavailableMessage: unavailableMessage,
      canAskAgent: canAskAgent,
      scrollController: scrollController,
    ),
  ),
);

/// Why the working tree cannot be read through [session], or null when it
/// can. [session] is null when the window has no live connection.
String? workingTreeChangesUnavailableReason(SshSession? session) {
  if (session == null) {
    return 'Connect to the host to read its working tree.';
  }
  if (session.remoteIsWindows) {
    return 'Working tree changes need a POSIX shell on the host, so Windows '
        'hosts are not supported yet.';
  }
  return null;
}

/// Formats [time] as a clock time with seconds, such as `14:03:12` or
/// `2:03:12 PM`.
String formatWorkingTreeRefreshTime(
  DateTime time, {
  required bool use24HourFormat,
}) {
  String two(int value) => value.toString().padLeft(2, '0');
  final minutes = two(time.minute);
  final seconds = two(time.second);
  if (use24HourFormat) {
    return '${two(time.hour)}:$minutes:$seconds';
  }
  final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
  final period = time.hour < 12 ? 'AM' : 'PM';
  return '$hour:$minutes:$seconds $period';
}

/// The contents of the "Working tree changes" sheet: a grouped list of
/// changed files that opens into per-file, per-hunk diffs.
///
/// This shows what git sees in the directory, not who made the change, so it
/// never claims authorship.
class WorkingTreeChangesSheet extends StatefulWidget {
  /// Creates the sheet contents.
  const WorkingTreeChangesSheet({
    required this.service,
    required this.directory,
    required this.scrollController,
    super.key,
    this.unavailableMessage,
    this.canAskAgent = false,
  });

  /// Reads git on the host, or null when no connection can.
  final GitWorkingTreeService? service;

  /// The window's working directory on the host, when known.
  final String? directory;

  /// Why changes cannot be read here, shown instead of loading.
  final String? unavailableMessage;

  /// Whether hunks offer "Ask agent".
  final bool canAskAgent;

  /// The sheet's scroll controller, shared by the file list and the diff.
  final ScrollController scrollController;

  @override
  State<WorkingTreeChangesSheet> createState() =>
      _WorkingTreeChangesSheetState();
}

class _WorkingTreeChangesSheetState extends State<WorkingTreeChangesSheet> {
  GitWorkingTreeSnapshot? _snapshot;
  bool _loading = false;
  String? _loadError;
  Map<String, GitLineCounts> _untrackedCounts = const {};
  int _generation = 0;

  GitChangedFile? _selected;
  GitFileDiff? _diff;
  bool _diffLoading = false;
  String? _diffError;
  int _diffGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  bool get _canLoad =>
      widget.unavailableMessage == null &&
      widget.service != null &&
      (widget.directory?.trim().isNotEmpty ?? false);

  Future<void> _refresh() async {
    if (!_canLoad) {
      return;
    }
    final service = widget.service!;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final snapshot = await service.loadStatus(widget.directory!.trim());
      if (!mounted || generation != _generation) {
        return;
      }
      final selected = _selected;
      final stillSelected = selected == null
          ? null
          : snapshot.files.firstWhereOrNull((file) => file.id == selected.id);
      setState(() {
        _snapshot = snapshot;
        _loading = false;
        _untrackedCounts = const {};
        if (selected != null && stillSelected == null) {
          _selected = null;
          _diff = null;
          _diffError = null;
        } else if (stillSelected != null) {
          _selected = stillSelected;
        }
      });
      if (stillSelected != null) {
        unawaited(_loadDiff(stillSelected));
      }
      unawaited(_loadUntrackedCounts(snapshot, generation));
    } on Object catch (error) {
      if (!mounted || generation != _generation) {
        return;
      }
      DiagnosticsLogService.instance.warning(
        'git_changes',
        'status_failed',
        fields: {'errorType': error.runtimeType},
      );
      setState(() {
        _loading = false;
        _loadError = error is GitWorkingTreeTimeoutException
            ? 'The host took too long to answer. Check the connection and '
                  'try again.'
            : 'The connection could not run git. Check the connection and '
                  'try again.';
      });
    }
  }

  Future<void> _loadUntrackedCounts(
    GitWorkingTreeSnapshot snapshot,
    int generation,
  ) async {
    final root = snapshot.repositoryRoot;
    final untracked = snapshot.filesIn(GitChangeGroup.untracked);
    if (root == null || untracked.isEmpty) {
      return;
    }
    try {
      final counts = await widget.service!.loadUntrackedCounts(root, [
        for (final file in untracked) file.path,
      ]);
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() => _untrackedCounts = counts);
    } on Object catch (error) {
      DiagnosticsLogService.instance.debug(
        'git_changes',
        'untracked_counts_failed',
        fields: {'errorType': error.runtimeType},
      );
    }
  }

  Future<void> _loadDiff(GitChangedFile file) async {
    final root = _snapshot?.repositoryRoot;
    final service = widget.service;
    if (root == null || service == null) {
      return;
    }
    final generation = ++_diffGeneration;
    setState(() {
      _diffLoading = true;
      _diffError = null;
    });
    try {
      final diff = await service.loadDiff(root, file);
      if (!mounted || generation != _diffGeneration) {
        return;
      }
      setState(() {
        _diffLoading = false;
        if (diff.failed) {
          _diff = null;
          _diffError = 'git could not produce a diff for this file.';
        } else {
          _diff = diff;
        }
      });
    } on Object catch (error) {
      if (!mounted || generation != _diffGeneration) {
        return;
      }
      DiagnosticsLogService.instance.warning(
        'git_changes',
        'diff_failed',
        fields: {'errorType': error.runtimeType},
      );
      setState(() {
        _diffLoading = false;
        _diff = null;
        _diffError = error is GitWorkingTreeTimeoutException
            ? 'The host took too long to answer.'
            : 'The connection could not run git.';
      });
    }
  }

  void _openFile(GitChangedFile file) {
    setState(() {
      _selected = file;
      _diff = null;
      _diffError = null;
    });
    unawaited(_loadDiff(file));
  }

  void _closeFile() {
    _diffGeneration++;
    setState(() {
      _selected = null;
      _diff = null;
      _diffError = null;
      _diffLoading = false;
    });
  }

  void _askAboutHunk(GitChangedFile file, GitDiffHunk hunk) {
    Navigator.of(context).pop(buildGitHunkPrompt(file: file, hunk: hunk));
  }

  GitLineCounts? _countsFor(GitChangedFile file) =>
      file.counts ??
      (file.group == GitChangeGroup.untracked
          ? _untrackedCounts[file.path]
          : null);

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return PopScope(
      canPop: selected == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selected != null) {
          _closeFile();
        }
      },
      child: Column(
        children: [
          _buildHeader(context, selected),
          const Divider(height: 1),
          Expanded(
            child: selected == null
                ? _buildFileListBody(context)
                : _buildDiffBody(context, selected),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, GitChangedFile? selected) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final subtitleStyle = FluttyTheme.monoStyle.copyWith(
      fontSize: 12,
      color: scheme.onSurfaceVariant,
    );
    final snapshot = _snapshot;
    final String title;
    final List<String> subtitles;
    if (selected == null) {
      title = 'Working tree changes';
      subtitles = _listSubtitles(context, snapshot);
    } else {
      title = _baseName(selected.path);
      subtitles = [_fileSubtitle(selected)];
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FluttyTheme.spacingSm,
        0,
        FluttyTheme.spacingSm,
        FluttyTheme.spacingSm,
      ),
      child: Row(
        children: [
          if (selected != null)
            IconButton(
              tooltip: 'Back to changed files',
              onPressed: _closeFile,
              icon: const Icon(Icons.arrow_back),
            )
          else
            const SizedBox(width: FluttyTheme.spacingSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: FluttyTheme.displayMono(
                      fontSize: 18,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                if (subtitles.isNotEmpty)
                  const SizedBox(height: FluttyTheme.spacingXs),
                for (final subtitle in subtitles)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: subtitleStyle,
                  ),
              ],
            ),
          ),
          if (_canLoad)
            SizedBox.square(
              dimension: 48,
              child: _loading || _diffLoading
                  ? Center(
                      child: Semantics(
                        label: 'Refreshing',
                        child: const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  : IconButton(
                      tooltip: 'Refresh',
                      onPressed: _refresh,
                      icon: const Icon(Icons.refresh),
                    ),
            ),
          IconButton(
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  List<String> _listSubtitles(
    BuildContext context,
    GitWorkingTreeSnapshot? snapshot,
  ) {
    if (snapshot == null) {
      return const [];
    }
    final lines = <String>[];
    final root = snapshot.repositoryRoot;
    if (snapshot.state == GitWorkingTreeState.ready && root != null) {
      final head = snapshot.detached ? 'detached HEAD' : snapshot.branch;
      lines.add(head == null ? _baseName(root) : '${_baseName(root)} · $head');
    }
    final time = formatWorkingTreeRefreshTime(
      snapshot.refreshedAt,
      use24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    lines.add('refreshed $time');
    return lines;
  }

  String _fileSubtitle(GitChangedFile file) {
    final parts = <String>[gitChangeGroupLabel(file.group)];
    final original = file.originalPath;
    if (original != null) {
      parts.add('from $original');
    } else {
      final directory = _directoryName(file.path);
      if (directory.isNotEmpty) {
        parts.add(directory);
      }
    }
    return parts.join(' · ');
  }

  Widget _buildFileListBody(BuildContext context) {
    final unavailable = widget.unavailableMessage;
    if (unavailable != null || widget.service == null) {
      return _scrollableState(
        BrandErrorState(
          icon: Icons.link_off_rounded,
          title: 'changes unavailable',
          message:
              unavailable ?? 'Connect to the host to read its working tree.',
        ),
      );
    }
    if (!_canLoad) {
      return _scrollableState(
        const BrandErrorState(
          icon: Icons.folder_off_outlined,
          title: 'no working directory',
          message:
              "This window hasn't reported its directory yet. Run a command "
              'in it, then try again.',
        ),
      );
    }
    final snapshot = _snapshot;
    final loadError = _loadError;
    if (snapshot == null) {
      if (loadError != null) {
        return _scrollableState(
          BrandErrorState(
            title: "couldn't read git status",
            message: loadError,
            onRetry: _refresh,
          ),
        );
      }
      return _scrollableState(const _WorkingTreeLoading(label: 'git status'));
    }
    switch (snapshot.state) {
      case GitWorkingTreeState.notRepository:
        return _scrollableState(
          BrandEmptyState(
            title: 'not a git repository',
            message:
                "This window's directory isn't inside a git work tree, so "
                'there is nothing to diff.',
            primaryLabel: 'Refresh',
            primaryIcon: Icons.refresh,
            onPrimary: _refresh,
          ),
        );
      case GitWorkingTreeState.missingDirectory:
        return _scrollableState(
          BrandErrorState(
            icon: Icons.folder_off_outlined,
            title: 'directory not found',
            message: "The window's directory no longer exists on the host.",
            onRetry: _refresh,
          ),
        );
      case GitWorkingTreeState.gitUnavailable:
        return _scrollableState(
          BrandErrorState(
            icon: Icons.terminal_rounded,
            title: 'git not found',
            message:
                'Install git on the host, or put it on the PATH that SSH '
                'commands use.',
            onRetry: _refresh,
          ),
        );
      case GitWorkingTreeState.unsafeRepository:
        return _scrollableState(
          BrandErrorState(
            icon: Icons.gpp_maybe_outlined,
            title: 'repository not trusted',
            message:
                'git refuses this repository because another user owns it. '
                "Add it to git's safe.directory on the host.",
            onRetry: _refresh,
          ),
        );
      case GitWorkingTreeState.failed:
        final exitCode = snapshot.exitCode;
        return _scrollableState(
          BrandErrorState(
            title: 'git status failed',
            message: exitCode == null
                ? 'git stopped before reporting status.'
                : 'git exited with status $exitCode.',
            onRetry: _refresh,
          ),
        );
      case GitWorkingTreeState.ready:
        break;
    }
    if (snapshot.files.isEmpty) {
      return _scrollableState(
        BrandEmptyState(
          title: 'nothing to commit',
          message: 'Working tree clean. Enjoy it while it lasts.',
          primaryLabel: 'Refresh',
          primaryIcon: Icons.refresh,
          onPrimary: _refresh,
        ),
      );
    }
    final items = <Object>[if (snapshot.truncated) const _TruncatedNotice()];
    for (final group in GitChangeGroup.values) {
      final files = snapshot.filesIn(group);
      if (files.isNotEmpty) {
        items
          ..add((group: group, count: files.length))
          ..addAll(files);
      }
    }
    return ListView.builder(
      key: const PageStorageKey<String>('working-tree-files'),
      controller: widget.scrollController,
      padding: const EdgeInsets.only(bottom: FluttyTheme.spacingLg),
      itemCount: items.length,
      itemBuilder: (context, index) => switch (items[index]) {
        final _TruncatedNotice notice => notice,
        (group: final GitChangeGroup group, count: final int count) =>
          _GroupHeader(group: group, count: count),
        final GitChangedFile file => _ChangedFileTile(
          file: file,
          counts: _countsFor(file),
          onTap: () => _openFile(file),
        ),
        _ => const SizedBox.shrink(),
      },
    );
  }

  Widget _buildDiffBody(BuildContext context, GitChangedFile file) {
    final diffError = _diffError;
    if (diffError != null) {
      return _scrollableState(
        BrandErrorState(
          title: "couldn't read this diff",
          message: diffError,
          onRetry: () => _loadDiff(file),
        ),
      );
    }
    final diff = _diff;
    if (diff == null) {
      return _scrollableState(const _WorkingTreeLoading(label: 'git diff'));
    }
    final meta = diff.headerLines.where(_isDescriptiveHeaderLine).toList();
    if (diff.binary) {
      return _scrollableState(
        BrandErrorState(
          icon: Icons.insert_drive_file_outlined,
          title: 'binary file',
          message: file.isSubmodule
              ? 'This submodule changed. Its commits have no text diff here.'
              : 'git reports a binary change, so there is no text diff to '
                    'show.',
        ),
      );
    }
    final items = <Widget>[
      if (meta.isNotEmpty) _DiffMetaLines(lines: meta),
      if (diff.hunks.isEmpty)
        Padding(
          padding: const EdgeInsets.all(FluttyTheme.spacingMd),
          child: Text(
            meta.isEmpty
                ? 'No text changes in this file.'
                : 'No text changes beyond the lines above.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
    ];
    final hunkCount = diff.hunks.length;
    return ListView.builder(
      key: ValueKey<String>('working-tree-diff-${file.id}'),
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(
        FluttyTheme.spacingSm,
        FluttyTheme.spacingSm,
        FluttyTheme.spacingSm,
        FluttyTheme.spacingLg,
      ),
      itemCount: items.length + hunkCount + (diff.truncated ? 1 : 0),
      itemBuilder: (context, index) {
        if (index < items.length) {
          return items[index];
        }
        final hunkIndex = index - items.length;
        if (hunkIndex >= hunkCount) {
          return const _DiffTruncatedFooter();
        }
        final hunk = diff.hunks[hunkIndex];
        final previous = hunkIndex == 0 ? null : diff.hunks[hunkIndex - 1];
        final unchanged = gitUnchangedLinesBetween(previous, hunk);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (unchanged != null && unchanged > 0)
              _UnchangedLines(count: unchanged)
            else if (hunkIndex > 0)
              const SizedBox(height: FluttyTheme.spacingSm),
            AcpDiffView(
              diff: AcpDiff(path: hunk.header, unifiedDiff: hunk.body),
              semanticsLabel:
                  'Hunk ${hunkIndex + 1} of $hunkCount, '
                  '${hunk.lines.length} lines',
              headerTrailing: widget.canAskAgent
                  ? _AskAgentButton(onPressed: () => _askAboutHunk(file, hunk))
                  : null,
            ),
          ],
        );
      },
    );
  }

  Widget _scrollableState(Widget child) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      controller: widget.scrollController,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(FluttyTheme.spacingLg),
            child: child,
          ),
        ),
      ),
    ),
  );
}

bool _isDescriptiveHeaderLine(String line) =>
    !line.startsWith('diff ') &&
    !line.startsWith('index ') &&
    !line.startsWith('--- ') &&
    !line.startsWith('+++ ') &&
    !line.startsWith('Binary files ');

String _baseName(String path) {
  final trimmed = path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  final slash = trimmed.lastIndexOf('/');
  return slash < 0 ? trimmed : trimmed.substring(slash + 1);
}

String _directoryName(String path) {
  final trimmed = path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  final slash = trimmed.lastIndexOf('/');
  return slash < 0 ? '' : trimmed.substring(0, slash);
}

Color _additionColor(ThemeData theme) => theme.brightness == Brightness.dark
    ? const Color(0xFF3FB950)
    : const Color(0xFF1A7F37);

/// A status hue adjusted to stay readable as small text on the sheet.
Color _statusTextColor(ThemeData theme, Color color) => legibleDiffColor(
  color,
  background: theme.colorScheme.surface,
  ink: theme.colorScheme.onSurface,
);

class _WorkingTreeLoading extends StatelessWidget {
  const _WorkingTreeLoading({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Running $label',
      child: ExcludeSemantics(
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: label,
                style: FluttyTheme.monoStyle.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: CursorBlock(size: 14, color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TruncatedNotice extends StatelessWidget {
  const _TruncatedNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(
        FluttyTheme.spacingMd,
        FluttyTheme.spacingSm,
        FluttyTheme.spacingMd,
        0,
      ),
      padding: const EdgeInsets.all(FluttyTheme.spacingSm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: FluttyTheme.spacingSm),
          Expanded(
            child: Text(
              'Too many changes to list them all, so some files are not '
              'shown.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.group, required this.count});

  final GitChangeGroup group;
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FluttyTheme.spacingMd,
        FluttyTheme.spacingMd,
        FluttyTheme.spacingMd,
        FluttyTheme.spacingXs,
      ),
      child: Semantics(
        header: true,
        label:
            '${gitChangeGroupLabel(group)}, $count '
            '${count == 1 ? 'file' : 'files'}',
        child: ExcludeSemantics(
          child: Text(
            '${gitChangeGroupLabel(group)} · $count',
            style: FluttyTheme.displayMono(
              fontSize: 13,
              letterSpacing: 0,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

String _kindLetter(GitChangedFile file) => switch (file.kind) {
  GitChangeKind.modified => 'M',
  GitChangeKind.added => 'A',
  GitChangeKind.deleted => 'D',
  GitChangeKind.renamed => 'R',
  GitChangeKind.copied => 'C',
  GitChangeKind.typeChanged => 'T',
  GitChangeKind.untracked => '?',
  GitChangeKind.conflicted => 'U',
};

String _kindLabel(GitChangedFile file) => switch (file.kind) {
  GitChangeKind.modified => 'modified',
  GitChangeKind.added => 'added',
  GitChangeKind.deleted => 'deleted',
  GitChangeKind.renamed => 'renamed',
  GitChangeKind.copied => 'copied',
  GitChangeKind.typeChanged => 'type changed',
  GitChangeKind.untracked => 'untracked',
  GitChangeKind.conflicted => 'conflict ${file.statusCode ?? ''}'.trim(),
};

class _ChangedFileTile extends StatelessWidget {
  const _ChangedFileTile({
    required this.file,
    required this.counts,
    required this.onTap,
  });

  final GitChangedFile file;
  final GitLineCounts? counts;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final kindColor = switch (file.kind) {
      GitChangeKind.added ||
      GitChangeKind.untracked => _statusTextColor(theme, _additionColor(theme)),
      GitChangeKind.deleted ||
      GitChangeKind.conflicted => _statusTextColor(theme, scheme.error),
      _ => scheme.onSurfaceVariant,
    };
    final original = file.originalPath;
    final directory = _directoryName(file.path);
    final detail = original != null ? 'from $original' : directory;
    final counts = this.counts;
    final countsLabel = counts == null
        ? ''
        : counts.binary
        ? ', binary'
        : ', ${counts.added} added, ${counts.removed} removed';
    final semanticsLabel =
        '${file.path}, ${_kindLabel(file)}'
        '${original == null ? '' : ' from $original'}'
        '${file.isSubmodule ? ', submodule' : ''}$countsLabel';
    return Semantics(
      button: true,
      label: semanticsLabel,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FluttyTheme.spacingMd,
              vertical: FluttyTheme.spacingSm,
            ),
            child: Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: kindColor.withValues(alpha: 0.6)),
                  ),
                  child: Text(
                    _kindLetter(file),
                    style: FluttyTheme.displayMono(
                      fontSize: 12,
                      letterSpacing: 0,
                      color: kindColor,
                    ),
                  ),
                ),
                const SizedBox(width: FluttyTheme.spacingSm + 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _baseName(file.path),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: FluttyTheme.monoStyle.copyWith(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: scheme.onSurface,
                        ),
                      ),
                      if (detail.isNotEmpty)
                        Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: FluttyTheme.monoStyle.copyWith(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: FluttyTheme.spacingSm),
                if (counts != null) _LineCounts(counts: counts),
                Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LineCounts extends StatelessWidget {
  const _LineCounts({required this.counts});

  final GitLineCounts counts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = FluttyTheme.monoStyle.copyWith(fontSize: 12);
    if (counts.binary) {
      return Text('bin', style: style.copyWith(color: scheme.onSurfaceVariant));
    }
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '+${counts.added}',
            style: style.copyWith(
              color: _statusTextColor(theme, _additionColor(theme)),
            ),
          ),
          const TextSpan(text: ' '),
          TextSpan(
            text: '\u2212${counts.removed}',
            style: style.copyWith(color: _statusTextColor(theme, scheme.error)),
          ),
        ],
      ),
    );
  }
}

class _AskAgentButton extends StatelessWidget {
  const _AskAgentButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Ask the agent about this hunk',
    child: TextButton.icon(
      onPressed: onPressed,
      // Neutral, not Signal Teal: every hunk carries one, so it must recede.
      style: TextButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: FluttyTheme.spacingSm),
      ),
      icon: const Icon(Icons.forum_outlined, size: 18),
      label: const Text('Ask agent'),
    ),
  );
}

class _UnchangedLines extends StatelessWidget {
  const _UnchangedLines({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = count == 1 ? '1 unchanged line' : '$count unchanged lines';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: FluttyTheme.spacingXs),
      child: Row(
        children: [
          Expanded(child: Divider(color: scheme.outlineVariant)),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FluttyTheme.spacingSm,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.unfold_less_rounded,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: FluttyTheme.spacingXs),
                Text(
                  label,
                  style: FluttyTheme.monoStyle.copyWith(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: Divider(color: scheme.outlineVariant)),
        ],
      ),
    );
  }
}

class _DiffMetaLines extends StatelessWidget {
  const _DiffMetaLines({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: FluttyTheme.spacingSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Text(
              line,
              style: FluttyTheme.monoStyle.copyWith(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

class _DiffTruncatedFooter extends StatelessWidget {
  const _DiffTruncatedFooter();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: FluttyTheme.spacingSm),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: FluttyTheme.spacingSm),
          Expanded(
            child: Text(
              'Diff cut off at ${kGitDiffMaxBytes ~/ 1024} KB. Later hunks '
              'are not shown.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
