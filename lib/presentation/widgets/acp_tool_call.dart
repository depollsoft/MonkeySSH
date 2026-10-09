import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../app/theme.dart';
import '../models/acp_timeline.dart';
import 'acp_audio_player.dart';
import 'acp_chat_typography.dart';
import 'acp_diff.dart';
import 'acp_inline_image.dart';
import 'acp_markdown.dart';
import 'acp_markdown_paths.dart';
import 'acp_path_text.dart';
import 'acp_resource_chip.dart';
import 'acp_terminal_output.dart';

final _whitespaceRun = RegExp(r'\s+');
final _fenceLine = RegExp('^```', multiLine: true);
final _headingLine = RegExp(r'^#{1,6}\s', multiLine: true);
final _quoteLine = RegExp(r'^>\s', multiLine: true);
final _listLine = RegExp(r'^\s*(?:[-*+]|\d+\.)\s+', multiLine: true);
final _inlineLink = RegExp(r'\[[^\]]+\]\([^)]+\)');
final _inlineCode = RegExp('`[^`]+`');
final _tableLine = RegExp(r'^\|.+\|$', multiLine: true);

/// Whether a call's raw output renders as Markdown, decided once per call.
final _richOutputCache = Expando<bool>('ACP rich tool output');

/// Presentation helpers for [AcpToolStatus].
extension AcpToolStatusPresentation on AcpToolStatus {
  /// Short human-readable label for the status.
  String get label => switch (this) {
    AcpToolStatus.pending => 'Pending',
    AcpToolStatus.running => 'Running',
    AcpToolStatus.completed => 'Completed',
    AcpToolStatus.failed => 'Failed',
    AcpToolStatus.cancelled => 'Cancelled',
  };
}

/// Presentation helpers for [AcpToolKind].
extension AcpToolKindPresentation on AcpToolKind {
  /// Icon representing the tool kind.
  IconData get icon => switch (this) {
    AcpToolKind.read => Icons.description_outlined,
    AcpToolKind.edit => Icons.edit_outlined,
    AcpToolKind.delete => Icons.delete_outline,
    AcpToolKind.move => Icons.drive_file_move_outlined,
    AcpToolKind.search => Icons.search,
    AcpToolKind.execute => Icons.terminal_rounded,
    AcpToolKind.fetch => Icons.cloud_download_outlined,
    AcpToolKind.think => Icons.psychology_outlined,
    AcpToolKind.switchMode => Icons.swap_horiz_rounded,
    AcpToolKind.other => Icons.build_outlined,
  };
}

/// Renders a single tool call as a compact, expandable status row.
///
/// The row shows a kind icon, title, and a status badge conveyed with both an
/// icon and text (never colour alone). Active calls expand automatically so
/// YAML-like input and result updates remain visible, then collapse
/// independently when each call reaches a terminal state. Completed details
/// remain available
/// on tap.
class AcpToolCallView extends StatefulWidget {
  /// Creates a tool call view.
  const AcpToolCallView({
    required this.toolCall,
    super.key,
    this.initiallyExpanded = false,
    this.onOpenLocation,
    this.onTapLink,
  });

  /// The merged tool call state to render.
  final AcpToolCall toolCall;

  /// Whether the detail section is expanded initially.
  ///
  /// Turning it on after the view is built expands the details too, which is
  /// how transcript search reveals a match inside them.
  final bool initiallyExpanded;

  /// Called when a file location is tapped.
  final ValueChanged<AcpToolLocation>? onOpenLocation;

  /// Handles links and detected paths in rich tool results.
  final MarkdownTapLinkCallback? onTapLink;

  @override
  State<AcpToolCallView> createState() => _AcpToolCallViewState();
}

class _AcpToolCallViewState extends State<AcpToolCallView> {
  late bool _expanded = widget.initiallyExpanded || _isActive(widget.toolCall);
  late String? _headerPreview = _buildHeaderPreview();

  static bool _isActive(AcpToolCall call) =>
      call.status == AcpToolStatus.pending ||
      call.status == AcpToolStatus.running;

  @override
  void didUpdateWidget(covariant AcpToolCallView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasActive = _isActive(oldWidget.toolCall);
    final isActive = _isActive(widget.toolCall);
    if (wasActive != isActive) {
      _expanded = isActive;
    }
    if (widget.initiallyExpanded && !oldWidget.initiallyExpanded) {
      _expanded = true;
    }
    if (!identical(oldWidget.toolCall, widget.toolCall)) {
      _headerPreview = _buildHeaderPreview();
    }
  }

