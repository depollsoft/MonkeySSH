import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_metadata.dart';
import '../../app/theme.dart';
import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/key_repository.dart';
import '../../data/repositories/snippet_repository.dart';
import '../../domain/commands/duplicate_host_command.dart';
import '../../domain/models/acp_provider.dart';
import '../../domain/models/acp_session_state.dart';
import '../../domain/models/monetization.dart';
import '../../domain/models/remote_multiplexer.dart';
import '../../domain/models/terminal_themes.dart';
import '../../domain/models/tmux_state.dart';
import '../../domain/services/acp_session_manager.dart';
import '../../domain/services/agent_session_discovery_service.dart';
import '../../domain/services/auth_service.dart';
import '../../domain/services/diagnostics_log_service.dart';
import '../../domain/services/home_screen_shortcut_service.dart';
import '../../domain/services/host_cli_launch_preferences_service.dart';
import '../../domain/services/local_notification_service.dart';
import '../../domain/services/monetization_service.dart';
import '../../domain/services/monkeymux_service.dart';
import '../../domain/services/remote_multiplexer_service.dart';
import '../../domain/services/secure_transfer_service.dart';
import '../../domain/services/settings_service.dart';
import '../../domain/services/ssh_service.dart';
import '../../domain/services/telemetry_service.dart';
import '../../domain/services/terminal_theme_service.dart';
import '../../domain/services/tmux_service.dart';
import '../../domain/services/transfer_intent_service.dart';
import '../providers/entity_list_providers.dart';
import '../providers/host_row_providers.dart';
import '../widgets/acp_mux_window_status_badge.dart';
import '../widgets/acp_session_presentation.dart';
import '../widgets/acp_session_switcher.dart';
import '../widgets/agent_tool_icon.dart';
import '../widgets/ai_session_picker.dart';
import '../widgets/brand_empty_state.dart';
import '../widgets/brand_error_state.dart';
import '../widgets/brand_list_skeleton.dart';
import '../widgets/connection_attempt_dialog.dart';
import '../widgets/connection_preview_snippet.dart';
import '../widgets/connection_status_dot.dart';
import '../widgets/cursor_block.dart';
import '../widgets/file_picker_helpers.dart';
import '../widgets/panel_header.dart';
import '../widgets/premium_access.dart';
import '../widgets/reorder_helpers.dart';
import '../widgets/snippet_folder_dialog.dart';
import '../widgets/tmux_window_status_badge.dart';
import 'snippet_edit_screen.dart';
import 'transfer_screen.dart';

const _redactStoreScreenshotIdentities = bool.fromEnvironment(
  'STORE_SCREENSHOT_REDACT_IDENTITIES',
);
const _connectionTileHorizontalPadding = 16.0;
const _connectionTileMinLeadingWidth = 40.0;
const _connectionTileHorizontalTitleGap = 16.0;
const _connectionPreviewLeadingInset =
    _connectionTileHorizontalPadding +
    _connectionTileMinLeadingWidth +
    _connectionTileHorizontalTitleGap;

/// Top-level sections available on the home screen.
enum HomeScreenTab {
  /// Saved host definitions.
  hosts,

  /// Active SSH connections.
  connections,

  /// SSH key management.
  keys,

  /// Snippet management.
  snippets,
}

/// The main home screen - Termius-style sidebar layout.
class HomeScreen extends ConsumerStatefulWidget {
  /// Creates a new [HomeScreen].
  const HomeScreen({super.key, this.initialTab = HomeScreenTab.hosts});

  /// The tab selected when the home screen route is opened.
  final HomeScreenTab initialTab;

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  late int _selectedIndex;
  bool _isOpeningTerminalRoute = false;

  /// Switches to the Connections tab so the user lands there when
  /// returning from the terminal.
  void switchToConnectionsTab() {
    if (_selectedIndex != 1) setState(() => _selectedIndex = 1);
  }

  /// Switches back to the Hosts tab.
  void switchToHostsTab() {
    if (_selectedIndex != 0) setState(() => _selectedIndex = 0);
  }

