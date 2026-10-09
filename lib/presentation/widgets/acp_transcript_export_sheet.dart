/// Preview and share a native chat transcript as Markdown.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/theme.dart';
import '../models/acp_transcript_markdown.dart';

/// Characters of the export shown in the preview. The shared document is
/// always complete; laying out a multi-megabyte text field is not.
const int kAcpExportPreviewChars = 24 * 1024;

/// Largest export copied to the clipboard on Android, whose clipboard shares
/// the ~1 MB binder transaction limit; larger exports go through Share.
const int kAcpExportMaxAndroidCopyBytes = 512 * 1024;

/// Folder under the app's temporary directory that holds shared exports.
const String kAcpExportFolderName = 'monkeyssh-chat-exports';

/// Whether Share is a Save dialog here: desktop share targets either don't
/// take files (Linux) or read them from a shared temporary folder.
bool get acpExportSavesToFile => switch (defaultTargetPlatform) {
  TargetPlatform.android || TargetPlatform.iOS => false,
  _ => true,
};

/// Hands a finished export to another app.
typedef AcpTranscriptShare = Future<void> Function(
  BuildContext context,
  String markdown,
  String fileName,
);

/// Opens the export preview for [source].
///
/// A bottom sheet on phones keeps the actions in thumb reach; wide layouts
/// get a dialog. [share] defaults to the platform share sheet.
Future<void> showAcpTranscriptExportSheet(
  BuildContext context, {
  required AcpTranscriptExportSource source,
  AcpTranscriptShare share = shareAcpTranscriptMarkdown,
}) {
  final wide = MediaQuery.sizeOf(context).width >= 600;
  if (wide) {
    return showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
          child: AcpTranscriptExportSheet(source: source, share: share),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.9,
      child: AcpTranscriptExportSheet(source: source, share: share),
    ),
  );
}

/// Shares [markdown] as a `.md` file through the platform share sheet, or
/// saves it through a Save dialog on desktop.
///
/// A file keeps formatting intact and has no size limit; Copy covers pasting
/// straight into an issue.
Future<void> shareAcpTranscriptMarkdown(
  BuildContext context,
  String markdown,
  String fileName,
) async {
  final bytes = Uint8List.fromList(utf8.encode(markdown));
  if (acpExportSavesToFile) {
    await FilePicker.saveFile(
      dialogTitle: 'Save transcript',
      fileName: fileName,
      bytes: bytes,
      mimeType: 'text/markdown',
    );
    return;
  }
  final box = context.findRenderObject() as RenderBox?;
  final origin = box != null && box.hasSize
      ? box.localToGlobal(Offset.zero) & box.size
      : null;
  final file = await writeAcpTranscriptExportFile(bytes, fileName);
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile(file.path, mimeType: 'text/markdown', name: fileName)],
      subject: 'Agent chat transcript',
      sharePositionOrigin: origin,
    ),
  );
}

