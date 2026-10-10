// ignore_for_file: public_member_api_docs, depend_on_referenced_packages

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/socks_browser_proxy_service.dart';
import 'package:monkeyssh/domain/services/socks_forward_route.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/screens/port_forward_browser_screen.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:webview_flutter/webview_flutter.dart' show WebViewWidget;
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class _Settings extends Mock implements SettingsService {}

class _NoSessions extends ActiveSessionsNotifier {
  @override
  Map<int, SshConnectionState> build() => {};
}

/// Records native proxy calls and web view creation in one timeline.
final _events = <String>[];

class _WebViewPlatform extends WebViewPlatform {
  final controllers = <_Controller>[];
  final delegates = <_NavigationDelegate>[];

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    _events.add('webview');
    final controller = _Controller();
    controllers.add(controller);
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) {
    final delegate = _NavigationDelegate();
    delegates.add(delegate);
    return delegate;
  }

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _WebViewWidget(params);
}

class _Controller extends Fake
    with MockPlatformInterfaceMixin
    implements PlatformWebViewController {
  final requests = <Uri>[];
  int reloads = 0;

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    _events.add('load:${params.uri}');
    requests.add(params.uri);
  }

  @override
  Future<void> reload() async {
    reloads++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _NavigationDelegate extends Fake
    with MockPlatformInterfaceMixin
    implements PlatformNavigationDelegate {
  NavigationRequestCallback? onNavigationRequest;

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {
    this.onNavigationRequest = onNavigationRequest;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _WebViewWidget extends PlatformWebViewWidget {
  _WebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

class _RouteSource extends ChangeNotifier implements SocksForwardRouteSource {
  _RouteSource(this._route);

  SocksForwardRoute? _route;
  int restarts = 0;
  bool probeResult = true;
  SocksForwardRoute? Function()? onRestart;
  String? restartError;

  @override
  SocksForwardRoute? get route => _route;

  set route(SocksForwardRoute? value) {
    _route = value;
    notifyListeners();
  }

  @override
  void refresh() {}

  @override
  Future<String?> restart() async {
    restarts++;
    final next = onRestart?.call();
    if (next != null) {
      route = next;
      return null;
    }
    return restartError;
  }

  @override
  Future<bool> probe() async => probeResult;

  @override
  Future<void> stopForward() async {
    _events.add('stop-forward');
  }
}

final _forward = PortForward(
  id: 7,
  name: 'Office',
  hostId: 42,
  forwardType: 'dynamic',
  localHost: '127.0.0.1',
  localPort: 0,
  remoteHost: '',
  remotePort: 0,
  autoStart: false,
  createdAt: DateTime(2026),
);

const _proxyChannel = MethodChannel(SocksBrowserProxyService.channelName);
const _sinkPort = 9;

void main() {
  late _WebViewPlatform platform;
  late _Settings settings;

  setUp(() {
    _events.clear();
    FluttyTheme.debugUseSystemFonts = true;
    addTearDown(() => FluttyTheme.debugUseSystemFonts = false);
    final previousPlatform = WebViewPlatform.instance;
    platform = _WebViewPlatform();
    WebViewPlatform.instance = platform;
    addTearDown(() {
      if (previousPlatform != null) {
        WebViewPlatform.instance = previousPlatform;
      }
    });
    settings = _Settings();
    when(
      () => settings.getBool(
        SettingKeys.portForwardBrowserCookieIsolationMigration,
      ),
    ).thenAnswer((_) async => true);
  });

  /// Answers the native proxy bridge. [applyGate], when given, can hold an
  /// `apply` for a port until the returned completer completes.
  void mockProxyChannel({
    bool supported = true,
    bool clearFails = false,
    Completer<void>? Function(int port)? applyGate,
  }) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          ..setMockMethodCallHandler(_proxyChannel, (call) async {
            switch (call.method) {
              case 'isSupported':
                return supported;
              case 'apply':
                final port = (call.arguments as Map)['port'] as int;
                _events.add('apply:$port');
                await applyGate?.call(port)?.future;
              case 'clear':
                _events.add('clear');
                if (clearFails) {
                  throw PlatformException(code: 'clear_failed');
                }
            }
            return null;
          });
    addTearDown(() => messenger.setMockMethodCallHandler(_proxyChannel, null));
  }

  Future<void> pumpScreen(
    WidgetTester tester,
    Widget screen, {
    _RouteSource? source,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsServiceProvider.overrideWithValue(settings),
          activeSessionsProvider.overrideWith(_NoSessions.new),
          socksBrowserProxyServiceProvider.overrideWithValue(
            SocksBrowserProxyService(
              platform: TargetPlatform.iOS,
              sinkPort: () async => _sinkPort,
            ),
          ),
          if (source != null)
            socksForwardRouteSourceFactoryProvider.overrideWithValue(
              (_) => source,
            ),
        ],
        child: MaterialApp(home: screen),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
  }

  Future<void> pumpBrowser(WidgetTester tester, _RouteSource source) =>
      pumpScreen(
        tester,
        PortForwardBrowserScreen.socks(
          socksForward: _forward,
          socksHostLabel: 'Dev box',
        ),
        source: source,
      );

  /// Disposes the browser and lets its teardown run.
  Future<void> closeBrowser(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<NavigationDecision> navigate(String url) async =>
      await platform.delegates.single.onNavigationRequest!(
        NavigationRequest(url: url, isMainFrame: true),
      );

  Future<void> openAddress(WidgetTester tester, String address) async {
    await tester.enterText(find.byType(TextField), address);
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();
    await tester.pump();
  }

  bool webViewSemanticsExcluded(WidgetTester tester) => tester
      .widget<ExcludeSemantics>(
        find
            .ancestor(
              of: find.byType(WebViewWidget),
              matching: find.byType(ExcludeSemantics),
            )
            .first,
      )
      .excluding;

  testWidgets('routes through the forward and fails closed when it drops', (
    tester,
  ) async {
    mockProxyChannel();
    final source = _RouteSource(
      const SocksForwardRoute(connectionId: 1, port: 41080),
    );
    await pumpBrowser(tester, source);

    // The proxy is in place before any web view exists.
    expect(_events, ['apply:41080', 'webview']);
    expect(find.text('browse via Office'), findsOneWidget);
    expect(find.byTooltip('Open in system browser'), findsNothing);
    expect(find.byTooltip('Routed through Office'), findsOneWidget);

    await openAddress(tester, '10.0.0.5:8080');
    final page = Uri.parse('http://10.0.0.5:8080');
    expect(platform.controllers.single.requests, [page]);
    expect(find.text('browse via Office'), findsNothing);
    expect(webViewSemanticsExcluded(tester), isFalse);
    // Redirects to other internal hosts keep loading through the proxy.
    expect(
      await navigate('http://sso.internal/login'),
      NavigationDecision.navigate,
    );

    _events.clear();
    source.route = null;
    await tester.pump();
    await tester.pump();
    expect(find.text('tunnel down'), findsOneWidget);
    expect(find.text('Restart forward'), findsOneWidget);
    // The page is stopped and the proxy moved off the freed port; nothing
    // clears it, which would let requests go direct.
    expect(_events, ['load:about:blank', 'apply:$_sinkPort']);
    expect(
      await navigate('http://sso.internal/login'),
      NavigationDecision.prevent,
    );
    expect(await navigate('https://example.com/'), NavigationDecision.prevent);
    expect(webViewSemanticsExcluded(tester), isTrue);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      page.toString(),
    );

    _events.clear();
    source.route = const SocksForwardRoute(connectionId: 2, port: 41090);
    await tester.pump();
    await tester.pump();
    expect(_events, ['apply:41090', 'load:$page']);
    expect(find.text('tunnel down'), findsNothing);
    expect(platform.controllers.single.reloads, 0);

    _events.clear();
    await closeBrowser(tester);
    // The page goes blank before the proxy moves to the sink; the forward was
    // already running, so it stays up.
    expect(_events, ['load:about:blank', 'apply:$_sinkPort']);
  });

  testWidgets('a forward that drops while the proxy is applied ends down', (
    tester,
  ) async {
    final gate = Completer<void>();
    mockProxyChannel(applyGate: (port) => port == 41090 ? gate : null);
    final source = _RouteSource(
      const SocksForwardRoute(connectionId: 1, port: 41080),
    );
    await pumpBrowser(tester, source);
    await openAddress(tester, '10.0.0.5:8080');

    // The move to a new port is held in flight while the forward drops.
    source.route = const SocksForwardRoute(connectionId: 2, port: 41090);
    await tester.pump();
    await tester.pump();
    expect(_events.last, 'apply:41090');
    expect(find.text('starting tunnel'), findsOneWidget);
    expect(find.text('Close browser'), findsOneWidget);

    source.route = null;
    gate.complete();
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(find.text('starting tunnel'), findsNothing);
    expect(find.text('tunnel down'), findsOneWidget);
    expect(find.text('Restart forward'), findsOneWidget);
    await closeBrowser(tester);
  });

  testWidgets('starts a stopped forward, and stops it again on close', (
    tester,
  ) async {
    mockProxyChannel();
    final source = _RouteSource(null)
      ..restartError = 'Connect to the host to start this forward.';
    await pumpBrowser(tester, source);

    expect(source.restarts, 1);
    expect(find.text('tunnel down'), findsOneWidget);
    expect(
      find.text('Connect to the host to start this forward.'),
      findsOneWidget,
    );
    expect(platform.controllers, isEmpty);

    source.onRestart = () =>
        const SocksForwardRoute(connectionId: 1, port: 41080);
    await tester.tap(find.text('Restart forward'));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(source.restarts, 2);
    expect(_events, ['apply:41080', 'webview']);
    expect(find.text('browse via Office'), findsOneWidget);

    _events.clear();
    await closeBrowser(tester);
    // Only once the proxy points at the sink does the forward free its port.
    expect(_events, ['apply:$_sinkPort', 'stop-forward']);
  });

  testWidgets('restarts a listener lost while the app was suspended', (
    tester,
  ) async {
    mockProxyChannel();
    final source =
        _RouteSource(const SocksForwardRoute(connectionId: 1, port: 41080))
          ..probeResult = false
          ..onRestart = () =>
              const SocksForwardRoute(connectionId: 1, port: 41095);
    await pumpBrowser(tester, source);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(source.restarts, 1);
    expect(_events.last, 'apply:41095');
    expect(find.text('browse via Office'), findsOneWidget);
    await closeBrowser(tester);
  });

  testWidgets('blocks links that hand pages to other apps', (tester) async {
    mockProxyChannel();
    final source = _RouteSource(
      const SocksForwardRoute(connectionId: 1, port: 41080),
    );
    await pumpBrowser(tester, source);
    await openAddress(tester, '10.0.0.5:8080');

    for (final link in [
      'x-safari-https://grafana.internal/',
      'googlechrome://navigate?url=grafana.internal',
      'ftp://files.internal/',
      'mailto:ops@example.com',
    ]) {
      expect(await navigate(link), NavigationDecision.prevent, reason: link);
    }
    await tester.pump();
    expect(
      find.text('Links to other apps are blocked in a SOCKS browser.'),
      findsWidgets,
    );
    await closeBrowser(tester);
  });

  test('defaults internal-looking addresses to plain HTTP', () {
    for (final (address, internal) in [
      ('10.0.0.5', true),
      ('grafana', true),
      ('dash.corp:3000', true),
      ('[fd00::5]', true),
      ('example.com', false),
      ('docs.internal.example', false),
    ]) {
      expect(
        isLikelyInternalBrowserAddress(Uri.parse('//$address')),
        internal,
        reason: address,
      );
    }
  });

  testWidgets('explains why SOCKS browsing is unavailable', (tester) async {
    mockProxyChannel(supported: false);
    final source = _RouteSource(
      const SocksForwardRoute(connectionId: 1, port: 41080),
    );
    await pumpBrowser(tester, source);

    expect(find.text('socks browsing unavailable'), findsOneWidget);
    expect(
      find.text('In-app browsing through SOCKS needs iOS 17 or later.'),
      findsOneWidget,
    );
    expect(_events, isEmpty);
    expect(find.text('Close browser'), findsOneWidget);
  });

  testWidgets('a loopback browser will not load past a stuck proxy', (
    tester,
  ) async {
    mockProxyChannel(clearFails: true);
    await pumpScreen(
      tester,
      PortForwardBrowserScreen(
        initialTabs: [
          PortForwardBrowserInitialTab(uri: Uri.parse('http://localhost:8080')),
        ],
      ),
    );

    expect(_events, ['clear']);
    expect(find.text('browser proxy stuck'), findsOneWidget);
    expect(platform.controllers, isEmpty);
  });
}
