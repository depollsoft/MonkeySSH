// Development-only comparison. Illustrative quotas; no SSH or polling.
// flutter run --flavor private -t tool/monkeymux_quota_preview.dart -d <device>
// ignore_for_file: public_member_api_docs
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/presentation/widgets/agent_tool_icon.dart';

enum QuotaTreatment {
  single('Single ring', 'The allowance closest to empty.'),
  doubleRing('Concentric rings', 'Outer: 5 hours. Inner: weekly.'),
  split('Split ring', 'Top: 5 hours. Bottom: weekly.');

  const QuotaTreatment(this.label, this.description);
  final String label;
  final String description;
}

enum QuotaSample {
  healthy('Healthy', 58, 82),
  shortLow('5h low', 12, 64),
  weekLow('Week low', 72, 8),
  empty('Exhausted', 0, 64),
  unknown('Unknown', null, null);

  const QuotaSample(this.label, this.shortRemaining, this.weekRemaining);
  final String label;
  final double? shortRemaining;
  final double? weekRemaining;
  double? get tightest => shortRemaining == null || weekRemaining == null
      ? null
      : math.min(shortRemaining!, weekRemaining!);
  String get limitingLabel =>
      (shortRemaining ?? 0) <= (weekRemaining ?? 0) ? '5-hour' : 'Weekly';
}