  Future<void> _openTerminalRoute(String route) async {
    if (_isOpeningTerminalRoute) {
      return;
    }
    final router = GoRouter.maybeOf(context);
    if (router == null) {
      return;
    }
    _isOpeningTerminalRoute = true;
    // Release the double-tap guard once the terminal route has been pushed and
    // can capture input, rather than when `router.push` resolves. That future
    // only completes when the route is popped, and is orphaned entirely if the
    // route is instead removed via `go(...)` (for example navigating home from
    // SFTP). Tying the guard to it would leave it stuck `true`, permanently
    // blocking every future terminal open even though connections still open.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _releaseTerminalRouteGuard(),
    );
    try {
      await router.push(route);
    } finally {
      // Belt-and-suspenders: also release here, before the theme clear (which
      // can throw if the provider is gone) so a throw can never strand the guard.
      _releaseTerminalRouteGuard();
      if (mounted) {
        ref.read(terminalAppThemeOverrideProvider.notifier).clear();
      }
    }
  }

  void _releaseTerminalRouteGuard() {
    if (!_isOpeningTerminalRoute) {
      return;
    }
    if (mounted) {
      setState(() => _isOpeningTerminalRoute = false);
    } else {
      _isOpeningTerminalRoute = false;
    }
  }

  StreamSubscription<String>? _incomingTransferSubscription;
  final Queue<String> _incomingTransferQueue = Queue<String>();
  String? _activeIncomingTransferPayload;
  bool _isHandlingIncomingTransfer = false;
  StreamSubscription<int>? _homeScreenShortcutSubscription;
  final Queue<int> _pendingHomeScreenShortcutHostIds = Queue<int>();
  int? _activeHomeScreenShortcutHostId;
  bool _isHandlingHomeScreenShortcut = false;

  // Breakpoint for switching between mobile and desktop layout
  static const double _mobileBreakpoint = 600;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialTab.index;
    WidgetsBinding.instance.addObserver(this);
    final transferIntentService = ref.read(transferIntentServiceProvider);
    _incomingTransferSubscription = transferIntentService.incomingPayloads
        .listen((payload) {
          if (payload.isNotEmpty && mounted) {
            _enqueueIncomingTransferPayload(payload);
          }
        });
    _homeScreenShortcutSubscription = ref
        .read(homeScreenShortcutServiceProvider)
        .hostLaunches
        .listen((hostId) {
          if (mounted) {
            _enqueueHomeScreenShortcutHostLaunch(hostId);
          }
        });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_checkIncomingTransferPayload());
      }
    });
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTab != widget.initialTab) {
      _selectedIndex = widget.initialTab.index;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_incomingTransferSubscription?.cancel());
    unawaited(_homeScreenShortcutSubscription?.cancel());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_checkIncomingTransferPayload());
    }
  }

  Future<void> _checkIncomingTransferPayload() async {
    final payload = await ref
        .read(transferIntentServiceProvider)
        .consumeIncomingTransferPayload();
    if (!mounted || payload == null || payload.isEmpty) {
      return;
    }
    _enqueueIncomingTransferPayload(payload);
  }

  void _enqueueIncomingTransferPayload(String encodedPayload) {
    final normalizedPayload = encodedPayload.trim();
    if (normalizedPayload.isEmpty ||
        normalizedPayload == _activeIncomingTransferPayload ||
        _incomingTransferQueue.contains(normalizedPayload)) {
      return;
    }
    _incomingTransferQueue.add(normalizedPayload);
    unawaited(_processIncomingTransferQueue());
  }

  Future<void> _processIncomingTransferQueue() async {
    if (_isHandlingIncomingTransfer) {
      return;
    }
    while (mounted && _incomingTransferQueue.isNotEmpty) {
      _isHandlingIncomingTransfer = true;
      final encodedPayload = _incomingTransferQueue.removeFirst();
      _activeIncomingTransferPayload = encodedPayload;
      try {
        await _handleIncomingTransferPayload(encodedPayload);
      } finally {
        _activeIncomingTransferPayload = null;
        _isHandlingIncomingTransfer = false;
      }
    }
  }

  Future<void> _handleIncomingTransferPayload(String encodedPayload) async {
    try {
      final hasAccess = await requireMonetizationFeatureAccess(
        context: context,
        ref: ref,
        feature: MonetizationFeature.encryptedTransfers,
        blockedAction: 'Open incoming encrypted transfer',
        blockedOutcome:
            'Unlock Pro to decrypt this transfer and import its hosts or keys.',
      );
      if (!hasAccess || !mounted) {
        return;
      }
      final transferPassphrase = await showTransferPassphraseDialog(
        context: context,
        title: 'Incoming transfer passphrase',
      );
      if (!mounted || transferPassphrase == null) {
        return;
      }

      final transferService = ref.read(secureTransferServiceProvider);
      final payload = await transferService.decryptPayload(
        encodedPayload: encodedPayload,
        transferPassphrase: transferPassphrase,
      );

      switch (payload.type) {
        case TransferPayloadType.host:
          if (!mounted) {
            return;
          }
          final confirmed = await showTransferPayloadImportConfirmationDialog(
            context: context,
            payload: payload,
          );
          if (!mounted || !confirmed) {
            return;
          }
          final host = await transferService.importHostPayload(payload);
          ref.invalidate(allHostsProvider);
          if (!mounted) {
            return;
          }
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Imported host: ${host.label}')),
          );
          break;
        case TransferPayloadType.key:
          if (!mounted) {
            return;
          }
          final confirmed = await showTransferPayloadImportConfirmationDialog(
            context: context,
            payload: payload,
          );
          if (!mounted || !confirmed) {
            return;
          }
          final key = await transferService.importKeyPayload(payload);
          ref.invalidate(allKeysProvider);
          if (!mounted) {
            return;
          }
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Imported key: ${key.name}')));
          break;
        case TransferPayloadType.fullMigration:
          final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
          final preview = transferService.previewMigrationPayload(payload);
          if (!mounted) {
            return;
          }
          final mode = await showMigrationImportModeDialog(
            context: context,
            preview: preview,
            title: 'Incoming migration package',
            message: 'Choose how to apply the incoming data.',
          );
          if (mode == null || !mounted) {
            return;
          }
          await transferService.importFullMigrationPayload(
            payload: payload,
            mode: mode,
          );
          if (mode == MigrationImportMode.replace) {
            await sessionsNotifier.disconnectAll();
          }
          invalidateSyncedDataProviders(ref.invalidate);
          if (!mounted) {
            return;
          }
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Imported full migration package')),
          );
          break;
      }
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: ${error.message}')),
      );
    } on Exception {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Import failed. Check the file and try again.'),
        ),
      );
    }
  }

  void _enqueueHomeScreenShortcutHostLaunch(int hostId) {
    if (hostId <= 0 ||
        hostId == _activeHomeScreenShortcutHostId ||
        _pendingHomeScreenShortcutHostIds.contains(hostId)) {
      return;
    }
    _pendingHomeScreenShortcutHostIds.add(hostId);
    unawaited(_processHomeScreenShortcutQueue());
  }

  Future<void> _processHomeScreenShortcutQueue() async {
    if (_isHandlingHomeScreenShortcut) {
      return;
    }

    while (mounted && _pendingHomeScreenShortcutHostIds.isNotEmpty) {
      _isHandlingHomeScreenShortcut = true;
      final hostId = _pendingHomeScreenShortcutHostIds.removeFirst();
      _activeHomeScreenShortcutHostId = hostId;
      try {
        await _openHomeScreenShortcutHost(hostId);
      } finally {
        _activeHomeScreenShortcutHostId = null;
        _isHandlingHomeScreenShortcut = false;
      }
    }
  }

  Future<void> _openHomeScreenShortcutHost(int hostId) async {
    final host = await ref.read(hostRepositoryProvider).getById(hostId);
    if (!mounted) {
      return;
    }

    if (host == null) {
      await ref
          .read(homeScreenShortcutPreferencesServiceProvider)
          .setHostPinned(hostId, pinned: false);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'That home screen host shortcut is no longer available',
          ),
        ),
      );
      return;
    }

    switchToConnectionsTab();
    unawaited(_openTerminalRoute('/terminal/${host.id}'));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<Map<int, SshConnectionState>>(activeSessionsProvider, (
      previous,
      next,
    ) {
      final hadConnections = previous?.isNotEmpty ?? false;
      if (!hadConnections || next.isNotEmpty || _selectedIndex != 1) {
        return;
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _selectedIndex != 1) {
          return;
        }
        switchToHostsTab();
      });
    });

    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth >= _mobileBreakpoint;

    return isWide ? _buildDesktopLayout() : _buildMobileLayout();
  }

  Widget _buildMobileLayout() => Scaffold(
    // This shell has no text input. Ignore stale IME insets left behind by
    // input-heavy routes.
    resizeToAvoidBottomInset: false,
    appBar: AppBar(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.asset(
              'assets/icons/monkeyssh_icon.png',
              width: 28,
              height: 28,
            ),
          ),
          const SizedBox(width: 8),
          Text(ref.watch(appDisplayNameProvider)),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => context.push('/settings'),
        ),
      ],
    ),
    body: _buildContent(),
    bottomNavigationBar: NavigationBar(
      // Keep destinations clear of edge-to-edge system navigation while an
      // IME inset temporarily reduces MediaQuery.padding.
      maintainBottomViewPadding: true,
      selectedIndex: _selectedIndex,
      onDestinationSelected: (index) => setState(() => _selectedIndex = index),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      height: 65,
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.dns_outlined),
          selectedIcon: Icon(Icons.dns_rounded),
          label: 'Hosts',
        ),
        NavigationDestination(
          icon: Icon(Icons.link_outlined),
          selectedIcon: Icon(Icons.link),
          label: 'Connections',
        ),
        NavigationDestination(
          icon: Icon(Icons.key_outlined),
          selectedIcon: Icon(Icons.key_rounded),
          label: 'Keys',
        ),
        NavigationDestination(
          icon: Icon(Icons.code_outlined),
          selectedIcon: Icon(Icons.code_rounded),
          label: 'Snippets',
        ),
      ],
    ),
  );

  Widget _buildDesktopLayout() {
    final appName = ref.watch(appDisplayNameProvider);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      body: Row(
        children: [
          // Sidebar navigation
          Container(
            width: 230,
            decoration: BoxDecoration(
              color: colorScheme.surface,
              border: Border(
                right: BorderSide(color: colorScheme.outline.withAlpha(60)),
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  // App header
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.asset(
                            'assets/icons/monkeyssh_icon.png',
                            width: 32,
                            height: 32,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: appName,
                                  style: FluttyTheme.displayMono(
                                    fontSize: 16,
                                    color: colorScheme.onSurface,
                                  ),
                                ),
                                WidgetSpan(
                                  alignment: PlaceholderAlignment.baseline,
                                  baseline: TextBaseline.alphabetic,
                                  child: Padding(
                                    padding: const EdgeInsets.only(left: 4),
                                    child: CursorBlock(
                                      size: 16,
                                      color: colorScheme.primary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),

                  Divider(
                    height: 1,
                    indent: 16,
                    endIndent: 16,
                    color: colorScheme.outline.withAlpha(40),
                  ),
                  const SizedBox(height: 12),

                  // Navigation items
                  _NavItem(
                    icon: Icons.dns_rounded,
                    label: 'Hosts',
                    selected: _selectedIndex == 0,
                    onTap: () => setState(() => _selectedIndex = 0),
                  ),
                  _NavItem(
                    icon: Icons.link,
                    label: 'Connections',
                    selected: _selectedIndex == 1,
                    onTap: () => setState(() => _selectedIndex = 1),
                  ),
                  _NavItem(
                    icon: Icons.key_rounded,
                    label: 'Keys',
                    selected: _selectedIndex == 2,
                    onTap: () => setState(() => _selectedIndex = 2),
                  ),
                  _NavItem(
                    icon: Icons.code_rounded,
                    label: 'Snippets',
                    selected: _selectedIndex == 3,
                    onTap: () => setState(() => _selectedIndex = 3),
                  ),

                  const Spacer(),

                  Divider(
                    height: 1,
                    indent: 16,
                    endIndent: 16,
                    color: colorScheme.outline.withAlpha(40),
                  ),
                  const SizedBox(height: 8),

                  // Settings at bottom
                  _NavItem(
                    icon: Icons.settings_outlined,
                    label: 'Settings',
                    selected: false,
                    onTap: () => context.push('/settings'),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),

          // Main content
          Expanded(
            child: SafeArea(
              left: false,
              right: false,
              bottom: false,
              child: _buildContent(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() => Column(
    children: [
      const _TelemetryOptInPromptCard(),
      Expanded(
        child: switch (_selectedIndex) {
          0 => const HostsPanel(),
          1 => const _ConnectionsPanel(),
          2 => const _KeysPanel(),
          3 => const SnippetsPanel(),
          _ => const HostsPanel(),
        },
      ),
    ],
  );
}

void _openTerminalRoute(BuildContext context, String route) {
  final homeState = context.findAncestorStateOfType<_HomeScreenState>();
  if (homeState != null) {
    unawaited(homeState._openTerminalRoute(route));
    return;
  }
  final router = GoRouter.maybeOf(context);
  if (router != null) {
    unawaited(router.push(route));
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected
            ? colorScheme.primary.withAlpha(isDark ? 25 : 20)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          hoverColor: colorScheme.primary.withAlpha(isDark ? 12 : 8),
          splashColor: colorScheme.primary.withAlpha(isDark ? 20 : 15),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: selected
                      ? colorScheme.primary
                      : colorScheme.onSurface.withAlpha(150),
                ),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: selected
                        ? colorScheme.primary
                        : colorScheme.onSurface.withAlpha(200),
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TelemetryOptInPromptCard extends ConsumerWidget {
  const _TelemetryOptInPromptCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final telemetryService = ref.watch(telemetryServiceProvider);
    if (!telemetryService.isAvailable) {
      return const SizedBox.shrink();
    }

    final promptState = ref.watch(telemetryOptInPromptNotifierProvider);
    if (promptState.isResolved) {
      return const SizedBox.shrink();
    }

    final hosts = ref.watch(allHostsProvider).asData?.value ?? const <Host>[];
    final hasSuccessfulConnection = hosts.any(
      (host) => host.lastConnectedAt != null,
    );
    final trigger = hasSuccessfulConnection
        ? 'successful_connection'
        : 'launches';
    final isEligible =
        hasSuccessfulConnection ||
        promptState.appLaunchCount >=
            TelemetryOptInPromptNotifier.minimumLaunchCountForPrompt;
    if (!isEligible) {
      return const SizedBox.shrink();
    }
    if (promptState.choice == TelemetryOptInPromptChoice.notShown) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) {
          return;
        }
        ref
            .read(telemetryOptInPromptNotifierProvider.notifier)
            .markShown(trigger: trigger);
      });
    }

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Material(
        color: colorScheme.primaryContainer.withAlpha(130),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.insights_outlined,
                    color: colorScheme.onPrimaryContainer,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Help improve MonkeySSH',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Share anonymous feature usage and crash reports so we can understand what works, what breaks, and where to improve the app.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Never includes hostnames, usernames, commands, terminal output, file paths, clipboard contents, or credentials.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onPrimaryContainer.withAlpha(
                              210,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => unawaited(
                      ref
                          .read(telemetryOptInPromptNotifierProvider.notifier)
                          .dismiss(trigger: trigger),
                    ),
                    child: const Text('Not now'),
                  ),
                  FilledButton(
                    onPressed: () => unawaited(
                      ref
                          .read(telemetryOptInPromptNotifierProvider.notifier)
                          .accept(trigger: trigger),
                    ),
                    child: const Text('Share analytics'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Panel for displaying and managing hosts inline.
class HostsPanel extends ConsumerWidget {
  /// Creates a [HostsPanel].
  const HostsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hostsAsync = ref.watch(allHostsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header bar
        PanelHeader(
          title: 'hosts',
          actions: [
            _ActionButton(
              icon: Icons.add,
              label: 'Add Host',
              onTap: () => context.push('/hosts/add'),
              primary: true,
            ),
          ],
        ),

        Expanded(child: _buildHostsBody(context, ref, hostsAsync)),
      ],
    );
  }

  Widget _buildHostsBody(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<Host>> hostsAsync,
  ) => hostsAsync.when(
    loading: () => const BrandListSkeleton(),
    error: (_, _) => BrandErrorState(
      title: 'couldn’t load hosts',
      message: 'Your saved hosts didn’t load.',
      onRetry: () => ref.invalidate(allHostsProvider),
    ),
    data: (hosts) => hosts.isEmpty
        ? _buildEmptyState(context)
        : _buildHostsList(context, ref, hosts),
  );

  Widget _buildEmptyState(BuildContext context) => _buildCenteredHostsState(
    child: BrandEmptyState(
      title: 'no hosts yet',
      message: 'Nothing to connect to — let’s fix that.',
      primaryLabel: 'Add Host',
      onPrimary: () => context.push('/hosts/add'),
      secondaryActions: [
        BrandEmptyAction(
          icon: Icons.content_paste_go_outlined,
          label: 'Paste SSH URL',
          onTap: () => unawaited(_openPastedSshUrl(context)),
        ),
      ],
    ),
  );

  Future<void> _openPastedSshUrl(BuildContext context) async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final sshUrl = clipboard?.text?.trim();
    if (sshUrl == null || sshUrl.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Copy an ssh:// URL first.')),
        );
      }
      return;
    }
    final uri = Uri.tryParse(sshUrl);
    if (uri == null || uri.scheme != 'ssh' || uri.host.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Clipboard does not contain an ssh:// URL.'),
          ),
        );
      }
      return;
    }
    if (context.mounted) {
      unawaited(
        context.push('/hosts/add?sshUrl=${Uri.encodeQueryComponent(sshUrl)}'),
      );
    }
  }

  Widget _buildCenteredHostsState({required Widget child}) => CustomScrollView(
    slivers: [
      SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: child,
          ),
        ),
      ),
    ],
  );

  Widget _buildHostsList(
    BuildContext context,
    WidgetRef ref,
    List<Host> hosts,
  ) => ReorderableListView.builder(
    padding: const EdgeInsets.symmetric(vertical: 4),
    buildDefaultDragHandles: false,
    itemCount: hosts.length,
    onReorderItem: (oldIndex, newIndex) => unawaited(
      _reorderHosts(
        ref: ref,
        hosts: hosts,
        oldIndex: oldIndex,
        newIndex: newIndex,
      ),
    ),
    itemBuilder: (context, index) {
      final host = hosts[index];
      return _HostRow(
        key: ValueKey('home-host-${host.id}'),
        host: host,
        reorderHandle: ReorderGrip(index: index),
      );
    },
  );

  Future<void> _reorderHosts({
    required WidgetRef ref,
    required List<Host> hosts,
    required int oldIndex,
    required int newIndex,
  }) async {
    final reorderedIds = reorderVisibleIdsInFullOrder(
      allIds: hosts.map((host) => host.id).toList(growable: false),
      visibleIds: hosts.map((host) => host.id).toList(growable: false),
      oldIndex: oldIndex,
      newIndex: newIndex,
    );
    await ref.read(hostRepositoryProvider).reorderByIds(reorderedIds);
  }
}

