import 'dart:convert';

import '../models/agent_usage.dart';

/// Parses only the small, normalized records emitted by the remote quota probe.
Map<String, AgentUsage> parseAgentUsageOutput(
  String output, {
  required DateTime checkedAt,
}) {
  final result = <String, AgentUsage>{};
  for (final line in const LineSplitter().convert(output)) {
    const marker = '__monkeyssh_usage__=';
    if (!line.startsWith(marker) || line.length > 65536) continue;
    try {
      final data = jsonDecode(line.substring(marker.length));
      if (data is! Map<String, dynamic>) continue;
      final id = data['id'];
      if (!const {
        'claude',
        'codex',
        'copilot',
        'opencode',
        'antigravity',
        'cursor',
        'pi',
        'hermes',
        'openclaw',
        'grok',
      }.contains(id)) {
        continue;
      }
      final status =
          AgentUsageStatus.values
              .where((value) => value.name == data['status'])
              .firstOrNull ??
          AgentUsageStatus.unavailable;
      final windows = <AgentUsageWindow>[];
      if (data['windows'] case final List<dynamic> entries) {
        for (final entry in entries) {
          if (entry is! Map<String, dynamic>) continue;
          final label = entry['label'];
          if (label is! String || label.isEmpty || label.length > 100) continue;
          final percent = _number(entry['usedPercent']);
          final unlimited = entry['unlimited'] == true;
          final remaining = _number(entry['remaining']);
          final reached = entry['restricted'];
          final reset = entry['resetsAt'] is String
              ? DateTime.tryParse(entry['resetsAt'] as String)?.toUtc()
              : null;
          if (percent != null && percent < 0) continue;
          if (!unlimited &&
              percent == null &&
              remaining == null &&
              reached is! bool &&
              reset == null) {
            continue;
          }
          windows.add(
            AgentUsageWindow(
              label: label.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ''),
              usedPercent: unlimited ? null : percent,
              unlimited: unlimited,
              used: _number(entry['used']),
              limit: _number(entry['limit']),
              overageAllowed: entry['overageAllowed'] == true,
              resetsAt: reset,
              remaining: remaining,
              restricted: reached is bool ? reached : null,
              unit: entry['unit'] == 'USD' ? 'USD' : null,
            ),
          );
        }
      }
      final notices = <AgentUsageNotice>[];
      if (data['notices'] case final List<dynamic> entries) {
        for (final entry in entries) {
          if (entry is! Map<String, dynamic>) continue;
          final provider = entry['provider'];
          if (provider is! String ||
              provider.isEmpty ||
              provider.length > 100) {
            continue;
          }
          final noticeStatus = AgentUsageStatus.values
              .where((value) => value.name == entry['status'])
              .firstOrNull;
          if (noticeStatus == null ||
              noticeStatus == AgentUsageStatus.available) {
            continue;
          }
          notices.add(
            AgentUsageNotice(
              provider: provider.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ''),
              status: noticeStatus,
            ),
          );
        }
      }
      final credits = _number(data['resetCredits']);
      result[id as String] = AgentUsage(
        status: status == AgentUsageStatus.available && windows.isEmpty
            ? AgentUsageStatus.unavailable
            : status,
        windows: status == AgentUsageStatus.available ? windows : const [],
        notices: notices,
        checkedAt: checkedAt,
        resetCredits: credits != null && credits >= 0 ? credits.toInt() : null,
      );
    } on Object {
      // Malformed records must not hide results from other providers.
    }
  }
  return result;
}

double? _number(Object? value) =>
    value is num && value.isFinite ? value.toDouble() : null;
