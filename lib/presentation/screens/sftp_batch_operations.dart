import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../domain/services/remote_file_service.dart';

/// How one item in a batch ended.
enum SftpBatchOutcome {
  /// The action completed for this item.
  done,

  /// The action failed for this item.
  failed,

  /// The item was not attempted, or was cancelled part-way.
  skipped,
}

/// Result for one item of a batch action.
@immutable
class SftpBatchItemResult {
  /// Creates a result.
  const SftpBatchItemResult(this.name, this.outcome, {this.detail});

  /// File name shown to the user.
  final String name;

  /// How the item ended.
  final SftpBatchOutcome outcome;

  /// Short reason for a failure or skip.
  final String? detail;
}

/// Everything a batch did, plus the first error for logging.
@immutable
class SftpBatchReport {
  /// Creates a report.
  const SftpBatchReport(
    this.results, {
    this.firstError,
    this.cancelled = false,
  });

  /// Per-item results in the order the items were given.
  final List<SftpBatchItemResult> results;

  /// The first failure, used for telemetry categories and diagnostics.
  final Object? firstError;

  /// Whether the user cancelled the batch.
  final bool cancelled;

  /// Number of items that completed.
  int get doneCount =>
      results.where((result) => result.outcome == SftpBatchOutcome.done).length;

  /// Whether every item completed.
  bool get allDone => doneCount == results.length;
}

/// Thrown from a batch step when the user cancelled it.
class SftpBatchCancelledException implements Exception {
  /// Creates the exception.
  const SftpBatchCancelledException();

  @override
  String toString() => 'Cancelled';
}

/// Thrown from a batch step to fail that item with a specific [detail].
class SftpBatchItemFailure implements Exception {
  /// Creates the failure.
  const SftpBatchItemFailure(this.detail);

  /// Short, path-free reason shown for the item.
  final String detail;

  @override
  String toString() => detail;
}

/// Thrown from a batch step to skip that item with a [detail].
class SftpBatchItemSkipped implements Exception {
  /// Creates the skip.
  const SftpBatchItemSkipped(this.detail);

  /// Short, path-free reason shown for the item.
  final String detail;

  @override
  String toString() => detail;
}

/// Live state of a running batch for [SftpBatchProgressBar].
class SftpBatchProgress extends ChangeNotifier {
  /// Creates progress for [total] items described by [verb], such as
  /// `Uploading`.
  SftpBatchProgress({
    required this.verb,
    required this.total,
    this.cancellable = true,
    this.indeterminate = false,
  });

  /// Present participle shown in the bar.
  final String verb;

  /// Number of items in the batch.
  final int total;

  /// Whether the bar offers a cancel button.
  final bool cancellable;

  /// Whether progress cannot be measured, as for a remote extraction.
  final bool indeterminate;

  final _cancelListeners = <VoidCallback>[];
  int _index = 0;
  String? _currentName;
  int? _currentBytes;
  int? _currentTotalBytes;
  bool _cancelRequested = false;

  /// Zero-based index of the item in progress.
  int get index => _index;

  /// Name of the item in progress.
  String? get currentName => _currentName;

  /// Whether the user asked to stop.
  bool get cancelRequested => _cancelRequested;

  /// Overall completion between 0 and 1, counting bytes of the current item
  /// when its size is known.
  double get fraction {
    if (total == 0) return 1;
    final itemTotal = _currentTotalBytes;
    final itemBytes = _currentBytes;
    final itemFraction = itemTotal != null && itemTotal > 0 && itemBytes != null
        ? (itemBytes / itemTotal).clamp(0.0, 1.0)
        : 0.0;
    return ((_index + itemFraction) / total).clamp(0.0, 1.0);
  }

  /// Marks item [index] named [name] as started.
  void start(int index, String name, {int? totalBytes}) {
    _index = index;
    _currentName = name;
    _currentBytes = 0;
    _currentTotalBytes = totalBytes;
    notifyListeners();
  }

  /// Records bytes moved for the current item.
  void updateBytes(int bytes) {
    _currentBytes = bytes;
    notifyListeners();
  }

  /// Requests cancellation and runs registered cancel callbacks.
  void cancel() {
    if (_cancelRequested) return;
    _cancelRequested = true;
    for (final listener in List.of(_cancelListeners)) {
      listener();
    }
    notifyListeners();
  }

  /// Runs [listener] when the batch is cancelled; returns a remover.
  VoidCallback onCancel(VoidCallback listener) {
    _cancelListeners.add(listener);
    return () => _cancelListeners.remove(listener);
  }

  /// Throws [SftpBatchCancelledException] once cancellation was requested.
  void throwIfCancelled() {
    if (_cancelRequested) throw const SftpBatchCancelledException();
  }
}