enum _HostContextAction {
  connect,
  newConnection,
  toggleHomeScreen,
  disconnect,
  edit,
  duplicate,
  export,
  delete,
}

Future<void> _disconnectConnection(WidgetRef ref, int connectionId) async {
  await ref.read(tmuxServiceProvider).clearCache(connectionId);
  await ref.read(monkeyMuxServiceProvider).clearCache(connectionId);
  await ref.read(activeSessionsProvider.notifier).disconnect(connectionId);
}

Future<void> _disconnectHostConnections(
  WidgetRef ref,
  Iterable<int> connectionIds,
) async {
  for (final connectionId in connectionIds.toList(growable: false)) {
    await _disconnectConnection(ref, connectionId);
  }
}

class _HostRow extends ConsumerWidget {
  const _HostRow({required this.host, required this.reorderHandle, super.key});

  final Host host;
  final Widget reorderHandle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    // Single per-host watch: only rebuilds when THIS host's data changes.
    final rowData = ref.watch(
      hostRowDataProvider((
        hostId: host.id,
        lightThemeId: host.terminalThemeLightId,
        darkThemeId: host.terminalThemeDarkId,
        isDark: isDark,
      )),
    );
    final isConnected = rowData.isConnected;
    final isConnectionStarting = rowData.isConnectionStarting;
    final connectionAttemptMessage = rowData.connectionAttemptMessage;
    final connectionCount = rowData.connectionCount;
    final isPinnedToHomeScreen = rowData.isPinnedToHomeScreen;
    final previewEntries = rowData.previewEntries;
    void openHostConnection() => unawaited(_openHostConnection(context, ref));

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: openHostConnection,
        onLongPress: () => unawaited(_showContextMenuAtCenter(context, ref)),
        onSecondaryTapDown: (details) =>
            unawaited(_showContextMenu(context, ref, details.globalPosition)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colorScheme.outline.withAlpha(30)),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Status indicator
                  SizedBox(
                    height: 28,
                    child: Center(
                      child: ConnectionStatusDot(
                        isConnected: isConnected,
                        isConnecting: isConnectionStarting,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Host info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                host.label,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            if (connectionCount > 0) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: colorScheme.primary.withAlpha(20),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  '$connectionCount',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: colorScheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                            if (host.isFavorite) ...[
                              const SizedBox(width: 6),
                              Icon(
                                Icons.star_rounded,
                                size: 14,
                                color: colorScheme.tertiary,
                              ),
                            ],
                            if (isPinnedToHomeScreen) ...[
                              const SizedBox(width: 6),
                              Icon(
                                Icons.home_rounded,
                                size: 14,
                                color: colorScheme.primary,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _redactStoreScreenshotIdentities
                              ? 'store@local-demo'
                              : '${host.username}@${host.hostname}',
                          style: FluttyTheme.monoStyle.copyWith(
                            fontSize: 11,
                            color: colorScheme.onSurface.withAlpha(160),
                          ),
                        ),
                        if (connectionAttemptMessage != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            connectionAttemptMessage,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.primary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.outline.withAlpha(40),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          ':${host.port}',
                          style: FluttyTheme.monoStyle.copyWith(
                            fontSize: 10,
                            color: colorScheme.onSurface.withAlpha(160),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Builder(
                        builder: (buttonContext) => _SmallIconButton(
                          icon: Icons.more_vert,
                          tooltip: 'Host actions',
                          onTap: () => unawaited(
                            _showContextMenuAtCenter(buttonContext, ref),
                          ),
                        ),
                      ),
                      reorderHandle,
                    ],
                  ),
                ],
              ),
              if (previewEntries.isNotEmpty &&
                  !_redactStoreScreenshotIdentities) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(left: 20),
                  child: ConnectionPreviewStack(
                    entries: previewEntries,
                    onTap: openHostConnection,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openHostConnection(BuildContext context, WidgetRef ref) async {
    final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
    final connectionIds = sessionsNotifier.getConnectionsForHost(host.id);

    if (connectionIds.isEmpty) {
      await _openNewConnection(context, ref);
      return;
    }

    if (connectionIds.length == 1) {
      if (context.mounted) {
        context
            .findAncestorStateOfType<_HomeScreenState>()
            ?.switchToConnectionsTab();
        _openTerminalRoute(
          context,
          '/terminal/${host.id}?connectionId=${connectionIds.first}',
        );
      }
      return;
    }

    // The sheet can rebuild after this host row has been removed.
    final connectionStates = ref.read(activeSessionsProvider);
    final terminalThemeSettings = ref.read(terminalThemeSettingsProvider);
    final terminalThemes =
        ref.read(allTerminalThemesProvider).asData?.value ?? TerminalThemes.all;
    final selection = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: connectionIds.length + 2,
          itemBuilder: (context, index) {
            if (index == 0) {
              return ListTile(
                title: Text(host.label),
                subtitle: Text('${connectionIds.length} active connections'),
              );
            }
            if (index == connectionIds.length + 1) {
              return ListTile(
                leading: const Icon(Icons.add),
                title: const Text('New connection'),
                onTap: () => Navigator.pop(context, 'new'),
              );
            }
            final connectionId = connectionIds[connectionIds.length - index];
            final connection = sessionsNotifier.getActiveConnection(
              connectionId,
            );
            final createdAt = sessionsNotifier
                .getSession(connectionId)
                ?.createdAt;
            final endpoint = '${host.username}@${host.hostname}:${host.port}';
            final subtitle = createdAt == null
                ? endpoint
                : '$endpoint\nOpened ${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}';
            final terminalTheme =
                connection?.terminalTheme ??
                resolveConnectionPreviewTheme(
                  brightness: Theme.of(context).brightness,
                  themeSettings: terminalThemeSettings,
                  availableThemes: terminalThemes,
                  lightThemeId:
                      connection?.terminalThemeLightId ??
                      host.terminalThemeLightId,
                  darkThemeId:
                      connection?.terminalThemeDarkId ??
                      host.terminalThemeDarkId,
                );
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              minTileHeight: 64,
              minVerticalPadding: 10,
              leading: const Icon(Icons.terminal),
              title: Text(
                'Connection #$connectionId',
                style: FluttyTheme.displayMono(
                  fontSize: 15,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              subtitle: ConnectionPreviewSnippet(
                endpoint: subtitle,
                endpointStyle: FluttyTheme.monoStyle.copyWith(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                preview: connection?.preview,
                previewSnapshot: connection?.previewSnapshot,
                nativeAcpPreviewSnapshot: connection?.nativeAcpPreviewSnapshot,
                sessionTitle: connection?.sessionTitle,
                windowTitle: connection?.windowTitle,
                iconName: connection?.iconName,
                workingDirectory: connection?.workingDirectory,
                shellStatus: connection?.shellStatus,
                lastExitCode: connection?.lastExitCode,
                terminalTheme: terminalTheme,
              ),
              isThreeLine: connection?.preview?.trim().isNotEmpty ?? false,
              trailing: Text(
                switch (connectionStates[connectionId] ??
                    SshConnectionState.disconnected) {
                  SshConnectionState.connected => 'Connected',
                  SshConnectionState.connecting => 'Connecting',
                  SshConnectionState.authenticating => 'Auth',
                  SshConnectionState.reconnecting => 'Reconnecting',
                  SshConnectionState.error => 'Error',
                  SshConnectionState.disconnected => 'Disconnected',
                },
                style: FluttyTheme.monoStyle.copyWith(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              onTap: () => Navigator.pop(context, 'connection:$connectionId'),
            );
          },
        ),
      ),
    );

    if (!context.mounted || selection == null) {
      return;
    }

    if (selection == 'new') {
      await _openNewConnection(context, ref);
      return;
    }

    final selectedId = int.tryParse(selection.replaceFirst('connection:', ''));
    if (selectedId != null) {
      context
          .findAncestorStateOfType<_HomeScreenState>()
          ?.switchToConnectionsTab();
      _openTerminalRoute(
        context,
        '/terminal/${host.id}?connectionId=$selectedId',
      );
    }
  }

  Future<void> _showContextMenuAtCenter(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      return;
    }

    final globalPosition = renderBox.localToGlobal(
      renderBox.size.center(Offset.zero),
    );
    await _showContextMenu(context, ref, globalPosition);
  }

  Future<void> _openNewConnection(BuildContext context, WidgetRef ref) async {
    final result = await connectToHostWithProgressDialog(context, ref, host);

    if (!context.mounted) {
      return;
    }

    if (!result.success || result.connectionId == null) {
      return;
    }

    if (context.mounted) {
      context
          .findAncestorStateOfType<_HomeScreenState>()
          ?.switchToConnectionsTab();
      _openTerminalRoute(
        context,
        '/terminal/${host.id}?connectionId=${result.connectionId}',
      );
    }
  }

  Future<void> _showContextMenu(
    BuildContext context,
    WidgetRef ref,
    Offset globalPosition,
  ) async {
    final colorScheme = Theme.of(context).colorScheme;
    final pinnedHomeScreenShortcutHostIds = ref.read(
      pinnedHomeScreenShortcutHostIdsProvider,
    );
    final isPinnedToHomeScreen =
        supportsHomeScreenShortcutActions &&
        (pinnedHomeScreenShortcutHostIds.asData?.value.contains(host.id) ??
            false);
    final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
    final connectionIds = sessionsNotifier.getConnectionsForHost(host.id);
    final disconnectLabel = connectionIds.length > 1
        ? 'Disconnect all'
        : 'Disconnect';

    final overlay = Overlay.maybeOf(context);
    final overlayBox = overlay?.context.findRenderObject() as RenderBox?;
    if (overlayBox == null) {
      return;
    }
    final selection = await showMenu<_HostContextAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
        Offset.zero & overlayBox.size,
      ),
      items: [
        const PopupMenuItem<_HostContextAction>(
          value: _HostContextAction.connect,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.link),
            title: Text('Connect'),
          ),
        ),
        const PopupMenuItem<_HostContextAction>(
          value: _HostContextAction.newConnection,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.add),
            title: Text('New connection'),
          ),
        ),
        if (connectionIds.isNotEmpty)
          PopupMenuItem<_HostContextAction>(
            value: _HostContextAction.disconnect,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.link_off_rounded),
              title: Text(disconnectLabel),
            ),
          ),
        if (supportsHomeScreenShortcutActions)
          PopupMenuItem<_HostContextAction>(
            value: _HostContextAction.toggleHomeScreen,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                isPinnedToHomeScreen ? Icons.home_rounded : Icons.home_outlined,
              ),
              title: Text(
                isPinnedToHomeScreen
                    ? 'Remove from Home Screen'
                    : 'Add to Home Screen',
              ),
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<_HostContextAction>(
          value: _HostContextAction.edit,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.edit_outlined),
            title: Text('Edit'),
          ),
        ),
        const PopupMenuItem<_HostContextAction>(
          value: _HostContextAction.duplicate,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.copy),
            title: Text('Duplicate'),
          ),
        ),
        PopupMenuItem<_HostContextAction>(
          value: _HostContextAction.export,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(useShareSheet ? Icons.share : Icons.save_alt),
            title: Text(
              useShareSheet
                  ? 'Share Encrypted (Pro)'
                  : 'Export Encrypted File (Pro)',
            ),
          ),
        ),
        PopupMenuItem<_HostContextAction>(
          value: _HostContextAction.delete,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_outline, color: colorScheme.error),
            title: Text('Delete', style: TextStyle(color: colorScheme.error)),
          ),
        ),
      ],
    );

    if (!context.mounted || selection == null) {
      return;
    }

    switch (selection) {
      case _HostContextAction.connect:
        await _openHostConnection(context, ref);
        return;
      case _HostContextAction.newConnection:
        await _openNewConnection(context, ref);
        return;
      case _HostContextAction.toggleHomeScreen:
        await _toggleHomeScreenShortcut(
          context,
          ref,
          isPinnedToHomeScreen: isPinnedToHomeScreen,
        );
        return;
      case _HostContextAction.disconnect:
        await _disconnectHostConnections(ref, connectionIds);
        return;
      case _HostContextAction.edit:
        unawaited(context.push('/hosts/edit/${host.id}'));
        return;
      case _HostContextAction.duplicate:
        await _duplicateHost(context, ref);
        return;
      case _HostContextAction.export:
        await _exportEncryptedFile(context, ref);
        return;
      case _HostContextAction.delete:
        await _confirmDelete(context, ref);
        return;
    }
  }

  Future<void> _toggleHomeScreenShortcut(
    BuildContext context,
    WidgetRef ref, {
    required bool isPinnedToHomeScreen,
  }) async {
    await ref
        .read(homeScreenShortcutPreferencesServiceProvider)
        .setHostPinned(host.id, pinned: !isPinnedToHomeScreen);
    if (!context.mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          isPinnedToHomeScreen
              ? 'Removed from home screen shortcuts'
              : 'Added to home screen shortcuts',
        ),
      ),
    );
  }

  Future<void> _exportEncryptedFile(BuildContext context, WidgetRef ref) async {
    final hasAccess = await requireMonetizationFeatureAccess(
      context: context,
      ref: ref,
      feature: MonetizationFeature.encryptedTransfers,
      blockedAction: 'Export encrypted host file',
      blockedOutcome:
          'Unlock Pro to share this host securely with another device.',
    );
    if (!hasAccess || !context.mounted) {
      return;
    }
    if ((host.password?.isNotEmpty ?? false) || host.keyId != null) {
      final isAuthorized = await authorizeSensitiveTransferExport(
        context: context,
        authService: ref.read(authServiceProvider),
        readAuthState: () => ref.read(authStateProvider),
        reason: 'Authenticate to export host credentials',
      );
      if (!context.mounted) {
        return;
      }
      if (!isAuthorized) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Authentication required for host export'),
          ),
        );
        return;
      }
    }

    final transferPassphrase = await showTransferPassphraseDialog(
      context: context,
      title: 'Host transfer passphrase',
    );
    if (!context.mounted || transferPassphrase == null) {
      return;
    }

    try {
      final payload = await ref
          .read(secureTransferServiceProvider)
          .createHostPayload(
            host: host,
            transferPassphrase: transferPassphrase,
            includeReferencedKey: host.keyId != null,
          );

      if (!context.mounted) {
        return;
      }

      final defaultFileName = sanitizeTransferFileBaseName(
        'host-${host.label.toLowerCase().replaceAll(' ', '-')}',
      );

      await saveTransferPayloadToFile(
        context: context,
        payload: payload,
        defaultFileName: defaultFileName,
        sharePositionOrigin: shareOriginFromContext(context),
      );
    } on FormatException catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } on Exception catch (error) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          library: 'home',
          context: ErrorDescription('while exporting host data'),
        ),
      );
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Export failed. Try again.')),
      );
    }
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Host'),
        content: Text('Delete "${host.label}"? This removes the saved host.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if ((confirmed ?? false) && context.mounted) {
      final deletedCount = await ref
          .read(hostRepositoryProvider)
          .delete(host.id);
      if (deletedCount > 0) {
        await ref
            .read(homeScreenShortcutPreferencesServiceProvider)
            .setHostPinned(host.id, pinned: false);
      }
    }
  }

  Future<void> _duplicateHost(BuildContext context, WidgetRef ref) async {
    await ref.read(duplicateHostCommandProvider).execute(host);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Host duplicated')));
    }
  }
}

