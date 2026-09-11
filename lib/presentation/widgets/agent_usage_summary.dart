import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../app/theme.dart';
import '../../domain/models/agent_usage.dart';

/// Compact account quotas under an installed runtime's version information.
class AgentUsageSummary extends StatelessWidget {
  /// Creates a summary with optional details and an injectable clock.
  const AgentUsageSummary({
    required this.usage,
    this.checking = false,
    this.expanded = false,
    this.now,
    super.key,
  });

  /// Most recent account snapshot.
  final AgentUsage? usage;

  /// Whether a new check is in progress.
  final bool checking;

  /// Whether to include counts, snapshot age, and reset credits.
  final bool expanded;

  /// Test clock, otherwise the current local time.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final snapshot = usage;
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    if (snapshot == null || snapshot.status != AgentUsageStatus.available) {
      final notices = snapshot?.notices ?? const <AgentUsageNotice>[];
      final visible = expanded ? notices : notices.take(1);
      final hidden = notices.length - visible.length;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (checking || snapshot == null || snapshot.notices.isEmpty)
            Text(
              checking ? 'Checking usage…' : _statusLabel(snapshot?.status),
              style: style,
            ),
          if (!checking && snapshot != null)
            for (final notice in visible)
              Text(
                '${notice.provider} · ${_statusLabel(notice.status)}',
                style: style,
              ),
          if (!checking && hidden > 0)
            Text(_moreDetailsLabel(hidden), style: style),
        ],
      );
    }
    final clock = now ?? DateTime.now();
    final windows = expanded ? snapshot.windows : snapshot.windows.take(3);
    final notices = expanded ? snapshot.notices : snapshot.notices.take(1);
    final hidden =
        snapshot.windows.length +
        snapshot.notices.length -
        windows.length -
        notices.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final window in windows) ...[
          Builder(
            builder: (context) {
              final resetPassed =
                  window.resetsAt != null && !window.resetsAt!.isAfter(clock);
              final exhausted =
                  !resetPassed &&
                  ((window.usedPercent ?? 0) >= 100 ||
                      (window.restricted ?? false));
              final remainingPercent = window.usedPercent == null
                  ? null
                  : (100 - window.usedPercent!).clamp(0.0, 100.0);
              final amount = window.unlimited
                  ? 'Unlimited'
                  : window.usedPercent != null
                  ? '${_number(remainingPercent!)}% remaining'
                  : window.remaining != null
                  ? '${_amount(window.remaining!, window.unit)} remaining'
                  : window.restricted != null
                  ? resetPassed
                        ? 'Previous limit status'
                        : window.restricted!
                        ? 'Usage restricted'
                        : 'No restriction reported'
                  : 'Usage amount not reported';
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${window.label} · $amount${exhausted && window.usedPercent != null ? ' · Limit reached' : ''}',
                      style: FluttyTheme.monoStyle.copyWith(
                        fontSize: 12,
                        color: exhausted
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                        fontWeight: exhausted ? FontWeight.w600 : null,
                      ),
                    ),
                    if (!window.unlimited && remainingPercent != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: remainingPercent / 100,
                            minHeight: 4,
                            backgroundColor: scheme.onSurface.withValues(
                              alpha: 0.16,
                            ),
                            color: resetPassed
                                ? scheme.outline
                                : scheme.primary,
                            semanticsLabel:
                                '${window.label} allowance remaining',
                            semanticsValue: '${_number(remainingPercent)}%',
                          ),
                        ),
                      ),
                    if (expanded && (window.usedPercent ?? 0) > 100)
                      Text(
                        '${_number(window.usedPercent!)}% used including overage',
                        style: style,
                      ),
                    if (!window.unlimited &&
                        (window.remaining == null ||
                            window.usedPercent != null ||
                            window.used != null ||
                            window.limit != null ||
                            window.restricted != null ||
                            window.resetsAt != null))
                      Text(
                        _resetLabel(context, window.resetsAt, clock),
                        style: style,
                      ),
                    if (expanded && window.used != null && window.limit != null)
                      Text(
                        '${_amount(window.used!, window.unit)} / ${_amount(window.limit!, window.unit)}',
                        style: style,
                      ),
                    if (expanded && window.overageAllowed)
                      Text('Additional paid usage allowed', style: style),
                  ],
                ),
              );
            },
          ),
        ],
        for (final notice in notices)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '${notice.provider} · ${_statusLabel(notice.status)}',
              style: style,
            ),
          ),
        if (hidden > 0) Text(_moreDetailsLabel(hidden), style: style),
        if (expanded && snapshot.resetCredits != null)
          Text(
            '${snapshot.resetCredits} ${snapshot.resetCredits == 1 ? 'reset' : 'resets'} available',
            style: style,
          ),
        if (snapshot.checkedAt != null)
          Text(
            checking
                ? 'Updating usage…'
                : 'Usage checked ${_age(clock.difference(snapshot.checkedAt!))}',
            style: style,
          ),
      ],
    );
  }
}

