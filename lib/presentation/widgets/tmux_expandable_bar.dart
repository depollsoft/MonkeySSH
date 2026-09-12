part of '../screens/terminal_screen.dart';

/// Whether a window snapshot changed terminal identity or theme context.
@visibleForTesting
bool shouldRefreshTmuxThemeAfterWindowChange(
  List<TmuxWindow> previousWindows,
  List<TmuxWindow> nextWindows,
) {
  if (previousWindows.length != nextWindows.length) {
    return true;
  }
  final byId = <String, TmuxWindow>{};
  final byIndex = <int, TmuxWindow>{};
  for (final window in previousWindows) {
    if (window.id case final id?) byId.putIfAbsent(id, () => window);
    byIndex.putIfAbsent(window.index, () => window);
  }
  for (final nextWindow in nextWindows) {
    final previousWindow = nextWindow.id == null
        ? byIndex[nextWindow.index]
        : byId[nextWindow.id];
    if (previousWindow == null ||
        _tmuxWindowRefreshIdentity(previousWindow) !=
            _tmuxWindowRefreshIdentity(nextWindow)) {
      return true;
    }
  }
  return false;
}

({
  String? currentCommand,
  AgentLaunchTool? foregroundAgentTool,
  String? id,
  int index,
  bool isActive,
  int? panePid,
  String? paneStartCommand,
})
_tmuxWindowRefreshIdentity(TmuxWindow window) => (
  currentCommand: window.currentCommand,
  foregroundAgentTool: window.foregroundAgentTool,
  id: window.id,
  index: window.index,
  isActive: window.isActive,
  panePid: window.panePid,
  paneStartCommand: window.paneStartCommand,
);

/// Builds the compact native-agent identity used by collapsed mux handles.
///
/// The provider mark identifies the agent and the chat badge distinguishes a
/// native ACP pane from a terminal window running the same tool. Window numbers
/// remain in the expanded window list, matching terminal-bar behavior.
@visibleForTesting
Widget buildNativeAcpHandleIcon({
  required ThemeData theme,
  required AgentLaunchTool? tool,
}) {
  final color = theme.colorScheme.primary;
  return SizedBox(
    width: 22,
    height: 20,
    child: Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.centerLeft,
      children: [
        AgentToolIcon(
          key: const ValueKey('native-acp-handle-icon'),
          tool: tool,
          size: 16,
          color: color,
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: AcpNativeBadge(
            key: const ValueKey('native-acp-handle-indicator'),
            color: color,
            size: 10,
          ),
        ),
      ],
    ),
  );
}

/// Builds the persistent bar in isolation for notification lifecycle tests.
@visibleForTesting
Widget buildTmuxExpandableBarTestHost({
  required WidgetRef ref,
  required SshSession session,
  required RemoteMultiplexerService remoteMultiplexerService,
}) => _TmuxExpandableBar(
  session: session,
  tmuxSessionName: 'main',
  availableHeight: 400,
  placement: TmuxBarPlacement.bottomOverlay,
  recoveryGeneration: 0,
  isProUser: false,
  startClisInYoloMode: false,
  initiallyExpanded: true,
  ref: ref,
  remoteMultiplexerService: remoteMultiplexerService,
  activeMuxBackend: RemoteMuxBackend.tmux,
  onAction: (_) async {},
  onExpandedChanged: (_) {},
  onSidebarDragOffsetChanged: (_) {},
);

/// Expandable tmux bar shown as a bottom overlay or a wide-layout side rail.
///
/// Bottom overlay collapsed: a slim handle bar sitting over bottom padding in
/// the terminal. Bottom overlay expanded: slides up over the terminal content.
/// Sidebar collapsed: a vertical window switcher rail. Sidebar expanded: a
/// master/detail panel docked beside the terminal.
class _TmuxExpandableBar extends StatefulWidget {
  const _TmuxExpandableBar({
    required this.session,
    required this.tmuxSessionName,
    required this.availableHeight,
    required this.placement,
    required this.recoveryGeneration,
    required this.isProUser,
    required this.startClisInYoloMode,
    required this.initiallyExpanded,
    required this.ref,
    required this.remoteMultiplexerService,
    required this.activeMuxBackend,
    required this.onAction,
    required this.onExpandedChanged,
    required this.onSidebarDragOffsetChanged,
    this.tmuxExtraFlags,
    this.scopeWorkingDirectory,
    this.activeNativeAcpSessionKey,
    this.onWindowsChanged,
    this.onWindowStateChanged,
    this.onActiveWindowTerminalModeChanged,
    this.onWindowLoadStalled,
    this.onSessionEnded,
    super.key,
  });

  /// The active SSH session.
  final SshSession session;

  /// The tmux session name.
  final String tmuxSessionName;

  /// Optional extra flags for tmux commands (e.g. custom socket path).
  final String? tmuxExtraFlags;

  /// The available terminal height the bar can expand into.
  final double availableHeight;

  /// Where the bar is rendered in the terminal layout.
  final TmuxBarPlacement placement;

  /// Forces state recovery when tmux window loading stalls.
  final int recoveryGeneration;

  /// Whether the user has Pro access.
  final bool isProUser;

  /// Whether supported coding CLIs should launch in YOLO mode for this host.
  final bool startClisInYoloMode;

  /// Whether the tmux window list should start expanded.
  final bool initiallyExpanded;

  /// Riverpod ref.
  final WidgetRef ref;

  /// Backend used to load and watch remote windows.
  final RemoteMultiplexerService remoteMultiplexerService;

  /// Active multiplexer backend for backend-specific lifecycle behavior.
  final RemoteMuxBackend activeMuxBackend;

  /// Callback for navigator actions.
  final Future<void> Function(TmuxNavigatorAction) onAction;

  /// Called when the expanded/collapsed state changes.
  final ValueChanged<bool> onExpandedChanged;

  /// Called as the sidebar is dragged horizontally so the parent can resize.
  final ValueChanged<double> onSidebarDragOffsetChanged;

  /// Called whenever the full remote window snapshot changes.
  final ValueChanged<List<TmuxWindow>>? onWindowsChanged;

  final void Function(
    SshSession session,
    String sessionName, {
    required bool activeWindowChanged,
  })?
  onWindowStateChanged;

  /// Called when the active window's terminal-mode metadata changes without the
  /// active window itself changing — for example when the foreground app enters
  /// or leaves mouse or bracketed-paste mode. Lets the parent inherit the active
  /// mux window's local terminal modes without waiting for a window switch.
  final VoidCallback? onActiveWindowTerminalModeChanged;

  final Future<void> Function(SshSession session, String sessionName)?
  onWindowLoadStalled;

  final Future<void> Function(SshSession session, String sessionName)?
  onSessionEnded;

  /// Best-known project working directory for AI session scoping.
  final String? scopeWorkingDirectory;

  /// Native ACP session currently replacing the terminal viewport.
  final AcpSessionKey? activeNativeAcpSessionKey;

  /// Height of the collapsed handle bar. The terminal adds this as
  /// bottom padding so the handle sits over empty space.
  static const handleHeight = tmuxHandleMinTouchExtent;

  @override
  State<_TmuxExpandableBar> createState() => _TmuxExpandableBarState();
}

