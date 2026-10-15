// ignore_for_file: public_member_api_docs, depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/services/app_permission_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
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
  void Function(PlatformWebViewPermissionRequest request)? onPermissionRequest;

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    requests.add(params.uri);
  }

  @override
  Future<void> setOnPlatformPermissionRequest(
    void Function(PlatformWebViewPermissionRequest request) onPermissionRequest,
  ) async {
    this.onPermissionRequest = onPermissionRequest;
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

/// A page asking for camera and/or microphone access.
class _PagePermissionRequest extends PlatformWebViewPermissionRequest {
  _PagePermissionRequest(Set<WebViewPermissionResourceType> types)
    : super(types: types);

  /// Every grant (true) or deny (false), in order.
  final answers = <bool>[];

  bool? get granted => answers.isEmpty ? null : answers.single;

  @override
  Future<void> grant() async => answers.add(true);

  @override
  Future<void> deny() async => answers.add(false);
}

/// Answers each permission from [statuses] and records what was asked.
class _FakeAppPermissionService extends AppPermissionService {
  _FakeAppPermissionService(this.statuses);

  final Map<AppPermission, AppPermissionStatus> statuses;
  final requested = <AppPermission>[];

  @override
  Future<AppPermissionStatus> request(AppPermission permission) async {
    requested.add(permission);
    return statuses[permission] ?? AppPermissionStatus.denied;
  }
}

class _WebViewWidget extends PlatformWebViewWidget {
  _WebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

Future<_WebViewPlatform> _pumpBrowser(
  WidgetTester tester,
  List<PortForwardBrowserInitialTab> tabs, {
  AppPermissionService? permissions,
}) async {
  FluttyTheme.debugUseSystemFonts = true;
  addTearDown(() => FluttyTheme.debugUseSystemFonts = false);
  final previousPlatform = WebViewPlatform.instance;
  final platform = _WebViewPlatform();
  WebViewPlatform.instance = platform;
  addTearDown(() {
    if (previousPlatform != null) {
      WebViewPlatform.instance = previousPlatform;
    }
  });
  final settings = _Settings();
  when(
    () => settings.getBool(
      SettingKeys.portForwardBrowserCookieIsolationMigration,
    ),
  ).thenAnswer((_) async => true);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsServiceProvider.overrideWithValue(settings),
        if (permissions != null)
          appPermissionServiceProvider.overrideWithValue(permissions),
      ],
      child: MaterialApp(home: PortForwardBrowserScreen(initialTabs: tabs)),
    ),
  );
  await tester.pump();
  await tester.pump();
  return platform;
}

void main() {
  testWidgets('closing the selected tab loads its unvisited replacement', (
    tester,
  ) async {
    final first = Uri.parse('http://localhost:8080');
    final second = Uri.parse('http://localhost:8081');
    final platform = await _pumpBrowser(tester, [
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

  group('page camera and microphone requests', () {
    const both = {
      WebViewPermissionResourceType.camera,
      WebViewPermissionResourceType.microphone,
    };

    Future<_PagePermissionRequest> askFromPage(
      WidgetTester tester,
      _WebViewPlatform platform, {
      required String answer,
    }) async {
      final request = _PagePermissionRequest(both);
      platform.controllers.single.onPermissionRequest!(request);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Allow camera and microphone?'), findsOneWidget);
      await tester.tap(find.text(answer));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      return request;
    }

    final tab = PortForwardBrowserInitialTab(
      uri: Uri.parse('http://localhost:8080'),
      title: 'Camera page',
    );

    testWidgets('grants the page once the app holds both permissions', (
      tester,
    ) async {
      final permissions = _FakeAppPermissionService({
        AppPermission.camera: AppPermissionStatus.granted,
        AppPermission.microphone: AppPermissionStatus.granted,
      });
      final platform = await _pumpBrowser(tester, [
        tab,
      ], permissions: permissions);

      final request = await askFromPage(tester, platform, answer: 'Allow');

      expect(permissions.requested, [
        AppPermission.camera,
        AppPermission.microphone,
      ]);
      expect(request.granted, isTrue);
    });

    testWidgets('denies the page when the app was refused the microphone', (
      tester,
    ) async {
      final permissions = _FakeAppPermissionService({
        AppPermission.camera: AppPermissionStatus.granted,
        AppPermission.microphone: AppPermissionStatus.permanentlyDenied,
      });
      final platform = await _pumpBrowser(tester, [
        tab,
      ], permissions: permissions);

      final request = await askFromPage(tester, platform, answer: 'Allow');

      expect(permissions.requested, [
        AppPermission.camera,
        AppPermission.microphone,
      ]);
      expect(request.granted, isFalse);
      expect(
        find.text('Camera and microphone access was denied.'),
        findsOneWidget,
      );
    });

    testWidgets('asks the OS nothing when the user declines the page', (
      tester,
    ) async {
      final permissions = _FakeAppPermissionService(const {});
      final platform = await _pumpBrowser(tester, [
        tab,
      ], permissions: permissions);

      final request = await askFromPage(tester, platform, answer: 'Not now');

      expect(permissions.requested, isEmpty);
      expect(request.granted, isFalse);
    });
  });
}