String _moreDetailsLabel(int count) =>
    '$count more usage ${count == 1 ? 'detail' : 'details'} · expand above';

String _statusLabel(AgentUsageStatus? status) => switch (status) {
  AgentUsageStatus.unsupported => 'Usage reporting not supported',
  AgentUsageStatus.notReported => 'Quota not reported by provider',
  AgentUsageStatus.noAccounts => 'No accounts found in saved credentials',
  AgentUsageStatus.runtimeUnavailable =>
    'Usage checks need Node.js on the host',
  AgentUsageStatus.needsRunning => 'Start the agent on the host to check usage',
  AgentUsageStatus.signInRequired => 'Usage unavailable · sign in on the host',
  AgentUsageStatus.rateLimited => 'Usage check rate limited · try again later',
  _ => 'Usage unavailable · re-check to retry',
};

String _amount(double value, String? unit) =>
    unit == 'USD' ? '\$${value.toStringAsFixed(2)}' : _number(value);

String _number(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toStringAsFixed(1);

String _age(Duration age) => age.inMinutes < 1
    ? 'just now'
    : age.inMinutes < 60
    ? '${age.inMinutes} min ago'
    : '${age.inHours} hr ago';

String _resetLabel(BuildContext context, DateTime? reset, DateTime now) {
  if (reset == null) return 'Reset time not reported';
  if (!reset.isAfter(now)) return 'Reset time passed · re-check usage';
  final local = reset.toLocal();
  final date = MaterialLocalizations.of(context).formatShortDate(local);
  final time = MaterialLocalizations.of(context).formatTimeOfDay(
    TimeOfDay.fromDateTime(local),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
  return 'Resets $date, $time';
}

/// Illustrative usage values for previewing narrow layouts.
@Preview(name: 'Agent usage', size: Size(320, 240))
Widget agentUsagePreview() => MaterialApp(
  theme: FluttyTheme.light,
  home: Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: AgentUsageSummary(
        expanded: true,
        usage: AgentUsage(
          status: AgentUsageStatus.available,
          checkedAt: DateTime.now(),
          resetCredits: 2,
          windows: [
            AgentUsageWindow(
              label: '5 hours',
              usedPercent: 100,
              resetsAt: DateTime.now().add(const Duration(hours: 2)),
            ),
            AgentUsageWindow(
              label: 'Weekly',
              usedPercent: 42,
              resetsAt: DateTime.now().add(const Duration(days: 3)),
            ),
          ],
        ),
      ),
    ),
  ),
);

/// Illustrative failed accounts for checking compact and expanded disclosure.
@Preview(name: 'Unavailable usage', size: Size(320, 240))
Widget unavailableAgentUsagePreview() => MaterialApp(
  theme: FluttyTheme.light,
  home: const Scaffold(
    body: Padding(
      padding: EdgeInsets.all(16),
      child: AgentUsageSummary(
        usage: AgentUsage(
          status: AgentUsageStatus.unavailable,
          notices: [
            AgentUsageNotice(
              provider: 'Anthropic',
              status: AgentUsageStatus.signInRequired,
            ),
            AgentUsageNotice(
              provider: 'OpenAI Codex',
              status: AgentUsageStatus.unavailable,
            ),
          ],
        ),
      ),
    ),
  ),
);
