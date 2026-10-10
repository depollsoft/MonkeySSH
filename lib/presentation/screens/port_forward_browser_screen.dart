import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../../app/routes.dart';
import '../../app/theme.dart';
import '../../data/database/database.dart';
import '../../domain/services/diagnostics_log_service.dart';
import '../../domain/services/port_forward_browser_service.dart';
import '../../domain/services/settings_service.dart';
import '../../domain/services/socks_browser_proxy_service.dart';
import '../../domain/services/socks_forward_route.dart';
import '../../domain/services/ssh_service.dart';
import '../browser/browser_file_picker.dart';
import '../browser/socks_browser_panels.dart';
import '../widgets/brand_error_state.dart';

/// Group used to prioritize and separate forwarded browser tabs.
enum PortForwardBrowserTabGroup {
  /// Automatically detected from this saved host's shell/mux process tree.
  savedHost,

  /// A user-configured saved port-forward rule.
  savedForward,

  /// A host-level service such as Docker or a background daemon.
  sharedHost,
}

/// Presentation helpers for [PortForwardBrowserTabGroup].
extension PortForwardBrowserTabGroupPresentation on PortForwardBrowserTabGroup {
  /// Compact section label shown above grouped browser tabs.
  String get label => switch (this) {
    PortForwardBrowserTabGroup.savedHost => 'this saved host',
    PortForwardBrowserTabGroup.savedForward => 'saved forwards',
    PortForwardBrowserTabGroup.sharedHost => 'shared host services',
  };

  /// Icon identifying this group in the browser tab chip.
  IconData get icon => switch (this) {
    PortForwardBrowserTabGroup.savedHost => Icons.terminal_rounded,
    PortForwardBrowserTabGroup.savedForward => Icons.swap_horiz_rounded,
    PortForwardBrowserTabGroup.sharedHost => Icons.dns_rounded,
  };
}

/// Initial tab configuration for the embedded browser.
class PortForwardBrowserInitialTab {
  /// Creates an initial browser tab.
  const PortForwardBrowserInitialTab({
    required this.uri,
    this.sourceUri,
    this.fallbackUri,
    this.title,
    this.group = PortForwardBrowserTabGroup.savedForward,
  });

  /// URL loaded by the tab.
  final Uri uri;

  /// Original local-forward URL represented by [uri].
  final Uri? sourceUri;

  /// Explicit loopback URL used if the friendly `.localhost` host cannot load.
  final Uri? fallbackUri;

  /// Optional label shown until the page title is available.
  final String? title;

  /// Presentation group used to order and separate tabs.
  final PortForwardBrowserTabGroup group;
}

/// Launch configuration for the embedded port-forward browser.
class PortForwardBrowserLaunch {
  /// Creates browser launch configuration.
  const PortForwardBrowserLaunch({required this.tabs, this.selectedIndex = 0})
    : assert(tabs.length > 0),
      assert(selectedIndex >= 0),
      assert(selectedIndex < tabs.length);

  /// Initial browser tabs.
  final List<PortForwardBrowserInitialTab> tabs;

  /// Initially selected tab.
  final int selectedIndex;
}

/// Launch configuration for a browser routed through a SOCKS forward.
class PortForwardBrowserSocksLaunch {
  /// Creates a SOCKS browser launch for [portForward].
  const PortForwardBrowserSocksLaunch({
    required this.portForward,
    this.hostLabel,
  });

  /// The saved dynamic forward every page loads through.
  final PortForward portForward;

  /// Saved label of the host that relays the pages, shown on the start page.
  final String? hostLabel;
}

/// Opens the in-app browser routed through the SOCKS [portForward].
///
/// The browser starts the forward, connecting to its host if needed.
Future<void> openSocksForwardBrowser(
  BuildContext context, {
  required PortForward portForward,
  String? hostLabel,
}) => context.pushNamed<void>(
  Routes.portForwardBrowser,
  extra: PortForwardBrowserSocksLaunch(
    portForward: portForward,
    hostLabel: hostLabel,
  ),
);

/// Embedded browser for pages exposed through local port forwards.
class PortForwardBrowserScreen extends ConsumerStatefulWidget {
  /// Creates a port-forward browser screen.
  const PortForwardBrowserScreen({
    required this.initialTabs,
    this.initialTabIndex = 0,
    super.key,
  }) : socksForward = null,
       socksHostLabel = null,
       assert(initialTabs.length > 0),
       assert(initialTabIndex >= 0),
       assert(initialTabIndex < initialTabs.length);

  /// Creates a browser that loads every page through [socksForward].
  ///
  /// It starts blank, and fails closed: while the forward is down it blocks
  /// navigation and covers the page instead of loading over the device's own
  /// network.
  const PortForwardBrowserScreen.socks({
    required PortForward this.socksForward,
    this.socksHostLabel,
    super.key,
  }) : initialTabs = const [],
       initialTabIndex = 0;

  /// Initial tabs to open.
  final List<PortForwardBrowserInitialTab> initialTabs;

  /// Initially selected tab.
  final int initialTabIndex;

  /// The dynamic forward this browser routes through, or null for a browser
  /// of loopback local forwards.
  final PortForward? socksForward;

  /// Saved label of the host behind [socksForward].
  final String? socksHostLabel;

  @override
  ConsumerState<PortForwardBrowserScreen> createState() =>
      _PortForwardBrowserScreenState();
}