class _TmuxExpandableBarState extends State<_TmuxExpandableBar>
    with SingleTickerProviderStateMixin {
  static const _monkeyMuxHandleIconAsset =
      'assets/icons/monkeyssh_icon_monochrome.png';
  static const _denseTileVisualDensity = VisualDensity(vertical: -2);
  static const _denseTilePadding = EdgeInsets.symmetric(horizontal: 12);
  static const _pendingSelectionTimeout = Duration(seconds: 2);
  static const _sidebarDragStartThreshold = 8.0;

  List<TmuxWindow>? _windows;
  AgentLaunchTool? _preferredLaunchTool;
  final _seenAlertWindowKeys = <String>{};
  final Map<String, int> _alertNotificationIdsByWindowKey = <String, int>{};
  final Set<String> _closingWindowKeys = <String>{};
  late bool _expanded;
  bool _isLoading = true;
  double _dragOffset = 0;
  int? _sidebarDragPointer;
  Offset? _sidebarDragStartGlobalPosition;
  Offset? _sidebarDragLastGlobalPosition;
  bool _isSidebarDragActive = false;
  StreamSubscription<TmuxWindowChangeEvent>? _windowChangeSubscription;
  StreamSubscription<AcpSessionManagerState>? _acpSessionSubscription;
  List<AcpSessionState> _nativeAcpSessions = const <AcpSessionState>[];
  late AnimationController _bounceController;
  late Animation<double> _bounceAnimation;
  int _windowEventGeneration = 0;
  int? _pendingSelectedWindowIndex;
  Timer? _pendingSelectionTimer;
  bool _windowReloadRecoveryRequested = false;
  bool _sessionEndedNotified = false;
  late LocalNotificationService _localNotifications;

  late final _windowLoader = TmuxWindowLoader(
    fetch: () => _mux.listWindows(
      widget.session,
      widget.tmuxSessionName,
      extraFlags: widget.tmuxExtraFlags,
    ),
    currentWindows: () => _windows,
    connectionId: () => widget.session.connectionId,
    acceptEmpty: () => _emptyWindowListEndsSession,
    onChanged: _applyWindowReload,
  );

  RemoteMultiplexerService get _mux => widget.remoteMultiplexerService;

  bool get _isSidebar => widget.placement == TmuxBarPlacement.sidebar;

  List<TmuxWindow>? get currentWindowsSnapshot => _windows;

  bool get hasPendingWindowSelection => _pendingSelectedWindowIndex != null;

  bool get _emptyWindowListEndsSession =>
      widget.activeMuxBackend == RemoteMuxBackend.monkeyMux;

  bool get _showsExpandedSidebarContent => _expanded || _dragOffset > 0;

  List<TmuxWindow>? get _displayedWindows {
    final visibleWindows = _windows
        ?.where(
          (window) => !_closingWindowKeys.contains(_windowCloseKey(window)),
        )
        .toList(growable: false);
    return resolveTmuxBarDisplayedWindows(
      visibleWindows,
      pendingSelectedWindowIndex: _pendingSelectedWindowIndex,
    );
  }

  String _windowCloseKey(TmuxWindow window) => window.id ?? '#${window.index}';

  @override
  void initState() {
    super.initState();
    _localNotifications = widget.ref.read(localNotificationServiceProvider);
    _expanded = widget.initiallyExpanded;
    _bounceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    // A single subtle attention nudge (ease-out up, ease-in settle) — not a
    // springy bounce, per the design system's "no bounce/elastic" rule.
    _bounceAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0,
          end: -6,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 1,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: -6,
          end: 0,
        ).chain(CurveTween(curve: Curves.easeInCubic)),
        weight: 1.4,
      ),
    ]).animate(_bounceController);
    unawaited(_loadPreferredLaunchTool());
    unawaited(
      widget.ref
          .read(tmuxServiceProvider)
          .prefetchInstalledAgentTools(widget.session),
    );
    _windowLoader.load();
    _subscribeToWindowChanges();
    _subscribeToNativeAcpSessions();
  }

  @override
  void didUpdateWidget(covariant _TmuxExpandableBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sessionChanged =
        oldWidget.session.connectionId != widget.session.connectionId ||
        oldWidget.tmuxSessionName != widget.tmuxSessionName ||
        oldWidget.tmuxExtraFlags != widget.tmuxExtraFlags;
    final backendChanged =
        oldWidget.activeMuxBackend != widget.activeMuxBackend ||
        oldWidget.remoteMultiplexerService != widget.remoteMultiplexerService;
    final recoveryChanged =
        oldWidget.recoveryGeneration != widget.recoveryGeneration;
    if (!sessionChanged && !backendChanged && !recoveryChanged) {
      return;
    }
    final wasExpanded = _expanded;
    _clearPendingSelectedWindow(notify: false);
    _closingWindowKeys.clear();
    _resetWindowReloadRecovery();
    if (!shouldPreserveTmuxBarSnapshotOnUpdate(
      sessionChanged: sessionChanged,
      backendChanged: backendChanged,
      recoveryChanged: recoveryChanged,
    )) {
      _clearSeenAlertNotifications();
      setState(() {
        _windows = null;
        _isLoading = true;
        _expanded = false;
        _dragOffset = 0;
      });
      if (wasExpanded) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            widget.onExpandedChanged(false);
          }
        });
      }
      unawaited(
        widget.ref
            .read(tmuxServiceProvider)
            .prefetchInstalledAgentTools(widget.session),
      );
    } else if (!(_windows?.isNotEmpty ?? false)) {
      setState(() => _isLoading = true);
    }
    if (sessionChanged || backendChanged) {
      _sessionEndedNotified = false;
      unawaited(_windowChangeSubscription?.cancel());
      _subscribeToWindowChanges();
      _subscribeToNativeAcpSessions();
    }
    unawaited(_loadPreferredLaunchTool());
    _windowLoader.load();
  }

  @override
  void dispose() {
    _clearPendingSelectedWindow(notify: false);
    _windowLoader.dispose();
    unawaited(_windowChangeSubscription?.cancel());
    unawaited(_acpSessionSubscription?.cancel());
    _clearSeenAlertNotifications();
    _bounceController.dispose();
    super.dispose();
  }

  late MuxWindowProjection _projection;

  AcpSessionState? get _activeNativeAcpEntry => _nativeAcpSessions
      .where((session) => session.key == widget.activeNativeAcpSessionKey)
      .firstOrNull;

  List<AcpSessionState> get _nativeAcpEntries => _projection.orphanSessions;

  AcpSessionState? _sessionForNativeWindow(TmuxWindow window) =>
      _projection.sessionForWindow(window);

  TerminalProgress? _progressForWindow(TmuxWindow window) {
    if (widget.activeMuxBackend != RemoteMuxBackend.monkeyMux) {
      return null;
    }
    if (window.isNativeAcp) {
      final session = _sessionForNativeWindow(window);
      if (session != null) {
        return acpActivityTerminalProgress(acpSessionActivityDisplay(session));
      }
    }
    return window.terminalProgress;
  }

  TmuxOpenAcpWindowAction _openNativeWindowAction(TmuxWindow window) =>
      TmuxOpenAcpWindowAction(
        windowIndex: window.index,
        bridgeId: window.nativeAcpBridgeId!,
        providerId: window.nativeAcpProviderId!,
        workingDirectory: window.currentPath,
      );

  int _nativeAcpWindowIndex(AcpSessionState session) =>
      _projection.nativeIndices[session.key] ?? 0;

  bool _sameNativeWindowPresentation(
    List<AcpSessionState> previous,
    List<AcpSessionState> next,
  ) {
    if (identical(previous, next)) {
      return true;
    }
    if (previous.length != next.length) {
      return false;
    }
    for (var index = 0; index < previous.length; index++) {
      final before = previous[index];
      final after = next[index];
      if (before.key != after.key ||
          before.title != after.title ||
          before.providerLabel != after.providerLabel ||
          before.cwd != after.cwd ||
          before.isLive != after.isLive ||
          AcpActivitySnapshot.fromSession(before) !=
              AcpActivitySnapshot.fromSession(after)) {
        return false;
      }
    }
    return true;
  }

  void _subscribeToNativeAcpSessions() {
    unawaited(_acpSessionSubscription?.cancel());
    _acpSessionSubscription = null;
    if (widget.activeMuxBackend != RemoteMuxBackend.monkeyMux) {
      if (mounted) {
        setState(() {
          _nativeAcpSessions = const <AcpSessionState>[];
        });
      }
      return;
    }
    final manager = widget.ref.read(acpSessionManagerProvider);
    final hostId = widget.session.hostId;
    _nativeAcpSessions = manager.state.sessions
        .where(
          (session) => session.key.hostId == hostId && session.isOpenMuxWindow,
        )
        .toList(growable: false);
    _acpSessionSubscription = manager.states.listen((state) {
      if (!mounted || widget.session.hostId != hostId) {
        return;
      }
      final nextSessions = state.sessions
          .where(
            (session) =>
                session.key.hostId == hostId && session.isOpenMuxWindow,
          )
          .toList(growable: false);
      if (_sameNativeWindowPresentation(_nativeAcpSessions, nextSessions)) {
        return;
      }
      setState(() => _nativeAcpSessions = nextSessions);
    });
  }

  Future<void> _loadPreferredLaunchTool() async {
    final hostId = widget.session.hostId;
    final preset = await widget.ref
        .read(agentLaunchPresetServiceProvider)
        .getPresetForHost(hostId);
    if (!mounted || widget.session.hostId != hostId) return;

    final preferredLaunchTool = preset?.tool;
    if (_preferredLaunchTool == preferredLaunchTool) return;
    setState(() => _preferredLaunchTool = preferredLaunchTool);
  }

  void _subscribeToWindowChanges() {
    final generation = ++_windowEventGeneration;
    DiagnosticsLogService.instance.info(
      'tmux.ui',
      'bar_subscribe',
      fields: {
        'connectionId': widget.session.connectionId,
        'generation': generation,
      },
    );
    _windowChangeSubscription = _mux
        .watchWindowChanges(
          widget.session,
          widget.tmuxSessionName,
          extraFlags: widget.tmuxExtraFlags,
        )
        .listen((event) => _handleWindowChangeEvent(event, generation));
  }

  void _handleWindowChangeEvent(TmuxWindowChangeEvent event, int generation) {
    if (!mounted) return;
    if (generation != _windowEventGeneration) return;
    if (event is TmuxWindowReloadEvent) {
      DiagnosticsLogService.instance.debug(
        'tmux.ui',
        'bar_reload_event',
        fields: {
          'connectionId': widget.session.connectionId,
          'generation': generation,
        },
      );
      _windowLoader.load();
      _notifyWindowStateChanged(activeWindowChanged: false);
      return;
    }
    if (event is TmuxWindowListEvent) {
      _resetWindowReloadRecovery();
      if (event.windows.isEmpty && _emptyWindowListEndsSession) {
        _applyWindows(const <TmuxWindow>[]);
        _notifySessionEnded();
        return;
      }
      final currentWindows = _windows;
      final windows = currentWindows == null
          ? event.windows
          : applyTmuxWindowChangeEvent(currentWindows, event);
      final shouldNotifyWindowStateChanged =
          currentWindows == null ||
          shouldRefreshTmuxThemeAfterWindowChange(currentWindows, windows);
      final activeWindowChanged =
          currentWindows != null &&
          _didDisplayedTmuxWindowChange(currentWindows, windows);
      _applyWindows(windows);
      if (shouldNotifyWindowStateChanged) {
        _notifyWindowStateChanged(activeWindowChanged: activeWindowChanged);
      }
      return;
    }
    final currentWindows = _windows;
    if (currentWindows == null) {
      DiagnosticsLogService.instance.debug(
        'tmux.ui',
        'bar_snapshot_without_state',
        fields: {'connectionId': widget.session.connectionId},
      );
      _windowLoader.load();
      return;
    }
    _resetWindowReloadRecovery();
    final windows = applyTmuxWindowChangeEvent(currentWindows, event);
    final shouldNotifyWindowStateChanged =
        shouldRefreshTmuxThemeAfterWindowChange(currentWindows, windows);
    final activeWindowChanged = _didDisplayedTmuxWindowChange(
      currentWindows,
      windows,
    );
    DiagnosticsLogService.instance.debug(
      'tmux.ui',
      'bar_snapshot_applied',
      fields: {
        'connectionId': widget.session.connectionId,
        'windowCount': windows.length,
        'themeRefreshNeeded': shouldNotifyWindowStateChanged,
      },
    );
    _applyWindows(windows);
    if (shouldNotifyWindowStateChanged) {
      _notifyWindowStateChanged(activeWindowChanged: activeWindowChanged);
    }
  }

  void _notifyWindowStateChanged({required bool activeWindowChanged}) {
    widget.onWindowStateChanged?.call(
      widget.session,
      widget.tmuxSessionName,
      activeWindowChanged: activeWindowChanged,
    );
  }

  bool _didDisplayedTmuxWindowChange(
    List<TmuxWindow> previousWindows,
    List<TmuxWindow> nextWindows,
  ) =>
      _displayedTmuxWindowContext(previousWindows) !=
      _displayedTmuxWindowContext(nextWindows);

  ({String key, int? panePid})? _displayedTmuxWindowContext(
    List<TmuxWindow> windows,
  ) {
    final activeWindow = windows.where((window) => window.isActive).firstOrNull;
    if (activeWindow == null) {
      return null;
    }
    return (
      key: activeWindow.id ?? '#${activeWindow.index}',
      panePid: activeWindow.panePid,
    );
  }

  void _applyWindows(List<TmuxWindow> windows) {
    final previousTerminalModeSignature = activeTmuxWindowTerminalModeSignature(
      _windows,
    );
    final currentAlerts = <String, TmuxWindow>{
      for (final window in windows)
        if (window.hasAlert) _tmuxAlertWindowKey(window): window,
    };
    _seenAlertWindowKeys.retainAll(currentAlerts.keys);
    for (final key in _alertNotificationIdsByWindowKey.keys.toList()) {
      final window = currentAlerts[key];
      if (window == null || window.isActive) _clearAlertNotification(key);
    }
    var hasNewAlert = false;
    for (final entry in currentAlerts.entries) {
      if (entry.value.isActive || !_seenAlertWindowKeys.add(entry.key)) {
        continue;
      }
      hasNewAlert = true;
      _sendAlertNotification(entry.value, windows);
    }
    if (hasNewAlert &&
        mounted &&
        !(MediaQuery.maybeOf(context)?.disableAnimations ?? false)) {
      unawaited(_bounceController.forward(from: 0));
    }

    final nextPendingSelectedWindowIndex =
        resolveTmuxBarPendingSelectedWindowIndex(
          windows,
          pendingSelectedWindowIndex: _pendingSelectedWindowIndex,
        );
    if (_pendingSelectedWindowIndex != null &&
        nextPendingSelectedWindowIndex == null) {
      _pendingSelectionTimer?.cancel();
      _pendingSelectionTimer = null;
    }

    setState(() {
      _windows = windows;
      _isLoading = false;
      _pendingSelectedWindowIndex = nextPendingSelectedWindowIndex;
    });
    widget.onWindowsChanged?.call(windows);

    // Terminal-mode toggles arrive as `window_updated` events that don't change
    // the active window or its theme identity, so they wouldn't otherwise
    // notify the parent. Surface them explicitly so local mode state stays in
    // sync and touch-scroll routing doesn't get stuck until the next switch.
    if (activeTmuxWindowTerminalModeSignature(windows) !=
        previousTerminalModeSignature) {
      widget.onActiveWindowTerminalModeChanged?.call();
    }
  }

  void _startPendingSelectionTimer(int windowIndex) {
    _pendingSelectionTimer?.cancel();
    _pendingSelectionTimer = Timer(_pendingSelectionTimeout, () {
      _pendingSelectionTimer = null;
      if (!mounted || _pendingSelectedWindowIndex != windowIndex) {
        return;
      }
      setState(() => _pendingSelectedWindowIndex = null);
    });
  }

  void _clearPendingSelectedWindow({required bool notify}) {
    _pendingSelectionTimer?.cancel();
    _pendingSelectionTimer = null;
    if (_pendingSelectedWindowIndex == null) {
      return;
    }
    if (!notify || !mounted) {
      _pendingSelectedWindowIndex = null;
      return;
    }
    setState(() => _pendingSelectedWindowIndex = null);
  }

  void _resetWindowReloadRecovery() {
    _windowLoader.invalidate();
    _windowReloadRecoveryRequested = false;
  }

  void _requestWindowReloadRecovery() {
    if (_windowReloadRecoveryRequested) {
      return;
    }
    _windowReloadRecoveryRequested = true;
    DiagnosticsLogService.instance.warning(
      'tmux.ui',
      'bar_recovery_requested',
      fields: {'connectionId': widget.session.connectionId},
    );
    final onWindowLoadStalled = widget.onWindowLoadStalled;
    if (onWindowLoadStalled != null) {
      unawaited(onWindowLoadStalled(widget.session, widget.tmuxSessionName));
    }
  }

  void _notifySessionEnded() {
    if (_sessionEndedNotified) {
      return;
    }
    _sessionEndedNotified = true;
    DiagnosticsLogService.instance.info(
      'tmux.ui',
      'mux_session_ended',
      fields: {
        'connectionId': widget.session.connectionId,
        'backend': widget.activeMuxBackend.storageValue,
      },
    );
    final onSessionEnded = widget.onSessionEnded;
    if (onSessionEnded != null) {
      unawaited(onSessionEnded(widget.session, widget.tmuxSessionName));
    }
  }

  bool collapseIfExpanded() {
    if (!_expanded) {
      return false;
    }
    setState(() {
      _expanded = false;
      _dragOffset = 0;
    });
    widget.onExpandedChanged(false);
    return true;
  }

  String? _resolveRecentSessionScopeWorkingDirectory([
    List<TmuxWindow>? windows,
  ]) {
    final activeWindow = (windows ?? _windows)
        ?.where((window) => window.isActive)
        .firstOrNull;
    return widget.scopeWorkingDirectory ??
        resolveAgentSessionScopeWorkingDirectory(
          activeWorkingDirectory: activeWindow?.currentPath,
          sessionWorkingDirectory: widget.session.workingDirectory,
        );
  }

  void _applyWindowReload(
    List<TmuxWindow>? windows,
    AsyncError? error, {
    required bool shouldRecover,
  }) {
    if (windows != null) {
      if (windows.isNotEmpty) {
        _windowReloadRecoveryRequested = false;
      }
      _applyWindows(windows);
      if (windows.isEmpty && _emptyWindowListEndsSession) {
        _notifySessionEnded();
      }
    } else if (error != null && (_windows?.isNotEmpty ?? false)) {
      if (_isLoading) setState(() => _isLoading = false);
    } else if (shouldRecover) {
      final wasExpanded = _expanded;
      setState(() {
        _expanded = false;
        _isLoading = false;
      });
      if (wasExpanded) widget.onExpandedChanged(false);
      _requestWindowReloadRecovery();
    } else {
      setState(() {
        if (error == null) _windows = null;
        _isLoading = true;
      });
    }
  }

  Future<AgentWindowModePreference> _loadAgentWindowModePreference() => widget
      .ref
      .read(agentWindowModePreferenceNotifierProvider.notifier)
      .initializedValue();

  Future<void> _showNewWindowPicker({BuildContext? anchorContext}) async {
    final installedToolsFuture = widget.ref
        .read(tmuxServiceProvider)
        .detectInstalledAgentTools(widget.session);
    final nativeAcpAvailable =
        widget.activeMuxBackend == RemoteMuxBackend.monkeyMux;
    final nativeAcpProviderIds = nativeAcpAvailable
        ? builtinNativeAcpProvidersByTool()
        : const <AgentLaunchTool, String>{};
    final agentWindowModePreference = await _loadAgentWindowModePreference();
    if (!mounted || (anchorContext != null && !anchorContext.mounted)) {
      return;
    }
    final usesTerminalOnlyContextMenu =
        _isSidebar &&
        anchorContext != null &&
        widget.activeMuxBackend != RemoteMuxBackend.monkeyMux;
    final action = usesTerminalOnlyContextMenu
        ? await showTmuxNewWindowContextMenu(
            context: context,
            anchorContext: anchorContext,
            startClisInYoloMode: widget.startClisInYoloMode,
            installedToolsFuture: installedToolsFuture,
            preferredTool: _preferredLaunchTool,
          )
        : await showTmuxNewWindowPicker(
            context: context,
            isProUser: widget.isProUser,
            startClisInYoloMode: widget.startClisInYoloMode,
            agentWindowModePreference: agentWindowModePreference,
            installedToolsFuture: installedToolsFuture,
            preferredTool: _preferredLaunchTool,
            nativeAcpProviderIds: nativeAcpProviderIds,
          );
    if (!mounted || action == null) {
      return;
    }
    await widget.onAction(action);
  }

  int _tmuxAlertNotificationId(
    SshSession session,
    String tmuxSessionName,
    String windowKey,
  ) =>
      Object.hash(
        session.hostId,
        session.connectionId,
        tmuxSessionName,
        windowKey,
      ) &
      0x7fffffff;

  int _legacyTmuxAlertNotificationId(
    SshSession session,
    String tmuxSessionName,
    int windowIndex,
  ) =>
      Object.hash(
        session.hostId,
        session.connectionId,
        tmuxSessionName,
        windowIndex,
      ) &
      0x7fffffff;

  String _tmuxAlertIndexWindowKey(int windowIndex) => 'index:$windowIndex';

  String _tmuxAlertWindowKey(TmuxWindow window) =>
      window.id != null && isValidTmuxWindowId(window.id!)
      ? window.id!
      : _tmuxAlertIndexWindowKey(window.index);

  void _sendAlertNotification(TmuxWindow window, List<TmuxWindow> windows) {
    final content = resolveTmuxAlertNotificationContent(
      tmuxSessionName: widget.tmuxSessionName,
      window: window,
      windows: windows,
    );
    final windowId = window.id;
    final stableWindowId = windowId != null && isValidTmuxWindowId(windowId)
        ? windowId
        : null;
    final session = widget.session;
    final tmuxSessionName = widget.tmuxSessionName;
    final windowIndex = window.index;
    final notificationId = stableWindowId != null
        ? _tmuxAlertNotificationId(session, tmuxSessionName, stableWindowId)
        : _legacyTmuxAlertNotificationId(session, tmuxSessionName, windowIndex);
    _alertNotificationIdsByWindowKey[_tmuxAlertWindowKey(window)] =
        notificationId;
    final payload = TmuxAlertNotificationPayload(
      hostId: session.hostId,
      connectionId: session.connectionId,
      tmuxSessionName: tmuxSessionName,
      windowIndex: windowIndex,
      windowId: stableWindowId,
    );
    unawaited(HapticFeedback.mediumImpact());
    unawaited(
      _localNotifications.showTmuxAlert(
        notificationId: notificationId,
        title: content.title,
        body: content.body,
        payload: payload,
      ),
    );
  }

  void _clearAlertNotification(String windowKey) {
    final notificationId = _alertNotificationIdsByWindowKey.remove(windowKey);
    if (notificationId != null) {
      unawaited(_localNotifications.clearTmuxAlert(notificationId));
    }
  }

  void _clearSeenAlertNotifications() {
    _seenAlertWindowKeys.clear();
    for (final key in _alertNotificationIdsByWindowKey.keys.toList()) {
      _clearAlertNotification(key);
    }
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (_isSidebar) {
      return;
    }
    setState(() {
      _dragOffset += _expanded ? details.delta.dy : -details.delta.dy;
      _dragOffset = _dragOffset.clamp(0.0, 300.0);
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (_isSidebar) {
      return;
    }
    final velocity = details.primaryVelocity ?? 0;
    final shouldExpand = !_expanded && (velocity < -200 || _dragOffset > 60);
    final shouldCollapse = _expanded && (velocity > 200 || _dragOffset > 60);
    setState(() {
      if (shouldExpand) {
        _expanded = true;
      } else if (shouldCollapse) {
        _expanded = false;
      }
      _dragOffset = 0;
    });
    if (shouldExpand) {
      widget.onExpandedChanged(true);
    } else if (shouldCollapse) {
      widget.onExpandedChanged(false);
    }
    if (shouldExpand) _windowLoader.load();
  }

  void _applySidebarDragDelta(double deltaX) {
    const maxDrag = tmuxSidebarExpandedWidth - tmuxSidebarCollapsedWidth;
    final nextDragOffset = (_dragOffset + deltaX).clamp(
      _expanded ? -maxDrag : 0.0,
      _expanded ? 0.0 : maxDrag,
    );
    if (nextDragOffset == _dragOffset) {
      return;
    }
    setState(() => _dragOffset = nextDragOffset);
    widget.onSidebarDragOffsetChanged(nextDragOffset);
  }

  void _finishSidebarDrag(double velocity) {
    final shouldExpand =
        !_expanded &&
        (velocity > 200 || _dragOffset > tmuxSidebarDragThreshold);
    final shouldCollapse =
        _expanded &&
        (velocity < -200 || _dragOffset < -tmuxSidebarDragThreshold);
    setState(() {
      if (shouldExpand) {
        _expanded = true;
      } else if (shouldCollapse) {
        _expanded = false;
      }
      _dragOffset = 0;
    });
    widget.onSidebarDragOffsetChanged(0);
    if (shouldExpand) {
      widget.onExpandedChanged(true);
      _windowLoader.load();
    } else if (shouldCollapse) {
      widget.onExpandedChanged(false);
    }
  }

  void _onHorizontalDragCancel() {
    if (!_isSidebar || _dragOffset == 0) {
      return;
    }
    setState(() => _dragOffset = 0);
    widget.onSidebarDragOffsetChanged(0);
  }

  void _onSidebarPointerDown(PointerDownEvent event) {
    if (!_isSidebar || _sidebarDragPointer != null) {
      return;
    }
    _sidebarDragPointer = event.pointer;
    _sidebarDragStartGlobalPosition = event.position;
    _sidebarDragLastGlobalPosition = event.position;
    _isSidebarDragActive = false;
  }

  void _onSidebarPointerMove(PointerMoveEvent event) {
    final start = _sidebarDragStartGlobalPosition;
    final last = _sidebarDragLastGlobalPosition;
    if (!_isSidebar ||
        _sidebarDragPointer != event.pointer ||
        start == null ||
        last == null) {
      return;
    }
    final totalDelta = event.position - start;
    if (!_isSidebarDragActive) {
      if (totalDelta.dx.abs() < _sidebarDragStartThreshold &&
          totalDelta.dy.abs() < _sidebarDragStartThreshold) {
        _sidebarDragLastGlobalPosition = event.position;
        return;
      }
      if (totalDelta.dx.abs() <= totalDelta.dy.abs()) {
        _sidebarDragLastGlobalPosition = event.position;
        return;
      }
      _isSidebarDragActive = true;
    }

    final deltaX = event.position.dx - last.dx;
    _sidebarDragLastGlobalPosition = event.position;
    if (deltaX == 0) {
      return;
    }
    _applySidebarDragDelta(deltaX);
  }

  void _onSidebarPointerUp(PointerUpEvent event) {
    if (!_isSidebar || _sidebarDragPointer != event.pointer) {
      return;
    }
    final shouldFinishDrag = _isSidebarDragActive || _dragOffset != 0;
    _resetSidebarPointerDrag();
    if (shouldFinishDrag) {
      _finishSidebarDrag(0);
    }
  }

  void _onSidebarPointerCancel(PointerCancelEvent event) {
    if (_sidebarDragPointer != event.pointer) {
      return;
    }
    final shouldCancelDrag = _isSidebarDragActive || _dragOffset != 0;
    _resetSidebarPointerDrag();
    if (shouldCancelDrag) {
      _onHorizontalDragCancel();
    }
  }

  void _resetSidebarPointerDrag() {
    _sidebarDragPointer = null;
    _sidebarDragStartGlobalPosition = null;
    _sidebarDragLastGlobalPosition = null;
    _isSidebarDragActive = false;
  }

  @override
  Widget build(BuildContext context) {
    _projection = MuxWindowProjection(
      // Closing windows still own their native sessions until remote close
      // succeeds. Filtering them here would create spurious orphan rows.
      _windows ?? const [],
      widget.activeMuxBackend == RemoteMuxBackend.monkeyMux
          ? _nativeAcpSessions
          : const [],
    );
    if (_isSidebar) {
      return _buildSidebar(context);
    }

    final theme = Theme.of(context);
    final availableHeight = widget.availableHeight.isFinite
        ? widget.availableHeight
        : MediaQuery.sizeOf(context).height * 0.5;
    final mediaQuery = MediaQuery.of(context);
    final visibleViewportHeight = max(
      0,
      mediaQuery.size.height -
          mediaQuery.viewPadding.vertical -
          mediaQuery.viewInsets.bottom,
    );
    final maxContentHeight = resolveTmuxBarMaxContentHeight(
      availableHeight,
      fallbackAvailableHeight: visibleViewportHeight * 0.5,
    );
    final dragDistance = _dragOffset.clamp(0.0, maxContentHeight);
    final contentHeight = _expanded
        ? (maxContentHeight - dragDistance).clamp(0.0, maxContentHeight)
        : dragDistance;

    return AnimatedBuilder(
      animation: _bounceAnimation,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, _bounceAnimation.value),
        child: child,
      ),
      child: GestureDetector(
        onVerticalDragUpdate: _onVerticalDragUpdate,
        onVerticalDragEnd: _onVerticalDragEnd,
        child: Material(
          color: theme.colorScheme.surfaceContainerHighest,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: theme.colorScheme.outlineVariant,
                  width: 0.5,
                ),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildHandleBar(theme),
                AnimatedContainer(
                  duration: _dragOffset > 0
                      ? Duration.zero
                      : const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  height: contentHeight,
                  child: ClipRect(
                    child: Offstage(
                      offstage: contentHeight <= 0,
                      child: _buildWindowList(theme),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSidebar(BuildContext context) {
    final theme = Theme.of(context);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onSidebarPointerDown,
      onPointerMove: _onSidebarPointerMove,
      onPointerUp: _onSidebarPointerUp,
      onPointerCancel: _onSidebarPointerCancel,
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              right: BorderSide(
                color: theme.colorScheme.outlineVariant,
                width: 0.5,
              ),
            ),
          ),
          child: Column(
            children: [
              _buildSidebarHandle(theme),
              Expanded(
                // An IndexedStack also lays out hidden rows at the rail's
                // collapsed width, which is too narrow for expanded ListTiles.
                child: _showsExpandedSidebarContent
                    ? _buildWindowList(theme)
                    : _buildCollapsedSidebarWindowRail(theme),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _toggleExpanded() {
    final wasExpanded = _expanded;
    setState(() => _expanded = !_expanded);
    widget.onExpandedChanged(!wasExpanded);
    // Refresh window list when expanding to get current active state.
    if (!wasExpanded) {
      _windowLoader.load();
    }
  }

  Widget _buildHandleBar(ThemeData theme) {
    final displayedWindows = _displayedWindows;
    final activeNative = _activeNativeAcpEntry;
    final nativeActivity = activeNative == null
        ? null
        : acpSessionActivityDisplay(activeNative);
    final handleLabel = activeNative == null
        ? resolveTmuxBarHandleLabel(
            widget.tmuxSessionName,
            activeWindowTitle: resolveTmuxBarActiveWindowTitle(
              displayedWindows,
            ),
          )
        : '${acpSessionDisplayTitle(activeNative)} · ${nativeActivity!.label}';
    final activeWindowTool = activeNative == null
        ? resolveTmuxBarActiveWindowTool(displayedWindows)
        : null;
    final activeNativeTool = activeNative == null
        ? null
        : agentLaunchToolForAcpProviderId(activeNative.key.providerId);
    final tooltip = _expanded
        ? 'Collapse tmux windows'
        : 'Show tmux windows: $handleLabel';

    return Semantics(
      button: true,
      toggled: _expanded,
      label: 'tmux windows: $handleLabel',
      hint: _expanded
          ? 'Double tap to collapse the tmux window list'
          : 'Double tap to show tmux windows',
      child: Tooltip(
        message: tooltip,
        child: GestureDetector(
          key: const ValueKey('tmux-handle-bar'),
          behavior: HitTestBehavior.opaque,
          onTap: _toggleExpanded,
          child: SizedBox(
            height: _TmuxExpandableBar.handleHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  _buildHandleIcon(
                    theme,
                    activeWindowTool,
                    nativeWindowIndex: activeNative == null
                        ? null
                        : _nativeAcpWindowIndex(activeNative),
                    nativeWindowTool: activeNativeTool,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      handleLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.onSurfaceVariant.withAlpha(110),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const SizedBox(width: 28, height: 4),
                  ),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    duration: const Duration(milliseconds: 300),
                    turns: _expanded ? 0.5 : 0,
                    child: Icon(
                      Icons.keyboard_arrow_up,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSidebarHandle(ThemeData theme) {
    final displayedWindows = _displayedWindows;
    final activeNative = _activeNativeAcpEntry;
    final nativeActivity = activeNative == null
        ? null
        : acpSessionActivityDisplay(activeNative);
    final handleLabel = activeNative == null
        ? resolveTmuxBarHandleLabel(
            widget.tmuxSessionName,
            activeWindowTitle: resolveTmuxBarActiveWindowTitle(
              displayedWindows,
            ),
          )
        : '${acpSessionDisplayTitle(activeNative)} · ${nativeActivity!.label}';
    final activeWindowTool = activeNative == null
        ? resolveTmuxBarActiveWindowTool(displayedWindows)
        : null;
    final activeNativeTool = activeNative == null
        ? null
        : agentLaunchToolForAcpProviderId(activeNative.key.providerId);
    final tooltip = _expanded
        ? 'Collapse tmux windows'
        : 'Show tmux windows: $handleLabel';
    final icon = _buildHandleIcon(
      theme,
      activeWindowTool,
      nativeWindowIndex: activeNative == null
          ? null
          : _nativeAcpWindowIndex(activeNative),
      nativeWindowTool: activeNativeTool,
    );

    return Semantics(
      button: true,
      toggled: _expanded,
      label: 'tmux windows: $handleLabel',
      hint: _expanded
          ? 'Double tap or drag left to collapse the tmux window sidebar'
          : 'Double tap or drag right to show tmux windows',
      child: Tooltip(
        message: tooltip,
        child: GestureDetector(
          key: const ValueKey('tmux-handle-bar'),
          behavior: HitTestBehavior.opaque,
          onTap: _toggleExpanded,
          child: SizedBox(
            height: 56,
            width: double.infinity,
            child: _showsExpandedSidebarContent
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        icon,
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            handleLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.chevron_left,
                          size: 20,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  )
                : Center(child: icon),
          ),
        ),
      ),
    );
  }

  Widget _buildHandleIcon(
    ThemeData theme,
    AgentLaunchTool? activeWindowTool, {
    required int? nativeWindowIndex,
    required AgentLaunchTool? nativeWindowTool,
  }) {
    final color = theme.colorScheme.primary;
    Widget withUsage(
      Widget icon,
      AgentLaunchTool? tool, {
      double diameter = 28,
    }) {
      if (tool == null ||
          widget.activeMuxBackend != RemoteMuxBackend.monkeyMux) {
        return icon;
      }
      return AgentUsageRingIcon(
        key: ValueKey((widget.session, tool)),
        session: widget.session,
        tool: tool,
        diameter: diameter,
        child: icon,
      );
    }

    if (nativeWindowIndex != null) {
      return withUsage(
        buildNativeAcpHandleIcon(theme: theme, tool: nativeWindowTool),
        nativeWindowTool,
        diameter: 32,
      );
    }
    if (activeWindowTool != null) {
      return withUsage(
        AgentToolIcon(tool: activeWindowTool, size: 16, color: color),
        activeWindowTool,
      );
    }
    if (widget.activeMuxBackend == RemoteMuxBackend.monkeyMux) {
      return ImageIcon(
        const AssetImage(_monkeyMuxHandleIconAsset),
        key: const ValueKey('monkeymux-handle-icon'),
        size: 16,
        color: color,
      );
    }
    return Icon(Icons.window_outlined, size: 16, color: color);
  }

  Widget _buildCollapsedSidebarWindowRail(ThemeData theme) {
    final displayedWindows = _displayedWindows;
    if (_isLoading) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator.adaptive(strokeWidth: 2),
        ),
      );
    }

    final nativeEntries = _nativeAcpEntries;
    if ((displayedWindows == null || displayedWindows.isEmpty) &&
        nativeEntries.isEmpty) {
      return const SizedBox.shrink();
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          for (final window in displayedWindows ?? const <TmuxWindow>[])
            _buildCollapsedSidebarWindowButton(theme, window),
          for (final entry in nativeEntries)
            _buildCollapsedNativeAcpButton(theme, entry),
          const SizedBox(height: 4),
          _buildCollapsedSidebarNewWindowButton(theme),
        ],
      ),
    );
  }

  Widget _buildCollapsedSidebarWindowButton(
    ThemeData theme,
    TmuxWindow window,
  ) {
    final activeNativeKey = widget.activeNativeAcpSessionKey;
    final isActive = window.isNativeAcp
        ? activeNativeKey?.bridgeId == window.nativeAcpBridgeId
        : window.isActive && activeNativeKey == null;
    final windowTool = window.isNativeAcp
        ? agentLaunchToolForAcpProviderId(window.nativeAcpProviderId!)
        : window.foregroundAgentTool;
    final nativeSession = window.isNativeAcp
        ? _sessionForNativeWindow(window)
        : null;
    final progress = _progressForWindow(window);
    final title = _redactStoreScreenshotIdentities
        ? _storeScreenshotWindowTitle(window)
        : nativeSession == null
        ? window.displayTitle
        : acpSessionDisplayTitle(nativeSession);
    final iconColor = agentWindowIdentityColor(
      theme.colorScheme,
      isActive: isActive,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: Tooltip(
        message: 'Switch to $title',
        child: Semantics(
          button: true,
          selected: isActive,
          label: 'tmux window ${window.index}: $title',
          child: InkWell(
            key: ValueKey('tmux-sidebar-window-${window.index}'),
            customBorder: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            onTap: isActive
                ? null
                : () {
                    unawaited(HapticFeedback.selectionClick());
                    setState(() {
                      _pendingSelectedWindowIndex = window.index;
                    });
                    _startPendingSelectionTimer(window.index);
                    unawaited(
                      widget.onAction(
                        window.isNativeAcp
                            ? _openNativeWindowAction(window)
                            : TmuxSwitchWindowAction(
                                window.index,
                                windowId: window.id,
                              ),
                      ),
                    );
                  },
            child: Ink(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: isActive
                    ? theme.colorScheme.primaryContainer
                    : theme.colorScheme.surfaceContainerHigh,
                border: window.hasAlert
                    ? Border.all(color: theme.colorScheme.error, width: 2)
                    : null,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    AgentToolIcon(
                      tool: windowTool,
                      color: iconColor,
                      fallbackIcon: window.isNativeAcp
                          ? Icons.smart_toy_outlined
                          : Icons.terminal,
                    ),
                    if (window.isNativeAcp)
                      Positioned(
                        left: 2,
                        top: 2,
                        child: AcpNativeBadge(
                          key: ValueKey(
                            'monkeymux-sidebar-native-${window.index}',
                          ),
                          color: iconColor,
                        ),
                      ),
                    Positioned(
                      right: -9,
                      bottom: -9,
                      child: _buildCollapsedSidebarWindowIndex(
                        theme,
                        window,
                        isActive: isActive,
                      ),
                    ),
                    if (window.hasAlert)
                      Positioned(
                        right: -10,
                        top: -10,
                        child: Icon(
                          Icons.notifications_active,
                          size: 14,
                          color: theme.colorScheme.error,
                        ),
                      ),
                    if (progress != null)
                      Positioned(
                        left: -7,
                        right: 7,
                        bottom: -11,
                        child: MuxWindowProgressIndicator(
                          key: ValueKey(
                            'monkeymux-sidebar-progress-${window.index}',
                          ),
                          progress: progress,
                          semanticsWindowLabel: isActive
                              ? null
                              : 'MonkeyMux window ${window.index}: $title',
                          compact: true,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCollapsedSidebarWindowIndex(
    ThemeData theme,
    TmuxWindow window, {
    required bool isActive,
  }) {
    final colorScheme = theme.colorScheme;
    return DecoratedBox(
      key: ValueKey('tmux-sidebar-window-index-${window.index}'),
      decoration: BoxDecoration(
        color: isActive
            ? colorScheme.primary
            : colorScheme.surfaceContainerHigh,
        border: Border.all(
          color: theme.colorScheme.surfaceContainerHighest,
          width: 1.5,
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        child: Text(
          '${window.index}',
          style: theme.textTheme.labelSmall?.copyWith(
            color: isActive
                ? colorScheme.onPrimary
                : colorScheme.onSurfaceVariant,
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _buildCollapsedSidebarNewWindowButton(ThemeData theme) => Builder(
    builder: (buttonContext) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: Tooltip(
        message: 'New tmux window',
        child: InkWell(
          key: const ValueKey('tmux-sidebar-new-window'),
          customBorder: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          onTap: () =>
              unawaited(_showNewWindowPicker(anchorContext: buttonContext)),
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(
              Icons.add_circle_outline,
              size: 22,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
      ),
    ),
  );

  Widget _buildWindowList(ThemeData theme) {
    final displayedWindows = _displayedWindows;
    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator.adaptive(strokeWidth: 2),
          ),
        ),
      );
    }

    final nativeEntries = _nativeAcpEntries;
    if ((displayedWindows == null || displayedWindows.isEmpty) &&
        nativeEntries.isEmpty) {
      return const SizedBox.shrink();
    }

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Divider(height: 1),
          for (final window in displayedWindows ?? const <TmuxWindow>[])
            _buildWindowTile(theme, window),
          for (final entry in nativeEntries) _buildNativeAcpTile(theme, entry),
          const Divider(height: 1),
          ListTile(
            dense: true,
            visualDensity: _denseTileVisualDensity,
            minTileHeight: 42,
            contentPadding: _denseTilePadding,
            horizontalTitleGap: 12,
            minLeadingWidth: 20,
            leading: Icon(
              Icons.add_circle_outline,
              color: theme.colorScheme.primary,
              size: 18,
            ),
            title: const Text('New window'),
            onTap: () {
              final wasExpanded = _expanded;
              setState(() => _expanded = false);
              if (wasExpanded) {
                widget.onExpandedChanged(false);
              }
              unawaited(_showNewWindowPicker());
            },
          ),
          if (widget.isProUser) ...[
            const Divider(height: 1),
            _buildSessionsSection(theme),
          ],
        ],
      ),
    );
  }

  Widget _buildSessionsSection(ThemeData theme) => MuxRecentSessionsSection(
    session: widget.session,
    tmuxSessionName: widget.tmuxSessionName,
    remoteMuxBackend: widget.activeMuxBackend,
    scopeWorkingDirectory: _resolveRecentSessionScopeWorkingDirectory(),
    liveWindows: _windows ?? const [],
    isProUser: widget.isProUser,
    startClisInYoloMode: widget.startClisInYoloMode,
    preferredTool: _preferredLaunchTool,
    loadModePreference: _loadAgentWindowModePreference,
    inBar: true,
    onAction: (action) {
      final wasExpanded = _expanded;
      setState(() => _expanded = false);
      if (wasExpanded) widget.onExpandedChanged(false);
      unawaited(widget.onAction(action));
    },
    headerBuilder: (context, toggle, {required expanded}) => ListTile(
      dense: true,
      visualDensity: _denseTileVisualDensity,
      minTileHeight: 42,
      contentPadding: _denseTilePadding,
      horizontalTitleGap: 12,
      minLeadingWidth: 18,
      leading: Icon(
        Icons.smart_toy_outlined,
        size: 16,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      title: const Text('AI Sessions'),
      trailing: Icon(
        expanded ? Icons.expand_less : Icons.expand_more,
        size: 16,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      onTap: toggle,
    ),
  );

  Widget _buildCollapsedNativeAcpButton(
    ThemeData theme,
    AcpSessionState entry,
  ) {
    final key = entry.key;
    final windowIndex = _nativeAcpWindowIndex(entry);
    final agentTool = agentLaunchToolForAcpProviderId(key.providerId);
    final isActive = widget.activeNativeAcpSessionKey == key;
    final activity = acpSessionActivityDisplay(entry);
    final identityColor = agentWindowIdentityColor(
      theme.colorScheme,
      isActive: isActive,
    );
    final activityColor = acpStatusColor(theme.colorScheme, activity.tone);
    final progress = acpActivityTerminalProgress(activity);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: Tooltip(
        message: 'Open ${acpSessionDisplayTitle(entry)}',
        child: InkWell(
          key: ValueKey('monkeymux-sidebar-acp-${key.value}'),
          customBorder: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          onTap: () {
            unawaited(HapticFeedback.selectionClick());
            unawaited(widget.onAction(TmuxOpenAcpSessionAction(key)));
          },
          child: Ink(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: isActive
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
              border: isActive
                  ? Border.all(color: theme.colorScheme.primary)
                  : null,
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                AgentToolIcon(tool: agentTool, size: 22, color: identityColor),
                Positioned(
                  left: 2,
                  top: 2,
                  child: AcpNativeBadge(
                    key: ValueKey('monkeymux-sidebar-acp-native-${key.value}'),
                    color: identityColor,
                  ),
                ),
                Positioned(
                  right: -9,
                  bottom: -9,
                  child: DecoratedBox(
                    key: ValueKey('monkeymux-sidebar-acp-index-${key.value}'),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHigh,
                      border: Border.all(
                        color: theme.colorScheme.surfaceContainerHighest,
                        width: 1.5,
                      ),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: SizedBox(
                      width: 18,
                      height: 15,
                      child: Center(
                        child: Text(
                          '$windowIndex',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: identityColor,
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (!activity.isReady)
                  Positioned(
                    right: 3,
                    top: 3,
                    child: Icon(activity.icon, size: 11, color: activityColor),
                  ),
                if (progress != null)
                  Positioned(
                    left: -7,
                    right: 7,
                    bottom: -11,
                    child: MuxWindowProgressIndicator(
                      key: ValueKey(
                        'monkeymux-sidebar-acp-progress-${key.value}',
                      ),
                      progress: progress,
                      semanticsWindowLabel:
                          'Native agent window: ${acpSessionDisplayTitle(entry)}',
                      compact: true,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNativeAcpTile(ThemeData theme, AcpSessionState session) =>
      MuxWindowRow(
        key: ValueKey(('native-session', session.key)),
        inBar: true,
        presentation: MuxWindowPresentation.session(
          session,
          index: _nativeAcpWindowIndex(session),
          isActive: widget.activeNativeAcpSessionKey == session.key,
        ),
        onClose: () => unawaited(
          _confirmCloseNativeAcpSession(
            session.key,
            acpSessionDisplayTitle(session),
          ),
        ),
        onTap: () {
          unawaited(HapticFeedback.selectionClick());
          unawaited(widget.onAction(TmuxOpenAcpSessionAction(session.key)));
        },
      );

  Future<void> _confirmCloseNativeAcpSession(
    AcpSessionKey key,
    String title,
  ) async {
    final confirmed = await confirmMuxWindowClose(
      context: context,
      ref: widget.ref,
      title: title,
    );
    if (!mounted || !confirmed) {
      return;
    }
    await widget.onAction(TmuxCloseAcpSessionAction(key));
  }

  Future<void> _confirmCloseWindow(TmuxWindow window) async {
    final title = _redactStoreScreenshotIdentities
        ? _storeScreenshotWindowTitle(window)
        : window.displayTitle;
    final confirmed = await confirmMuxWindowClose(
      context: context,
      ref: widget.ref,
      title: title,
    );
    if (!mounted || !confirmed) {
      return;
    }
    final closeKey = _windowCloseKey(window);
    setState(() {
      _closingWindowKeys.add(closeKey);
      if (_pendingSelectedWindowIndex == window.index) {
        _pendingSelectedWindowIndex = null;
        _pendingSelectionTimer?.cancel();
        _pendingSelectionTimer = null;
      }
    });
    try {
      await widget.onAction(
        TmuxCloseWindowAction(window.index, windowId: window.id),
      );
    } on Object {
      if (mounted) {
        setState(() => _closingWindowKeys.remove(closeKey));
      }
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _closingWindowKeys.remove(closeKey);
      _windows = _windows
          ?.where((candidate) => _windowCloseKey(candidate) != closeKey)
          .toList();
    });
  }

  Widget _buildWindowTile(ThemeData theme, TmuxWindow window) {
    final activeNativeKey = widget.activeNativeAcpSessionKey;
    final isActive = window.isNativeAcp
        ? activeNativeKey?.bridgeId == window.nativeAcpBridgeId
        : window.isActive && activeNativeKey == null;
    return MuxWindowRow(
      key: ValueKey(('server-window', window.index)),
      inBar: true,
      presentation: MuxWindowPresentation.window(
        window,
        session: _sessionForNativeWindow(window),
        isActive: isActive,
        showProgress: widget.activeMuxBackend == RemoteMuxBackend.monkeyMux,
        displayTitle: _redactStoreScreenshotIdentities
            ? _storeScreenshotWindowTitle(window)
            : null,
      ),
      onClose: () => unawaited(_confirmCloseWindow(window)),
      onTap: isActive
          ? () {
              final wasExpanded = _expanded;
              setState(() => _expanded = false);
              if (wasExpanded) {
                widget.onExpandedChanged(false);
              }
            }
          : () {
              unawaited(HapticFeedback.selectionClick());
              setState(() {
                _pendingSelectedWindowIndex = window.index;
                _expanded = false;
              });
              widget.onExpandedChanged(false);
              _startPendingSelectionTimer(window.index);
              unawaited(
                widget.onAction(
                  window.isNativeAcp
                      ? _openNativeWindowAction(window)
                      : TmuxSwitchWindowAction(
                          window.index,
                          windowId: window.id,
                        ),
                ),
              );
            },
    );
  }
}

/// Store-safe window title that brands by detected agent without private names.
String _storeScreenshotWindowTitle(TmuxWindow window) {
  final tool =
      window.foregroundAgentTool ??
      agentLaunchToolForCommandName(window.name) ??
      agentLaunchToolForCommandText(window.name);
  if (tool != null) {
    return '${tool.label} Workspace';
  }
  final name = window.name.trim();
  if (name.isNotEmpty) {
    return name;
  }
  return window.displayTitle;
}
