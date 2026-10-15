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

/// A web view with a minimal history: loads push, goBack steps back.
class _Controller extends Fake
    with MockPlatformInterfaceMixin
    implements PlatformWebViewController {
  final requests = <Uri>[];
  final history = <Uri>[];
  int index = -1;
  int reloads = 0;

  /// Holds the first platform setup call, to model a slow first load.
  Completer<void>? setupGate;

  @override
  Future<void> enableZoom(bool enabled) async => setupGate?.future;

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    _events.add('load:${params.uri}');
    requests.add(params.uri);
    history
      ..removeRange(index + 1, history.length)
      ..add(params.uri);
    index = history.length - 1;
  }

  @override
  Future<void> reload() async {
    reloads++;
  }

  @override
  Future<bool> canGoBack() async => index > 0;

  @override
  Future<bool> canGoForward() async => index < history.length - 1;

  @override
  Future<void> goBack() async {
    _events.add('back');
    if (index > 0) index--;
  }

  @override
  Future<String?> getTitle() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _NavigationDelegate extends Fake
    with MockPlatformInterfaceMixin
    implements PlatformNavigationDelegate {
  NavigationRequestCallback? onNavigationRequest;
  PageEventCallback? onPageStarted;
  UrlChangeCallback? onUrlChange;

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {
    this.onNavigationRequest = onNavigationRequest;
  }

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {
    this.onPageStarted = onPageStarted;
  }

  @override
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) async {
    this.onUrlChange = onUrlChange;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _WebViewWidget extends PlatformWebViewWidget {
  _WebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

/// Like the real source, it stops tracking the route once disposed.
class _RouteSource extends ChangeNotifier implements SocksForwardRouteSource {
  _RouteSource(this._route);

  SocksForwardRoute? _route;
  int restarts = 0;
  bool probeResult = true;

  /// Whether a restart of a stopped forward starts it, rather than finding it
  /// started elsewhere (an auto-start rule, another browser).
  bool startsForward = true;
  SocksForwardRoute? Function()? onRestart;
  String? restartError;
  Completer<void>? restartGate;
  bool disposed = false;

  @override
  SocksForwardRoute? get route => _route;

  set route(SocksForwardRoute? value) {
    if (disposed) return;
    _route = value;
    notifyListeners();
  }

  @override
  void refresh() {}

  @override
  Future<SocksForwardStartResult> restart() async {
    restarts++;
    final wasStopped = _route == null;
    await restartGate?.future;
    final next = onRestart?.call();
    if (next != null) {
      route = next;
      return SocksForwardStartResult.running(
        next,
        startedOnConnectionId: wasStopped && startsForward
            ? next.connectionId
            : null,
      );
    }
    return SocksForwardStartResult.failed(restartError ?? 'failed');
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }

  @override
  Future<bool> probe() async => probeResult;

  @override
  Future<void> stopForward(Set<int> connectionIds) async {
    _events.add('stop-forward:${(connectionIds.toList()..sort()).join(',')}');
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
    bool Function(int port)? applyFails,
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
                if (applyFails?.call(port) ?? false) {
                  throw PlatformException(code: 'apply_failed');
                }
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

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
  }

  /// Shows a SOCKS browser for each name in [visible], stacked; a browser
  /// dropped from it is disposed, as when its route pops. Each new browser
  /// takes the next of [sources].
  Future<void> pumpBrowsers(
    WidgetTester tester,
    ValueNotifier<List<String>> visible,
    List<_RouteSource> sources,
  ) async {
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
          socksForwardRouteSourceFactoryProvider.overrideWithValue(
            (_) => sources.removeAt(0),
          ),
        ],
        child: MaterialApp(
          home: ValueListenableBuilder<List<String>>(
            valueListenable: visible,
            builder: (context, names, _) => Stack(
              children: [
                for (final name in names)
                  Positioned.fill(
                    key: ValueKey(name),
                    child: PortForwardBrowserScreen.socks(
                      socksForward: _forward,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await settle(tester);
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
    // The page comes back by stepping off the blank entry, so Back never
    // lands on it.
    expect(_events, ['apply:41090', 'back']);
    expect(find.text('tunnel down'), findsNothing);
    expect(platform.controllers.single.reloads, 0);
    final controller = platform.controllers.single;
    expect(controller.history[controller.index], page);

    _events.clear();
    await closeBrowser(tester);
    // The page goes blank before the proxy moves to the sink; the forward was
    // already running, so it stays up.
    expect(_events, ['load:about:blank', 'apply:$_sinkPort']);
  });

  testWidgets('history skips the blank placeholder a drop left behind', (
    tester,
  ) async {
    mockProxyChannel();
    final source = _RouteSource(
      const SocksForwardRoute(connectionId: 1, port: 41080),
    );
    await pumpBrowser(tester, source);
    await openAddress(tester, '10.0.0.5:8080');
    final page = Uri.parse('http://10.0.0.5:8080');
    final controller = platform.controllers.single;
    final delegate = platform.delegates.single;

    source.route = null;
    await tester.pump();
    source.route = const SocksForwardRoute(connectionId: 1, port: 41090);
    await tester.pump();
    await tester.pump();
    delegate.onPageStarted!(page.toString());
    delegate.onUrlChange!(UrlChange(url: page.toString()));
    await tester.pump();
    await tester.pump();
    // The blank entry sits ahead of the page, so Forward stays off.
    expect(controller.history, [page, Uri.parse('about:blank')]);
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byIcon(Icons.arrow_forward),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNull,
    );

    // Reaching it anyway (a swipe) steps straight back to the page.
    _events.clear();
    delegate.onUrlChange!(const UrlChange(url: 'about:blank'));
    await tester.pump();
    expect(_events, ['back']);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      page.toString(),
    );
    await closeBrowser(tester);
  });

  testWidgets('a restore that lands elsewhere loads the dropped page', (
    tester,
  ) async {
    mockProxyChannel();
    final source = _RouteSource(
      const SocksForwardRoute(connectionId: 1, port: 41080),
    );
    await pumpBrowser(tester, source);
    await openAddress(tester, '10.0.0.5:8080');
    // A link to a second page starts, and the forward drops before it commits.
    final second = Uri.parse('http://10.0.0.6:9090');
    platform.delegates.single.onPageStarted!(second.toString());
    await tester.pump();

    source.route = null;
    await tester.pump();
    source.route = const SocksForwardRoute(connectionId: 1, port: 41090);
    await tester.pump();
    await tester.pump();
    expect(_events.last, 'back');
    _events.clear();
    // Going back reached the first page instead.
    platform.delegates.single.onPageStarted!('http://10.0.0.5:8080');
    await tester.pump();
    expect(_events, ['load:$second']);
    await closeBrowser(tester);
  });

  testWidgets('a first load still being set up does not outlive a drop', (
    tester,
  ) async {
    mockProxyChannel();
    final source = _RouteSource(
      const SocksForwardRoute(connectionId: 1, port: 41080),
    );
    await pumpBrowser(tester, source);
    final controller = platform.controllers.single
      ..setupGate = Completer<void>();

    await openAddress(tester, '10.0.0.5:8080');
    source.route = null;
    await tester.pump();
    controller.setupGate!.complete();
    await tester.pump();
    await tester.pump();

    expect(find.text('tunnel down'), findsOneWidget);
    expect(controller.requests, [Uri.parse('about:blank')]);
    await closeBrowser(tester);
  });

  testWidgets('a first load still being set up does not outlive a close', (
    tester,
  ) async {
    mockProxyChannel();
    final source = _RouteSource(
      const SocksForwardRoute(connectionId: 1, port: 41080),
    );
    await pumpBrowser(tester, source);
    final controller = platform.controllers.single
      ..setupGate = Completer<void>();

    await openAddress(tester, '10.0.0.5:8080');
    await closeBrowser(tester);
    controller.setupGate!.complete();
    await tester.pump();

    expect(controller.requests, [Uri.parse('about:blank')]);
  });

  testWidgets('closing while the forward starts stops it once it is up', (
    tester,
  ) async {
    mockProxyChannel();
    final gate = Completer<void>();
    final source = _RouteSource(null)
      ..restartGate = gate
      ..onRestart = () => const SocksForwardRoute(connectionId: 1, port: 41080);
    await pumpBrowser(tester, source);
    expect(find.text('starting tunnel'), findsOneWidget);

    await tester.tap(find.text('Close browser'));
    await tester.pump();
    await closeBrowser(tester);
    expect(source.disposed, isTrue);
    expect(_events, isNot(contains(startsWith('stop-forward'))));

    // The start completes after the browser and its source are gone.
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(source.route, isNull);
    expect(_events, contains('stop-forward:1'));
  });

  testWidgets('closing one of two browsers leaves the other its forward', (
    tester,
  ) async {
    mockProxyChannel();
    const route = SocksForwardRoute(connectionId: 1, port: 41080);
    final visible = ValueNotifier(['first']);
    addTearDown(visible.dispose);
    await pumpBrowsers(tester, visible, [
      _RouteSource(null)..onRestart = () => route,
      _RouteSource(route),
    ]);
    // The first browser started the forward.
    expect(_events, ['apply:41080', 'webview']);

    // The rule is browsed again while the first browser's route is still
    // popping, so both are mounted for a moment.
    visible.value = ['first', 'second'];
    await settle(tester);
    visible.value = ['second'];
    await settle(tester);
    expect(_events, isNot(contains(startsWith('stop-forward'))));
    expect(find.text('browse via Office'), findsOneWidget);

    _events.clear();
    visible.value = [];
    await settle(tester);
    // The last browser out stops the forward a browser started.
    expect(_events, ['apply:$_sinkPort', 'stop-forward:1']);
  });

  testWidgets('a start finishing after its browser closed spares a new one', (
    tester,
  ) async {
    mockProxyChannel();
    const route = SocksForwardRoute(connectionId: 1, port: 41080);
    final gate = Completer<void>();
    final visible = ValueNotifier(['closing']);
    addTearDown(visible.dispose);
    await pumpBrowsers(tester, visible, [
      _RouteSource(null)
        ..restartGate = gate
        ..onRestart = () => route,
      _RouteSource(route),
    ]);
    expect(find.text('starting tunnel'), findsOneWidget);

    visible.value = [];
    await settle(tester);
    // Reopened before the first start finished; it finds the forward up.
    visible.value = ['reopened'];
    await settle(tester);
    expect(find.text('browse via Office'), findsOneWidget);

    gate.complete();
    await settle(tester);
    expect(_events, isNot(contains(startsWith('stop-forward'))));

    _events.clear();
    visible.value = [];
    await settle(tester);
    expect(_events, ['apply:$_sinkPort', 'stop-forward:1']);
  });

  testWidgets('leaves running a forward it found started elsewhere', (
    tester,
  ) async {
    mockProxyChannel();
    // Stopped when the browser opens; by the time its start runs, an
    // auto-start rule has brought it up on the session.
    final source = _RouteSource(null)
      ..startsForward = false
      ..onRestart = () => const SocksForwardRoute(connectionId: 1, port: 41080);
    await pumpBrowser(tester, source);
    expect(find.text('browse via Office'), findsOneWidget);

    _events.clear();
    await closeBrowser(tester);
    expect(_events, ['apply:$_sinkPort']);
  });

  testWidgets('retries the sink when a drop could not move the proxy', (
    tester,
  ) async {
    var sinkFailures = 2;
    mockProxyChannel(
      applyFails: (port) => port == _sinkPort && sinkFailures-- > 0,
    );
    final source = _RouteSource(
      const SocksForwardRoute(connectionId: 1, port: 41080),
    );
    await pumpBrowser(tester, source);
    await openAddress(tester, '10.0.0.5:8080');

    _events.clear();
    source.route = null;
    await settle(tester);
    expect(_events, ['load:about:blank', 'apply:$_sinkPort']);
    expect(find.text('tunnel down'), findsOneWidget);
    final stuck = find.textContaining('Couldn’t move the browser’s proxy');
    expect(stuck, findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(_events, hasLength(3));
    expect(stuck, findsOneWidget);
    // Backs off: the next attempt waits twice as long.
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    expect(_events, [
      'load:about:blank',
      'apply:$_sinkPort',
      'apply:$_sinkPort',
      'apply:$_sinkPort',
    ]);
    expect(stuck, findsNothing);
    expect(find.text('tunnel down'), findsOneWidget);

    await tester.pump(const Duration(seconds: 30));
    expect(_events, hasLength(4));
    await closeBrowser(tester);
  });

  testWidgets('a forward coming back ends the sink retries', (tester) async {
    mockProxyChannel(applyFails: (port) => port == _sinkPort);
    final source = _RouteSource(
      const SocksForwardRoute(connectionId: 1, port: 41080),
    );
    await pumpBrowser(tester, source);
    await openAddress(tester, '10.0.0.5:8080');
    source.route = null;
    await settle(tester);
    expect(
      find.textContaining('Couldn’t move the browser’s proxy'),
      findsOneWidget,
    );

    _events.clear();
    source.route = const SocksForwardRoute(connectionId: 2, port: 41090);
    await settle(tester);
    expect(_events, ['apply:41090', 'back']);
    expect(find.text('tunnel down'), findsNothing);

    // No late retry moves the live proxy to the sink.
    await tester.pump(const Duration(minutes: 1));
    expect(_events, ['apply:41090', 'back']);
    await closeBrowser(tester);
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
    expect(_events, ['apply:$_sinkPort', 'stop-forward:1']);
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
      // Reserved and private suffixes never resolve publicly.
      ('nas.local', true),
      ('grafana.lan', true),
      ('app.internal', true),
      ('router.home.arpa', true),
      ('dev.localhost', true),
      ('NAS.Local', true),
      ('mylocal.com', false),
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

  testWidgets('the start page gives the address field the toolbar', (
    tester,
  ) async {
    mockProxyChannel();
    final source = _RouteSource(
      const SocksForwardRoute(connectionId: 1, port: 41080),
    );
    await pumpBrowser(tester, source);

    // Nothing to go back, forward or reload to before the first page.
    for (final tooltip in ['Back', 'Forward', 'Reload']) {
      expect(find.byTooltip(tooltip), findsNothing, reason: tooltip);
    }
    expect(find.text('Enter an address'), findsOneWidget);
    expect(find.byTooltip('Routed through Office'), findsOneWidget);

    await openAddress(tester, '10.0.0.5:8080');
    // A focused address field takes the whole row; leave it.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    for (final tooltip in ['Back', 'Forward', 'Reload']) {
      expect(find.byTooltip(tooltip), findsOneWidget, reason: tooltip);
    }

    await tester.tap(find.byTooltip('Routed through Office'));
    await tester.pump();
    expect(find.text('Pages load through Office on Dev box.'), findsOneWidget);
    await closeBrowser(tester);
  });

  testWidgets('a loopback browser says to close a SOCKS browser holding it', (
    tester,
  ) async {
    mockProxyChannel();
    final proxy = SocksBrowserProxyService(
      platform: TargetPlatform.iOS,
      sinkPort: () async => _sinkPort,
    );
    await proxy.hold(41080);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsServiceProvider.overrideWithValue(settings),
          activeSessionsProvider.overrideWith(_NoSessions.new),
          socksBrowserProxyServiceProvider.overrideWithValue(proxy),
        ],
        child: MaterialApp(
          home: PortForwardBrowserScreen(
            initialTabs: [
              PortForwardBrowserInitialTab(
                uri: Uri.parse('http://localhost:8080'),
              ),
            ],
          ),
        ),
      ),
    );
    await settle(tester);

    expect(find.text('browser proxy stuck'), findsOneWidget);
    expect(
      find.textContaining('Close the SOCKS browser first.'),
      findsOneWidget,
    );
    expect(platform.controllers, isEmpty);
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
