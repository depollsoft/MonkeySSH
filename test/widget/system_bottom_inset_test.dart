import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:monkeyssh/presentation/controllers/system_keyboard_visibility_controller.dart';
import 'package:monkeyssh/presentation/widgets/system_bottom_inset.dart';

import '../helpers/keyboard_visibility_channel.dart';

SystemKeyboardVisibilityController _keyboard({required bool? visible}) {
  final keyboard = SystemKeyboardVisibilityController.instance
    ..debugSetVisible(visible: visible);
  addTearDown(() => keyboard.debugSetVisible(visible: null));
  return keyboard;
}

Widget _guarded(
  ValueListenable<double> inset,
  ValueSetter<MediaQueryData> on,
) => ValueListenableBuilder<double>(
  valueListenable: inset,
  builder: (context, bottom, _) => MediaQuery(
    data: MediaQueryData(
      padding: EdgeInsets.fromLTRB(4, 0, 6, bottom > 0 ? 0 : 34),
      viewPadding: const EdgeInsets.fromLTRB(4, 44, 6, 34),
      viewInsets: EdgeInsets.fromLTRB(1, 2, 3, bottom),
    ),
    child: PlatformKeyboardInsetMediaQuery(
      child: Builder(
        builder: (context) {
          on(MediaQuery.of(context));
          return const SizedBox();
        },
      ),
    ),
  ),
);

