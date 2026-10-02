import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../models/acp_timeline.dart';
import 'acp_code_block.dart';
import 'syntax_highlight_language.dart';

/// Bottom-sheet body for reading a resource whose contents an agent embedded.
///
/// The agent sent the text inline, so it is readable even when [resource]'s
/// URI is not a path this client can open. Shows the name and URI, the text in
/// the chat's code-block treatment, and an "Open in files" action when the URI
/// is a remote path.
class AcpResourceTextSheet extends StatelessWidget {
  /// Creates a resource text sheet.
  const AcpResourceTextSheet({
    required this.resource,
    required this.text,
    super.key,
    this.onCopy,
    this.onOpenPath,
  });

  /// The resource being read.
  final AcpResourceRef resource;

  /// The embedded text contents.
  final String text;

  /// Called after the contents are copied.
  final VoidCallback? onCopy;

  /// Opens a remote path in the file browser.
  final ValueChanged<String>? onOpenPath;

  /// The remote path [resource] names, if it is one the file browser can open.
  String? get remotePath {
    final uri = resource.uri;
    final path = uri.startsWith('file:')
        ? Uri.tryParse(uri)?.path
        : uri.startsWith('/')
        ? uri
        : null;
    return path == null || path.isEmpty ? null : path;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final path = remotePath;
    final onOpenPath = this.onOpenPath;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                FluttyTheme.spacingMd,
                0,
                FluttyTheme.spacingMd,
                FluttyTheme.spacingSm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    resource.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: FluttyTheme.displayMono(fontSize: 16)
                        .copyWith(color: scheme.onSurface),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    resource.uri,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: FluttyTheme.monoStyle.copyWith(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: FluttyTheme.spacingMd,
                ),
                child: AcpCodeBlock(
                  code: text,
                  // Never auto-detect: it runs every grammar over the text.
                  language:
                      detectLanguageFromFilename(resource.displayName) ??
                      'plaintext',
                  onCopy: onCopy == null ? null : (_) => onCopy!(),
                ),
              ),
            ),
            if (path != null && onOpenPath != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  FluttyTheme.spacingMd,
                  FluttyTheme.spacingSm,
                  FluttyTheme.spacingMd,
                  FluttyTheme.spacingMd,
                ),
                child: OutlinedButton.icon(
                  onPressed: () => onOpenPath(path),
                  icon: const Icon(Icons.folder_open_outlined, size: 18),
                  label: const Text('Open in files'),
                ),
              )
            else
              const SizedBox(height: FluttyTheme.spacingMd),
          ],
        ),
      ),
    );
  }
}