/// Runs [run] for each item in order and records per-item results.
///
/// A cancellation marks the current and remaining items as skipped. With
/// [stopOnFailure], the first failure skips the remaining items too.
Future<SftpBatchReport> runSftpBatch<T>({
  required List<T> items,
  required String Function(T item) nameOf,
  required Future<void> Function(T item, int index) run,
  required SftpBatchProgress progress,
  bool stopOnFailure = false,
  String stoppedDetail = 'Not attempted',
}) async {
  final results = <SftpBatchItemResult>[];
  Object? firstError;
  var cancelled = false;
  void skipRest(int from, String detail) {
    for (final item in items.skip(from)) {
      results.add(
        SftpBatchItemResult(
          nameOf(item),
          SftpBatchOutcome.skipped,
          detail: detail,
        ),
      );
    }
  }

  for (var index = 0; index < items.length; index++) {
    final item = items[index];
    if (progress.cancelRequested) {
      cancelled = true;
      skipRest(index, 'Cancelled');
      break;
    }
    progress.start(index, nameOf(item));
    try {
      await run(item, index);
      results.add(SftpBatchItemResult(nameOf(item), SftpBatchOutcome.done));
    } on SftpBatchItemSkipped catch (skip) {
      results.add(
        SftpBatchItemResult(
          nameOf(item),
          SftpBatchOutcome.skipped,
          detail: skip.detail,
        ),
      );
    } on Object catch (error) {
      if (isSftpBatchCancellation(error) || progress.cancelRequested) {
        cancelled = true;
        skipRest(index, 'Cancelled');
        break;
      }
      firstError ??= error;
      results.add(
        SftpBatchItemResult(
          nameOf(item),
          SftpBatchOutcome.failed,
          detail: describeSftpBatchError(error),
        ),
      );
      if (stopOnFailure) {
        skipRest(index + 1, stoppedDetail);
        break;
      }
    }
  }
  return SftpBatchReport(results, firstError: firstError, cancelled: cancelled);
}

/// Whether [error] reports a user cancellation.
bool isSftpBatchCancellation(Object error) =>
    error is SftpBatchCancelledException ||
    error is RemoteFileDownloadCancelledException;

/// Short, path-free reason for a failed batch item.
String describeSftpBatchError(Object error) => switch (error) {
  SftpBatchItemFailure(:final detail) => detail,
  SftpStatusError(code: SftpStatusCode.noSuchFile) => 'No longer exists',
  SftpStatusError(code: SftpStatusCode.permissionDenied) => 'Permission denied',
  SftpStatusError() => 'The server refused it',
  TimeoutException() => 'Timed out',
  FileSystemException() => 'Could not save it on this device',
  SSHError() || SocketException() => 'Connection lost',
  _ => 'Failed',
};

/// One-line summary such as `Deleted 2 of 3 files`.
String sftpBatchSummary(String pastVerb, SftpBatchReport report) {
  final total = report.results.length;
  final done = report.doneCount;
  final noun = total == 1 ? 'file' : 'files';
  if (report.allDone) return '$pastVerb $total $noun';
  final suffix = report.cancelled ? 'Cancelled.' : 'Some failed.';
  return '$pastVerb $done of $total $noun. $suffix';
}

/// Shows per-file results for a batch.
Future<void> showSftpBatchResults(
  BuildContext context, {
  required String title,
  required SftpBatchReport report,
}) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(title),
    scrollable: true,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final result in report.results) _SftpBatchResultRow(result),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Close'),
      ),
    ],
  ),
);

class _SftpBatchResultRow extends StatelessWidget {
  const _SftpBatchResultRow(this.result);

