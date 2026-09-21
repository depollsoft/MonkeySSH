import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

/// Progress of a paste upload (clipboard image, picked media, or files) that
/// the terminal screen is pushing over SFTP before pasting the remote paths.
///
/// Byte counts cover the whole batch so a multi-file paste reads as one
/// upload rather than a line that restarts per file.
@immutable
class TerminalPasteUploadProgress {
  /// Creates a snapshot of an in-flight paste upload.
  const TerminalPasteUploadProgress({
    required this.uploadedBytes,
    this.totalBytes,
  });

  /// Bytes written so far across the batch.
  final int uploadedBytes;

  /// Total bytes in the batch, or null when any file's size is unknown.
  final int? totalBytes;

  /// Fraction complete, or null when the total is unknown (indeterminate).
  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) {
      return null;
    }
    return (uploadedBytes / total).clamp(0.0, 1.0);
  }

  /// Returns a copy with the given fields replaced.
  TerminalPasteUploadProgress copyWith({int? uploadedBytes, int? totalBytes}) =>
      TerminalPasteUploadProgress(
        uploadedBytes: uploadedBytes ?? this.uploadedBytes,
        totalBytes: totalBytes ?? this.totalBytes,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalPasteUploadProgress &&
          uploadedBytes == other.uploadedBytes &&
          totalBytes == other.totalBytes;

  @override
  int get hashCode => Object.hash(uploadedBytes, totalBytes);
}

/// Accessibility label for the upload line.
String describeTerminalPasteUploadProgress(
  TerminalPasteUploadProgress progress,
) {
  final fraction = progress.fraction;
  if (fraction == null) {
    return 'Uploading paste';
  }
  return 'Uploading paste, ${(fraction * 100).round()} percent';
}

/// A thin progress line that overlays the bottom edge of the terminal while
/// a pasted image, video, or file uploads.
///
/// It shares the terminal task-progress bar's vocabulary (3px, accent on the
/// raised surface) and adds nothing else: no caption, no control. The
/// terminal keeps its size, so the remote TUI is not resized mid-upload, and
/// the existing "Uploaded ..." message still closes the loop.
class TerminalPasteUploadStrip extends StatelessWidget {
  /// Creates the upload line.
  const TerminalPasteUploadStrip({required this.progress, super.key});

  /// Height of the line.
  static const lineHeight = 3.0;

  /// Current upload progress.
  final TerminalPasteUploadProgress progress;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final fraction = progress.fraction;
    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final percentage = fraction == null ? null : (fraction * 100).round();

    return Semantics(
      label: describeTerminalPasteUploadProgress(progress),
      value: percentage?.toString(),
      minValue: percentage == null ? null : '0',
      maxValue: percentage == null ? null : '100',
      role: percentage == null
          ? SemanticsRole.loadingSpinner
          : SemanticsRole.progressBar,
      child: ExcludeSemantics(
        child: LinearProgressIndicator(
          key: const ValueKey<String>('terminal-paste-upload-line'),
          value: fraction ?? (disableAnimations ? 0.5 : null),
          minHeight: lineHeight,
          color: colorScheme.primary,
          backgroundColor: colorScheme.surfaceContainerHighest,
        ),
      ),
    );
  }
}
