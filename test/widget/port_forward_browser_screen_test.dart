// ignore_for_file: public_member_api_docs, depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/socks_browser_proxy_service.dart';
import 'package:monkeyssh/presentation/screens/port_forward_browser_screen.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class _Settings extends Mock implements SettingsService {}

class _WebViewPlatform extends WebViewPlatform {
  final controllers = <_Controller>[];

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final controller = _Controller();
    controllers.add(controller);
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _NavigationDelegate();

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _WebViewWidget(params);
}

class _Controller extends Fake
    with MockPlatformInterfaceMixin
    implements PlatformWebViewController {
  final requests = <Uri>[];

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    requests.add(params.uri);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _NavigationDelegate extends Fake
    with MockPlatformInterfaceMixin
    implements PlatformNavigationDelegate {
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _WebViewWidget extends PlatformWebViewWidget {
  _WebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  late _WebViewPlatform platform;

  Future<void> pumpBrowser(
    WidgetTester tester,
    List<PortForwardBrowserInitialTab> tabs,
  ) async {
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
    // Opening a loopback browser first clears any SOCKS proxy left behind.
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          ..setMockMethodCallHandler(
            const MethodChannel(SocksBrowserProxyService.channelName),
            (_) async => null,
          );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel(SocksBrowserProxyService.channelName),
        null,
      ),
    );
    final settings = _Settings();
    when(
      () => settings.getBool(
        SettingKeys.portForwardBrowserCookieIsolationMigration,
      ),
    ).thenAnswer((_) async => true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsServiceProvider.overrideWithValue(settings)],
        child: MaterialApp(home: PortForwardBrowserScreen(initialTabs: tabs)),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('closing the selected tab loads its unvisited replacement', (
    tester,
  ) async {
    final first = Uri.parse('http://localhost:8080');
    final second = Uri.parse('http://localhost:8081');
    await pumpBrowser(tester, [
      PortForwardBrowserInitialTab(uri: first, title: 'First'),
      PortForwardBrowserInitialTab(uri: second, title: 'Second'),
    ]);
    expect(platform.controllers[0].requests, [first]);
    expect(platform.controllers[1].requests, isEmpty);

    final firstTab = find.widgetWithText(InputChip, 'First');
    await tester.tap(
      find.descendant(of: firstTab, matching: find.byTooltip('Delete')),
    );
    await tester.pump();
    await tester.pump();
    expect(platform.controllers[1].requests, [second]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one tap on the address field opens the keyboard', (
    tester,
  ) async {
    await pumpBrowser(tester, [
      PortForwardBrowserInitialTab(uri: Uri.parse('http://localhost:8080')),
    ]);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.pump();

    // Focus widens the field to the whole toolbar; the move must keep the
    // field's input connection, or the keyboard closes again at once.
    expect(find.byTooltip('Back'), findsNothing);
    expect(tester.testTextInput.hasAnyClients, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
  });
}