class _ConnectionsPanel extends ConsumerWidget {
  const _ConnectionsPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionIds = ref.watch(connectionIdsProvider);
    final hosts = ref.watch(allHostsProvider).asData?.value ?? <Host>[];
    final hostLookup = {for (final host in hosts) host.id: host};
    final sessionsNotifier = ref.read(activeSessionsProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PanelHeader(title: 'connections'),
        Expanded(
          child: connectionIds.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24),
                    child: BrandEmptyState(
                      title: 'no active sessions',
                      message:
                          'Open a host and your live terminals show up here.',
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: connectionIds.length,
                  itemBuilder: (context, index) {
                    final connectionId = connectionIds[index];
                    final connection = sessionsNotifier.getActiveConnection(
                      connectionId,
                    );
                    return _ConnectionRow(
                      key: ValueKey(connectionId),
                      connectionId: connectionId,
                      host: hostLookup[connection?.hostId],
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ConnectionRow extends ConsumerWidget {
  const _ConnectionRow({required this.connectionId, this.host, super.key});

  final int connectionId;
  final Host? host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final previewEntry = ref.watch(
      connectionPreviewProvider((
        connectionId: connectionId,
        lightThemeId: host?.terminalThemeLightId,
        darkThemeId: host?.terminalThemeDarkId,
        isDark: theme.brightness == Brightness.dark,
      )),
    );
    ref.watch(
      activeSessionsProvider.select((states) {
        final connection = ref
            .read(activeSessionsProvider.notifier)
            .getActiveConnection(connectionId);
        return (
          states[connectionId],
          connection?.remoteMuxSessionName,
          connection?.remoteMuxBackend,
        );
      }),
    );
    final connection = ref
        .read(activeSessionsProvider.notifier)
        .getActiveConnection(connectionId);
    if (connection == null) return const SizedBox.shrink();
    final state = connection.state;
    final endpoint =
        '${connection.config.username}@'
        '${connection.config.hostname}:${connection.config.port}';
    void openConnection() => _openTerminalRoute(
      context,
      '/terminal/${connection.hostId}?connectionId=$connectionId',
    );
    final preferredTmuxSessionName = resolvePreferredTmuxSessionName(
      structuredSessionName: host?.tmuxSessionName,
      autoConnectCommand: host?.autoConnectCommand,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: _connectionTileHorizontalPadding,
          ),
          horizontalTitleGap: _connectionTileHorizontalTitleGap,
          minLeadingWidth: _connectionTileMinLeadingWidth,
          leading: Icon(
            Icons.terminal,
            color: state == SshConnectionState.connected
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
          ),
          title: Text(host?.label ?? 'Host ${connection.hostId}'),
          subtitle: Text('$endpoint  •  Connection #$connectionId'),
          trailing: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Disconnect',
            onPressed: () =>
                unawaited(_disconnectConnection(ref, connectionId)),
          ),
          onTap: openConnection,
        ),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: openConnection,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              _connectionPreviewLeadingInset,
              0,
              _connectionTileHorizontalPadding,
              8,
            ),
            child: ConnectionPreviewStack(
              entries: [previewEntry],
              onTap: openConnection,
            ),
          ),
        ),
        if (state == SshConnectionState.connected)
          _TmuxConnectionBadge(
            key: ValueKey('tmux-badge-$connectionId'),
            connectionId: connectionId,
            preferredSessionName:
                connection.remoteMuxSessionName ?? preferredTmuxSessionName,
            configuredMuxBackend:
                connection.remoteMuxBackend ??
                RemoteMuxBackendPresentation.fromStorageValue(
                  host?.remoteMuxBackend,
                ) ??
                RemoteMuxBackend.tmux,
            tmuxExtraFlags: host?.tmuxExtraFlags,
            onTap: openConnection,
          ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (primary) {
      return FilledButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(label),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      );
    }

    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16, color: colorScheme.onSurface.withAlpha(150)),
      label: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          color: colorScheme.onSurface.withAlpha(150),
        ),
      ),
    );
  }
}

class _SmallIconButton extends StatelessWidget {
  const _SmallIconButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final button = ExcludeSemantics(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        hoverColor: colorScheme.onSurface.withAlpha(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          child: Center(
            child: Icon(
              icon,
              size: 16,
              color: colorScheme.onSurface.withAlpha(120),
            ),
          ),
        ),
      ),
    );
    final semanticButton = Semantics(
      button: true,
      onTap: onTap,
      label: tooltip,
      child: button,
    );

    if (tooltip case final tooltipText?) {
      return Tooltip(
        message: tooltipText,
        excludeFromSemantics: true,
        child: semanticButton,
      );
    }
    return semanticButton;
  }
}

class _KeysPanel extends ConsumerWidget {
  const _KeysPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keysAsync = ref.watch(allKeysProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header bar
        PanelHeader(
          title: 'keys',
          actions: [
            _ActionButton(
              icon: Icons.add,
              label: 'Add Key',
              onTap: () => context.push('/keys/add'),
              primary: true,
            ),
          ],
        ),

        // Keys list
        Expanded(
          child: keysAsync.when(
            loading: () => const BrandListSkeleton(),
            error: (_, _) => BrandErrorState(
              title: 'couldn’t load keys',
              message: 'Your SSH keys didn’t load.',
              onRetry: () => ref.invalidate(allKeysProvider),
            ),
            data: (keys) => keys.isEmpty
                ? _buildEmptyState(context)
                : _buildKeysList(context, ref, keys),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: BrandEmptyState(
        title: 'no keys yet',
        message: 'Generate a key and stop saving server passwords.',
        primaryLabel: 'Generate Key',
        primaryIcon: Icons.enhanced_encryption,
        onPrimary: () => context.push('/keys/add'),
        secondaryActions: [
          BrandEmptyAction(
            icon: Icons.upload_file_outlined,
            label: 'Import Key',
            onTap: () => context.push('/keys/add?tab=import'),
          ),
        ],
      ),
    ),
  );

  Widget _buildKeysList(
    BuildContext context,
    WidgetRef ref,
    List<SshKey> keys,
  ) => ListView.builder(
    padding: const EdgeInsets.symmetric(vertical: 4),
    itemCount: keys.length,
    itemBuilder: (context, index) {
      final key = keys[index];
      return _KeyRow(sshKey: key);
    },
  );
}

class _KeyRow extends ConsumerWidget {
  const _KeyRow({required this.sshKey});

