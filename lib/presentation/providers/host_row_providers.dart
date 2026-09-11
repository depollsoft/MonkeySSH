import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/agent_launch_preset.dart';
import '../../domain/models/monetization.dart';
import '../../domain/models/remote_multiplexer.dart';
import '../../domain/models/terminal_themes.dart';
import '../../domain/services/home_screen_shortcut_service.dart';
import '../../domain/services/monetization_service.dart';
import '../../domain/services/settings_service.dart';
import '../../domain/services/ssh_service.dart';
import '../../domain/services/terminal_theme_service.dart';
import '../widgets/connection_preview_snippet.dart';

/// Arguments for [hostRowDataProvider].
///
/// [hostId] identifies the host. [lightThemeId] and [darkThemeId] are the
/// host-specific terminal theme overrides (nullable). [isDark] is the current
/// brightness, derived from [Theme.of(context).brightness].
typedef HostRowProviderArgs = ({
  int hostId,
  String? lightThemeId,
  String? darkThemeId,
  bool isDark,
});

/// Value-equal snapshot of all reactive data required to render one host row.
///
/// All fields use primitive or value-equal types so that Riverpod's equality
/// check can skip widget rebuilds when nothing relevant to this host changed.
@immutable
final class HostRowData {
  /// Creates a [HostRowData].
  const HostRowData({
    required this.connectionIds,
    required this.isConnected,
    required this.isConnectionStarting,
    required this.previewEntries,
    required this.isPinnedToHomeScreen,
    required this.hasHostThemeAccess,
    this.connectionAttemptMessage,
  });

  /// Active connection IDs for this host, oldest first.
  final List<int> connectionIds;

  /// Whether any connection is in [SshConnectionState.connected].
  final bool isConnected;

  /// Whether a connection is being established or actively progressing.
  final bool isConnectionStarting;

  /// Latest progress message while a connection attempt is in progress.
  ///
  /// Non-null only when a connect or reconnect attempt is actively progressing.
  final String? connectionAttemptMessage;

  /// Preview cards for each active connection, in connection-ID order.
  final List<ConnectionPreviewStackEntry> previewEntries;

  /// Whether this host is pinned to the OS home screen (iOS/macOS shortcuts).
  final bool isPinnedToHomeScreen;

  /// Whether the current plan allows per-host terminal theme overrides.
  final bool hasHostThemeAccess;

  /// Convenience: number of active connections.
  int get connectionCount => connectionIds.length;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is HostRowData &&
        listEquals(other.connectionIds, connectionIds) &&
        other.isConnected == isConnected &&
        other.isConnectionStarting == isConnectionStarting &&
        other.connectionAttemptMessage == connectionAttemptMessage &&
        listEquals(other.previewEntries, previewEntries) &&
        other.isPinnedToHomeScreen == isPinnedToHomeScreen &&
        other.hasHostThemeAccess == hasHostThemeAccess;
  }

  @override
  int get hashCode => Object.hash(
    Object.hashAll(connectionIds),
    isConnected,
    isConnectionStarting,
    connectionAttemptMessage,
    Object.hashAll(previewEntries),
    isPinnedToHomeScreen,
    hasHostThemeAccess,
  );
}

/// Active connections in display order, independent of preview refreshes.
final connectionIdsProvider = NotifierProvider.autoDispose(
  _ConnectionIdsNotifier.new,
);

class _ConnectionIdsNotifier extends Notifier<List<int>> {
  @override
  List<int> build() {
    ref.watch(activeSessionsProvider);
    return List.unmodifiable(
      ref
          .read(activeSessionsProvider.notifier)
          .getActiveConnections()
          .map((connection) => connection.connectionId),
    );
  }

  @override
  bool updateShouldNotify(List<int> previous, List<int> next) =>
      !listEquals(previous, next);
}

/// Theme context for a single connection preview.
typedef ConnectionPreviewProviderArgs = ({
  int connectionId,
  String? lightThemeId,
  String? darkThemeId,
  bool isDark,
});

/// Value-equal preview shared by host and connection rows.
final connectionPreviewProvider = Provider.autoDispose
    .family<ConnectionPreviewStackEntry, ConnectionPreviewProviderArgs>((
      ref,
      args,
    ) {
      final states = ref.watch(activeSessionsProvider);
      final connection = ref
          .read(activeSessionsProvider.notifier)
          .getActiveConnection(args.connectionId);
      final monetizationState =
          ref.watch(monetizationStateProvider).asData?.value ??
          ref.read(monetizationServiceProvider).currentState;
      final hasHostThemeAccess = monetizationState.allowsFeature(
        MonetizationFeature.hostSpecificThemes,
      );
      return buildConnectionPreviewStackEntry(
        connectionId: args.connectionId,
        state: states[args.connectionId] ?? SshConnectionState.connected,
        brightness: args.isDark ? Brightness.dark : Brightness.light,
        themeSettings: ref.watch(terminalThemeSettingsProvider),
        availableThemes:
            ref.watch(allTerminalThemesProvider).asData?.value ??
            TerminalThemes.all,
        preview: connection?.preview,
        previewSnapshot: connection?.previewSnapshot,
        nativeAcpPreviewSnapshot: connection?.nativeAcpPreviewSnapshot,
        activeTerminalTheme: connection?.terminalTheme,
        sessionTitle: connection?.sessionTitle,
        windowTitle: connection?.windowTitle,
        iconName: connection?.iconName,
        workingDirectory: connection?.workingDirectory,
        shellStatus: connection?.shellStatus,
        lastExitCode: connection?.lastExitCode,
        hostLightThemeId: hasHostThemeAccess ? args.lightThemeId : null,
        hostDarkThemeId: hasHostThemeAccess ? args.darkThemeId : null,
        connectionLightThemeId: connection?.terminalThemeLightId,
        connectionDarkThemeId: connection?.terminalThemeDarkId,
      );
    });