  bool get _hasDetails {
    final call = widget.toolCall;
    return _isActive(call) ||
        (call.rawInput?.isNotEmpty ?? false) ||
        (call.rawOutput?.isNotEmpty ?? false) ||
        call.locations.isNotEmpty ||
        call.diffs.isNotEmpty ||
        call.resources.isNotEmpty ||
        call.terminalIds.isNotEmpty;
  }

  String? _buildHeaderPreview() {
    final call = widget.toolCall;
    if (call.locations.isNotEmpty) {
      final location = call.locations.first;
      return location.line == null
          ? location.path
          : '${location.path}:${location.line}';
    }
    final input = call.rawInput?.trim();
    if (input == null || input.isEmpty) {
      final name = call.name?.trim();
      return name == null || name.isEmpty || name == call.title ? null : name;
    }
    final line = input.split('\n').firstWhere((line) => line.trim().isNotEmpty);
    final compact = line.trim().replaceAll(_whitespaceRun, ' ');
    return compact.length <= 96 ? compact : '${compact.substring(0, 95)}…';
  }

  ({IconData icon, Color color, bool spinning}) _statusVisual(
    ColorScheme scheme,
  ) => switch (widget.toolCall.status) {
    AcpToolStatus.pending => (
      icon: Icons.schedule,
      color: scheme.onSurfaceVariant,
      spinning: false,
    ),
    AcpToolStatus.running => (
      icon: Icons.sync,
      color: scheme.primary,
      spinning: true,
    ),
    AcpToolStatus.completed => (
      icon: Icons.check_circle_outline,
      color: scheme.primary,
      spinning: false,
    ),
    AcpToolStatus.failed => (
      icon: Icons.error_outline,
      color: scheme.error,
      spinning: false,
    ),
    AcpToolStatus.cancelled => (
      icon: Icons.cancel_outlined,
      color: scheme.onSurfaceVariant,
      spinning: false,
    ),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final call = widget.toolCall;
    final status = call.status;
    final visual = _statusVisual(scheme);
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    final header = InkWell(
      onTap: _hasDetails ? () => setState(() => _expanded = !_expanded) : null,
      borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FluttyTheme.spacingSm,
            vertical: FluttyTheme.spacingXs,
          ),
          child: Row(
            children: [
              Icon(call.kind.icon, size: 17, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      call.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AcpChatTypography.monoStyleOf(context).copyWith(
                        color: scheme.onSurface,
                        fontSize: 12.5,
                        height: 1.15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (_headerPreview case final preview?)
                      Text(
                        preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AcpChatTypography.monoStyleOf(context).copyWith(
                          color: scheme.onSurfaceVariant,
                          fontSize: 10.5,
                          height: 1.15,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              _StatusBadge(
                icon: visual.icon,
                color: visual.color,
                label: status.label,
                spinning: visual.spinning && !reduceMotion,
              ),
              if (_hasDetails)
                Padding(
                  padding: const EdgeInsets.only(left: FluttyTheme.spacingXs),
                  child: Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    final imageActions = AcpImageActions.maybeOf(context);
    return Semantics(
      container: true,
      label: '${call.title}, ${status.label}',
      value: _hasDetails ? (_expanded ? 'expanded' : 'collapsed') : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          header,
          if (call.images.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                FluttyTheme.spacingSm,
                0,
                FluttyTheme.spacingSm,
                FluttyTheme.spacingSm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var index = 0; index < call.images.length; index++) ...[
                    if (index > 0)
                      const SizedBox(height: FluttyTheme.spacingSm),
                    AcpInlineImage(
                      image: call.images[index],
                      resolver: imageActions?.resolver,
                      onTap: imageActions?.onTap,
                    ),
                  ],
                ],
              ),
            ),
          if (call.audio.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                FluttyTheme.spacingSm,
                0,
                FluttyTheme.spacingSm,
                FluttyTheme.spacingSm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var index = 0; index < call.audio.length; index++) ...[
                    if (index > 0)
                      const SizedBox(height: FluttyTheme.spacingSm),
                    AcpAudioPlayer(clip: call.audio[index]),
                  ],
                ],
              ),
            ),
          if (_expanded && _hasDetails)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                FluttyTheme.spacingSm,
                0,
                FluttyTheme.spacingSm,
                6,
              ),
              child: _ToolCallDetails(
                toolCall: call,
                onOpenLocation: widget.onOpenLocation,
                onTapLink: widget.onTapLink,
              ),
            ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.icon,
    required this.color,
    required this.label,
    required this.spinning,
  });