  final SshKey sshKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showKeyDetails(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colorScheme.outline.withAlpha(30)),
            ),
          ),
          child: Row(
            children: [
              // Key icon
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colorScheme.primary.withAlpha(isDark ? 25 : 15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  _getKeyIcon(),
                  size: 16,
                  color: colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),

              // Key info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sshKey.name,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      sshKey.keyType.toUpperCase(),
                      style: FluttyTheme.monoStyle.copyWith(
                        fontSize: 10,
                        color: colorScheme.onSurface.withAlpha(160),
                      ),
                    ),
                  ],
                ),
              ),

              // Transfer and key actions
              _SmallIconButton(
                icon: useShareSheet ? Icons.share : Icons.save_alt,
                tooltip: useShareSheet ? 'Share encrypted' : 'Export encrypted',
                onTap: () => unawaited(_exportEncryptedFile(context, ref)),
              ),
              _SmallIconButton(
                icon: Icons.copy,
                tooltip: 'Copy public key',
                onTap: () => _copyPublicKey(context),
              ),
              _SmallIconButton(
                icon: Icons.delete_outline,
                tooltip: 'Delete',
                onTap: () => _confirmDelete(context, ref),
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _getKeyIcon() {
    if (sshKey.keyType.toLowerCase().contains('ed25519')) {
      return Icons.enhanced_encryption;
    } else if (sshKey.keyType.toLowerCase().contains('rsa')) {
      return Icons.key;
    }
    return Icons.vpn_key;
  }

  void _copyPublicKey(BuildContext context) {
    Clipboard.setData(ClipboardData(text: sshKey.publicKey));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Public key copied')));
  }

  Future<void> _exportEncryptedFile(BuildContext context, WidgetRef ref) async {
    final hasAccess = await requireMonetizationFeatureAccess(
      context: context,
      ref: ref,
      feature: MonetizationFeature.encryptedTransfers,
      blockedAction: 'Export encrypted key file',
      blockedOutcome:
          'Unlock Pro to move this SSH key securely to another device.',
    );
    if (!hasAccess || !context.mounted) {
      return;
    }
    final isAuthorized = await authorizeSensitiveTransferExport(
      context: context,
      authService: ref.read(authServiceProvider),
      readAuthState: () => ref.read(authStateProvider),
      reason: 'Authenticate to export private key',
    );
    if (!context.mounted) {
      return;
    }
    if (!isAuthorized) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Authentication required for key export')),
      );
      return;
    }

    final transferPassphrase = await showTransferPassphraseDialog(
      context: context,
      title: 'Key transfer passphrase',
    );
    if (!context.mounted || transferPassphrase == null) {
      return;
    }

    try {
      final payload = await ref
          .read(secureTransferServiceProvider)
          .createKeyPayload(
            key: sshKey,
            transferPassphrase: transferPassphrase,
          );

      if (!context.mounted) {
        return;
      }

      final defaultFileName = sanitizeTransferFileBaseName(
        'key-${sshKey.name.toLowerCase().replaceAll(' ', '-')}',
      );

      await saveTransferPayloadToFile(
        context: context,
        payload: payload,
        defaultFileName: defaultFileName,
        sharePositionOrigin: shareOriginFromContext(context),
      );
    } on FormatException catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } on Exception catch (error) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          library: 'home',
          context: ErrorDescription('while exporting key data'),
        ),
      );
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Export failed. Try again.')),
      );
    }
  }

  void _showKeyDetails(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        maxChildSize: 0.9,
        minChildSize: 0.3,
        expand: false,
        builder: (context, scrollController) => Padding(
          padding: const EdgeInsets.all(20),
          child: ListView(
            controller: scrollController,
            children: [
              // Handle bar
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colorScheme.outline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(sshKey.name, style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                sshKey.keyType.toUpperCase(),
                style: TextStyle(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 20),
              Text('Public Key', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: colorScheme.outline.withAlpha(60)),
                ),
                child: SelectableText(
                  sshKey.publicKey,
                  style: FluttyTheme.monoStyle.copyWith(fontSize: 11),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => _copyPublicKey(context),
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy Public Key'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Key'),
        content: Text(
          'Delete "${sshKey.name}"? You’ll need the private key to reconnect.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if ((confirmed ?? false) && context.mounted) {
      await ref.read(keyRepositoryProvider).delete(sshKey.id);
    }
  }
}

/// Panel for displaying and managing snippets inline.
class SnippetsPanel extends ConsumerStatefulWidget {
  /// Creates a [SnippetsPanel].
  const SnippetsPanel({super.key});

  @override
  ConsumerState<SnippetsPanel> createState() => _SnippetsPanelState();
}

class _SnippetsPanelState extends ConsumerState<SnippetsPanel> {
  int? _selectedFolderId;
  bool _showsUnfiledSnippets = false;

  bool get _showsAllSnippets =>
      !_showsUnfiledSnippets && _selectedFolderId == null;

  @override
  Widget build(BuildContext context) {
    final snippetsAsync = ref.watch(allSnippetsProvider);
    final foldersAsync = ref.watch(allSnippetFoldersProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header bar
        PanelHeader(
          title: 'snippets',
          actions: [
            _ActionButton(
              icon: Icons.create_new_folder_outlined,
              label: 'New Folder',
              onTap: () => unawaited(_createFolder(context)),
            ),
            const SizedBox(width: 8),
            _ActionButton(
              icon: Icons.add,
              label: 'Add Snippet',
              onTap: () => _addSnippet(context),
              primary: true,
            ),
          ],
        ),

        // Snippets list
        Expanded(
          child: snippetsAsync.when(
            loading: () => const BrandListSkeleton(),
            error: (_, _) => BrandErrorState(
              title: 'couldn’t load snippets',
              message: 'Your snippets didn’t load.',
              onRetry: () => ref.invalidate(allSnippetsProvider),
            ),
            data: (snippets) => foldersAsync.when(
              loading: () => const BrandListSkeleton(),
              error: (_, _) => BrandErrorState(
                title: 'couldn’t load folders',
                message: 'Your snippet folders didn’t load.',
                onRetry: () => ref.invalidate(allSnippetFoldersProvider),
              ),
              data: (folders) => _buildSnippetsBody(context, snippets, folders),
            ),
          ),
        ),
      ],
    );
  }

  void _addSnippet(BuildContext context) {
    context.push(
      '/snippets/add',
      extra: SnippetEditPrefill(folderId: _selectedFolderId),
    );
  }

  Future<void> _createFolder(BuildContext context) async {
    final name = await showCreateSnippetFolderDialog(context);
    if (name == null || !context.mounted) {
      return;
    }

    try {
      final folderId = await ref
          .read(snippetRepositoryProvider)
          .insertFolder(SnippetFoldersCompanion.insert(name: name));
      if (!context.mounted) {
        return;
      }
      setState(() {
        _selectedFolderId = folderId;
        _showsUnfiledSnippets = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Created folder "$name"')));
    } on Exception catch (e) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          library: 'snippets',
          context: ErrorDescription('while creating a snippet folder'),
        ),
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not create folder. Try again.')),
        );
      }
    }
  }

  Future<void> _showFolderContextMenu(
    BuildContext context,
    LongPressStartDetails details,
    SnippetFolder folder,
    int snippetCount,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) {
      return;
    }

    final menuPosition = overlay.globalToLocal(details.globalPosition);
    final action = await showMenu<_SnippetFolderAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(menuPosition.dx, menuPosition.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem<_SnippetFolderAction>(
          value: _SnippetFolderAction.delete,
          child: Row(
            children: [
              Icon(Icons.delete_outline),
              SizedBox(width: 12),
              Text('Delete folder'),
            ],
          ),
        ),
      ],
    );

    if (action == _SnippetFolderAction.delete && context.mounted) {
      await _deleteFolder(context, folder, snippetCount);
    }
  }

  Future<void> _deleteFolder(
    BuildContext context,
    SnippetFolder folder,
    int snippetCount,
  ) async {
    final snippetLabel = snippetCount == 1
        ? '1 snippet'
        : '$snippetCount snippets';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${folder.name}"?'),
        content: Text(
          snippetCount == 0
              ? 'This folder will be removed.'
              : '$snippetLabel will move to No folder.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if ((confirmed ?? false) == false || !context.mounted) {
      return;
    }

    try {
      final deleted = await ref
          .read(snippetRepositoryProvider)
          .deleteFolder(folder.id);
      if (!context.mounted) {
        return;
      }
      setState(() {
        if (_selectedFolderId == folder.id) {
          _selectedFolderId = null;
          _showsUnfiledSnippets = snippetCount > 0;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            deleted == 0
                ? 'Folder "${folder.name}" was already deleted.'
                : 'Deleted folder "${folder.name}"',
          ),
        ),
      );
    } on Exception catch (e, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          stack: stackTrace,
          library: 'snippets',
          context: ErrorDescription('while deleting a snippet folder'),
        ),
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not delete folder. Try again.')),
        );
      }
    }
  }

  Widget _buildSnippetsBody(
    BuildContext context,
    List<Snippet> snippets,
    List<SnippetFolder> folders,
  ) {
    final folderIds = folders.map((folder) => folder.id).toSet();
    final selectedFolderId = folderIds.contains(_selectedFolderId)
        ? _selectedFolderId
        : null;
    SnippetFolder? selectedFolder;
    for (final folder in folders) {
      if (folder.id == selectedFolderId) {
        selectedFolder = folder;
        break;
      }
    }
    final visibleSnippets = _visibleSnippets(
      snippets,
      selectedFolderId: selectedFolderId,
    );
    final folderNames = {for (final folder in folders) folder.id: folder.name};
    final showsFolderFilters =
        folders.isNotEmpty ||
        snippets.any((snippet) => snippet.folderId == null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showsFolderFilters)
          _buildFolderFilters(
            snippets: snippets,
            folders: folders,
            selectedFolderId: selectedFolderId,
          ),
        Expanded(
          child: visibleSnippets.isEmpty
              ? _buildEmptyState(context, selectedFolder?.name)
              : _buildSnippetsList(
                  context,
                  snippets,
                  visibleSnippets,
                  folderNames,
                ),
        ),
      ],
    );
  }

  List<Snippet> _visibleSnippets(
    List<Snippet> snippets, {
    required int? selectedFolderId,
  }) {
    if (_showsUnfiledSnippets) {
      return snippets
          .where((snippet) => snippet.folderId == null)
          .toList(growable: false);
    }
    if (selectedFolderId == null) {
      return snippets;
    }
    return snippets
        .where((snippet) => snippet.folderId == selectedFolderId)
        .toList(growable: false);
  }

  Widget _buildFolderFilters({
    required List<Snippet> snippets,
    required List<SnippetFolder> folders,
    required int? selectedFolderId,
  }) {
    final unfiledCount = snippets
        .where((snippet) => snippet.folderId == null)
        .length;
    final folderCounts = <int, int>{};
    for (final snippet in snippets) {
      final folderId = snippet.folderId;
      if (folderId != null) {
        folderCounts[folderId] = (folderCounts[folderId] ?? 0) + 1;
      }
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          FilterChip(
            label: Text('All (${snippets.length})'),
            selected: _showsAllSnippets,
            onSelected: (_) => setState(() {
              _selectedFolderId = null;
              _showsUnfiledSnippets = false;
            }),
          ),
          if (unfiledCount > 0 || _showsUnfiledSnippets) ...[
            const SizedBox(width: 8),
            FilterChip(
              label: Text('No folder ($unfiledCount)'),
              selected: _showsUnfiledSnippets,
              onSelected: (_) => setState(() {
                _selectedFolderId = null;
                _showsUnfiledSnippets = true;
              }),
            ),
          ],
          for (final folder in folders) ...[
            const SizedBox(width: 8),
            Tooltip(
              message: 'Long press for folder actions',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPressStart: (details) => unawaited(
                  _showFolderContextMenu(
                    context,
                    details,
                    folder,
                    folderCounts[folder.id] ?? 0,
                  ),
                ),
                child: FilterChip(
                  label: Text(
                    '${folder.name} (${folderCounts[folder.id] ?? 0})',
                  ),
                  selected:
                      !_showsUnfiledSnippets && selectedFolderId == folder.id,
                  onSelected: (_) => setState(() {
                    _selectedFolderId = folder.id;
                    _showsUnfiledSnippets = false;
                  }),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, String? selectedFolderName) =>
      Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: BrandEmptyState(
            title: selectedFolderName == null
                ? 'no snippets yet'
                : 'empty folder',
            message: selectedFolderName == null
                ? 'Save commands you keep retyping — {{variables}} and all.'
                : 'Nothing in this folder yet — add one or pick another above.',
            primaryLabel: 'Add Snippet',
            onPrimary: () => _addSnippet(context),
          ),
        ),
      );

  Widget _buildSnippetsList(
    BuildContext context,
    List<Snippet> allSnippets,
    List<Snippet> visibleSnippets,
    Map<int, String> folderNames,
  ) => ReorderableListView.builder(
    padding: const EdgeInsets.symmetric(vertical: 4),
    buildDefaultDragHandles: false,
    itemCount: visibleSnippets.length,
    onReorderItem: (oldIndex, newIndex) => unawaited(
      _reorderSnippets(
        allSnippets: allSnippets,
        visibleSnippets: visibleSnippets,
        oldIndex: oldIndex,
        newIndex: newIndex,
      ),
    ),
    itemBuilder: (context, index) {
      final snippet = visibleSnippets[index];
      return _SnippetRow(
        key: ValueKey('home-snippet-${snippet.id}'),
        snippet: snippet,
        folderName: _showsAllSnippets && snippet.folderId != null
            ? folderNames[snippet.folderId]
            : null,
        reorderHandle: ReorderGrip(index: index),
      );
    },
  );

  Future<void> _reorderSnippets({
    required List<Snippet> allSnippets,
    required List<Snippet> visibleSnippets,
    required int oldIndex,
    required int newIndex,
  }) async {
    final reorderedIds = reorderVisibleIdsInFullOrder(
      allIds: allSnippets.map((snippet) => snippet.id).toList(growable: false),
      visibleIds: visibleSnippets
          .map((snippet) => snippet.id)
          .toList(growable: false),
      oldIndex: oldIndex,
      newIndex: newIndex,
    );
    await ref.read(snippetRepositoryProvider).reorderByIds(reorderedIds);
  }
}

enum _SnippetFolderAction { delete }

enum _SnippetContextAction { copy, edit, delete }

class _SnippetRow extends ConsumerWidget {
  const _SnippetRow({
    required this.snippet,
    required this.reorderHandle,
    this.folderName,
    super.key,
  });

  final Snippet snippet;
  final String? folderName;
  final Widget reorderHandle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _copySnippet(context, ref),
        onLongPress: () => unawaited(_showContextMenuAtCenter(context, ref)),
        onSecondaryTapDown: (details) =>
            unawaited(_showContextMenu(context, ref, details.globalPosition)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colorScheme.outline.withAlpha(30)),
            ),
          ),
          child: Row(
            children: [
              // Snippet icon
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colorScheme.primary.withAlpha(isDark ? 25 : 15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(Icons.code, size: 16, color: colorScheme.primary),
              ),
              const SizedBox(width: 12),

              // Snippet info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      snippet.name,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      snippet.command.replaceAll('\n', ' '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: FluttyTheme.monoStyle.copyWith(
                        fontSize: 10,
                        color: colorScheme.onSurface.withAlpha(150),
                      ),
                    ),
                    if (folderName case final folderName?) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.folder_outlined,
                            size: 12,
                            color: colorScheme.onSurface.withAlpha(140),
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              folderName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colorScheme.onSurface.withAlpha(120),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),

              Builder(
                builder: (buttonContext) => _SmallIconButton(
                  icon: Icons.more_vert,
                  tooltip: 'Snippet actions',
                  onTap: () =>
                      unawaited(_showContextMenuAtCenter(buttonContext, ref)),
                ),
              ),
              reorderHandle,
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showContextMenuAtCenter(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      return;
    }

    final globalPosition = renderBox.localToGlobal(
      renderBox.size.center(Offset.zero),
    );
    await _showContextMenu(context, ref, globalPosition);
  }

  Future<void> _showContextMenu(
    BuildContext context,
    WidgetRef ref,
    Offset globalPosition,
  ) async {
    final colorScheme = Theme.of(context).colorScheme;
    final overlay = Overlay.maybeOf(context);
    final overlayBox = overlay?.context.findRenderObject() as RenderBox?;
    if (overlayBox == null) {
      return;
    }

    final selection = await showMenu<_SnippetContextAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
        Offset.zero & overlayBox.size,
      ),
      items: [
        const PopupMenuItem<_SnippetContextAction>(
          value: _SnippetContextAction.copy,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.copy),
            title: Text('Copy command'),
          ),
        ),
        const PopupMenuItem<_SnippetContextAction>(
          value: _SnippetContextAction.edit,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.edit_outlined),
            title: Text('Edit'),
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<_SnippetContextAction>(
          value: _SnippetContextAction.delete,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_outline, color: colorScheme.error),
            title: Text('Delete', style: TextStyle(color: colorScheme.error)),
          ),
        ),
      ],
    );

    if (!context.mounted || selection == null) {
      return;
    }

    switch (selection) {
      case _SnippetContextAction.copy:
        _copySnippet(context, ref);
        return;
      case _SnippetContextAction.edit:
        unawaited(context.push('/snippets/edit/${snippet.id}'));
        return;
      case _SnippetContextAction.delete:
        await _confirmDelete(context, ref);
        return;
    }
  }

  void _copySnippet(BuildContext context, WidgetRef ref) {
    Clipboard.setData(ClipboardData(text: snippet.command));
    unawaited(ref.read(snippetRepositoryProvider).incrementUsage(snippet.id));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied "${snippet.name}" to clipboard')),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Snippet'),
        content: Text('Delete "${snippet.name}"? This can’t be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if ((confirmed ?? false) && context.mounted) {
      await ref.read(snippetRepositoryProvider).delete(snippet.id);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Deleted "${snippet.name}"')));
      }
    }
  }
}