/// Writes [bytes] as [fileName] in a private temporary folder for sharing,
/// after deleting what earlier exports left there.
///
/// A share target may read the file after the sheet closes, so the newest
/// export stays until the next one replaces it.
Future<File> writeAcpTranscriptExportFile(
  List<int> bytes,
  String fileName, {
  Directory? temporaryDirectory,
}) async {
  final root = temporaryDirectory ?? await getTemporaryDirectory();
  final folder = Directory(p.join(root.path, kAcpExportFolderName));
  if (folder.existsSync()) {
    for (final stale in folder.listSync()) {
      try {
        stale.deleteSync(recursive: true);
      } on FileSystemException {
        // A target still reading an older export keeps it a little longer.
      }
    }
  }
  folder.createSync(recursive: true);
  final file = File(p.join(folder.path, fileName));
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

/// The export preview: what is included, an option for reasoning, a bounded
/// preview of the Markdown, and Copy and Share actions.
class AcpTranscriptExportSheet extends StatefulWidget {
  /// Creates an export preview.
  const AcpTranscriptExportSheet({
    required this.source,
    this.share = shareAcpTranscriptMarkdown,
    this.now,
    super.key,
  });

  /// The conversation to export.
  final AcpTranscriptExportSource source;

  /// Hands the export to another app.
  final AcpTranscriptShare share;

  /// Clock for the export timestamp and file name; defaults to now.
  final DateTime Function()? now;

  @override
  State<AcpTranscriptExportSheet> createState() =>
      _AcpTranscriptExportSheetState();
}

class _AcpTranscriptExportSheetState extends State<AcpTranscriptExportSheet> {
  var _includeReasoning = false;
  late DateTime _exportedAt = (widget.now ?? DateTime.now)();
  late AcpTranscriptExport _export = _build();
  late int _exportBytes = utf8.encode(_export.markdown).length;
  var _copied = false;
  var _sharing = false;
  String? _shareError;
  Timer? _copiedReset;

  AcpTranscriptExport _build() => buildAcpTranscriptMarkdown(
    widget.source,
    includeReasoning: _includeReasoning,
    exportedAt: _exportedAt,
  );

  @override
  void dispose() {
    _copiedReset?.cancel();
    super.dispose();
  }

  void _setIncludeReasoning(bool value) {
    setState(() {
      _includeReasoning = value;
      _exportedAt = (widget.now ?? DateTime.now)();
      _export = _build();
      _exportBytes = utf8.encode(_export.markdown).length;
    });
  }

  String get _fileName {
    String two(int value) => value.toString().padLeft(2, '0');
    final time = _exportedAt.toLocal();
    return 'monkeyssh-chat-${time.year}${two(time.month)}${two(time.day)}-'
        '${two(time.hour)}${two(time.minute)}.md';
  }

  Future<void> _copy() async {
    if (defaultTargetPlatform == TargetPlatform.android &&
        _exportBytes > kAcpExportMaxAndroidCopyBytes) {
      setState(
        () => _shareError =
            'This transcript is too large to copy. Use Share instead.',
      );
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: _export.markdown));
    } on Object {
      if (mounted) {
        setState(
          () =>
              _shareError = 'Couldn’t copy the transcript. Use Share instead.',
        );
      }
      return;
    }
    if (!mounted) return;
    _copiedReset?.cancel();
    setState(() {
      _copied = true;
      _shareError = null;
    });
    _copiedReset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _share(BuildContext buttonContext) async {
    setState(() {
      _sharing = true;
      _shareError = null;
    });
    try {
      await widget.share(buttonContext, _export.markdown, _fileName);
    } on Object {
      if (mounted) {
        setState(
          () => _shareError = acpExportSavesToFile
              ? 'Couldn’t save the file. Copy the Markdown instead.'
              : 'Couldn’t open the share sheet. Copy the Markdown instead.',
        );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final export = _export;
    final markdown = export.markdown;
    final preview = markdown.length <= kAcpExportPreviewChars
        ? markdown
        : markdown.substring(0, kAcpExportPreviewChars);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    // The modal sheet's safe area covers the top and sides only; keep Copy
    // and Share clear of the system navigation bar.
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          FluttyTheme.spacingMd,
          0,
          FluttyTheme.spacingMd,
          FluttyTheme.spacingMd,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Everything above the actions scrolls as one, so a short
            // screen or large text never pushes Copy and Share off the sheet.
            Expanded(
              child: Scrollbar(
                child: SingleChildScrollView(
                  key: const ValueKey('acp-export-preview'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Export transcript',
                        style: FluttyTheme.displayMono(
                          fontSize: 18,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: FluttyTheme.spacingXs),
                      Text(
                        '${_plural(export.prompts, 'prompt')} · '
                        '${_plural(export.replies, 'reply', 'replies')} · '
                        '${_plural(export.toolCalls, 'tool call')} · '
                        '${_formatSize(_exportBytes)}',
                        key: const ValueKey('acp-export-summary'),
                        style: FluttyTheme.monoStyle.copyWith(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: FluttyTheme.spacingSm),
                      if (export.historyIncomplete)
                        _Notice(
                          key: const ValueKey('acp-export-history-notice'),
                          icon: Icons.history_toggle_off,
                          color: scheme.tertiary,
                          text:
                              'Earlier history isn’t loaded. The export says '
                              'so at the top.',
                        ),
                      if (export.omittedAttachments > 0)
                        _Notice(
                          icon: Icons.attach_file,
                          color: scheme.onSurfaceVariant,
                          text:
                              'Images, audio and attachments are marked where '
                              'they appeared, not included.',
                        ),
                      if (widget.source.hasReasoning)
                        SwitchListTile(
                          key: const ValueKey('acp-export-include-reasoning'),
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Include reasoning'),
                          subtitle: Text(
                            'Agent reasoning is left out unless you add it.',
                            style: muted,
                          ),
                          value: _includeReasoning,
                          onChanged: _setIncludeReasoning,
                        ),
                      const SizedBox(height: FluttyTheme.spacingSm),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(
                            FluttyTheme.radiusMd,
                          ),
                          border: Border.all(color: scheme.outlineVariant),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(
                            FluttyTheme.spacingSm + 4,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SelectableText(
                                preview,
                                style: FluttyTheme.monoStyle.copyWith(
                                  fontSize: 12,
                                  color: scheme.onSurface,
                                ),
                              ),
                              if (preview.length < markdown.length) ...[
                                const SizedBox(height: FluttyTheme.spacingSm),
                                Text(
                                  'Preview ends here. Copy or Share includes '
                                  'all ${_formatSize(_exportBytes)}.',
                                  key: const ValueKey(
                                    'acp-export-preview-truncated',
                                  ),
                                  style: muted,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_shareError != null) ...[
              const SizedBox(height: FluttyTheme.spacingSm),
              // Announced, since it appears in answer to a button press.
              Semantics(
                liveRegion: true,
                child: _Notice(
                  key: const ValueKey('acp-export-error'),
                  icon: Icons.error_outline,
                  color: scheme.error,
                  text: _shareError!,
                ),
              ),
            ],
            const SizedBox(height: FluttyTheme.spacingMd),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('acp-export-copy'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: _copy,
                    icon: Icon(_copied ? Icons.check : Icons.copy, size: 18),
                    label: Text(_copied ? 'Copied' : 'Copy'),
                  ),
                ),
                const SizedBox(width: FluttyTheme.spacingSm),
                Expanded(
                  child: Builder(
                    builder: (buttonContext) => FilledButton.icon(
                      key: const ValueKey('acp-export-share'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      onPressed: _sharing ? null : () => _share(buttonContext),
                      icon: Icon(
                        acpExportSavesToFile
                            ? Icons.save_alt
                            : Icons.adaptive.share,
                        size: 18,
                      ),
                      label: Text(acpExportSavesToFile ? 'Save' : 'Share'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.color,
    required this.text,
    super.key,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: FluttyTheme.spacingXs),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 16, color: color),
        ),
        const SizedBox(width: FluttyTheme.spacingSm),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: Theme.of(context).colorScheme.onSurface),
          ),
        ),
      ],
    ),
  );
}

String _plural(int value, String singular, [String? plural]) =>
    '$value ${value == 1 ? singular : (plural ?? '${singular}s')}';

String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
