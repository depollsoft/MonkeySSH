import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../../domain/models/acp_elicitation.dart';
import 'acp_chat_typography.dart';
import 'acp_elicitation_form_sheet.dart';
import 'acp_elicitation_url_sheet.dart';
import 'cursor_block.dart';

/// Sends a form submission (or URL consent, with `null` content).
typedef AcpElicitationAccept = Future<void> Function(
  String requestKey,
  Map<String, Object?>? content,
);

/// Answers one elicitation without content.
typedef AcpElicitationAnswer = Future<void> Function(String requestKey);

/// Pending agent requests for input, shown in the chat's anchored action area
/// beside permission prompts.
///
/// Each card names the agent. Form requests open an editable sheet; URL
/// requests open a consent sheet that shows the full address before anything
/// is opened. Dismissing either sheet answers `cancel`. If the agent withdraws
/// a request while its sheet is open, the sheet closes without answering.
class AcpElicitationSurface extends StatefulWidget {
  /// Creates an elicitation surface.
  const AcpElicitationSurface({
    required this.agentLabel,
    required this.elicitations,
    required this.awaiting,
    required this.onAccept,
    required this.onDecline,
    required this.onCancel,
    required this.onOpenUrl,
    required this.onDismissAwaiting,
    this.toolTitles = const <String, String>{},
    super.key,
  });

  /// Display name of the agent asking.
  final String agentLabel;

  /// Requests awaiting a decision.
  final List<AcpSessionElicitation> elicitations;

  /// Accepted URL requests the user is finishing in a browser.
  final List<AcpAwaitingElicitation> awaiting;

  /// Accepts a request.
  final AcpElicitationAccept onAccept;

  /// Declines a request.
  final AcpElicitationAnswer onDecline;

  /// Cancels a request the user dismissed.
  final AcpElicitationAnswer onCancel;

  /// Opens a consented URL outside the app. Returns whether it opened.
  final Future<bool> Function(Uri url) onOpenUrl;

  /// Stops showing an awaiting URL request.
  final void Function(String elicitationId) onDismissAwaiting;

  /// Tool-call titles by id, for requests tied to a tool call.
  final Map<String, String> toolTitles;

  @override
  State<AcpElicitationSurface> createState() => _AcpElicitationSurfaceState();
}

class _AcpElicitationSurfaceState extends State<AcpElicitationSurface> {
  final _resolving = <String>{};
  // Open sheets by request key; completing one closes its sheet unanswered.
  final _openSheets = <String, Completer<void>>{};

  @override
  void didUpdateWidget(AcpElicitationSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    final live = {for (final item in widget.elicitations) item.requestKey};
    for (final entry in _openSheets.entries) {
      if (!live.contains(entry.key) && !entry.value.isCompleted) {
        entry.value.complete();
      }
    }
  }

  @override
  void dispose() {
    for (final withdrawn in _openSheets.values) {
      if (!withdrawn.isCompleted) withdrawn.complete();
    }
    super.dispose();
  }

  Future<bool> _resolve(String key, Future<void> Function() action) async {
    if (_resolving.contains(key)) return false;
    setState(() => _resolving.add(key));
    try {
      await action();
      unawaited(HapticFeedback.selectionClick());
      return true;
    } on Object {
      _showMessage('The agent is no longer waiting for this request.');
      return false;
    } finally {
      if (mounted) setState(() => _resolving.remove(key));
    }
  }

  Future<void> _review(AcpSessionElicitation item) async {
    final key = item.requestKey;
    if (_resolving.contains(key) || _openSheets.containsKey(key)) return;
    final withdrawn = _openSheets[key] = Completer<void>();
    try {
      switch (item.request) {
        case final AcpFormElicitation form:
          final outcome = await showAcpElicitationFormSheet(
            context,
            agentLabel: widget.agentLabel,
            request: form,
            withdrawn: withdrawn.future,
          );
          if (withdrawn.isCompleted || !mounted) return;
          await switch (outcome) {
            AcpElicitationFormSubmitted(:final content) => _resolve(
              key,
              () => widget.onAccept(key, content),
            ),
            AcpElicitationFormDeclined() => _resolve(
              key,
              () => widget.onDecline(key),
            ),
            null => _resolve(key, () => widget.onCancel(key)),
          };
        case final AcpUrlElicitation link:
          final outcome = await showAcpElicitationUrlSheet(
            context,
            agentLabel: widget.agentLabel,
            request: link,
            withdrawn: withdrawn.future,
          );
          if (withdrawn.isCompleted || !mounted) return;
          switch (outcome) {
            case AcpElicitationUrlOutcome.open:
              // Consent is sent first; the page opens only once it is.
              if (await _resolve(key, () => widget.onAccept(key, null))) {
                await _open(link.url);
              }
            case AcpElicitationUrlOutcome.decline:
              await _resolve(key, () => widget.onDecline(key));
            case null:
              await _resolve(key, () => widget.onCancel(key));
          }
      }
    } finally {
      _openSheets.remove(key);
    }
  }