/// Shows a compact tmux window badge below a connection tile.
///
/// Asynchronously queries tmux state for the given connection and displays
/// a horizontal list of window name chips if tmux is active.
class _TmuxConnectionBadge extends ConsumerStatefulWidget {
  const _TmuxConnectionBadge({
    required this.connectionId,
    required this.configuredMuxBackend,
    required this.onTap,
    this.preferredSessionName,
    this.tmuxExtraFlags,
    super.key,
  });

  final int connectionId;
  final RemoteMuxBackend configuredMuxBackend;
  final String? preferredSessionName;
  final String? tmuxExtraFlags;

  /// Called when the user taps a window chip — opens the terminal.
  final VoidCallback onTap;

  @override
  ConsumerState<_TmuxConnectionBadge> createState() =>
      _TmuxConnectionBadgeState();
}

class _TmuxConnectionBadgeState extends ConsumerState<_TmuxConnectionBadge> {
  static const _monkeyMuxSummaryIconAsset =
      'assets/icons/monkeyssh_icon_monochrome.png';
  static const _initialSessionFetchLimit = 24;
  static const _prefetchSessionFetchLimit = 6;
  static const _tmuxQueryRetryDelay = Duration(seconds: 2);

  List<TmuxWindow>? _windows;
  String? _preferredSessionToolName;
  String? _sessionName;
  RemoteMuxBackend _muxBackend = RemoteMuxBackend.tmux;
  bool _queried = false;
  bool _expanded = false;
  bool _showSessions = false;
  bool _hasInitializedSessionProviders = false;
  bool _restoredUiState = false;
  RemoteMuxBackend? _preferredAgentMuxBackend;
  String? _preferredAgentSessionName;
  StreamSubscription<TmuxWindowChangeEvent>? _windowChangeSubscription;
  Timer? _tmuxRetryTimer;
  bool _loadingWindows = false;
  bool _pendingWindowReload = false;
  bool _tmuxQueryScheduled = false;
  bool _needsTmuxQuery = true;
  bool _muxSessionEnding = false;
  int _windowReloadGeneration = 0;
  int _windowEventGeneration = 0;
  int _tmuxQueryGeneration = 0;

  @override
  void didUpdateWidget(covariant _TmuxConnectionBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    final connectionChanged = oldWidget.connectionId != widget.connectionId;
    final preferredSessionChanged =
        oldWidget.preferredSessionName != widget.preferredSessionName;
    final muxBackendChanged =
        oldWidget.configuredMuxBackend != widget.configuredMuxBackend;
    final tmuxExtraFlagsChanged =
        oldWidget.tmuxExtraFlags != widget.tmuxExtraFlags;
    if (connectionChanged ||
        preferredSessionChanged ||
        muxBackendChanged ||
        tmuxExtraFlagsChanged) {
      _tmuxQueryGeneration++;
      _tmuxRetryTimer?.cancel();
      _tmuxRetryTimer = null;
      final subscription = _windowChangeSubscription;
      _windowChangeSubscription = null;
      unawaited(subscription?.cancel());
      _muxSessionEnding = false;
      setState(() {
        _windows = null;
        _sessionName = null;
        _queried = false;
        _loadingWindows = false;
        _pendingWindowReload = false;
        if (tmuxExtraFlagsChanged) {
          _showSessions = false;
          _hasInitializedSessionProviders = false;
        }
      });
      _syncConnectionSessionTitle(null);
      _needsTmuxQuery = true;
    }
  }

  bool _isCurrentTmuxQuery(int generation) =>
      mounted && generation == _tmuxQueryGeneration;

  @override
  void dispose() {
    _tmuxRetryTimer?.cancel();
    unawaited(_windowChangeSubscription?.cancel());
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restoredUiState) return;
    _restoredUiState = true;

    final storedState = PageStorage.maybeOf(
      context,
    )?.readState(context, identifier: _pageStorageIdentifier);
    if (storedState is! Map<Object?, Object?>) return;

    _expanded = storedState['expanded'] as bool? ?? _expanded;
    _showSessions = storedState['showSessions'] as bool? ?? _showSessions;

