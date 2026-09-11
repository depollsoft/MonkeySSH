import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database/database.dart';
import '../data/repositories/host_repository.dart';
import '../domain/models/terminal_theme.dart';
import '../domain/models/terminal_themes.dart';
import '../domain/services/acp_lifecycle_service.dart';
import '../domain/services/auth_service.dart';
import '../domain/services/background_ssh_service.dart';
import '../domain/services/home_screen_shortcut_service.dart';
import '../domain/services/local_notification_service.dart';
import '../domain/services/monetization_service.dart';
import '../domain/services/settings_service.dart';
import '../domain/services/ssh_service.dart';
import '../domain/services/telemetry_service.dart';
import '../domain/services/terminal_theme_service.dart';
import 'app_metadata.dart';
import 'auth_lifecycle_controller.dart';
import 'notification_navigation.dart';
import 'router.dart';
import 'theme.dart';

/// The root widget of the Flutty application.
class FluttyApp extends ConsumerWidget {
  /// Creates a new [FluttyApp].
  const FluttyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(themeModeNotifierProvider);
    final terminalThemesApplyToApp = ref.watch(
      terminalThemesApplyToAppNotifierProvider,
    );
    late final ThemeData lightTheme;
    late final ThemeData darkTheme;

    if (terminalThemesApplyToApp) {
      final terminalThemeSettings = ref.watch(terminalThemeSettingsProvider);
      final terminalAppThemeOverride = ref.watch(
        terminalAppThemeOverrideProvider,
      );
      final terminalThemes =
          ref.watch(allTerminalThemesProvider).asData?.value ??
          TerminalThemes.all;
      lightTheme = buildTerminalAppTheme(
        brightness: Brightness.light,
        terminalThemeSettings: terminalThemeSettings,
        terminalThemes: terminalThemes,
        terminalAppThemeOverride: terminalAppThemeOverride,
      );
      darkTheme = buildTerminalAppTheme(
        brightness: Brightness.dark,
        terminalThemeSettings: terminalThemeSettings,
        terminalThemes: terminalThemes,
        terminalAppThemeOverride: terminalAppThemeOverride,
      );
    } else {
      lightTheme = FluttyTheme.light;
      darkTheme = FluttyTheme.dark;
    }
    final appName = ref.watch(appDisplayNameProvider);

    return _BackgroundLifecycleBridge(
      child: MaterialApp.router(
        title: appName,
        debugShowCheckedModeBanner: false,
        theme: lightTheme,
        darkTheme: darkTheme,
        themeMode: themeMode,
        routerConfig: router,
      ),
    );
  }
}

/// Builds an app [ThemeData] from global settings plus active terminal overrides.
@visibleForTesting
ThemeData buildTerminalAppTheme({
  required Brightness brightness,
  required TerminalThemeSettings terminalThemeSettings,
  required List<TerminalThemeData> terminalThemes,
  TerminalAppThemeOverride? terminalAppThemeOverride,
}) {
  final themeId = switch (brightness) {
    Brightness.light =>
      terminalAppThemeOverride?.lightThemeId ??
          terminalThemeSettings.lightThemeId,
    Brightness.dark =>
      terminalAppThemeOverride?.darkThemeId ??
          terminalThemeSettings.darkThemeId,
  };
  final terminalTheme = TerminalThemes.resolveById(
    brightness: brightness,
    themeId: themeId,
    additionalThemes: terminalThemes,
  );
  return FluttyTheme.fromTerminalTheme(terminalTheme, brightness: brightness);
}

class _BackgroundLifecycleBridge extends ConsumerStatefulWidget {
  const _BackgroundLifecycleBridge({required this.child});

  final Widget child;

  @override
  ConsumerState<_BackgroundLifecycleBridge> createState() =>
      _BackgroundLifecycleBridgeState();
}

