// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';

import '../../domain/models/agent_runtime_info.dart';

const _redactStoreScreenshotIdentities = bool.fromEnvironment(
  'STORE_SCREENSHOT_REDACT_IDENTITIES',
);

class AgentStatusPresentation {
  const AgentStatusPresentation(this.label, this.icon, this.color);

  final String label;
  final IconData icon;
  final Color color;
}

AgentStatusPresentation agentStatusPresentation(
  AgentRuntimeInfo runtime,
  ColorScheme scheme,
) => switch (runtime.status) {
  AgentRuntimeStatus.checking => AgentStatusPresentation(
    'Checking…',
    Icons.sync_rounded,
    scheme.onSurfaceVariant,
  ),
  AgentRuntimeStatus.installed => AgentStatusPresentation(
    runtime.installedVersion == null
        ? 'Installed'
        : 'Installed v${runtime.installedVersion}',
    Icons.check_circle_outline,
    scheme.onSurfaceVariant,
  ),
  AgentRuntimeStatus.updateAvailable => AgentStatusPresentation(
    'Update v${runtime.installedVersion ?? '?'} → v${runtime.latestVersion ?? '?'}',
    Icons.upgrade_rounded,
    scheme.onSurface,
  ),
  AgentRuntimeStatus.notInstalled => AgentStatusPresentation(
    'Not installed${runtime.latestVersion == null ? '' : ' · latest v${runtime.latestVersion}'}',
    Icons.remove_circle_outline,
    scheme.onSurfaceVariant,
  ),
  AgentRuntimeStatus.needsRepair => AgentStatusPresentation(
    'Needs repair',
    Icons.build_circle_outlined,
    scheme.error,
  ),
  AgentRuntimeStatus.unavailable => AgentStatusPresentation(
    'Unavailable',
    Icons.block_outlined,
    scheme.onSurfaceVariant,
  ),
  AgentRuntimeStatus.failed => AgentStatusPresentation(
    'Check failed',
    Icons.error_outline,
    scheme.error,
  ),
};

String? agentSourceLine(AgentRuntimeInfo runtime) {
  final path = runtime.executablePath;
  if (path == null) return null;
  final source = runtime.detectionSource;
  final displayPath = displayAgentExecutablePath(path);
  return source == null ? displayPath : '$source · $displayPath';
}

String displayAgentExecutablePath(String path) =>
    _redactStoreScreenshotIdentities ? path.split(RegExp(r'[/\\]')).last : path;