class _PortForwardBrowserScreenState
    extends ConsumerState<PortForwardBrowserScreen>
    with WidgetsBindingObserver {
  TextEditingController? _addressController;
  List<_PortForwardBrowserTabState> _tabs = [];
  final _addressFocusNode = FocusNode();

  var _selectedTabIndex = 0;
  var _nextTabId = 0;
  var _allowRoutePop = false;

  // SOCKS mode only.
  late final SocksBrowserProxyService _socksProxy;
  SocksForwardRouteSource? _socksRoute;
  var _socksStatus = SocksBrowserRouteStatus.connecting;
  String? _socksMessage;
  var _socksProxyHeld = false;
  var _socksGeneration = 0;
  // Port the browser is being pointed at, while that is in flight.
  int? _socksRoutingPort;
  // Whether this browser started the forward, and so stops it on close.
  var _socksStartedForward = false;
  // A loopback browser could not remove a leftover SOCKS proxy.
  var _directProxyBlocked = false;

  _PortForwardBrowserTabState get _selectedTab => _tabs[_selectedTabIndex];

  bool get _isSocksBrowser => widget.socksForward != null;

  /// Whether pages may load: always for loopback forwards, and only while the
  /// browser is pointed at a live SOCKS listener otherwise.
  bool get _canLoadPages =>
      !_isSocksBrowser || _socksStatus == SocksBrowserRouteStatus.ready;

  @override
  void initState() {
    super.initState();
    _socksProxy = ref.read(socksBrowserProxyServiceProvider);
    _addressFocusNode.addListener(_handleAddressFocusChanged);
    if (_isSocksBrowser) {
      WidgetsBinding.instance.addObserver(this);
      ref.listenManual(
        activeSessionsProvider,
        (_, _) => _socksRoute?.refresh(),
      );
    }
    unawaited(_initializeBrowser());
  }

  @override
  void dispose() {
    if (_isSocksBrowser) {
      WidgetsBinding.instance.removeObserver(this);
      _socksGeneration++;
      _tearDownSocksBrowser();
    }
    _addressFocusNode.removeListener(_handleAddressFocusChanged);
    _addressController?.dispose();
    _addressFocusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_verifySocksRouteAfterResume());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_directProxyBlocked) {
      return Scaffold(
        appBar: AppBar(),
        body: BrandErrorState(
          icon: Icons.link_off_rounded,
          title: 'browser proxy stuck',
          message:
              'A SOCKS proxy is still set for the in-app browser, so it '
              'can’t open local forwards yet.',
          onRetry: () {
            setState(() => _directProxyBlocked = false);
            unawaited(_initializeBrowser());
          },
        ),
      );
    }
    if (_addressController == null || _tabs.isEmpty) {
      if (_isSocksBrowser) {
        return Scaffold(body: SafeArea(child: _buildSocksStatusPanel()));
      }
      return const Scaffold(
        body: SafeArea(child: Center(child: CircularProgressIndicator())),
      );
    }
    final selectedTab = _selectedTab;
    return PopScope(
      canPop:
          _allowRoutePop ||
          !_canLoadPages ||
          (!_addressFocusNode.hasFocus && !selectedTab.canGoBack),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _allowRoutePop) {
          return;
        }
        unawaited(_handleRouteBack());
      },
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      // A covered page must not stay reachable by screen
                      // readers either.
                      child: ExcludeSemantics(
                        excluding:
                            !_canLoadPages ||
                            (_isSocksBrowser && !selectedTab.hasStartedLoading),
                        child: WebViewWidget(
                          key: ValueKey<int>(selectedTab.id),
                          controller: selectedTab.controller,
                        ),
                      ),
                    ),
                    if (_isSocksBrowser && !selectedTab.hasStartedLoading)
                      Positioned.fill(
                        child: SocksBrowserStartPanel(
                          forwardName: widget.socksForward!.name,
                          hostLabel: widget.socksHostLabel,
                          port: _socksProxy.routedPort,
                        ),
                      ),
                    if (!_canLoadPages)
                      Positioned.fill(child: _buildSocksStatusPanel()),
                    if (_canLoadPages &&
                        selectedTab.isLoading &&
                        selectedTab.progress < 100)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: LinearProgressIndicator(
                          value: selectedTab.progress / 100,
                        ),
                      ),
                  ],
                ),
              ),
              _buildBottomChrome(context, selectedTab),
            ],
          ),
        ),
      ),
    );
  }

  _PortForwardBrowserTabState _createTab(PortForwardBrowserInitialTab seed) {
    final initialUri = _isSocksBrowser
        ? seed.uri
        : normalizePortForwardBrowserUri(seed.uri);
    late final _PortForwardBrowserTabState tab;
    var creationParams = const PlatformWebViewControllerCreationParams();
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      creationParams =
          WebKitWebViewControllerCreationParams.fromPlatformWebViewControllerCreationParams(
            creationParams,
            allowsInlineMediaPlayback: true,
          );
    }
    final controller =
        WebViewController.fromPlatformCreationParams(
            creationParams,
            onPermissionRequest: (request) =>
                unawaited(_handleWebPermissionRequest(tab, request)),
          )
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setNavigationDelegate(
            NavigationDelegate(
              onNavigationRequest: (request) =>
                  _handleNavigationRequest(tab, request),
              onWebResourceError: (error) =>
                  unawaited(_handleWebResourceError(tab, error)),
              onProgress: (progress) => _handleProgress(tab, progress),
              onPageStarted: (url) => _handlePageStarted(tab, url),
              onPageFinished: (url) => unawaited(_handlePageFinished(tab, url)),
              onUrlChange: (change) => _handleUrlChange(tab, change.url),
              onHttpAuthRequest: (request) =>
                  unawaited(_handleHttpAuthRequest(tab, request)),
            ),
          );

    return tab = _PortForwardBrowserTabState(
      id: _nextTabId++,
      controller: controller,
      browserUri: initialUri,
      sourceUri: _isSocksBrowser
          ? initialUri
          : normalizePortForwardBrowserUri(seed.sourceUri ?? seed.uri),
      fallbackUri: seed.fallbackUri == null
          ? null
          : normalizePortForwardBrowserUri(seed.fallbackUri!),
      currentUri: initialUri,
      initialTitle: seed.title,
      group: seed.group,
    );
  }

  Future<void> _initializeBrowser() async {
    final socksForward = widget.socksForward;
    if (socksForward != null) {
      await _initializeSocksBrowser(socksForward);
      return;
    }
    // A SOCKS browser that closed earlier leaves its proxy on the sink.
    try {
      await _socksProxy.clearBeforeDirectBrowsing();
    } on SocksBrowserProxyException {
      if (mounted) {
        setState(() => _directProxyBlocked = true);
      }
      return;
    }
    await _clearLegacySharedCookiesOnce();
    if (!mounted) {
      return;
    }
    final tabs = widget.initialTabs.map(_createTab).toList(growable: true);
    final selectedTabIndex = widget.initialTabIndex;
    final addressController = TextEditingController(
      text: tabs[selectedTabIndex].currentUri.toString(),
    );
    setState(() {
      _tabs = tabs;
      _selectedTabIndex = selectedTabIndex;
      _addressController = addressController;
    });
    _scheduleSelectedTabLoad();
  }

  Future<void> _initializeSocksBrowser(PortForward socksForward) async {
    final support = await _socksProxy.support();
    if (!mounted) {
      return;
    }
    if (!support.isSupported) {
      setState(() {
        _socksStatus = SocksBrowserRouteStatus.unsupported;
        _socksMessage = support.unavailableReason;
      });
      return;
    }
    await _clearLegacySharedCookiesOnce();
    if (!mounted) {
      return;
    }
    final source = ref.read(socksForwardRouteSourceFactoryProvider)(
      socksForward,
    );
    _socksRoute = source;
    source
      ..addListener(_handleSocksRouteChanged)
      ..refresh();
    if (source.route == null) {
      await _restartSocksRoute();
    } else {
      _handleSocksRouteChanged();
    }
  }

  /// Follows the forward: points the browser at a moved listener and blocks
  /// pages as soon as it stops.
  void _handleSocksRouteChanged() {
    final source = _socksRoute;
    if (!mounted || source == null) {
      return;
    }
    final route = source.route;
    if (route == null) {
      _socksGeneration++;
      _socksRoutingPort = null;
      final wasReady = _socksStatus == SocksBrowserRouteStatus.ready;
      if (wasReady || _socksStatus == SocksBrowserRouteStatus.connecting) {
        if (wasReady) {
          DiagnosticsLogService.instance.info('browser.socks', 'route_down');
        }
        setState(() {
          _socksStatus = SocksBrowserRouteStatus.down;
          _socksMessage = null;
        });
      }
      unawaited(_blockSocksPages());
      return;
    }
    if ((_socksStatus == SocksBrowserRouteStatus.ready &&
            route.port == _socksProxy.routedPort) ||
        _socksRoutingPort == route.port) {
      return;
    }
    unawaited(_routeBrowserThrough(route));
  }

  Future<void> _routeBrowserThrough(SocksForwardRoute route) async {
    final generation = ++_socksGeneration;
    final wasReady = _socksStatus == SocksBrowserRouteStatus.ready;
    _socksRoutingPort = route.port;
    setState(() => _socksStatus = SocksBrowserRouteStatus.connecting);
    if (wasReady) {
      // The forward moved: stop the pages before the old port is let go.
      await _blockSocksPages();
      if (!mounted || generation != _socksGeneration) {
        return;
      }
    }
    try {
      if (_socksProxyHeld) {
        await _socksProxy.reroute(route.port);
      } else {
        _socksProxyHeld = true;
        await _socksProxy.hold(route.port);
      }
    } on SocksBrowserProxyException {
      if (mounted && generation == _socksGeneration) {
        _socksRoutingPort = null;
        setState(() {
          _socksStatus = SocksBrowserRouteStatus.down;
          _socksMessage = 'Couldn’t point the browser at the forward.';
        });
      }
      return;
    }
    if (!mounted || generation != _socksGeneration) {
      return;
    }
    _socksRoutingPort = null;
    if (_socksRoute?.route != route) {
      // The forward moved or stopped while the proxy was being applied.
      _handleSocksRouteChanged();
      return;
    }
    if (_tabs.isEmpty) {
      final tab = _createTab(PortForwardBrowserInitialTab(uri: _blankSocksUri));
      setState(() {
        _tabs = [tab];
        _selectedTabIndex = 0;
        _addressController = TextEditingController();
        _socksStatus = SocksBrowserRouteStatus.ready;
        _socksMessage = null;
      });
      return;
    }
    setState(() {
      _socksStatus = SocksBrowserRouteStatus.ready;
      _socksMessage = null;
    });
    var restored = 0;
    for (final tab in _tabs) {
      final restoreUri = tab.socksRestoreUri;
      if (restoreUri == null) {
        continue;
      }
      tab.socksRestoreUri = null;
      restored++;
      unawaited(_loadSafely(tab, restoreUri));
    }
    if (restored > 0) {
      DiagnosticsLogService.instance.info(
        'browser.socks',
        'route_restored',
        fields: {'tabs': restored},
      );
    }
  }

  /// Stops every routed page and points the proxy at the sink.
  ///
  /// Covering a page does not stop its scripts, which keep requesting through
  /// the proxy. Each page is replaced by a blank one, remembering its address
  /// so it can load again once the forward is back.
  Future<void> _blockSocksPages() async {
    for (final tab in _tabs) {
      if (!tab.hasStartedLoading || tab.socksRestoreUri != null) {
        continue;
      }
      tab.socksRestoreUri = tab.currentUri;
      unawaited(_loadSafely(tab, _blankSocksUri));
    }
    if (_socksProxyHeld) {
      await _socksProxy.block();
    }
  }

  Future<void> _loadSafely(_PortForwardBrowserTabState tab, Uri uri) async {
    try {
      await tab.controller.loadRequest(uri);
    } on Object catch (error) {
      if (error is! PlatformException && error is! ArgumentError) rethrow;
    }
  }

  /// Leaves nothing able to load directly after the browser closes.
  ///
  /// The native web views can outlive this widget (Android's platform view
  /// does not destroy its WebView), so the pages are blanked first, then the
  /// proxy goes to the sink, and only then does a forward this browser started
  /// stop and free its port.
  void _tearDownSocksBrowser() {
    final source = _socksRoute;
    source?.removeListener(_handleSocksRouteChanged);
    for (final tab in _tabs) {
      if (tab.hasStartedLoading) {
        unawaited(_loadSafely(tab, _blankSocksUri));
      }
    }
    final released = _socksProxyHeld
        ? _socksProxy.release()
        : Future<void>.value();
    if (source != null) {
      final stopForward = _socksStartedForward ? source.stopForward : null;
      unawaited(
        released.whenComplete(() async {
          await stopForward?.call();
          source.dispose();
        }),
      );
    }
  }

  Future<void> _restartSocksRoute() async {
    final source = _socksRoute;
    if (source == null) {
      return;
    }
    _socksGeneration++;
    _socksRoutingPort = null;
    setState(() {
      _socksStatus = SocksBrowserRouteStatus.connecting;
      _socksMessage = null;
    });
    final wasStopped = source.route == null;
    final error = await source.restart();
    if (wasStopped && source.route != null) {
      if (!mounted) {
        // Closed while the forward was starting; nothing will use it.
        unawaited(source.stopForward());
        return;
      }
      _socksStartedForward = true;
    }
    if (!mounted || !identical(source, _socksRoute)) {
      return;
    }
    if (source.route == null) {
      setState(() {
        _socksStatus = SocksBrowserRouteStatus.down;
        _socksMessage = error;
      });
      return;
    }
    _handleSocksRouteChanged();
  }

  /// Restarts the forward when iOS reclaimed its listener while suspended.
  Future<void> _verifySocksRouteAfterResume() async {
    final source = _socksRoute;
    if (source == null ||
        source.route == null ||
        _socksStatus != SocksBrowserRouteStatus.ready) {
      return;
    }
    if (await source.probe() || !mounted) {
      return;
    }
    DiagnosticsLogService.instance.info(
      'browser.socks',
      'listener_lost_on_resume',
    );
    await _restartSocksRoute();
  }

  Widget _buildSocksStatusPanel() => SocksBrowserStatusPanel(
    status: _socksStatus,
    forwardName: widget.socksForward!.name,
    message: _socksMessage,
    onRestart: () => unawaited(_restartSocksRoute()),
    onClose: _closeBrowserRoute,
  );

  void _showSocksRouteInfo() {
    final host = widget.socksHostLabel?.trim();
    _showMessage(
      'Pages load through ${widget.socksForward!.name}'
      '${host == null || host.isEmpty ? '' : ' on $host'}. '
      'If it stops, pages are blocked rather than loaded directly.',
    );
  }

  Future<void> _clearLegacySharedCookiesOnce() async {
    final settings = ref.read(settingsServiceProvider);
    final alreadyMigrated = await settings.getBool(
      SettingKeys.portForwardBrowserCookieIsolationMigration,
    );
    if (alreadyMigrated) {
      return;
    }

    await WebViewCookieManager().clearCookies();
    await settings.setBool(
      SettingKeys.portForwardBrowserCookieIsolationMigration,
      value: true,
    );
  }

  void _scheduleSelectedTabLoad() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(_ensureTabLoaded(_selectedTab));
    });
  }

  Future<void> _ensureTabLoaded(_PortForwardBrowserTabState tab) async {
    if (tab.hasStartedLoading || !_tabs.contains(tab) || _isSocksBrowser) {
      return;
    }
    tab.hasStartedLoading = true;
    await _configureAndLoadController(tab);
  }

  Future<void> _configureAndLoadController(
    _PortForwardBrowserTabState tab,
  ) async {
    final controller = tab.controller;
    await controller.enableZoom(false);
    await controller.setOnJavaScriptAlertDialog(_showJavaScriptAlert);
    await controller.setOnJavaScriptConfirmDialog(_showJavaScriptConfirm);
    await controller.setOnJavaScriptTextInputDialog(_showJavaScriptPrompt);
    final platformController = controller.platform;
    if (platformController is AndroidWebViewController) {
      await platformController.setUseWideViewPort(true);
      await platformController.setTextZoom(100);
      await platformController.setGeolocationEnabled(true);
      await platformController.setOnShowFileSelector(
        (params) => _showAndroidFileSelector(tab, params),
      );
      await platformController.setGeolocationPermissionsPromptCallbacks(
        onShowPrompt: (request) =>
            _handleGeolocationPermissionRequest(tab, request),
      );
      // Flutter owns the safe viewport, so don't let Android WebView apply the
      // same system-bar and cutout insets again to the page's web content.
      await platformController.setInsetsForWebContentToIgnore([
        AndroidWebViewInsets.systemBars,
        AndroidWebViewInsets.displayCutout,
        AndroidWebViewInsets.mandatorySystemGestures,
        AndroidWebViewInsets.systemGestures,
        AndroidWebViewInsets.tappableElement,
      ]);
    }
    if (platformController is WebKitWebViewController) {
      await platformController.setAllowsBackForwardNavigationGestures(true);
    }
    await controller.loadRequest(tab.currentUri);
  }

  Future<List<String>> _showAndroidFileSelector(
    _PortForwardBrowserTabState tab,
    FileSelectorParams params,
  ) async {
    if (!mounted || !_tabs.contains(tab)) {
      return const [];
    }

    try {
      final captureType = params.isCaptureEnabled
          ? preferredBrowserMediaCaptureType(params.acceptTypes)
          : null;
      if (captureType != null) {
        final source = await _chooseBrowserFileSource(captureType);
        if (!mounted || !_tabs.contains(tab) || source == null) {
          return const [];
        }
        if (source == _BrowserFileSource.camera) {
          final capturedMedia = await _captureBrowserMedia(tab, captureType);
          return mounted && _tabs.contains(tab) ? capturedMedia : const [];
        }
      }

      final filter = resolveBrowserFilePickerFilter(params.acceptTypes);
      final allowMultiple = params.mode == FileSelectorMode.openMultiple;
      final List<PlatformFile> files;
      if (allowMultiple) {
        files = await FilePicker.pickFiles(
          type: filter.type,
          allowedExtensions: filter.allowedExtensions,
        );
      } else {
        final file = await FilePicker.pickFile(
          type: filter.type,
          allowedExtensions: filter.allowedExtensions,
        );
        files = file == null ? const [] : [file];
      }
      if (!mounted || !_tabs.contains(tab)) {
        return const [];
      }
      final uris = files
          .map(browserUploadUriForPlatformFile)
          .whereType<String>()
          .toList(growable: false);
      if (files.isNotEmpty && uris.isEmpty) {
        _showMessage('The selected file could not be opened.');
      }
      return uris;
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'browser.files',
        'picker_failed',
        fields: {'errorType': error.runtimeType},
      );
      _showMessage('Could not open the file picker. Try again.');
      return const [];
    }
  }

  Future<_BrowserFileSource?> _chooseBrowserFileSource(
    BrowserMediaCaptureType captureType,
  ) {
    final isImage = captureType == BrowserMediaCaptureType.image;
    return showModalBottomSheet<_BrowserFileSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                isImage ? Icons.photo_camera_outlined : Icons.videocam_outlined,
              ),
              title: Text(isImage ? 'Take photo' : 'Record video'),
              onTap: () => Navigator.of(context).pop(_BrowserFileSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('Choose file'),
              onTap: () => Navigator.of(context).pop(_BrowserFileSource.files),
            ),
          ],
        ),
      ),
    );
  }

  Future<List<String>> _captureBrowserMedia(
    _PortForwardBrowserTabState tab,
    BrowserMediaCaptureType captureType,
  ) async {
    final cameraStatus = await Permission.camera.request();
    if (!mounted || !_tabs.contains(tab)) {
      return const [];
    }
    if (!cameraStatus.isGranted) {
      _showMessage('Camera access is required to capture media.');
      return const [];
    }
    if (captureType == BrowserMediaCaptureType.video) {
      final microphoneStatus = await Permission.microphone.request();
      if (!mounted || !_tabs.contains(tab)) {
        return const [];
      }
      if (!microphoneStatus.isGranted) {
        _showMessage('Microphone access is required to record video.');
        return const [];
      }
    }

    final picker = ImagePicker();
    final media = switch (captureType) {
      BrowserMediaCaptureType.image => await picker.pickImage(
        source: ImageSource.camera,
        requestFullMetadata: false,
      ),
      BrowserMediaCaptureType.video => await picker.pickVideo(
        source: ImageSource.camera,
      ),
    };
    return media == null ? const [] : [Uri.file(media.path).toString()];
  }

  Future<void> _handleWebPermissionRequest(
    _PortForwardBrowserTabState tab,
    WebViewPermissionRequest request,
  ) async {
    final supportedTypes = {
      WebViewPermissionResourceType.camera,
      WebViewPermissionResourceType.microphone,
    };
    if (!mounted ||
        !_tabs.contains(tab) ||
        request.types.isEmpty ||
        !supportedTypes.containsAll(request.types)) {
      await request.deny();
      return;
    }

    final permissionLabel = _webPermissionLabel(request.types);
    final allowed = await _confirmPagePermission(
      origin: 'Current tab: ${_displayOrigin(tab.currentUri)}',
      title: 'Allow $permissionLabel?',
      message:
          'Web content in this tab wants to use your $permissionLabel. '
          'Only allow access if you trust this page.',
    );
    if (!mounted || !_tabs.contains(tab) || !allowed) {
      await request.deny();
      return;
    }

    if (defaultTargetPlatform == TargetPlatform.macOS) {
      try {
        await request.grant();
      } on PlatformException {
        await request.deny();
        _showMessage(
          'Could not grant ${_webPermissionLabel(request.types)} access.',
        );
      }
      return;
    }

    try {
      for (final type in request.types) {
        final status = await switch (type) {
          WebViewPermissionResourceType.camera => Permission.camera.request(),
          WebViewPermissionResourceType.microphone =>
            Permission.microphone.request(),
          _ => Future.value(PermissionStatus.denied),
        };
        if (!mounted || !_tabs.contains(tab)) {
          await request.deny();
          return;
        }
        if (!status.isGranted) {
          await request.deny();
          _showMessage(
            '${_capitalizedPermissionLabel(permissionLabel)} access was denied.',
          );
          return;
        }
      }
      await request.grant();
    } on MissingPluginException {
      await request.deny();
      _showMessage(
        '${_capitalizedPermissionLabel(permissionLabel)} access is not '
        'available on this device.',
      );
    } on PlatformException {
      await request.deny();
      _showMessage(
        'Could not grant ${_webPermissionLabel(request.types)} access.',
      );
    }
  }

  Future<GeolocationPermissionsResponse> _handleGeolocationPermissionRequest(
    _PortForwardBrowserTabState tab,
    GeolocationPermissionsRequestParams request,
  ) async {
    if (!mounted || !_tabs.contains(tab)) {
      return const GeolocationPermissionsResponse(allow: false, retain: false);
    }

    final allowed = await _confirmPagePermission(
      origin: _displayOrigin(Uri.tryParse(request.origin) ?? tab.currentUri),
      title: 'Allow location?',
      message:
          'This page wants to use your approximate location. '
          'Only allow access if you trust this page.',
    );
    if (!mounted || !_tabs.contains(tab) || !allowed) {
      return const GeolocationPermissionsResponse(allow: false, retain: false);
    }

    try {
      final status = await Permission.locationWhenInUse.request();
      if (!mounted || !_tabs.contains(tab)) {
        return const GeolocationPermissionsResponse(
          allow: false,
          retain: false,
        );
      }
      if (!status.isGranted) {
        _showMessage('Location access was denied.');
      }
      return GeolocationPermissionsResponse(
        allow: status.isGranted,
        retain: false,
      );
    } on PlatformException {
      _showMessage('Could not grant location access.');
      return const GeolocationPermissionsResponse(allow: false, retain: false);
    }
  }

  Future<bool> _confirmPagePermission({
    required String origin,
    required String title,
    required String message,
  }) async {
    if (!mounted) {
      return false;
    }
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text('$message\n\n$origin'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Not now'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Allow'),
              ),
            ],
          ),
        ) ??
        false;
  }

  String _webPermissionLabel(Set<WebViewPermissionResourceType> types) {
    final hasCamera = types.contains(WebViewPermissionResourceType.camera);
    final hasMicrophone = types.contains(
      WebViewPermissionResourceType.microphone,
    );
    if (hasCamera && hasMicrophone) {
      return 'camera and microphone';
    }
    return hasCamera ? 'camera' : 'microphone';
  }

  String _capitalizedPermissionLabel(String label) =>
      '${label.substring(0, 1).toUpperCase()}${label.substring(1)}';

  Future<void> _showJavaScriptAlert(
    JavaScriptAlertDialogRequest request,
  ) async {
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_displayRequestOrigin(request.url)),
        content: SelectableText(request.message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<bool> _showJavaScriptConfirm(
    JavaScriptConfirmDialogRequest request,
  ) async {
    if (!mounted) {
      return false;
    }
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(_displayRequestOrigin(request.url)),
            content: SelectableText(request.message),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('OK'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<String> _showJavaScriptPrompt(
    JavaScriptTextInputDialogRequest request,
  ) async {
    if (!mounted) {
      return '';
    }
    return await showDialog<String>(
          context: context,
          builder: (_) => _JavaScriptPromptDialog(
            title: _displayRequestOrigin(request.url),
            message: request.message,
            defaultText: request.defaultText,
          ),
        ) ??
        '';
  }

  Future<void> _handleHttpAuthRequest(
    _PortForwardBrowserTabState tab,
    HttpAuthRequest request,
  ) async {
    if (!mounted || !_tabs.contains(tab)) {
      request.onCancel();
      return;
    }
    final credential = await showDialog<WebViewCredential>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _HttpAuthDialog(
        origin: request.realm?.isNotEmpty ?? false
            ? '${request.host} - ${request.realm}'
            : request.host,
      ),
    );
    if (!mounted || !_tabs.contains(tab) || credential == null) {
      request.onCancel();
    } else {
      request.onProceed(credential);
    }
  }

  String _displayRequestOrigin(String url) {
    final fallbackUri = _tabs.isEmpty ? null : _selectedTab.currentUri;
    final uri = Uri.tryParse(url) ?? fallbackUri;
    return uri == null ? 'This page' : _displayOrigin(uri);
  }

  String _displayOrigin(Uri uri) => portForwardBrowserDisplayOrigin(uri);

  Widget _buildBottomChrome(
    BuildContext context,
    _PortForwardBrowserTabState selectedTab,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: colorScheme.outlineVariant)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_tabs.length > 1) _buildTabStrip(context),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                child: _buildBottomControls(context, selectedTab),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomControls(
    BuildContext context,
    _PortForwardBrowserTabState selectedTab,
  ) {
    final isEditingAddress = _addressFocusNode.hasFocus;
    if (isEditingAddress) {
      return _buildAddressField(context);
    }

    return Row(
      children: [
        IconButton(
          onPressed: _closeBrowserRoute,
          tooltip: 'Close',
          icon: const Icon(Icons.close),
        ),
        const SizedBox(width: 4),
        Expanded(child: _buildAddressField(context)),
        const SizedBox(width: 4),
        IconButton(
          onPressed: selectedTab.canGoBack && _canLoadPages
              ? () => unawaited(_goBack())
              : null,
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back),
        ),
        IconButton(
          onPressed: selectedTab.canGoForward && _canLoadPages
              ? () => unawaited(_goForward())
              : null,
          tooltip: 'Forward',
          icon: const Icon(Icons.arrow_forward),
        ),
        IconButton(
          onPressed: _canLoadPages && selectedTab.hasStartedLoading
              ? () => unawaited(selectedTab.controller.reload())
              : null,
          tooltip: 'Reload',
          icon: const Icon(Icons.refresh),
        ),
        // The system browser would load the page over the device's own
        // network, so a SOCKS browser shows its route instead.
        if (_isSocksBrowser)
          IconButton(
            onPressed: _showSocksRouteInfo,
            tooltip: 'Routed through ${widget.socksForward!.name}',
            icon: Icon(
              _canLoadPages ? Icons.lan_outlined : Icons.link_off_rounded,
            ),
          )
        else
          IconButton(
            onPressed: () => unawaited(_openCurrentPageInSystemBrowser()),
            tooltip: 'Open in system browser',
            icon: const Icon(Icons.open_in_new),
          ),
      ],
    );
  }

  Widget _buildAddressField(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return TextField(
      controller: _addressController,
      focusNode: _addressFocusNode,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: TextInputType.url,
      textInputAction: TextInputAction.go,
      style: FluttyTheme.monoStyle.copyWith(
        fontSize: 13,
        color: colorScheme.onSurface,
      ),
      inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest,
        hintText: _isSocksBrowser
            ? 'Address the host can reach'
            : 'Search or enter URL',
        prefixIcon: const Icon(Icons.travel_explore),
        suffixIcon: IconButton(
          onPressed: () => unawaited(_loadAddress(_addressController!.text)),
          tooltip: 'Load URL',
          icon: const Icon(Icons.arrow_circle_right_outlined),
        ),
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      onTapOutside: (_) => _addressFocusNode.unfocus(),
      onSubmitted: (value) => unawaited(_loadAddress(value)),
    );
  }

  void _handleAddressFocusChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Widget _buildTabStrip(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final groups = PortForwardBrowserTabGroup.values
        .map(
          (group) => (
            group: group,
            tabs: _tabs.indexed
                .where((entry) => entry.$2.group == group)
                .toList(growable: false),
          ),
        )
        .where((entry) => entry.tabs.isNotEmpty)
        .toList(growable: false);
    final children = <Widget>[];
    for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) {
      final groupEntry = groups[groupIndex];
      if (groupIndex > 0) {
        children.add(
          VerticalDivider(
            width: 20,
            indent: 8,
            endIndent: 8,
            color: colorScheme.outlineVariant,
          ),
        );
      }
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Center(
            child: Text(
              groupEntry.group.label,
              style: FluttyTheme.displayMono(
                fontSize: 11,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
      for (final indexedTab in groupEntry.tabs) {
        final tabIndex = indexedTab.$1;
        final tab = indexedTab.$2;
        final selected = tabIndex == _selectedTabIndex;
        children.add(
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: InputChip(
              selected: selected,
              label: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  _tabLabel(tab),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              avatar: Icon(
                tab.group.icon,
                size: 18,
                color: selected ? colorScheme.onSecondaryContainer : null,
              ),
              onPressed: () => _selectTab(tabIndex),
              onDeleted: _tabs.length > 1 ? () => _closeTab(tabIndex) : null,
            ),
          ),
        );
      }
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(top: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: SizedBox(
        height: 56,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          scrollDirection: Axis.horizontal,
          children: children,
        ),
      ),
    );
  }

  String _tabLabel(_PortForwardBrowserTabState tab) {
    if (tab.pageTitle?.trim().isNotEmpty ?? false) {
      return tab.pageTitle!.trim();
    }
    if (tab.initialTitle?.trim().isNotEmpty ?? false) {
      return tab.initialTitle!.trim();
    }
    return tab.currentUri.authority.isNotEmpty
        ? tab.currentUri.authority
        : tab.currentUri.toString();
  }

  void _selectTab(int index) {
    if (index == _selectedTabIndex) {
      return;
    }
    setState(() {
      _selectedTabIndex = index;
      _addressController?.text = _selectedTab.currentUri.toString();
    });
    _scheduleSelectedTabLoad();
    unawaited(_refreshNavigationState(_selectedTab));
  }

  void _closeTab(int index) {
    if (_tabs.length == 1) {
      return;
    }
    setState(() {
      _tabs.removeAt(index);
      if (_selectedTabIndex >= _tabs.length) {
        _selectedTabIndex = _tabs.length - 1;
      } else if (index < _selectedTabIndex) {
        _selectedTabIndex -= 1;
      }
      _addressController?.text = _selectedTab.currentUri.toString();
    });
    _scheduleSelectedTabLoad();
  }

  void _handleProgress(_PortForwardBrowserTabState tab, int progress) {
    if (!mounted) return;
    tab
      ..progress = progress
      ..isLoading = progress < 100;
    // Only the selected tab renders its progress bar; switching tabs rebuilds.
    if (identical(tab, _selectedTab)) {
      setState(() {});
    }
  }

  Future<void> _handleWebResourceError(
    _PortForwardBrowserTabState tab,
    WebResourceError error,
  ) async {
    final fallbackUri = tab.fallbackUri;
    if (fallbackUri == null || !_tabs.contains(tab)) {
      return;
    }
    final rawFailedUrl = error.url;
    final failedUri = rawFailedUrl == null || rawFailedUrl.isEmpty
        ? null
        : Uri.tryParse(rawFailedUrl);
    if (!shouldUsePortForwardBrowserFallback(
      browserUri: tab.browserUri,
      failedUri: failedUri,
      isForMainFrame: error.isForMainFrame,
      alreadyTried: tab.hasTriedLoopbackFallback,
    )) {
      return;
    }

    tab.hasTriedLoopbackFallback = true;
    final fallbackRequestUri = buildPortForwardBrowserFallbackRequestUri(
      browserUri: tab.browserUri,
      fallbackUri: fallbackUri,
      requestedUri: failedUri ?? tab.currentUri,
    );
    await tab.controller.loadRequest(fallbackRequestUri);
    if (!mounted || !_tabs.contains(tab)) {
      return;
    }
    _showMessage('Friendly host unavailable; opened the local proxy directly.');
  }

  /// Whether [uri] is a blank page this browser loaded to stop a SOCKS page,
  /// which must not replace the address the tab shows and restores.
  bool _isSocksPlaceholder(Uri? uri) =>
      _isSocksBrowser && uri != null && uri.scheme == 'about';

  void _handlePageStarted(_PortForwardBrowserTabState tab, String url) {
    if (!mounted) return;
    final uri = Uri.tryParse(url);
    if (_isSocksPlaceholder(uri)) return;
    setState(() {
      tab.isLoading = true;
      if (uri != null) {
        tab.currentUri = _normalizeLoadedBrowserUri(uri);
      }
      if (identical(tab, _selectedTab) && !_addressFocusNode.hasFocus) {
        _addressController?.text = tab.currentUri.toString();
      }
    });
  }

  void _handleUrlChange(_PortForwardBrowserTabState tab, String? url) {
    if (!mounted || url == null) return;
    final uri = Uri.tryParse(url);
    if (uri == null || _isSocksPlaceholder(uri)) return;

    setState(() {
      tab.currentUri = _normalizeLoadedBrowserUri(uri);
      if (identical(tab, _selectedTab) && !_addressFocusNode.hasFocus) {
        _addressController?.text = tab.currentUri.toString();
      }
    });
    unawaited(_refreshNavigationState(tab));
  }

  Future<void> _handlePageFinished(
    _PortForwardBrowserTabState tab,
    String url,
  ) async {
    final uri = Uri.tryParse(url);
    if (_isSocksPlaceholder(uri)) return;
    final title = await tab.controller.getTitle();
    if (!mounted) return;
    setState(() {
      tab
        ..isLoading = false
        ..pageTitle = title;
      if (uri != null) {
        tab.currentUri = _normalizeLoadedBrowserUri(uri);
      }
      if (identical(tab, _selectedTab) && !_addressFocusNode.hasFocus) {
        _addressController?.text = tab.currentUri.toString();
      }
    });
    await _refreshNavigationState(tab);
  }

  Future<void> _goBack() async {
    final tab = _selectedTab;
    await tab.controller.goBack();
    await _refreshNavigationState(tab);
  }

  Future<void> _handleRouteBack() async {
    if (_addressFocusNode.hasFocus) {
      _addressFocusNode.unfocus();
      return;
    }

    final tab = _selectedTab;
    final canGoBack = await tab.controller.canGoBack();
    if (!mounted || !_tabs.contains(tab)) {
      return;
    }

    if (canGoBack) {
      await tab.controller.goBack();
      await _refreshNavigationState(tab);
      return;
    }

    _closeBrowserRoute();
  }

  void _closeBrowserRoute() {
    if (_allowRoutePop) {
      return;
    }
    setState(() => _allowRoutePop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final navigator = Navigator.of(context);
      if (navigator.canPop()) {
        navigator.pop();
      } else {
        unawaited(navigator.maybePop());
      }
    });
  }

  Future<void> _goForward() async {
    final tab = _selectedTab;
    await tab.controller.goForward();
    await _refreshNavigationState(tab);
  }

  Future<void> _loadAddress(String address) async {
    final uri = _parseBrowserAddress(address);
    if (uri == null) {
      _showMessage('Enter an HTTP or HTTPS URL');
      return;
    }

    _addressFocusNode.unfocus();
    if (!_canLoadPages) {
      _showMessage('The SOCKS forward is down. Restart it to keep browsing.');
      return;
    }
    final tab = _selectedTab;
    if (!tab.hasStartedLoading) {
      // A SOCKS tab stays blank until its first address.
      setState(() {
        tab
          ..hasStartedLoading = true
          ..currentUri = uri;
        _addressController?.text = uri.toString();
      });
      await _configureAndLoadController(tab);
      return;
    }
    await tab.controller.loadRequest(uri);
    if (!mounted) return;
    setState(() {
      tab.currentUri = uri;
      _addressController?.text = uri.toString();
    });
  }

  Future<void> _openCurrentPageInSystemBrowser() async {
    final currentUrl = await _selectedTab.controller.currentUrl();
    if (!mounted) return;

    final uri = Uri.tryParse(currentUrl ?? '') ?? _selectedTab.currentUri;
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      _showMessage('Only HTTP and HTTPS pages can open in the system browser');
      return;
    }

    var launched = false;
    try {
      launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on PlatformException {
      launched = false;
    }
    if (!mounted || launched) {
      return;
    }
    _showMessage('Could not open $uri');
  }

  Future<NavigationDecision> _handleNavigationRequest(
    _PortForwardBrowserTabState tab,
    NavigationRequest request,
  ) async {
    final uri = Uri.tryParse(request.url);
    if (uri == null) {
      _showMessage('Could not open ${request.url}');
      return NavigationDecision.prevent;
    }
    if (_isSocksBrowser && _isNetworkScheme(uri.scheme)) {
      // Fail closed: nothing loads unless the forward is live, and the native
      // proxy has no direct fallback for what does.
      return _canLoadPages
          ? NavigationDecision.navigate
          : NavigationDecision.prevent;
    }
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      if (!request.isMainFrame) {
        return NavigationDecision.navigate;
      }
      if (shouldLoadPortForwardBrowserFallbackDirectly(
        requestedUri: uri,
        fallbackUri: tab.fallbackUri,
        fallbackActive: tab.hasTriedLoopbackFallback,
      )) {
        return NavigationDecision.navigate;
      }
      final normalizedUri = _normalizeBrowserUri(uri);
      if (normalizedUri.toString() != uri.toString()) {
        unawaited(tab.controller.loadRequest(normalizedUri));
        return NavigationDecision.prevent;
      }
      return NavigationDecision.navigate;
    }
    if (uri.scheme == 'about' || uri.scheme == 'blob' || uri.scheme == 'data') {
      return NavigationDecision.navigate;
    }
    if (uri.scheme == 'javascript') {
      return NavigationDecision.navigate;
    }
    if (shouldLaunchPortForwardBrowserUriExternally(uri)) {
      if (!request.isMainFrame) {
        return NavigationDecision.prevent;
      }
      if (_isSocksBrowser) {
        // Another app would load its target over this device's own network,
        // so a page reached through the forward cannot hand off links.
        _showMessage('Links to other apps are blocked in a SOCKS browser.');
        return NavigationDecision.prevent;
      }
      try {
        final launched = await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
        if (!launched) {
          _showMessage('No app can open this link.');
        }
      } on PlatformException {
        _showMessage('Could not open this link.');
      }
      return NavigationDecision.prevent;
    }

    _showMessage('Unsupported link scheme: ${uri.scheme}');
    return NavigationDecision.prevent;
  }

  Future<void> _refreshNavigationState(_PortForwardBrowserTabState tab) async {
    final canGoBack = await tab.controller.canGoBack();
    final canGoForward = await tab.controller.canGoForward();
    if (!mounted) return;
    setState(() {
      tab
        ..canGoBack = canGoBack
        ..canGoForward = canGoForward;
    });
  }

  Uri? _parseBrowserAddress(String address) {
    final trimmed = address.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final candidate = _hasUriScheme(trimmed)
        ? trimmed
        : '${_defaultSchemeForAddress(trimmed)}://$trimmed';
    final uri = Uri.tryParse(candidate);
    if (uri == null || uri.host.isEmpty) {
      return null;
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return null;
    }
    return _normalizeBrowserUri(uri);
  }

  Uri _normalizeLoadedBrowserUri(Uri uri) =>
      uri.scheme == 'http' || uri.scheme == 'https'
      ? _normalizeBrowserUri(uri)
      : uri;

  Uri _normalizeBrowserUri(Uri uri) {
    if (_isSocksBrowser) {
      // Hosts name the destination as the SSH server sees it; loopback
      // rewriting only applies to local forwards.
      return uri;
    }
    final normalizedUri = normalizePortForwardBrowserUri(uri);
    for (final tab in _tabs) {
      if (_sameBrowserEndpoint(normalizedUri, tab.browserUri)) {
        return normalizedUri;
      }
    }
    for (final tab in _tabs) {
      final rewritten = rewriteUriForPortForwardBrowser(
        normalizedUri,
        sourceUri: tab.sourceUri,
        browserUri: tab.browserUri,
      );
      if (rewritten != null) {
        return rewritten;
      }
    }
    return normalizedUri;
  }

  bool _sameBrowserEndpoint(Uri left, Uri right) =>
      left.host.toLowerCase() == right.host.toLowerCase() &&
      portForwardBrowserUriPort(left) == portForwardBrowserUriPort(right);

  String _defaultSchemeForAddress(String address) {
    final candidate = Uri.tryParse('//$address');
    if (_isSocksBrowser) {
      return candidate != null && isLikelyInternalBrowserAddress(candidate)
          ? 'http'
          : 'https';
    }
    return candidate != null && isPortForwardBrowserHost(candidate.host)
        ? 'http'
        : 'https';
  }

  bool _isNetworkScheme(String scheme) =>
      const {'http', 'https', 'ws', 'wss'}.contains(scheme.toLowerCase());

  bool _hasUriScheme(String value) =>
      RegExp('^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(value);

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

enum _BrowserFileSource { camera, files }

final _blankSocksUri = Uri.parse('about:blank');

/// Whether a scheme-less SOCKS browser address most likely names an internal
/// service, which usually serves plain HTTP: an IP literal, a single-label
/// name, or an explicit port.
@visibleForTesting
bool isLikelyInternalBrowserAddress(Uri candidate) {
  final host = candidate.host;
  if (host.isEmpty) {
    return false;
  }
  return candidate.hasPort ||
      !host.contains('.') ||
      InternetAddress.tryParse(host) != null;
}

class _PortForwardBrowserTabState {
  _PortForwardBrowserTabState({
    required this.id,
    required this.controller,
    required this.browserUri,
    required this.sourceUri,
    required this.fallbackUri,
    required this.currentUri,
    required this.group,
    this.initialTitle,
  });

  final int id;
  final WebViewController controller;
  final Uri browserUri;
  final Uri sourceUri;
  final Uri? fallbackUri;
  final String? initialTitle;
  final PortForwardBrowserTabGroup group;
  int progress = 0;
  bool canGoBack = false;
  bool canGoForward = false;
  bool isLoading = true;
  bool hasStartedLoading = false;
  bool hasTriedLoopbackFallback = false;

  /// Address to load again once a dropped SOCKS forward is back.
  Uri? socksRestoreUri;
  Uri currentUri;
  String? pageTitle;
}

/// Owns its controller so the field survives the dialog's exit transition.
class _JavaScriptPromptDialog extends StatefulWidget {
  const _JavaScriptPromptDialog({
    required this.title,
    required this.message,
    required this.defaultText,
  });

  final String title;
  final String message;
  final String? defaultText;

  @override
  State<_JavaScriptPromptDialog> createState() =>
      _JavaScriptPromptDialogState();
}

class _JavaScriptPromptDialogState extends State<_JavaScriptPromptDialog> {
  late final _controller = TextEditingController(text: widget.defaultText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.message),
        const SizedBox(height: 16),
        TextField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Response'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(''),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_controller.text),
        child: const Text('OK'),
      ),
    ],
  );
}

/// Owns its controllers so the fields survive the dialog's exit transition.
class _HttpAuthDialog extends StatefulWidget {
  const _HttpAuthDialog({required this.origin});

  final String origin;

  @override
  State<_HttpAuthDialog> createState() => _HttpAuthDialogState();
}

class _HttpAuthDialogState extends State<_HttpAuthDialog> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(
    WebViewCredential(
      user: _usernameController.text,
      password: _passwordController.text,
    ),
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Sign in'),
    content: AutofillGroup(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.origin),
          const SizedBox(height: 16),
          TextField(
            controller: _usernameController,
            autofocus: true,
            autofillHints: const [AutofillHints.username],
            decoration: const InputDecoration(labelText: 'Username'),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            autofillHints: const [AutofillHints.password],
            decoration: const InputDecoration(labelText: 'Password'),
            obscureText: true,
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Sign in')),
    ],
  );
}