    if (!_hasAgentSessionAccess) {
      _showSessions = false;
    }
    if (_showSessions) {
      _hasInitializedSessionProviders = true;
    }
  }

  String get _pageStorageIdentifier =>
      'tmux-badge-state-${widget.connectionId}-${widget.configuredMuxBackend.storageValue}';

  void _persistUiState() {
    PageStorage.maybeOf(context)?.writeState(context, <String, Object>{
      'expanded': _expanded,
      'showSessions': _showSessions,
    }, identifier: _pageStorageIdentifier);
  }

  bool get _hasAgentSessionAccess {
    final monetizationState =
        ref.read(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;
    return monetizationState.allowsFeature(
      MonetizationFeature.agentLaunchPresets,
    );
  }

  RemoteMuxBackend _resolveMuxBackend(SshSession session) {
    final activeBackend = session.remoteMuxBackend;
    if (activeBackend != null) {
      return activeBackend;
    }
    final preferredAgentBackend = _preferredAgentMuxBackend;
    if (preferredAgentBackend != null) {
      return preferredAgentBackend;
    }
    return widget.configuredMuxBackend == RemoteMuxBackend.auto
        ? RemoteMuxBackend.tmux
        : widget.configuredMuxBackend;
  }

  RemoteMultiplexerService _serviceForBackend(RemoteMuxBackend backend) =>
      backend == RemoteMuxBackend.monkeyMux
      ? ref.read(monkeyMuxServiceProvider)
      : ref.read(tmuxServiceProvider);

  Future<String?> _resolveMuxSessionName(
    SshSession session,
    RemoteMuxBackend backend,
  ) async {
    final activeSessionName = session.remoteMuxSessionName?.trim();
    if (activeSessionName != null &&
        activeSessionName.isNotEmpty &&
        session.remoteMuxBackend == backend) {
      return activeSessionName;
    }
    final preferredAgentSessionName = _preferredAgentSessionName;
    if (preferredAgentSessionName != null &&
        _preferredAgentMuxBackend == backend) {
      return preferredAgentSessionName;
    }
    final preferredSessionName = widget.preferredSessionName?.trim();
    if (preferredSessionName != null && preferredSessionName.isNotEmpty) {
      return preferredSessionName;
    }
    if (backend == RemoteMuxBackend.monkeyMux) {
      return null;
    }
    return ref
        .read(tmuxServiceProvider)
        .currentSessionName(session, extraFlags: widget.tmuxExtraFlags);
  }

  Future<void> _retryTmuxQuery(
    int retries, {
    required int expectedGeneration,
  }) async {
    if (!_isCurrentTmuxQuery(expectedGeneration)) {
      return;
    }
    if (retries <= 0) {
      setState(() => _queried = true);
      _scheduleTmuxRetry();
      return;
    }
    await Future<void>.delayed(_tmuxQueryRetryDelay);
    if (_isCurrentTmuxQuery(expectedGeneration)) {
      await _queryTmux(retries: retries - 1);
    }
  }

  Future<void> _handleLockedAiSessionsTap() => requireMonetizationFeatureAccess(
    context: context,
    ref: ref,
    feature: MonetizationFeature.agentLaunchPresets,
    blockedAction: 'Open coding-agent sessions from tmux',
    blockedOutcome:
        'Unlock Pro to discover and jump back into Codex, Claude Code, '
        'Copilot CLI, or OpenCode sessions.',
  );

  String? _resolveRecentSessionScopeWorkingDirectory(SshSession session) {
    final activeWindow = _windows?.where((w) => w.isActive).firstOrNull;
    return resolveAgentSessionScopeWorkingDirectory(
      activeWorkingDirectory: activeWindow?.currentPath,
      sessionWorkingDirectory: session.workingDirectory,
    );
  }

  String? _activeConnectionSessionTitle(List<TmuxWindow>? windows) => windows
      ?.where((window) => window.isActive)
      .firstOrNull
      ?.agentSessionDisplayTitle;

  void _syncConnectionSessionTitle(List<TmuxWindow>? windows) {
    ref
        .read(activeSessionsProvider.notifier)
        .updateConnectionSessionTitle(
          widget.connectionId,
          _activeConnectionSessionTitle(windows),
        );
  }

  Future<void> _prefetchPreferredSessionProvider() async {
    if (!_hasAgentSessionAccess) return;
    final toolName = _preferredSessionToolName;
    if (toolName == null || toolName.isEmpty) return;
    final session = ref
        .read(activeSessionsProvider.notifier)
        .getSession(widget.connectionId);
    if (session == null) return;

    await ref
        .read(agentSessionDiscoveryServiceProvider)
        .prefetchSessions(
          session,
          workingDirectory: _resolveRecentSessionScopeWorkingDirectory(session),
          maxPerTool: _prefetchSessionFetchLimit,
          toolName: toolName,
        );
  }

  void _scheduleTmuxRetry() {
    if (_tmuxRetryTimer?.isActive ?? false) return;
    _tmuxRetryTimer = Timer(const Duration(seconds: 10), () {
      _tmuxRetryTimer = null;
      if (mounted) {
        unawaited(_queryTmux());
      }
    });
  }

  Future<void> _queryTmux({int retries = 3}) async {
    final queryGeneration = ++_tmuxQueryGeneration;
    final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
    final session = sessionsNotifier.getSession(widget.connectionId);
    if (session == null) {
      _syncConnectionSessionTitle(null);
      // Session not available yet — retry after a delay so the badge
      // still appears for connections that finish establishing shortly.
      await _retryTmuxQuery(retries, expectedGeneration: queryGeneration);
      return;
    }

    final muxBackend = _resolveMuxBackend(session);
    final mux = _serviceForBackend(muxBackend);
    final sessionName = await _resolveMuxSessionName(session, muxBackend);
    if (!_isCurrentTmuxQuery(queryGeneration)) {
      return;
    }
    if (sessionName == null) {
      _syncConnectionSessionTitle(null);
      await _retryTmuxQuery(retries, expectedGeneration: queryGeneration);
      return;
    }
    _muxBackend = muxBackend;

    await _windowChangeSubscription?.cancel();
    if (!_isCurrentTmuxQuery(queryGeneration)) {
      return;
    }
    final generation = ++_windowEventGeneration;
    _windowChangeSubscription = mux
        .watchWindowChanges(
          session,
          sessionName,
          extraFlags: muxBackend == RemoteMuxBackend.tmux
              ? widget.tmuxExtraFlags
              : null,
        )
        .listen((event) {
          if (!_isCurrentTmuxQuery(queryGeneration)) return;
          _handleWindowChangeEvent(
            session,
            sessionName,
            event,
            generation,
            muxBackend,
            queryGeneration,
          );
        });
    await _refreshTmuxWindows(
      session,
      sessionName,
      muxBackend: muxBackend,
      queryGeneration: queryGeneration,
    );
  }

  void _handleWindowChangeEvent(
    SshSession session,
    String sessionName,
    TmuxWindowChangeEvent event,
    int generation,
    RemoteMuxBackend muxBackend,
    int queryGeneration,
  ) {
    if (!mounted || !_isCurrentTmuxQuery(queryGeneration)) return;
    if (generation != _windowEventGeneration) return;
    if (event is TmuxWindowReloadEvent) {
      _refreshTmuxWindows(
        session,
        sessionName,
        muxBackend: muxBackend,
        queryGeneration: queryGeneration,
      );
      return;
    }
    if (event is TmuxWindowListEvent) {
      _windowReloadGeneration += 1;
      _tmuxRetryTimer?.cancel();
      _tmuxRetryTimer = null;
      if (event.windows.isEmpty && muxBackend == RemoteMuxBackend.monkeyMux) {
        setState(() {
          _windows = const <TmuxWindow>[];
          _sessionName = sessionName;
          _muxBackend = muxBackend;
          _queried = true;
        });
        _syncConnectionSessionTitle(const <TmuxWindow>[]);
        unawaited(_disconnectEndedMonkeyMuxSession(session));
        return;
      }
      final currentWindows = _windows;
      final nextWindows = currentWindows == null
          ? event.windows
          : applyTmuxWindowChangeEvent(currentWindows, event);
      setState(() {
        _windows = nextWindows;
        _sessionName = sessionName;
        _muxBackend = muxBackend;
        _queried = true;
      });
      _syncConnectionSessionTitle(nextWindows);
      return;
    }
    final currentWindows = _windows;
    if (currentWindows == null) {
      _refreshTmuxWindows(
        session,
        sessionName,
        muxBackend: muxBackend,
        queryGeneration: queryGeneration,
      );
      return;
    }
    _windowReloadGeneration += 1;
    _tmuxRetryTimer?.cancel();
    _tmuxRetryTimer = null;
    final nextWindows = applyTmuxWindowChangeEvent(currentWindows, event);
    setState(() {
      _windows = nextWindows;
      _sessionName = sessionName;
      _muxBackend = muxBackend;
      _queried = true;
    });
    _syncConnectionSessionTitle(nextWindows);
  }

  Future<void> _refreshTmuxWindows(
    SshSession session,
    String sessionName, {
    required RemoteMuxBackend muxBackend,
    required int queryGeneration,
  }) async {
    if (!_isCurrentTmuxQuery(queryGeneration)) {
      return;
    }
    if (_loadingWindows) {
      _pendingWindowReload = true;
      return;
    }
    _loadingWindows = true;
    final reloadGeneration = ++_windowReloadGeneration;
    try {
      final mux = _serviceForBackend(muxBackend);
      final windows = await mux.listWindows(
        session,
        sessionName,
        extraFlags: muxBackend == RemoteMuxBackend.tmux
            ? widget.tmuxExtraFlags
            : null,
      );
      if (!_isCurrentTmuxQuery(queryGeneration)) {
        return;
      }
      if (reloadGeneration < _windowReloadGeneration) return;
      if (windows.isEmpty && muxBackend == RemoteMuxBackend.monkeyMux) {
        _tmuxRetryTimer?.cancel();
        _tmuxRetryTimer = null;
        setState(() {
          _windows = const <TmuxWindow>[];
          _sessionName = sessionName;
          _muxBackend = muxBackend;
          _queried = true;
        });
        _syncConnectionSessionTitle(const <TmuxWindow>[]);
        await _disconnectEndedMonkeyMuxSession(session);
        return;
      }
      if (windows.isEmpty) {
        _scheduleTmuxRetry();
      } else {
        _tmuxRetryTimer?.cancel();
        _tmuxRetryTimer = null;
      }
      setState(() {
        _windows = windows;
        _sessionName = sessionName;
        _muxBackend = muxBackend;
        _queried = true;
      });
      _syncConnectionSessionTitle(windows);
    } on Object {
      if (!_isCurrentTmuxQuery(queryGeneration)) {
        return;
      }
      _scheduleTmuxRetry();
      setState(() {
        _queried = true;
      });
    } finally {
      _loadingWindows = false;
      if (_pendingWindowReload && mounted) {
        _pendingWindowReload = false;
        unawaited(
          _isCurrentTmuxQuery(queryGeneration)
              ? _refreshTmuxWindows(
                  session,
                  sessionName,
                  muxBackend: muxBackend,
                  queryGeneration: queryGeneration,
                )
              : _queryTmux(),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final connectionState = ref.watch(
      activeSessionsProvider.select((state) => state[widget.connectionId]),
    );
    final hostId = ref.watch(
      activeSessionsProvider.select(
        (_) => ref
            .read(activeSessionsProvider.notifier)
            .getActiveConnection(widget.connectionId)
            ?.hostId,
      ),
    );
    final preferences = hostId == null
        ? null
        : ref.watch(hostAgentBadgePreferencesProvider(hostId));
    final preferred = preferences?.asData?.value;
    final preferredToolChanged =
        _preferredSessionToolName != preferred?.toolName;
    final preferencesChanged =
        preferredToolChanged ||
        _preferredAgentMuxBackend != preferred?.muxBackend ||
        _preferredAgentSessionName != preferred?.sessionName;
    _preferredSessionToolName = preferred?.toolName;
    _preferredAgentMuxBackend = preferred?.muxBackend;
    _preferredAgentSessionName = preferred?.sessionName;
    if (_showSessions && preferredToolChanged) {
      unawaited(_prefetchPreferredSessionProvider());
    }
    _needsTmuxQuery |= preferencesChanged;
    if (preferences?.isLoading != true &&
        !_tmuxQueryScheduled &&
        (_needsTmuxQuery ||
            (connectionState == SshConnectionState.connected &&
                !_loadingWindows &&
                !_queried))) {
      _tmuxQueryScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _tmuxQueryScheduled = false;
        _needsTmuxQuery = false;
        if (mounted) {
          unawaited(_queryTmux());
        }
      });
    }

    if (!_queried || _windows == null) {
      return const SizedBox.shrink();
    }

    final windows = _windows!;
    final activeSession = ref
        .read(activeSessionsProvider.notifier)
        .getSession(widget.connectionId);
    final nativeAcpSessions = _muxBackend == RemoteMuxBackend.monkeyMux
        ? () {
            final manager = ref.watch(acpSessionManagerProvider);
            final managerState =
                ref.watch(acpSessionManagerStateProvider).asData?.value ??
                manager.state;
            return managerState.sessions
                .where(
                  (session) =>
                      session.key.hostId == activeSession?.hostId &&
                      session.isOpenMuxWindow,
                )
                .toList(growable: false);
          }()
        : const <AcpSessionState>[];
    final nativeAcpEntries = buildAcpMuxWindowEntries(nativeAcpSessions);
    if (windows.isEmpty && nativeAcpEntries.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final hasAgentSessionAccess = _hasAgentSessionAccess;
    final totalWindowCount = windows.length + nativeAcpEntries.length;
    final firstNativeWindowIndex =
        windows.fold<int>(
          -1,
          (maximum, window) => window.index > maximum ? window.index : maximum,
        ) +
        1;
    final alertCount = windows.where((w) => w.hasAlert).length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(56, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Collapsed summary row — tap to expand/collapse.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              setState(() => _expanded = !_expanded);
              _persistUiState();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
              child: Row(
                children: [
                  _buildMuxSummaryIcon(theme),
                  const SizedBox(width: 4),
                  Text(
                    _sessionName != null
                        ? '$_sessionName · $totalWindowCount windows'
                        : '${_muxBackend.label} · $totalWindowCount windows',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (alertCount > 0) ...[
                    const SizedBox(width: 4),
                    Icon(
                      Icons.notifications_active,
                      size: 12,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      '$alertCount',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                  const Spacer(),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),

          // Expanded window list.
          if (_expanded) ...[
            const SizedBox(height: 4),
            for (final window in windows) _buildWindowRow(theme, window),
            for (var index = 0; index < nativeAcpEntries.length; index++)
              _buildNativeAcpWindowRow(
                theme,
                nativeAcpEntries[index],
                windowIndex: firstNativeWindowIndex + index,
              ),

            const SizedBox(height: 4),
            if (hasAgentSessionAccess) ...[
              // Recent AI Sessions subsection.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  final showSessions = !_showSessions;
                  setState(() {
                    _showSessions = showSessions;
                    if (showSessions) {
                      _hasInitializedSessionProviders = true;
                    }
                  });
                  _persistUiState();
                  if (showSessions) {
                    unawaited(_prefetchPreferredSessionProvider());
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 6,
                    horizontal: 2,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.smart_toy_outlined,
                        size: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'AI Sessions',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const Spacer(),
                      Icon(
                        _showSessions ? Icons.expand_less : Icons.expand_more,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
              if (_hasInitializedSessionProviders)
                Offstage(
                  offstage: !_showSessions,
                  child: Builder(
                    builder: (context) {
                      final session = ref
                          .read(activeSessionsProvider.notifier)
                          .getSession(widget.connectionId);
                      if (session == null) {
                        return const SizedBox.shrink();
                      }

                      final scopeWorkingDirectory =
                          _resolveRecentSessionScopeWorkingDirectory(session);
                      return AiSessionProviderList(
                        key: ValueKey<Object>(
                          Object.hashAll(<Object?>[
                            widget.connectionId,
                            _sessionName,
                            scopeWorkingDirectory,
                          ]),
                        ),
                        orderedTools: orderedDiscoveredSessionTools(
                          const <String, List<ToolSessionInfo>>{},
                          const <String>{},
                          preferredToolName: _preferredSessionToolName,
                        ),
                        loadSessions: (maxSessions) => ref
                            .read(agentSessionDiscoveryServiceProvider)
                            .discoverSessionsStream(
                              session,
                              workingDirectory: scopeWorkingDirectory,
                              maxPerTool: maxSessions,
                            ),
                        itemBuilder: (context, provider) =>
                            _buildSessionProviderRow(theme, provider),
                      );
                    },
                  ),
                ),
            ] else
              InkWell(
                onTap: () => unawaited(_handleLockedAiSessionsTap()),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 6,
                    horizontal: 2,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.smart_toy_outlined,
                        size: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'AI Sessions',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        Icons.workspace_premium,
                        size: 12,
                        color: theme.colorScheme.primary,
                      ),
                      const Spacer(),
                      Text(
                        'Pro',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildMuxSummaryIcon(ThemeData theme) {
    final color = theme.colorScheme.onSurfaceVariant;
    if (_muxBackend == RemoteMuxBackend.monkeyMux) {
      return ImageIcon(
        const AssetImage(_monkeyMuxSummaryIconAsset),
        key: const ValueKey('monkeymux-connection-summary-icon'),
        size: 14,
        color: color,
      );
    }
    return Icon(Icons.window_outlined, size: 14, color: color);
  }

  void _closeWindow(TmuxWindow window) {
    final session = ref
        .read(activeSessionsProvider.notifier)
        .getSession(widget.connectionId);
    if (session == null || _sessionName == null) return;

    final mux = _serviceForBackend(_muxBackend);
    final closesLastMonkeyMuxWindow =
        _muxBackend == RemoteMuxBackend.monkeyMux &&
        (_windows?.length ?? 0) <= 1;
    _runTmuxPreviewAction(() async {
      if (window.isNativeAcp) {
        await ref
            .read(acpSessionManagerProvider)
            .releaseSessionsForClosingMuxWindow(
              hostId: session.hostId,
              bridgeId: window.nativeAcpBridgeId!,
            );
      }
      await mux.killWindow(
        session,
        _sessionName!,
        window.index,
        windowId: window.id,
        extraFlags: _muxBackend == RemoteMuxBackend.tmux
            ? widget.tmuxExtraFlags
            : null,
      );
      if (closesLastMonkeyMuxWindow) {
        await _disconnectEndedMonkeyMuxSession(session);
      }
    }());

    // Optimistically remove from the list.
    setState(() {
      _windows = _windows
          ?.where(
            (w) =>
                window.id != null ? w.id != window.id : w.index != window.index,
          )
          .toList();
    });
  }

  Future<void> _disconnectEndedMonkeyMuxSession(SshSession session) async {
    if (_muxSessionEnding) {
      return;
    }
    _muxSessionEnding = true;
    DiagnosticsLogService.instance.info(
      'tmux.ui',
      'monkeymux_badge_disconnect',
      fields: {'connectionId': session.connectionId},
    );
    _tmuxRetryTimer?.cancel();
    _tmuxRetryTimer = null;
    final subscription = _windowChangeSubscription;
    _windowChangeSubscription = null;
    await subscription?.cancel();
    await ref.read(tmuxServiceProvider).clearCache(session.connectionId);
    await ref.read(monkeyMuxServiceProvider).clearCache(session.connectionId);
    await ref
        .read(activeSessionsProvider.notifier)
        .disconnect(session.connectionId);
  }

  void _switchAndOpenWindow(TmuxWindow window) {
    // Switch tmux to the target window before opening the terminal.
    final session = ref
        .read(activeSessionsProvider.notifier)
        .getSession(widget.connectionId);
    if (session != null && _sessionName != null) {
      final mux = _serviceForBackend(_muxBackend);
      _runTmuxPreviewAction(
        mux.selectWindow(
          session,
          _sessionName!,
          window.index,
          windowId: window.id,
          extraFlags: _muxBackend == RemoteMuxBackend.tmux
              ? widget.tmuxExtraFlags
              : null,
        ),
      );
    }
    widget.onTap();
  }

  void _runTmuxPreviewAction(Future<void> action) {
    unawaited(
      action.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Terminal window action failed. Check the session and try again.',
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _resumeSession(ToolSessionInfo info) async {
    if (!_hasAgentSessionAccess) {
      await _handleLockedAiSessionsTap();
      return;
    }
    final session = ref
        .read(activeSessionsProvider.notifier)
        .getSession(widget.connectionId);
    if (session == null || _sessionName == null) return;

    final cliLaunchPreferences = await ref
        .read(hostCliLaunchPreferencesServiceProvider)
        .getPreferencesForHost(session.hostId);
    if (!mounted) return;

    final discovery = ref.read(agentSessionDiscoveryServiceProvider);
    final command = discovery.buildResumeCommand(
      info,
      startInYoloMode: cliLaunchPreferences.startInYoloMode,
    );
    await _serviceForBackend(_muxBackend).createWindow(
      session,
      _sessionName!,
      command: command,
      name: info.toolName,
      workingDirectory: info.workingDirectory,
      extraFlags: _muxBackend == RemoteMuxBackend.tmux
          ? widget.tmuxExtraFlags
          : null,
    );
    if (mounted) {
      widget.onTap();
    }
  }

  Future<void> _showSessionPickerForTool(
    AiSessionProviderEntry provider,
  ) async {
    final session = ref
        .read(activeSessionsProvider.notifier)
        .getSession(widget.connectionId);
    if (session == null) return;

    final selected = await showAiSessionPickerDialog(
      context: context,
      toolName: provider.toolName,
      initialMaxSessions: _initialSessionFetchLimit,
      loadSessions: (maxSessions) => ref
          .read(agentSessionDiscoveryServiceProvider)
          .discoverSessionsStream(
            session,
            workingDirectory: _resolveRecentSessionScopeWorkingDirectory(
              session,
            ),
            maxPerTool: maxSessions,
            toolName: provider.toolName,
          ),
    );
    if (!mounted || selected == null) return;
    _runTmuxPreviewAction(_resumeSession(selected));
  }

  Widget _buildSessionProviderRow(
    ThemeData theme,
    AiSessionProviderEntry provider,
  ) => InkWell(
    onTap: () => unawaited(_showSessionPickerForTool(provider)),
    borderRadius: BorderRadius.circular(6),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
      child: Row(
        children: [
          AgentToolIcon(
            toolName: provider.toolName,
            size: 14,
            color: provider.hasFailure
                ? theme.colorScheme.error
                : theme.colorScheme.primary,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              provider.toolName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: provider.hasFailure
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (provider.isLoading && !provider.hasSessions)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator.adaptive(strokeWidth: 2),
            )
          else ...[
            if (provider.isLoading) ...[
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator.adaptive(strokeWidth: 2),
              ),
              const SizedBox(width: 4),
            ],
            Text(
              provider.compactStatusLabel,
              style: theme.textTheme.labelSmall?.copyWith(
                color: provider.hasFailure
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
            ...[
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ],
        ],
      ),
    ),
  );

  Widget _buildNativeAcpWindowRow(
    ThemeData theme,
    AcpSwitcherEntry entry, {
    required int windowIndex,
  }) {
    final session = entry.session!;
    final key = session.key;
    final identityColor = agentWindowIdentityColor(
      theme.colorScheme,
      isActive: false,
    );
    final agentTool = agentLaunchToolForBuiltinAcpProviderId(key.providerId);

    return InkWell(
      key: ValueKey('connection-native-acp-window-${key.value}'),
      onTap: () => unawaited(
        context.push<void>(
          buildAgentChatLocation(
            hostId: key.hostId,
            providerId: key.providerId,
            bridgeId: key.bridgeId,
            acpSessionId: key.acpSessionId,
          ),
        ),
      ),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
        child: Row(
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              alignment: Alignment.center,
              child: Text(
                '$windowIndex',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10,
                  color: identityColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: AgentToolIcon(
                key: ValueKey('connection-native-acp-agent-icon-${key.value}'),
                tool: agentTool,
                size: 14,
                color: identityColor,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Container(
                        key: ValueKey(
                          'connection-native-acp-indicator-${key.value}',
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: identityColor.withAlpha(24),
                          border: Border.all(
                            color: identityColor.withAlpha(110),
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'NATIVE',
                          style: FluttyTheme.monoStyle.copyWith(
                            color: identityColor,
                            fontSize: 7,
                            height: 1,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          entry.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    '${session.providerLabel} · ${acpCwdSummary(session.cwd)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 10,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 6, right: 6),
              child: AcpMuxWindowStatusBadge(session: session),
            ),
            GestureDetector(
              onTap: () async {
                try {
                  await ref.read(acpSessionManagerProvider).stopSession(key);
                } on Object {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Could not stop the native session. Try again.',
                      ),
                    ),
                  );
                }
              },
              child: Icon(
                Icons.close,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWindowRow(ThemeData theme, TmuxWindow window) {
    final title = window.displayTitle;
    final secondaryTitle = window.secondaryTitle;
    final iconColor = agentWindowIdentityColor(
      theme.colorScheme,
      isActive: window.isActive,
    );

    return InkWell(
      onTap: () => _switchAndOpenWindow(window),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
        child: Row(
          children: [
            // Window index badge.
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: window.isActive
                    ? theme.colorScheme.primary
                    : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              alignment: Alignment.center,
              child: Text(
                '${window.index}',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10,
                  color: window.isActive
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 6),
            // Alert icon.
            if (window.hasAlert)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(
                  Icons.notifications_active,
                  size: 12,
                  color: theme.colorScheme.error,
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: AgentToolIcon(
                tool: window.foregroundAgentTool,
                size: 14,
                color: iconColor,
                fallbackIcon: Icons.terminal,
              ),
            ),
            // Title — truncated.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: window.isActive
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface,
                      fontWeight: window.isActive
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                  if (secondaryTitle != null)
                    Text(
                      secondaryTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 6, right: 6),
              child: TmuxWindowStatusBadge(window: window),
            ),
            // Close button.
            GestureDetector(
              onTap: () => _closeWindow(window),
              child: Icon(
                Icons.close,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