// The existing theme's warning yellow needs darkening on light surfaces.
// Keep the hue theme-derived and meet text contrast on both preview surfaces.
Color quotaReadableColor(Color color, ColorScheme scheme) {
  double contrast(Color a, Color b) {
    final x = a.computeLuminance();
    final y = b.computeLuminance();
    return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
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

void main() => runApp(const QuotaComparisonApp());

@Preview(name: 'Quota rings · phone', size: Size(402, 874))
Widget quotaRingsPhonePreview() => const QuotaComparisonApp();
@Preview(name: 'Quota rings · tablet', size: Size(1194, 834))
Widget quotaRingsTabletPreview() => const QuotaComparisonApp();

class QuotaComparisonApp extends StatefulWidget {
  const QuotaComparisonApp({
    super.key,
    this.initialSample = QuotaSample.healthy,
  });
  final QuotaSample initialSample;
  @override
  State<QuotaComparisonApp> createState() => _QuotaComparisonAppState();
}

class _QuotaComparisonAppState extends State<QuotaComparisonApp> {
  bool _dark = true;
  late QuotaSample _sample = widget.initialSample;
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: FluttyTheme.light,
    darkTheme: FluttyTheme.dark,
    themeMode: _dark ? ThemeMode.dark : ThemeMode.light,
    home: Builder(
      builder: (context) {
        final theme = Theme.of(context);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Quota rings'),
            actions: [
              IconButton(
                key: const ValueKey('toggle-theme'),
                tooltip: _dark ? 'Use light theme' : 'Use dark theme',
                onPressed: () => setState(() => _dark = !_dark),
                icon: Icon(
                  _dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: SafeArea(
            top: false,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 750;
                final examples = [
                  for (final treatment in [
                    QuotaTreatment.doubleRing,
                    QuotaTreatment.split,
                  ])
                    QuotaTreatmentExample(
                      treatment: treatment,
                      sample: _sample,
                      sidebar: wide,
                    ),
                ];
                return ListView(
                  padding: EdgeInsets.fromLTRB(
                    wide ? 32 : 20,
                    12,
                    wide ? 32 : 20,
                    24,
                  ),
                  children: [
                    Text(
                      'Same window. Same sample quotas.\nThe filled arc is what remains.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 20),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: CupertinoSlidingSegmentedControl<QuotaSample>(
                        groupValue: _sample,
                        backgroundColor:
                            theme.colorScheme.surfaceContainerHighest,
                        thumbColor: theme.colorScheme.surfaceContainerLow,
                        onValueChanged: (value) {
                          if (value != null) setState(() => _sample = value);
                        },
                        children: {
                          for (final sample in QuotaSample.values)
                            sample: Padding(
                              key: ValueKey('sample-${sample.name}'),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 8,
                              ),
                              child: Text(
                                sample.label,
                                style: theme.textTheme.labelSmall,
                              ),
                            ),
                        },
                      ),
                    ),
                    const SizedBox(height: 28),
                    if (wide)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: examples[0]),
                          const SizedBox(width: 32),
                          Expanded(child: examples[1]),
                        ],
                      )
                    else ...[
                      examples[0],
                      const SizedBox(height: 28),
                      examples[1],
                    ],
                    const SizedBox(height: 24),
                    Text(
                      'Account-wide allowances. Bar taps still open windows; the rings add no new tap action.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Visual prototype · sample data · no live connection',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    ),
  );
}

class QuotaTreatmentExample extends StatefulWidget {
  const QuotaTreatmentExample({
    required this.treatment,
    required this.sample,
    required this.sidebar,
    super.key,
  });
  final QuotaTreatment treatment;
  final QuotaSample sample;
  final bool sidebar;
  @override
  State<QuotaTreatmentExample> createState() => _QuotaTreatmentExampleState();
}

class _QuotaTreatmentExampleState extends State<QuotaTreatmentExample> {
  bool _expanded = false;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final single = widget.treatment == QuotaTreatment.single;
    final sample = widget.sample;
    final low = sample.tightest != null && sample.tightest! <= 15;
    final icon = QuotaRingIcon(treatment: widget.treatment, sample: sample);
    final handle = Material(
      color: scheme.surfaceContainerHighest,
      child: InkWell(
        key: ValueKey('handle-${widget.treatment.name}'),
        onTap: () => setState(() => _expanded = !_expanded),
        child: Semantics(
          button: true,
          label: 'Show MonkeyMux windows',
          expanded: _expanded,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: widget.sidebar ? 56 : 44),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: widget.sidebar ? 10 : 12,
              ),
              child: widget.sidebar
                  ? icon
                  : Row(
                      children: [
                        icon,
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Reconnect handling',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          width: 28,
                          height: 4,
                          decoration: BoxDecoration(
                            color: scheme.onSurfaceVariant.withAlpha(110),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          _expanded
                              ? Icons.keyboard_arrow_down
                              : Icons.keyboard_arrow_up,
                          size: 20,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
    final terminal = Padding(
      padding: const EdgeInsets.all(16),
      child: DefaultTextStyle(
        style: TextStyle(
          fontFamily: 'JetBrains Mono',
          fontSize: 12,
          height: 1.65,
          color: scheme.onSurfaceVariant,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(r'$ claude'),
            const SizedBox(height: 8),
            Text(
              '> Review the reconnect change.',
              style: TextStyle(color: scheme.onSurface),
            ),
            const SizedBox(height: 8),
            const Text('Reading connection state…'),
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.treatment.label, style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          widget.treatment.description,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surface,
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: widget.sidebar
              ? SizedBox(
                  height: 280,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: 56,
                        child: ColoredBox(
                          color: scheme.surfaceContainerHighest,
                          child: Column(
                            children: [
                              handle,
                              const SizedBox(height: 12),
                              AgentToolIcon(
                                tool: AgentLaunchTool.codex,
                                color: scheme.onSurfaceVariant,
                              ),
                              const SizedBox(height: 24),
                              AgentToolIcon(
                                tool: AgentLaunchTool.copilotCli,
                                color: scheme.onSurfaceVariant,
                              ),
                            ],
                          ),
                        ),
                      ),
                      Expanded(child: terminal),
                    ],
                  ),
                )
              : Column(
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 108),
                      child: SizedBox(width: double.infinity, child: terminal),
                    ),
                    handle,
                  ],
                ),
        ),
        const SizedBox(height: 10),
        Text(
          sample.tightest == null
              ? 'No ring when the allowance is unknown.'
              : single
              ? '${sample.limitingLabel} · ${sample.tightest!.round()}% left'
              : '5h ${sample.shortRemaining!.round()}% · weekly ${sample.weekRemaining!.round()}%',
          style: theme.textTheme.bodySmall?.copyWith(
            fontFamily: 'JetBrains Mono',
            color: low
                ? quotaReadableColor(
                    sample.tightest == 0 ? scheme.error : scheme.tertiary,
                    scheme,
                  )
                : scheme.onSurfaceVariant,
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 12),
          Text('MonkeyMux windows', style: theme.textTheme.titleSmall),
          const SizedBox(height: 12),
          Row(
            children: [
              AgentToolIcon(
                tool: AgentLaunchTool.claudeCode,
                color: scheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Reconnect handling',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.check, size: 18),
            ],
          ),
        ],
      ],
    );
  }
}

class QuotaRingIcon extends StatelessWidget {
  const QuotaRingIcon({
    required this.treatment,
    required this.sample,
    super.key,
  });
  final QuotaTreatment treatment;
  final QuotaSample sample;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final value = sample.tightest == null
        ? 'Account usage unavailable'
        : treatment == QuotaTreatment.single
        ? '${sample.limitingLabel} account allowance, ${sample.tightest!.round()} percent remaining'
        : '5-hour account allowance, ${sample.shortRemaining!.round()} percent remaining; weekly account allowance, ${sample.weekRemaining!.round()} percent remaining';
    return Semantics(
      label: 'Claude Code',
      value: value,
      child: SizedBox.square(
        dimension: 36,
        child: CustomPaint(
          painter: _QuotaRingPainter(
            treatment: treatment,
            sample: sample,
            primary: quotaReadableColor(scheme.primary, scheme),
            secondary: scheme.onSurfaceVariant,
            track: scheme.outlineVariant,
            warning: quotaReadableColor(scheme.tertiary, scheme),
          ),
          child: Center(
            child: AgentToolIcon(
              tool: AgentLaunchTool.claudeCode,
              size: 16,
              color: scheme.primary,
            ),
          ),
        ),
      ),
    );
  }
}

typedef QuotaRingArc = ({
  double radius,
  double start,
  double sweep,
  double remaining,
  bool shortTerm,
});

// Fixed positions prevent a weekly limit from swapping places as values change.
// Eight degrees of inset at each end leaves a visible gap even with round caps.
List<QuotaRingArc> quotaRingArcs(QuotaTreatment treatment, QuotaSample sample) {
  if (sample.tightest == null) return const [];
  const gap = math.pi / 22.5;
  return switch (treatment) {
    QuotaTreatment.single => [
      (
        radius: 13,
        start: -math.pi / 2,
        sweep: math.pi * 2,
        remaining: sample.tightest!,
        shortTerm: true,
      ),
    ],
    QuotaTreatment.doubleRing => [
      (
        radius: 17,
        start: -math.pi / 2,
        sweep: math.pi * 2,
        remaining: sample.shortRemaining!,
        shortTerm: true,
      ),
      (
        radius: 13,
        start: -math.pi / 2,
        sweep: math.pi * 2,
        remaining: sample.weekRemaining!,
        shortTerm: false,
      ),
    ],
    QuotaTreatment.split => [
      (
        radius: 13,
        start: -math.pi + gap,
        sweep: math.pi - 2 * gap,
        remaining: sample.shortRemaining!,
        shortTerm: true,
      ),
      (
        radius: 13,
        start: gap,
        sweep: math.pi - 2 * gap,
        remaining: sample.weekRemaining!,
        shortTerm: false,
      ),
    ],
  };
}

class _QuotaRingPainter extends CustomPainter {
  const _QuotaRingPainter({
    required this.treatment,
    required this.sample,
    required this.primary,
    required this.secondary,
    required this.track,
    required this.warning,
  });
  final QuotaTreatment treatment;
  final QuotaSample sample;
  final Color primary;
  final Color secondary;
  final Color track;
  final Color warning;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    for (final arc in quotaRingArcs(treatment, sample)) {
      final rect = Rect.fromCircle(center: center, radius: arc.radius);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..color = track;
      canvas.drawArc(rect, arc.start, arc.sweep, false, paint);
      if (arc.remaining <= 0) continue;
      paint.color = arc.remaining <= 15
          ? warning
          : arc.shortTerm
          ? primary
          : secondary;
      canvas.drawArc(
        rect,
        arc.start,
        arc.sweep * (arc.remaining / 100).clamp(0, 1),
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_QuotaRingPainter oldDelegate) =>
      treatment != oldDelegate.treatment ||
      sample != oldDelegate.sample ||
      primary != oldDelegate.primary ||
      secondary != oldDelegate.secondary ||
      track != oldDelegate.track ||
      warning != oldDelegate.warning;
}