  final IconData icon;
  final Color color;
  final String label;
  final bool spinning;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (spinning)
        SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: color),
        )
      else
        Icon(icon, size: 14, color: color),
      const SizedBox(width: 2),
      Text(
        label,
        style: AcpChatTypography.monoStyleOf(context)
            .copyWith(fontSize: 11, color: color),
      ),
    ],
  );
}

class _ToolCallDetails extends StatelessWidget {
  const _ToolCallDetails({
    required this.toolCall,
    this.onOpenLocation,
    this.onTapLink,
  });

  final AcpToolCall toolCall;
  final ValueChanged<AcpToolLocation>? onOpenLocation;
  final MarkdownTapLinkCallback? onTapLink;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    final input = toolCall.rawInput;
    final output = toolCall.rawOutput;
    final active =
        toolCall.status == AcpToolStatus.pending ||
        toolCall.status == AcpToolStatus.running;
    final hasOutput = output?.isNotEmpty ?? false;
    final richOutput =
        hasOutput &&
        !toolCall.rawOutputIsStructured &&
        (_richOutputCache[toolCall] ??= _looksLikeRichToolOutput(output!));
    final terminals = AcpTerminalOutputScope.maybeOf(context);
    final showsTerminals = terminals != null && toolCall.terminalIds.isNotEmpty;
    if ((input?.isNotEmpty ?? false) ||
        (hasOutput && !richOutput) ||
        (active && !hasOutput && !showsTerminals)) {
      children.add(
        _ToolPayloadStream(
          input: input,
          output: richOutput ? null : output,
          active: active && !showsTerminals,
          onTapLink: onTapLink,
        ),
      );
    }
    if (showsTerminals) {
      for (final terminalId in toolCall.terminalIds) {
        children.add(
          AcpTerminalOutputView(
            key: ValueKey('terminal-$terminalId'),
            display: terminals.resolver(terminalId),
          ),
        );
      }
      if (toolCall.omittedTerminalCount > 0) {
        final count = toolCall.omittedTerminalCount;
        children.add(
          Text(
            '$count more ${count == 1 ? 'terminal' : 'terminals'} not shown',
            style: AcpChatTypography.monoStyleOf(context).copyWith(
              fontSize: 11.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        );
      }
    }
    if (richOutput) {
      final markdown = output!;
      children.add(
        _RichToolResult(
          onTapLink: onTapLink,
          markdown: active
              ? _ToolPayloadStream._boundedLiveValue(
                  markdown,
                  keepTail: !markdown.contains('```'),
                )
              : markdown,
        ),
      );
    }
    if (toolCall.locations.isNotEmpty) {
      children.add(
        _LocationsSection(
          locations: toolCall.locations,
          onOpenLocation: onOpenLocation,
        ),
      );
    }
    for (final diff in toolCall.diffs) {
      children.add(AcpDiffView(diff: diff));
    }
    if (toolCall.resources.isNotEmpty) {
      final actions = AcpResourceActions.maybeOf(context);
      children.add(
        Wrap(
          spacing: FluttyTheme.spacingXs,
          runSpacing: FluttyTheme.spacingXs,
          children: [
            for (final resource in toolCall.resources)
              AcpResourceChip(
                resource: resource,
                onOpen: actions?.onOpen,
                onCopy: actions?.onCopy,
              ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          children[i],
        ],
      ],
    );
  }
}

bool _looksLikeRichToolOutput(String value) {
  // Markdown syntax shows up early; the live view is bounded to 4 KiB anyway.
  const probeChars = 8192;
  final text = value.length > probeChars
      ? value.substring(0, probeChars).trimLeft()
      : value.trimLeft();
  return _fenceLine.hasMatch(text) ||
      _headingLine.hasMatch(text) ||
      _quoteLine.hasMatch(text) ||
      _listLine.hasMatch(text) ||
      _inlineLink.hasMatch(text) ||
      _inlineCode.hasMatch(text) ||
      text.contains('**') ||
      _tableLine.hasMatch(text);
}

class _RichToolResult extends StatelessWidget {
  const _RichToolResult({required this.markdown, this.onTapLink});

  final String markdown;
  final MarkdownTapLinkCallback? onTapLink;

  @override
  Widget build(BuildContext context) {
    final imageActions = AcpImageActions.maybeOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'result',
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 2),
        AcpMarkdown(
          data: markdown,
          onTapLink: onTapLink,
          machineContent: true,
          imageResolver: imageActions?.resolver,
          onTapImage: imageActions?.onTap,
        ),
      ],
    );
  }
}