class _BackgroundLifecycleBridgeState
    extends ConsumerState<_BackgroundLifecycleBridge>
    with WidgetsBindingObserver {
  StreamSubscription<List<Host>>? _homeScreenShortcutHostsSubscription;
  StreamSubscription<Set<int>>? _pinnedHomeScreenShortcutHostsSubscription;
  StreamSubscription<TmuxAlertNotificationPayload>? _tmuxAlertTapSubscription;
  StreamSubscription<TerminalNotificationPayload>?
  _terminalNotificationTapSubscription;
  StreamSubscription<AcpNotificationPayload>? _acpNotificationTapSubscription;
  ProviderSubscription<AuthState>? _authStateSubscription;
  List<Host> _latestHomeScreenShortcutHosts = const <Host>[];
  Set<int> _latestPinnedHomeScreenShortcutHostIds = const <int>{};
  bool _hasLoadedHomeScreenShortcutHosts = false;
  bool _hasLoadedPinnedHomeScreenShortcutHostIds = false;
  late final _tmuxAlertNavigation =
      NotificationNavigationScheduler<TmuxAlertNotificationPayload>(
        canNavigate: () =>
            mounted &&
            _canOpenTmuxAlertNotification(ref.read(authStateProvider)),
        open: (payload) => openTmuxAlertNotificationStack(
          router: ref.read(routerProvider),
          payload: payload,
          notificationTapId: '${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
  late final _terminalNavigation =
      NotificationNavigationScheduler<TerminalNotificationPayload>(
        canNavigate: () =>
            mounted &&
            _canOpenTmuxAlertNotification(ref.read(authStateProvider)),
        open: (payload) => openTerminalNotificationStack(
          router: ref.read(routerProvider),
          payload: payload,
          notificationTapId: '${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
  late final _acpNavigation =
      NotificationNavigationScheduler<AcpNotificationPayload>(
        canNavigate: () =>
            mounted &&
            _canOpenTmuxAlertNotification(ref.read(authStateProvider)),
        open: (payload) => openAcpNotificationStack(
          router: ref.read(routerProvider),
          payload: payload,
        ),
      );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startTmuxAlertNotificationRouting();
    _runLifecycleSync(
      _initializeTmuxAlertNotificationRouting,
      errorContext:
          'while initializing tmux alert notification routing during app startup',
      defer: true,
    );
    if (supportsHomeScreenShortcutActions) {
      _listenForHomeScreenShortcutChanges();
      _runLifecycleSync(
        () => ref.read(homeScreenShortcutServiceProvider).initialize(),
        errorContext:
            'while initializing home-screen shortcuts during app startup',
        defer: true,
      );
    }
    _runLifecycleSync(
      _refreshMonetizationOnStartup,
      errorContext: 'while refreshing subscription state during app startup',
      defer: true,
    );
    _runLifecycleSync(
      _syncForegroundBackgroundStatus,
      errorContext: 'while syncing background SSH status during app startup',
      defer: true,
    );
    _runLifecycleSync(
      _recordTelemetryPromptAppLaunch,
      errorContext: 'while recording telemetry prompt launch state',
      defer: true,
    );
    _runLifecycleSync(
      _recordAppStartedTelemetry,
      errorContext: 'while recording app startup telemetry',
      defer: true,
    );
    // Activates the ACP auth-lock and SSH-disconnect cleanup listeners; both
    // are no-ops until an ACP session actually exists.
    ref
      ..read(acpAuthLockWatcherProvider)
      ..read(acpSshConnectivityWatcherProvider);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_homeScreenShortcutHostsSubscription?.cancel());
    unawaited(_pinnedHomeScreenShortcutHostsSubscription?.cancel());
    unawaited(_tmuxAlertTapSubscription?.cancel());
    unawaited(_terminalNotificationTapSubscription?.cancel());
    unawaited(_acpNotificationTapSubscription?.cancel());
    _authStateSubscription?.close();
    super.dispose();
  }

  void _startTmuxAlertNotificationRouting() {
    final notificationService = ref.read(localNotificationServiceProvider);
    _tmuxAlertTapSubscription = notificationService.tmuxAlertTaps.listen(
      _handleTmuxAlertNotification,
    );
    _terminalNotificationTapSubscription = notificationService
        .terminalNotificationTaps
        .listen(_handleTerminalNotification);
    _acpNotificationTapSubscription = notificationService.acpNotificationTaps
        .listen(_handleAcpNotification);
    _authStateSubscription = ref.listenManual<AuthState>(authStateProvider, (
      previous,
      next,
    ) {
      if (_canOpenTmuxAlertNotification(next)) {
        _tmuxAlertNavigation.flush();
        _terminalNavigation.flush();
        _acpNavigation.flush();
      }
    });
  }

  Future<void> _initializeTmuxAlertNotificationRouting() async {
    final notificationService = ref.read(localNotificationServiceProvider);
    await notificationService.initialize();
    final launchAlert = await notificationService.consumeLaunchTmuxAlert();
    if (launchAlert != null) {
      _handleTmuxAlertNotification(launchAlert);
    }
    final launchTerminalNotification = await notificationService
        .consumeLaunchTerminalNotification();
    if (launchTerminalNotification != null) {
      _handleTerminalNotification(launchTerminalNotification);
    }
    final launchAcpNotification = await notificationService
        .consumeLaunchAcpNotification();
    if (launchAcpNotification != null) {
      _handleAcpNotification(launchAcpNotification);
    }
  }

  bool _canOpenTmuxAlertNotification(AuthState authState) =>
      authState != AuthState.unknown && authState != AuthState.locked;

  void _handleTmuxAlertNotification(TmuxAlertNotificationPayload payload) {
    _tmuxAlertNavigation.add(payload);
  }

  void _handleTerminalNotification(TerminalNotificationPayload payload) {
    try {
      ref
          .read(activeSessionsProvider.notifier)
          .handleTerminalNotificationTap(payload);
    } on Object {
      // The notification can outlive its SSH channel; navigation still
      // succeeds even when best-effort protocol reports cannot be sent.
    }
    if (payload.focusOnActivation) {
      _terminalNavigation.add(payload);
    }
  }

  void _handleAcpNotification(AcpNotificationPayload payload) {
    _acpNavigation.add(payload);
  }

  void _listenForHomeScreenShortcutChanges() {
    final hostRepository = ref.read(hostRepositoryProvider);
    _homeScreenShortcutHostsSubscription = hostRepository.watchAll().listen((
      hosts,
    ) {
      _latestHomeScreenShortcutHosts = hosts;
      _hasLoadedHomeScreenShortcutHosts = true;
      _runLifecycleSync(
        _syncHomeScreenShortcuts,
        errorContext:
            'while syncing home-screen shortcuts after the host list changed',
      );
    });

    final preferencesService = ref.read(
      homeScreenShortcutPreferencesServiceProvider,
    );
    _pinnedHomeScreenShortcutHostsSubscription = preferencesService
        .watchPinnedHostIds()
        .listen((hostIds) {
          _latestPinnedHomeScreenShortcutHostIds = hostIds;
          _hasLoadedPinnedHomeScreenShortcutHostIds = true;
          _runLifecycleSync(
            _syncHomeScreenShortcuts,
            errorContext:
                'while syncing home-screen shortcuts after pinned hosts changed',
          );
        });
  }

  Future<void> _syncForegroundBackgroundStatus() async {
    await BackgroundSshService.setForegroundState(isForeground: true);
    await ref.read(activeSessionsProvider.notifier).syncBackgroundStatus();
    await ref.read(acpLifecycleServiceProvider).handleForeground();
  }

  Future<void> _syncBackgroundState() async {
    await BackgroundSshService.setForegroundState(isForeground: false);
    await ref.read(acpLifecycleServiceProvider).handleBackground();
  }

  Future<void> _refreshMonetizationOnStartup() async {
    await ref.read(monetizationServiceProvider).initialize();
  }

  Future<void> _recordTelemetryPromptAppLaunch() async {
    await ref
        .read(telemetryOptInPromptNotifierProvider.notifier)
        .recordAppLaunch();
  }

  Future<void> _recordAppStartedTelemetry() async {
    final appMetadata = await ref.read(appMetadataProvider.future);
    await ref
        .read(telemetryServiceProvider)
        .logAppStarted(appMetadata: appMetadata);
  }

  Future<void> _syncHomeScreenShortcuts() async {
    if (!_hasLoadedHomeScreenShortcutHosts ||
        !_hasLoadedPinnedHomeScreenShortcutHostIds) {
      return;
    }

    await ref
        .read(homeScreenShortcutServiceProvider)
        .updateShortcuts(
          hosts: _latestHomeScreenShortcutHosts,
          pinnedHostIds: _latestPinnedHomeScreenShortcutHostIds,
        );
  }

  Future<void> _syncAuthLifecycle(AppLifecycleState state) => ref
      .read(authLifecycleControllerProvider)
      .handleLifecycleStateChanged(state);

  void _runLifecycleSync(
    Future<void> Function() operation, {
    required String errorContext,
    bool defer = false,
  }) {
    final future = defer ? Future<void>.microtask(operation) : operation();
    unawaited(
      future.catchError((Object error, StackTrace stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'app',
            context: ErrorDescription(errorContext),
          ),
        );
      }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isForeground = switch (state) {
      AppLifecycleState.resumed || AppLifecycleState.inactive => true,
      AppLifecycleState.hidden ||
      AppLifecycleState.paused ||
      AppLifecycleState.detached => false,
    };
    _runLifecycleSync(
      () async {
        await _syncAuthLifecycle(state);
        if (isForeground) {
          await _syncForegroundBackgroundStatus();
        } else {
          await _syncBackgroundState();
        }
      },
      errorContext: isForeground
          ? 'while syncing background SSH status and auth lock state after returning to the foreground'
          : 'while syncing background SSH status and auth lock state after moving to the background',
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
