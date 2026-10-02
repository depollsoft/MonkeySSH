import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../domain/models/acp_elicitation.dart';
import 'acp_elicitation_sheet_parts.dart';

/// How the user resolved a URL-mode elicitation. A dismissed sheet resolves
/// to `null`, which the caller answers as `cancel`.
enum AcpElicitationUrlOutcome {
  /// The user consented to open the page.
  open,

  /// The user explicitly declined.
  decline,
}

/// Asks for explicit consent before opening [request]'s URL. Nothing is
/// fetched or prefetched. Completing [withdrawn] (the agent cancelled the
/// request) closes the sheet with `null`.
Future<AcpElicitationUrlOutcome?> showAcpElicitationUrlSheet(
  BuildContext context, {
  required String agentLabel,
  required AcpUrlElicitation request,
  Future<void>? withdrawn,
}) => showAcpWithdrawableSheet<AcpElicitationUrlOutcome>(
  context,
  withdrawn: withdrawn,
  builder: (context) =>
      AcpElicitationUrlSheet(agentLabel: agentLabel, request: request),
);

/// The body of the URL-mode consent sheet.
class AcpElicitationUrlSheet extends StatefulWidget {
  /// Creates the sheet body.
  const AcpElicitationUrlSheet({
    required this.agentLabel,
    required this.request,
    super.key,
  });

  /// Display name of the agent asking.
  final String agentLabel;

  /// The URL-mode request.
  final AcpUrlElicitation request;

  @override
  State<AcpElicitationUrlSheet> createState() => _AcpElicitationUrlSheetState();
}

class _AcpElicitationUrlSheetState extends State<AcpElicitationUrlSheet> {
  var _acknowledged = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final review = widget.request.review;
    final needsAck = review.canOpen && review.needsAcknowledgement;
    final canOpen = review.canOpen && (!needsAck || _acknowledged);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.86,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AcpElicitationSheetHeader(
            title: 'Open a page for ${widget.agentLabel}?',
            onDismiss: () => Navigator.of(context).pop(),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(
                FluttyTheme.spacingLg,
                FluttyTheme.spacingXs,
                FluttyTheme.spacingLg,
                FluttyTheme.spacingMd,
              ),
              children: [
                if (widget.request.message.trim().isNotEmpty) ...[
                  Text(
                    widget.request.message,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurface,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: FluttyTheme.spacingMd),
                ],
                AcpElicitationUrlPanel(url: widget.request.url, review: review),
                const SizedBox(height: FluttyTheme.spacingMd),
                ..._warnings(context, review),
                if (needsAck)
                  CheckboxListTile(
                    value: _acknowledged,
                    onChanged: (value) =>
                        setState(() => _acknowledged = value ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    title: Text(
                      'I checked the address and want to open it',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                const SizedBox(height: FluttyTheme.spacingXs),
                const AcpElicitationNotice(
                  icon: Icons.shield_outlined,
                  text:
                      'Opens in your browser. MonkeySSH never loads the page '
                      'or sees what you enter there.',
                ),
              ],
            ),
          ),
          AcpElicitationSheetFooter(
            secondary: TextButton(
              style: TextButton.styleFrom(foregroundColor: scheme.error),
              onPressed: () =>
                  Navigator.of(context).pop(AcpElicitationUrlOutcome.decline),
              child: const Text('Decline'),
            ),
            primary: FilledButton.icon(
              onPressed: canOpen
                  ? () =>
                        Navigator.of(context).pop(AcpElicitationUrlOutcome.open)
                  : null,
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('Open in browser'),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _warnings(BuildContext context, AcpElicitationUrlReview review) {
    final scheme = Theme.of(context).colorScheme;
    Widget warning(String text, {bool blocking = false}) => Padding(
      padding: const EdgeInsets.only(bottom: FluttyTheme.spacingSm),
      child: AcpElicitationNotice(
        icon: blocking ? Icons.block : Icons.warning_amber_rounded,
        iconColor: blocking ? scheme.error : scheme.tertiary,
        color: scheme.onSurface,
        text: text,
      ),
    );
    return [
      if (!review.canOpen)
        warning(
          'MonkeySSH only opens web links that start with https:// or '
          'http://. You can decline this request.',
          blocking: true,
        ),
      if (review.insecure)
        warning(
          'Not encrypted. This page uses http://, so others on the network '
          'could read or change it.',
        ),
      if (review.punycode)
        warning(
          'International address. Punycode (xn--) can imitate a familiar '
          'site, so check every character.',
        ),
      if (review.hasUserInfo)
        warning(
          'The text before “@” is not the site. This link goes to '
          '${review.host}.',
        ),
    ];
  }
}

/// The full target URL with its host called out, set in mono so every
/// character can be checked. Plain text, never a tappable link.
class AcpElicitationUrlPanel extends StatelessWidget {
  /// Creates a URL panel.
  const AcpElicitationUrlPanel({
    required this.url,
    required this.review,
    super.key,
  });

  /// The exact URL from the agent.
  final String url;

  /// Its safety review.
  final AcpElicitationUrlReview review;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final secure = review.canOpen && !review.insecure;
    final host = review.host;
    final muted = FluttyTheme.monoStyle.copyWith(
      color: scheme.onSurfaceVariant,
      height: 1.45,
    );
    final hostAt = _hostOffset(url, review);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(FluttyTheme.radiusMd),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(FluttyTheme.spacingMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  secure ? Icons.lock_outline : Icons.lock_open,
                  size: 18,
                  color: secure ? scheme.onSurfaceVariant : scheme.tertiary,
                  semanticLabel: secure ? 'Encrypted' : 'Not encrypted',
                ),
                const SizedBox(width: FluttyTheme.spacingSm),
                Expanded(
                  child: Text(
                    host.isEmpty ? 'No web address' : host,
                    style: FluttyTheme.displayMono(
                      fontSize: 16,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: FluttyTheme.spacingSm),
            SelectableText.rich(
              TextSpan(
                style: muted,
                children: hostAt < 0
                    ? [TextSpan(text: url)]
                    : [
                        TextSpan(text: url.substring(0, hostAt)),
                        TextSpan(
                          text: host,
                          style: muted.copyWith(
                            color: scheme.onSurface,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        TextSpan(text: url.substring(hostAt + host.length)),
                      ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Where the real host starts in [url], skipping any `user@` prefix that
/// could repeat or imitate it; `-1` when it cannot be located exactly.
int _hostOffset(String url, AcpElicitationUrlReview review) {
  final host = review.host.toLowerCase();
  if (host.isEmpty) return -1;
  final lower = url.toLowerCase();
  final authority = lower.indexOf('//');
  var start = authority < 0 ? 0 : authority + 2;
  if (review.hasUserInfo) {
    final at = lower.indexOf('@', start);
    if (at >= 0) start = at + 1;
  }
  final offset = lower.indexOf(host, start);
  return offset == start ? offset : -1;
}
