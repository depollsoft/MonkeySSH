import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../domain/models/acp_terminal_display.dart';
import 'acp_chat_typography.dart';
import 'cursor_block.dart';

/// Resolves the live display of a client-run terminal by its ACP id.
typedef AcpTerminalDisplayResolver =
    ValueListenable<AcpTerminalDisplay?> Function(String terminalId);

/// Supplies terminal output to tool calls that embed a terminal.
class AcpTerminalOutputScope extends InheritedWidget {
  /// Creates a terminal output scope.
  const AcpTerminalOutputScope({
    required this.resolver,
    required super.child,
    super.key,
  });

  /// Looks up a terminal's live display.
  final AcpTerminalDisplayResolver resolver;

  /// Returns the nearest scope, if any.
  static AcpTerminalOutputScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AcpTerminalOutputScope>();

  @override
  bool updateShouldNotify(AcpTerminalOutputScope oldWidget) =>
      resolver != oldWidget.resolver;
}

final _escapeSequence = RegExp(
  // OSC ... BEL/ST, CSI ... final byte, then any other two-byte escape.
  '\x1B\\][^\x07\x1B]*(?:\x07|\x1B\\\\)|\x1B\\[[0-?]*[ -/]*[@-~]|\x1B[@-Z\\\\-_]',
);

/// Converts raw terminal output to plain text for display.
///
/// Strips ANSI escape sequences and resolves carriage-return overwrites
/// (progress bars redraw a line with `\r`) so each line shows its final state.
String acpPlainTerminalText(String raw) {
  final withoutEscapes = raw.replaceAll(_escapeSequence, '');
  final lines = withoutEscapes.replaceAll('\r\n', '\n').split('\n');
  for (var index = 0; index < lines.length; index++) {
    // A trailing `\r` only returns the cursor; text after an earlier `\r`
    // replaced what came before it on the same line.
    var line = lines[index];
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    final overwrite = line.lastIndexOf('\r');
    lines[index] = overwrite >= 0 ? line.substring(overwrite + 1) : line;
  }
  return lines.join('\n');
}

/// Shows a client-run terminal's command, live output, and exit status.
///
/// Renders nothing until the terminal is known to this client, so a tool
/// replayed from an earlier app run keeps its other details only.
class AcpTerminalOutputView extends StatefulWidget {
  /// Creates a terminal output view.
  const AcpTerminalOutputView({required this.display, super.key});

  /// The live display to render.
  final ValueListenable<AcpTerminalDisplay?> display;

  @override
  State<AcpTerminalOutputView> createState() => _AcpTerminalOutputViewState();
}

class _AcpTerminalOutputViewState extends State<AcpTerminalOutputView> {
  final _scroll = ScrollController();
  var _followTail = true;

  @override
  void initState() {
    super.initState();
    widget.display.addListener(_onDisplayChanged);
  }

  @override
  void didUpdateWidget(covariant AcpTerminalOutputView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.display != widget.display) {
      oldWidget.display.removeListener(_onDisplayChanged);
      widget.display.addListener(_onDisplayChanged);
    }
  }

  @override
  void dispose() {
    widget.display.removeListener(_onDisplayChanged);
    _scroll.dispose();
    super.dispose();
  }

  void _onDisplayChanged() {
    if (!mounted) return;
    setState(() {});
    if (_followTail) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification is UserScrollNotification ||
        notification is ScrollEndNotification) {
      final metrics = notification.metrics;
      _followTail = metrics.pixels >= metrics.maxScrollExtent - 8;
    }
    return false;
  }

  /// Exit state as an icon and mono label, or `null` while it runs: the live
  /// cursor already says that.
  ({IconData icon, String label, bool failed})? _exitStatus(
    AcpTerminalDisplay display,
  ) {
    if (!display.exited) {
      return display.released
          ? (icon: Icons.stop_circle_outlined, label: 'stopped', failed: false)
          : null;
    }
    final signal = display.signal;
    if (signal != null && signal.isNotEmpty) {
      return (
        icon: Icons.cancel_outlined,
        label: 'signal $signal',
        failed: true,
      );
    }
    final code = display.exitCode;
    if (code == null) {
      return (icon: Icons.stop_circle_outlined, label: 'exited', failed: false);
    }
    return code == 0
        ? (icon: Icons.check_rounded, label: 'exit 0', failed: false)
        : (icon: Icons.error_outline, label: 'exit $code', failed: true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mono = AcpChatTypography.monoStyleOf(context);
    final display = widget.display.value;
    if (display == null) {
      // A terminal from before the app reconnected: say so instead of
      // expanding onto nothing.
      return Row(
        children: [
          Icon(
            Icons.terminal_rounded,
            size: 14,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Terminal output is no longer available',
              style: mono.copyWith(
                fontSize: 11.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      );
    }
    final output = acpPlainTerminalText(display.output).trimRight();
    final running = !display.exited && !display.released;
    final exit = _exitStatus(display);
    final exitColor = exit != null && exit.failed
        ? scheme.error
        : scheme.onSurfaceVariant;
    final outputStyle = mono.copyWith(
      fontSize: 11.5,
      height: 1.35,
      color: scheme.onSurface,
    );
    return Semantics(
      container: true,
      label: 'Terminal output, ${exit?.label ?? 'running'}',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      '\$ ${display.command}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: outputStyle.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (exit != null) ...[
                    const SizedBox(width: FluttyTheme.spacingSm),
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(exit.icon, size: 13, color: exitColor),
                    ),
                    const SizedBox(width: 3),
                    Text(
                      exit.label,
                      style: mono.copyWith(fontSize: 11, color: exitColor),
                    ),
                  ],
                ],
              ),
              if (output.isNotEmpty || running) ...[
                const SizedBox(height: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _onScroll,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (output.isNotEmpty)
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: SelectableText(
                                display.truncated ? '…\n$output' : output,
                                style: outputStyle,
                              ),
                            ),
                          // A live command parks the cursor on the next line,
                          // the way the shell it runs in would.
                          if (running)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: CursorBlock(
                                color: scheme.onSurfaceVariant,
                                size: 11.5,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
