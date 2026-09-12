import 'dart:math' as math;

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

/// Static, top/bottom usage arcs with small gaps at 3 and 9 o'clock.
/// A dashed half means unreported; an empty continuous track means zero.
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
    String value(double? remaining) => remaining == null
        ? 'not reported'
        : '${remaining.round()} percent remaining';
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: '$agentLabel account allowance',
      value:
          '5-hour: ${value(rings.shortTerm)}; weekly: ${value(rings.weekly)}',
      child: SizedBox.square(
        dimension: diameter,
        child: CustomPaint(
          key: const ValueKey('split-usage-ring'),
          painter: _SplitUsageRingPainter(
            rings: rings,
            primary: _readableColor(scheme.primary, scheme),
            secondary: _readableColor(scheme.onSurfaceVariant, scheme),
            warning: _readableColor(scheme.tertiary, scheme),
            track: scheme.outlineVariant,
            unknown: _readableColor(
              Color.lerp(
                scheme.surfaceContainerHighest,
                scheme.onSurfaceVariant,
                0.5,
              )!,
              scheme,
            ),
          ),
          child: Center(child: child),
        ),
      ),
    );
  }
}

Color _readableColor(Color color, ColorScheme scheme) {
  double contrast(Color a, Color b) {
    final x = a.computeLuminance();
    final y = b.computeLuminance();
    return (math.max(x, y) + .05) / (math.min(x, y) + .05);
  }

  for (var step = 0; step <= 20; step++) {
    final candidate = Color.lerp(color, scheme.onSurface, step / 20)!;
    if (contrast(candidate, scheme.surface) >= 4.5 &&
        contrast(candidate, scheme.surfaceContainerHighest) >= 4.5) {
      return candidate;
    }
  }
  return scheme.onSurface;
}

class _SplitUsageRingPainter extends CustomPainter {
  const _SplitUsageRingPainter({
    required this.rings,
    required this.primary,
    required this.secondary,
    required this.warning,
    required this.track,
    required this.unknown,
  });
  final AgentUsageRings rings;
  final Color primary;
  final Color secondary;
  final Color warning;
  final Color track;
  final Color unknown;

  @override
  void paint(Canvas canvas, Size size) {
    const gap = math.pi / 22.5;
    const sweep = math.pi - 2 * gap;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: size.shortestSide / 2 - 1,
    );
    void half(double start, double? remaining, Color color) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..color = track;
      if (remaining == null) {
        // Missing data must not look exhausted, and must not borrow a scoped
        // model bucket. Six short dashes carry no numerical fill value.
        const count = 6;
        const step = sweep / count;
        const dash = step * 0.35;
        paint
          ..color = unknown
          ..strokeWidth = 1.2;
        for (var index = 0; index < count; index++) {
          canvas.drawArc(
            rect,
            start + index * step + (step - dash) / 2,
            dash,
            false,
            paint,
          );
        }
        return;
      }
      canvas.drawArc(rect, start, sweep, false, paint);
      if (remaining <= 0) return;
      paint.color = remaining <= 15 ? warning : color;
      canvas.drawArc(
        rect,
        start,
        sweep * (remaining / 100).clamp(0, 1),
        false,
        paint,
      );
    }

    half(-math.pi + gap, rings.shortTerm, primary);
    half(gap, rings.weekly, secondary);
  }

  @override
  bool shouldRepaint(_SplitUsageRingPainter oldDelegate) =>
      rings.shortTerm != oldDelegate.rings.shortTerm ||
      rings.weekly != oldDelegate.rings.weekly ||
      primary != oldDelegate.primary ||
      secondary != oldDelegate.secondary ||
      warning != oldDelegate.warning ||
      track != oldDelegate.track ||
      unknown != oldDelegate.unknown;
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