void main() {
  group('PlatformKeyboardInsetMediaQuery', () {
    testWidgets('drops a settled stale inset and restores bottom padding', (
      tester,
    ) async {
      final calls = mockKeyboardVisibilityChannel(tester);
      final keyboard = _keyboard(visible: true);
      final inset = ValueNotifier<double>(300);
      addTearDown(inset.dispose);
      late MediaQueryData resolved;
      await tester.pumpWidget(_guarded(inset, (data) => resolved = data));
      expect(resolved.viewInsets.bottom, 300);

      // The platform reports the IME hidden, but the inset never moves.
      keyboard.debugSetVisible(visible: false);
      await tester.pump();
      expect(resolved.viewInsets.bottom, 300);
      await tester.pump(
        staleKeyboardInsetDelay - const Duration(milliseconds: 1),
      );
      expect(resolved.viewInsets.bottom, 300);
      expect(calls, isNot(contains('refreshInsets')));

      await tester.pump(const Duration(milliseconds: 1));
      expect(resolved.viewInsets, const EdgeInsets.fromLTRB(1, 2, 3, 0));
      expect(resolved.padding, const EdgeInsets.fromLTRB(4, 0, 6, 34));
      expect(resolved.viewPadding, const EdgeInsets.fromLTRB(4, 44, 6, 34));
      // The platform is asked to replace the stale geometry at its source.
      expect(calls.where((method) => method == 'refreshInsets'), hasLength(1));

      keyboard.debugSetVisible(visible: true);
      await tester.pump();
      expect(resolved.viewInsets.bottom, 300);
      expect(resolved.padding.bottom, 0);
    });

    testWidgets('lets an ordinary keyboard dismissal animate to zero', (
      tester,
    ) async {
      final calls = mockKeyboardVisibilityChannel(tester);
      final keyboard = _keyboard(visible: true);
      final inset = ValueNotifier<double>(300);
      addTearDown(inset.dispose);
      late MediaQueryData resolved;
      await tester.pumpWidget(_guarded(inset, (data) => resolved = data));

      keyboard.debugSetVisible(visible: false);
      // A hide animation that takes longer than the settle delay overall
      // keeps every frame, because each new inset restarts the wait.
      for (final bottom in <double>[240, 180, 120, 60]) {
        inset.value = bottom;
        await tester.pump();
        expect(resolved.viewInsets.bottom, bottom);
        await tester.pump(const Duration(milliseconds: 300));
        expect(resolved.viewInsets.bottom, bottom);
      }
      inset.value = 0;
      await tester.pump();
      await tester.pump(staleKeyboardInsetDelay * 2);
      expect(resolved.viewInsets.bottom, 0);
      expect(resolved.padding.bottom, 34);
      expect(calls, isNot(contains('refreshInsets')));
    });

    testWidgets('leaves geometry alone until the platform reports', (
      tester,
    ) async {
      final calls = mockKeyboardVisibilityChannel(tester);
      _keyboard(visible: null);
      final inset = ValueNotifier<double>(300);
      addTearDown(inset.dispose);
      late MediaQueryData resolved;
      await tester.pumpWidget(_guarded(inset, (data) => resolved = data));

      await tester.pump(staleKeyboardInsetDelay * 4);
      expect(resolved.viewInsets.bottom, 300);
      expect(calls, isNot(contains('refreshInsets')));
    });

    testWidgets('waits for the live platform answer before dropping', (
      tester,
    ) async {
      // A missed show event leaves the cached state hidden while the IME is
      // up, and the platform answers the live query only after the delay.
      final answer = Completer<bool?>();
      final calls = mockKeyboardVisibilityChannel(
        tester,
        live: () => answer.future,
      );
      final keyboard = _keyboard(visible: false);
      final inset = ValueNotifier<double>(300);
      addTearDown(inset.dispose);
      late MediaQueryData resolved;
      await tester.pumpWidget(_guarded(inset, (data) => resolved = data));

      await tester.pump(staleKeyboardInsetDelay * 2);
      expect(calls, contains('getVisibility'));
      expect(resolved.viewInsets.bottom, 300);

      answer.complete(true);
      await tester.pump();
      expect(keyboard.visible, isTrue);
      expect(resolved.viewInsets.bottom, 300);
      expect(calls, isNot(contains('refreshInsets')));
    });

    testWidgets('keeps the inset when the live query fails', (tester) async {
      final calls = mockKeyboardVisibilityChannel(
        tester,
        live: () => throw PlatformException(code: 'unavailable'),
      );
      _keyboard(visible: false);
      final inset = ValueNotifier<double>(300);
      addTearDown(inset.dispose);
      late MediaQueryData resolved;
      await tester.pumpWidget(_guarded(inset, (data) => resolved = data));

      await tester.pump(staleKeyboardInsetDelay * 4);
      expect(calls, contains('getVisibility'));
      expect(resolved.viewInsets.bottom, 300);
      expect(calls, isNot(contains('refreshInsets')));
    });

    testWidgets('corrects every route below the app navigator', (tester) async {
      mockKeyboardVisibilityChannel(tester);
      tester.view
        ..physicalSize = const Size(390, 844)
        ..devicePixelRatio = 1
        ..viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(
        () => tester.view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio()
          ..resetViewInsets(),
      );
      // The keyboard closed on a previous route, leaving its inset behind.
      _keyboard(visible: false);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const Scaffold(body: SizedBox()),
          ),
          GoRoute(
            path: '/settings',
            builder: (context, state) => Scaffold(
              appBar: AppBar(title: const Text('Settings')),
              body: SizedBox.expand(
                key: const Key('settings'),
                child: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (context) => Scaffold(
                          appBar: AppBar(title: const Text('Agents')),
                          body: const SizedBox.expand(key: Key('agents')),
                        ),
                      ),
                    ),
                    child: const Text('Open agents'),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          builder: (context, child) =>
              PlatformKeyboardInsetMediaQuery(child: child!),
        ),
      );
      await tester.pump(staleKeyboardInsetDelay);

      router.go('/settings');
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const Key('settings'))).height,
        844 - kToolbarHeight,
      );

      await tester.tap(find.text('Open agents'));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const Key('agents'))).height,
        844 - kToolbarHeight,
      );
    });
  });

  group('resolveSystemBottomInset', () {
    test('reserves the navigation bar while no keyboard inset applies', () {
      const mediaQuery = MediaQueryData(
        padding: EdgeInsets.only(bottom: 34),
        viewPadding: EdgeInsets.only(bottom: 34),
      );

      expect(resolveSystemBottomInset(mediaQuery), 34);
    });

    test('reserves nothing once the layout is lifted above the keyboard', () {
      // Scaffold strips the bottom view inset from a body it resized, and the
      // keyboard already covers the navigation bar.
      const mediaQuery = MediaQueryData(
        viewPadding: EdgeInsets.only(bottom: 34),
      );

      expect(resolveSystemBottomInset(mediaQuery), 0);
    });

    test('reserves the navigation bar for an unlifted bottom inset', () {
      // The inset survived into this subtree, so nothing lifted the layout for
      // it: the navigation bar is still on screen even though padding.bottom
      // has been zeroed out by the (stale) keyboard inset.
      const mediaQuery = MediaQueryData(
        viewPadding: EdgeInsets.only(bottom: 34),
        viewInsets: EdgeInsets.only(bottom: 320),
      );

      expect(resolveSystemBottomInset(mediaQuery), 34);
    });

    test('reserves nothing when there is no bottom system bar', () {
      expect(
        resolveSystemBottomInset(
          const MediaQueryData(viewInsets: EdgeInsets.only(bottom: 320)),
        ),
        0,
      );
      expect(resolveSystemBottomInset(const MediaQueryData()), 0);
    });
  });

  group('removeSystemBottomInset', () {
    test('drops the bottom inset while keeping the keyboard inset', () {
      const mediaQuery = MediaQueryData(
        padding: EdgeInsets.fromLTRB(0, 44, 0, 34),
        viewPadding: EdgeInsets.fromLTRB(0, 44, 0, 34),
        viewInsets: EdgeInsets.only(bottom: 320),
      );

      final stripped = removeSystemBottomInset(mediaQuery);

      expect(resolveSystemBottomInset(stripped), 0);
      expect(stripped.padding.top, 44);
      expect(stripped.viewPadding.top, 44);
      expect(stripped.viewInsets.bottom, 320);
    });
  });
}