  Future<void> _open(String url) async {
    final review = AcpElicitationUrlReview.of(url);
    final uri = review.uri;
    var opened = false;
    if (review.canOpen && uri != null) {
      try {
        opened = await widget.onOpenUrl(uri);
      } on Object {
        opened = false;
      }
    }
    if (!opened) {
      _showMessage('Couldn’t open your browser. Tap Reopen to try again.');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.elicitations.isEmpty && widget.awaiting.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final awaiting in widget.awaiting)
          Padding(
            key: ValueKey('elicitation-awaiting:${awaiting.elicitationId}'),
            padding: const EdgeInsets.only(bottom: FluttyTheme.spacingSm),
            child: _AwaitingCard(
              awaiting: awaiting,
              onOpenAgain: () => _open(awaiting.url),
              onDismiss: () => widget.onDismissAwaiting(awaiting.elicitationId),
            ),
          ),
        for (final item in widget.elicitations)
          Padding(
            key: ValueKey('elicitation:${item.requestKey}'),
            padding: const EdgeInsets.only(bottom: FluttyTheme.spacingSm),
            child: _ElicitationCard(
              agentLabel: widget.agentLabel,
              item: item,
              toolTitle: switch (item.request.scope.toolCallId) {
                final id? => widget.toolTitles[id],
                null => null,
              },
              busy: _resolving.contains(item.requestKey),
              onReview: () => _review(item),
              onDecline: () => _resolve(
                item.requestKey,
                () => widget.onDecline(item.requestKey),
              ),
              onDismiss: () => _resolve(
                item.requestKey,
                () => widget.onCancel(item.requestKey),
              ),
            ),
          ),
      ],
    );
  }
}

class _CardFrame extends StatelessWidget {
  const _CardFrame({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      liveRegion: true,
      label: label,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(FluttyTheme.radiusMd),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Padding(padding: const EdgeInsets.all(12), child: child),
      ),
    );
  }
}

class _ElicitationCard extends StatelessWidget {
  const _ElicitationCard({
    required this.agentLabel,
    required this.item,
    required this.toolTitle,
    required this.busy,
    required this.onReview,
    required this.onDecline,
    required this.onDismiss,
  });

  final String agentLabel;
  final AcpSessionElicitation item;
  final String? toolTitle;
  final bool busy;
  final VoidCallback onReview;
  final VoidCallback onDecline;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final request = item.request;
    final link = request is AcpUrlElicitation ? request : null;
    final review = link?.review;
    final title = link == null
        ? '$agentLabel needs your input'
        : '$agentLabel wants you to open a page';
    final mono = AcpChatTypography.monoStyleOf(context)
        .copyWith(color: scheme.onSurfaceVariant, fontSize: 12);
    final caution =
        review != null && (!review.canOpen || review.needsAcknowledgement);
    final detail = switch (review) {
      final review? => review.host.isEmpty ? link!.url : review.host,
      null => toolTitle,
    };
    return _CardFrame(
      label: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                link == null ? Icons.assignment_outlined : Icons.link,
                size: 20,
                color: scheme.primary,
              ),
              const SizedBox(width: FluttyTheme.spacingSm),
              Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
            ],
          ),
          if (request.message.trim().isNotEmpty) ...[
            const SizedBox(height: FluttyTheme.spacingXs),
            Text(
              request.message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          if (detail != null && detail.isNotEmpty) ...[
            const SizedBox(height: FluttyTheme.spacingXs),
            Row(
              children: [
                if (caution) ...[
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 14,
                    color: scheme.tertiary,
                    semanticLabel: 'Check this address',
                  ),
                  const SizedBox(width: FluttyTheme.spacingXs),
                ],
                Expanded(
                  child: Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: mono,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: FluttyTheme.spacingSm),
          Wrap(
            spacing: FluttyTheme.spacingSm,
            runSpacing: FluttyTheme.spacingXs,
            children: [
              FilledButton(
                onPressed: busy ? null : onReview,
                child: Text(link == null ? 'Respond' : 'Review link'),
              ),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: scheme.error),
                onPressed: busy ? null : onDecline,
                child: const Text('Decline'),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: scheme.onSurfaceVariant,
                ),
                onPressed: busy ? null : onDismiss,
                child: const Text('Dismiss'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AwaitingCard extends StatelessWidget {
  const _AwaitingCard({
    required this.awaiting,
    required this.onOpenAgain,
    required this.onDismiss,
  });

  final AcpAwaitingElicitation awaiting;
  final VoidCallback onOpenAgain;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final host = awaiting.host;
    return _CardFrame(
      label: 'Waiting for you to finish in your browser',
      child: Row(
        children: [
          SizedBox.square(
            dimension: 20,
            child: Center(child: CursorBlock(color: scheme.primary, size: 10)),
          ),
          const SizedBox(width: FluttyTheme.spacingSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Continue in browser',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                if (host.isNotEmpty)
                  Text(
                    host,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AcpChatTypography.monoStyleOf(context)
                        .copyWith(color: scheme.onSurfaceVariant, fontSize: 12),
                  ),
              ],
            ),
          ),
          TextButton(onPressed: onOpenAgain, child: const Text('Reopen')),
          IconButton(
            tooltip: 'Stop waiting',
            icon: const Icon(Icons.close, size: 20),
            color: scheme.onSurfaceVariant,
            visualDensity: VisualDensity.compact,
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}