  final SftpBatchItemResult result;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (icon, color, label) = switch (result.outcome) {
      SftpBatchOutcome.done => (
        Icons.check_circle_outline,
        colorScheme.primary,
        'Done',
      ),
      SftpBatchOutcome.failed => (
        Icons.error_outline,
        colorScheme.error,
        'Failed',
      ),
      SftpBatchOutcome.skipped => (
        Icons.remove_circle_outline,
        colorScheme.onSurfaceVariant,
        'Skipped',
      ),
    };
    final status = result.detail == null ? label : '$label: ${result.detail}';
    return Semantics(
      container: true,
      label: '${result.name}, $status',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      result.name,
                      style: FluttyTheme.monoStyle.copyWith(
                        color: colorScheme.onSurface,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      status,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: result.outcome == SftpBatchOutcome.failed
                            ? colorScheme.error
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shared frame for the browser's bottom panels.
class SftpBottomPanel extends StatelessWidget {
  /// Creates a panel with a mono [title], a [summary] line and [actions].
  const SftpBottomPanel({
    required this.title,
    required this.summary,
    required this.actions,
    this.child,
    this.summaryIsMachineText = false,
    super.key,
  });

  /// Lowercase mono heading, such as `3 selected`.
  final String title;

  /// Explanation under the heading.
  final String summary;

  /// Buttons laid out in a row that shares the width.
  final List<Widget> actions;

  /// Optional content between the summary and the buttons.
  final Widget? child;

  /// Whether [summary] is a file name, set in mono like other machine text.
  final bool summaryIsMachineText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: Align(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    style: FluttyTheme.displayMono(
                      fontSize: 16,
                      color: theme.colorScheme.onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    summary,
                    style: summaryIsMachineText
                        ? FluttyTheme.monoStyle.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          )
                        : theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (child case final child?) ...[
                    const SizedBox(height: 8),
                    child,
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      for (final (index, action) in actions.indexed) ...[
                        if (index > 0) const SizedBox(width: 8),
                        Expanded(child: action),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom panel showing a running batch with a cancel button.
class SftpBatchProgressBar extends StatelessWidget {
  /// Creates the bar for [progress].
  const SftpBatchProgressBar({required this.progress, super.key});

  /// Progress to show.
  final SftpBatchProgress progress;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: progress,
    builder: (context, _) {
      final position = (progress.index + 1).clamp(1, progress.total);
      final title = progress.cancelRequested
          ? 'cancelling'
          : progress.total == 1
          ? progress.verb.toLowerCase()
          : '${progress.verb.toLowerCase()} $position of ${progress.total}';
      return SftpBottomPanel(
        title: title,
        summary: progress.currentName ?? '',
        summaryIsMachineText: true,
        actions: [
          if (progress.cancellable)
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: progress.cancelRequested ? null : progress.cancel,
              icon: const Icon(Icons.close),
              label: Text(progress.cancelRequested ? 'Cancelling…' : 'Cancel'),
            ),
        ],
        // An indeterminate bar animates forever, so reduced motion drops it
        // and the title alone reports the work.
        child: progress.indeterminate && MediaQuery.disableAnimationsOf(context)
            ? null
            : LinearProgressIndicator(
                value: progress.indeterminate ? null : progress.fraction,
                semanticsLabel: progress.indeterminate
                    ? progress.verb
                    : '${progress.verb} $position of ${progress.total}',
              ),
      );
    },
  );
}

/// Bottom panel for batch actions on the selected files.
class SftpBatchSelectionBar extends StatelessWidget {
  /// Creates the bar.
  const SftpBatchSelectionBar({
    required this.selectedCount,
    required this.onDone,
    required this.onDownload,
    required this.onMove,
    required this.onDelete,
    super.key,
  });

  /// Number of selected files.
  final int selectedCount;

  /// Leaves selection mode.
  final VoidCallback onDone;

  /// Downloads the selection.
  final VoidCallback onDownload;

  /// Starts moving the selection.
  final VoidCallback onMove;

  /// Deletes the selection.
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final hasSelection = selectedCount > 0;
    final colorScheme = Theme.of(context).colorScheme;
    const size = Size.fromHeight(48);
    Widget action(
      IconData icon,
      String label,
      VoidCallback onPressed, {
      Color? color,
    }) => TextButton(
      style: TextButton.styleFrom(
        minimumSize: size,
        foregroundColor: color ?? colorScheme.onSurface,
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
      onPressed: hasSelection ? onPressed : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [Icon(icon), Text(label, maxLines: 1)],
      ),
    );
    return SftpBottomPanel(
      title: hasSelection
          ? '$selectedCount ${selectedCount == 1 ? 'file' : 'files'} selected'
          : 'select files',
      summary: hasSelection
          ? 'Selections stay as you open other folders.'
          : 'Tap files to select them. Folders still open.',
      actions: [
        action(Icons.download, 'Download', onDownload),
        action(Icons.drive_file_move_outline, 'Move', onMove),
        action(
          Icons.delete_outline,
          'Delete',
          onDelete,
          color: colorScheme.error,
        ),
        TextButton(
          style: TextButton.styleFrom(
            minimumSize: size,
            foregroundColor: colorScheme.onSurface,
            padding: const EdgeInsets.symmetric(horizontal: 4),
          ),
          onPressed: onDone,
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [Icon(Icons.close), Text('Close', maxLines: 1)],
          ),
        ),
      ],
    );
  }
}

/// Bottom panel shown while choosing where to move files.
class SftpMoveBar extends StatelessWidget {
  /// Creates the bar.
  const SftpMoveBar({
    required this.fileCount,
    required this.onCancel,
    required this.onMoveHere,
    super.key,
  });

  /// Number of files being moved.
  final int fileCount;

  /// Abandons the move.
  final VoidCallback onCancel;

  /// Moves the files into the open folder.
  final VoidCallback onMoveHere;

  @override
  Widget build(BuildContext context) {
    const size = Size.fromHeight(48);
    final noun = fileCount == 1 ? 'file' : 'files';
    return SftpBottomPanel(
      title: 'move $fileCount $noun',
      summary: 'Open the destination folder, then move them here.',
      actions: [
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: size),
          onPressed: onCancel,
          icon: const Icon(Icons.close),
          label: const Text('Cancel'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: size),
          onPressed: onMoveHere,
          icon: const Icon(Icons.drive_file_move_outline),
          label: const Text('Move here'),
        ),
      ],
    );
  }
}