class _ToolPayloadStream extends StatefulWidget {
  const _ToolPayloadStream({
    required this.input,
    required this.output,
    required this.active,
    this.onTapLink,
  });

  final String? input;
  final String? output;
  final bool active;
  final MarkdownTapLinkCallback? onTapLink;

  @override
  State<_ToolPayloadStream> createState() => _ToolPayloadStreamState();

  String get _text {
    final sections = <String>[];
    final input = this.input;
    if (input != null && input.isNotEmpty) {
      sections.add(
        _section(
          'input',
          active ? _boundedLiveValue(input, keepTail: false) : input,
        ),
      );
    }
    final output = this.output;
    if (output != null && output.isNotEmpty) {
      sections.add(
        _section(
          'result',
          active ? _boundedLiveValue(output, keepTail: true) : output,
        ),
      );
    } else if (active) {
      sections.add('result: …');
    }
    return sections.join('\n');
  }

  static String _boundedLiveValue(String value, {required bool keepTail}) {
    const maxChars = 4096;
    const maxLines = 48;
    var bounded = value;
    var clipped = false;
    if (bounded.length > maxChars) {
      bounded = keepTail
          ? bounded.substring(bounded.length - maxChars)
          : bounded.substring(0, maxChars);
      clipped = true;
    }
    final lines = bounded.split('\n');
    if (lines.length > maxLines) {
      bounded =
          (keepTail
                  ? lines.sublist(lines.length - maxLines)
                  : lines.sublist(0, maxLines))
              .join('\n');
      clipped = true;
    }
    if (!clipped) return bounded;
    return keepTail ? '…\n$bounded' : '$bounded\n…';
  }

  static String _section(String label, String value) {
    final indented = value.split('\n').map((line) => '  $line').join('\n');
    return '$label:\n$indented';
  }
}

class _ToolPayloadStreamState extends State<_ToolPayloadStream> {
  // The indented payload is re-derived only when the payload itself changes,
  // not on every thread rebuild while a long-running call streams.
  late String _text = widget._text;

  @override
  void didUpdateWidget(_ToolPayloadStream oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.input != widget.input ||
        oldWidget.output != widget.output ||
        oldWidget.active != widget.active) {
      _text = widget._text;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: AcpPathText(
            text: _text,
            onTapPath: acpPathTapHandler(widget.onTapLink),
            style: AcpChatTypography.monoStyleOf(
              context,
            ).copyWith(fontSize: 11.5, color: scheme.onSurface, height: 1.35),
          ),
        ),
      ),
    );
  }
}

class _LocationsSection extends StatelessWidget {
  const _LocationsSection({required this.locations, this.onOpenLocation});

  final List<AcpToolLocation> locations;
  final ValueChanged<AcpToolLocation>? onOpenLocation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          locations.length == 1 ? 'Location' : 'Locations',
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: FluttyTheme.spacingXs),
        for (final location in locations)
          _LocationRow(location: location, onOpen: onOpenLocation),
      ],
    );
  }
}

class _LocationRow extends StatelessWidget {
  const _LocationRow({required this.location, this.onOpen});

  final AcpToolLocation location;
  final ValueChanged<AcpToolLocation>? onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final line = location.line;
    final label = line != null ? '${location.path}:$line' : location.path;
    final onOpen = this.onOpen;
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(Icons.chevron_right, size: 14, color: scheme.onSurfaceVariant),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AcpChatTypography.monoStyleOf(context).copyWith(
                fontSize: 12,
                color: onOpen != null ? scheme.primary : scheme.onSurface,
                decoration: onOpen != null ? TextDecoration.underline : null,
                decorationColor: scheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
    return Semantics(
      button: onOpen != null,
      label: 'Location $label',
      child: onOpen == null
          ? content
          : InkWell(
              onTap: () => onOpen(location),
              borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
              child: content,
            ),
    );
  }
}
