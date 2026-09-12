import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/agent_launch_preset.dart';
import '../../domain/models/agent_usage_rings.dart';
import '../../domain/services/ssh_service.dart';
import '../providers/agent_usage_rings_provider.dart';
import 'agent_tool_icon.dart';

/// Adds read-only account rings while the current MonkeyMux handle is visible.
/// Contains no gesture recognizer: window navigation belongs to the parent bar.
class AgentUsageRingIcon extends ConsumerStatefulWidget {
  /// Wraps the unchanged agent identity and optional native-chat badge.
  const AgentUsageRingIcon({
    required this.session,
    required this.tool,
    required this.child,
    this.diameter = 28,
    super.key,
  });

  /// Current SSH session.
  final SshSession session;

  /// Current foreground agent.
  final AgentLaunchTool tool;

  /// Existing agent mark, including any native badge.
  final Widget child;

  /// Native badges need slightly more clearance than a plain 16dp mark.
  final double diameter;

  @override
  ConsumerState<AgentUsageRingIcon> createState() => _AgentUsageRingIconState();
}

class _AgentUsageRingIconState extends ConsumerState<AgentUsageRingIcon>
    with WidgetsBindingObserver {
  bool _foreground =
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground != foreground) setState(() => _foreground = foreground);
  }

  @override
  Widget build(BuildContext context) {
    if (!_foreground ||
        !TickerMode.valuesOf(context).enabled ||
        ModalRoute.isCurrentOf(context) == false ||
        !supportsAgentUsageRings(widget.tool) ||
        !ref.watch(agentUsageRingsEnabledProvider) ||
        ref.watch(
              activeSessionsProvider.select(
                (states) => states[widget.session.connectionId],
              ),
            ) !=
            SshConnectionState.connected) {
      return widget.child;
    }
    final rings = ref
        .watch(
          agentUsageRingsProvider((session: widget.session, tool: widget.tool)),
        )
        .asData
        ?.value;
    if (rings == null) return widget.child;
    return SplitUsageRing(
      rings: rings,
      agentLabel: widget.tool.label,
      diameter: widget.diameter,
      child: widget.child,
    );
  }
}

/// Remaining-allowance meter: one quota uses the whole circle, two use halves,
/// and additional reported groups use equal segments. Unknown is never zero.
class SplitUsageRing extends StatelessWidget {
  /// Creates a non-interactive ring around an existing icon.
  const SplitUsageRing({
    required this.rings,
    required this.agentLabel,
    required this.child,
    this.diameter = 28,
    super.key,
  });

  /// Account-wide percentages remaining.
  final AgentUsageRings rings;

  /// Accessible agent identity, never a user-provided account name.
  final String agentLabel;

  /// Unchanged mark at the center.
  final Widget child;

  /// Outer size, including stroke clearance.
  final double diameter;

  @override
  Widget build(BuildContext context) {
    if (!rings.isAvailable) return child;
    String value(double remaining) => '${remaining.round()} percent remaining';
    final values = [
      for (final segment in rings.segments)
        '${segment.label}: ${value(segment.remaining)}',
    ];
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: '$agentLabel account allowance',
      value: values.join('; '),
      child: SizedBox.square(
        dimension: diameter,
        child: CustomPaint(
          key: const ValueKey('split-usage-ring'),
          painter: _SplitUsageRingPainter(
            rings: rings,
            primary: _readableColor(scheme.primary, scheme),
            secondary: _readableColor(scheme.onSurfaceVariant, scheme),
            warning: _readableColor(scheme.tertiary, scheme),
            track: _readableColor(
              scheme.surfaceContainerHighest,
              scheme,
              minContrast: 3,
            ),
          ),
          child: Center(child: child),
        ),
      ),
    );
  }
}

Color _readableColor(
  Color color,
  ColorScheme scheme, {
  double minContrast = 4.5,
}) {
  double contrast(Color a, Color b) {
    final x = a.computeLuminance();
    final y = b.computeLuminance();
    return (math.max(x, y) + .05) / (math.min(x, y) + .05);
  }

  // Default light-theme ink is translucent black87. Composite it before
  // measuring contrast; raw RGB luminance ignores alpha.
  final background = Color.alphaBlend(
    scheme.surfaceContainerHighest,
    scheme.surface,
  );
  final start = Color.alphaBlend(color, background);
  final foreground = Color.alphaBlend(scheme.onSurface, background);
  for (var step = 0; step <= 20; step++) {
    final candidate = Color.lerp(start, foreground, step / 20)!;
    if (contrast(candidate, scheme.surface) >= minContrast &&
        contrast(candidate, background) >= minContrast) {
      return candidate;
    }
  }
  return foreground;
}

class _SplitUsageRingPainter extends CustomPainter {
  const _SplitUsageRingPainter({
    required this.rings,
    required this.primary,
    required this.secondary,
    required this.warning,
    required this.track,
  });
  final AgentUsageRings rings;
  final Color primary;
  final Color secondary;
  final Color warning;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: size.shortestSide / 2 - 1,
    );
    void meter(double start, double sweep, double remaining, Color color) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..strokeCap = StrokeCap.round
        ..color = track;
      canvas.drawArc(rect, start, sweep, false, paint);
      if (remaining <= 0) return;
      // A thin neutral capacity track stays visible at zero. Remaining quota
      // is distinguished by both color and a heavier stroke, not color alone.
      paint
        ..color = remaining <= 15 ? warning : color
        ..strokeWidth = 1.8;
      canvas.drawArc(
        rect,
        start,
        sweep * (remaining / 100).clamp(0, 1),
        false,
        paint,
      );
    }

    final segments = rings.segments;
    if (segments.length == 1) {
      meter(-math.pi / 2, math.pi * 2, segments.single.remaining, primary);
    } else if (segments.isNotEmpty) {
      final span = math.pi * 2 / segments.length;
      final gap = math.min(math.pi / 22.5, span * 0.06);
      // Keep the established top/bottom layout for two quotas.
      final origin = segments.length == 2 ? -math.pi : -math.pi / 2;
      for (var index = 0; index < segments.length; index++) {
        meter(
          origin + index * span + gap,
          span - 2 * gap,
          segments[index].remaining,
          index.isEven ? primary : secondary,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_SplitUsageRingPainter oldDelegate) =>
      !listEquals(rings.segments, oldDelegate.rings.segments) ||
      primary != oldDelegate.primary ||
      secondary != oldDelegate.secondary ||
      warning != oldDelegate.warning ||
      track != oldDelegate.track;
}

/// Isolated preview; no SSH reads or entitlement checks are performed.
@Preview(name: 'Split usage rings', size: Size(160, 64))
Widget splitUsageRingPreview() => const MaterialApp(
  home: Scaffold(
    body: Center(
      child: SplitUsageRing(
        rings: AgentUsageRings(shortTerm: 12, weekly: 64),
        agentLabel: 'Claude Code',
        child: AgentToolIcon(tool: AgentLaunchTool.claudeCode, size: 16),
      ),
    ),
  ),
);