/// Value-equal reactive data for one host row.
final hostRowDataProvider = Provider.autoDispose
    .family<HostRowData, HostRowProviderArgs>((ref, args) {
      final allStates = ref.watch(activeSessionsProvider);
      final notifier = ref.read(activeSessionsProvider.notifier);

      final connectionIds = notifier.getConnectionsForHost(args.hostId);
      final attempt = notifier.getConnectionAttempt(args.hostId);

      final hostStates = connectionIds
          .map((id) => allStates[id])
          .whereType<SshConnectionState>()
          .toList(growable: false);

      final isConnected = hostStates.any(
        (s) => s == SshConnectionState.connected,
      );
      final isConnecting = hostStates.any(
        (s) =>
            s == SshConnectionState.connecting ||
            s == SshConnectionState.authenticating,
      );
      final isConnectionStarting =
          isConnecting || (attempt?.isInProgress ?? false);
      final connectionAttemptMessage = (attempt?.isInProgress ?? false)
          ? attempt!.latestMessage
          : null;

      // Monetization: whether per-host theme overrides are unlocked.
      final monetizationState =
          ref.watch(monetizationStateProvider).asData?.value ??
          ref.read(monetizationServiceProvider).currentState;
      final hasHostThemeAccess = monetizationState.allowsFeature(
        MonetizationFeature.hostSpecificThemes,
      );

      // Home-screen pin state for this specific host.
      final pinnedIds =
          ref.watch(pinnedHomeScreenShortcutHostIdsProvider).asData?.value ??
          const <int>{};
      final isPinnedToHomeScreen =
          supportsHomeScreenShortcutActions && pinnedIds.contains(args.hostId);

      final previewEntries = connectionIds
          .map(
            (connectionId) => ref.watch(
              connectionPreviewProvider((
                connectionId: connectionId,
                lightThemeId: args.lightThemeId,
                darkThemeId: args.darkThemeId,
                isDark: args.isDark,
              )),
            ),
          )
          .toList(growable: false);

      return HostRowData(
        connectionIds: connectionIds,
        isConnected: isConnected,
        isConnectionStarting: isConnectionStarting,
        connectionAttemptMessage: connectionAttemptMessage,
        previewEntries: previewEntries,
        isPinnedToHomeScreen: isPinnedToHomeScreen,
        hasHostThemeAccess: hasHostThemeAccess,
      );
    });

/// Saved launch presets, decoded once for all visible host badges.
final agentLaunchPresetMapProvider =
    StreamProvider.autoDispose<Map<String, AgentLaunchPreset>>(
      (ref) => ref
          .watch(settingsServiceProvider)
          .watchString(SettingKeys.agentLaunchPresets)
          .distinct()
          .map(_decodeAgentLaunchPresets),
    );

Map<String, AgentLaunchPreset> _decodeAgentLaunchPresets(String? value) {
  if (value == null) return const {};
  try {
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic>) return const {};
    final presets = <String, AgentLaunchPreset>{};
    for (final entry in decoded.entries) {
      final value = entry.value;
      if (value is! Map<String, dynamic>) continue;
      final preset = AgentLaunchPreset.tryFromJson(value);
      if (preset != null) presets[entry.key] = preset;
    }
    return presets;
  } on FormatException {
    return const {};
  }
}

/// Value-equal preset fields that affect a host's mux badge.
typedef HostAgentBadgePreferences = ({
  String? toolName,
  RemoteMuxBackend? muxBackend,
  String? sessionName,
});

/// Selects only the preset fields used by one host's mux badge.
final hostAgentBadgePreferencesProvider = Provider.autoDispose
    .family<AsyncValue<HostAgentBadgePreferences>, int>(
      (ref, hostId) => ref.watch(
        agentLaunchPresetMapProvider.select(
          (presets) => presets.whenData((presets) {
            final preset = presets[hostId.toString()];
            final sessionName = preset?.tmuxSessionName?.trim();
            final hasSessionName = sessionName?.isNotEmpty ?? false;
            return (
              toolName: preset?.tool.discoveredSessionToolName,
              muxBackend: hasSessionName
                  ? preset?.effectiveRemoteMuxBackend
                  : null,
              sessionName: hasSessionName ? sessionName : null,
            );
          }),
        ),
      ),
    );
