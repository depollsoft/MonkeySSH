import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/controllers/system_keyboard_visibility_controller.dart';
import 'package:monkeyssh/presentation/widgets/system_bottom_inset.dart';

void main() {
  testWidgets('clearing a stale IME inset restores only bottom safe padding', (
    tester,
  ) async {
    final keyboard = SystemKeyboardVisibilityController.instance
      ..debugSetVisible(visible: true);
    addTearDown(() => keyboard.debugSetVisible(visible: null));
    late MediaQueryData resolved;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          padding: EdgeInsets.fromLTRB(4, 0, 6, 0),
          viewPadding: EdgeInsets.fromLTRB(4, 44, 6, 34),
          viewInsets: EdgeInsets.fromLTRB(1, 2, 3, 300),
        ),
        child: PlatformKeyboardInsetMediaQuery(
          child: Builder(
            builder: (context) {
              resolved = MediaQuery.of(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    expect(resolved.viewInsets.bottom, 300);
    expect(resolved.padding, const EdgeInsets.fromLTRB(4, 0, 6, 0));

    keyboard.debugSetVisible(visible: false);
    await tester.pump();
    expect(resolved.viewInsets, const EdgeInsets.fromLTRB(1, 2, 3, 0));
    expect(resolved.padding, const EdgeInsets.fromLTRB(4, 0, 6, 34));
    expect(resolved.viewPadding, const EdgeInsets.fromLTRB(4, 44, 6, 34));

    keyboard.debugSetVisible(visible: true);
    await tester.pump();
    expect(resolved.viewInsets.bottom, 300);
    expect(resolved.padding.bottom, 0);
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
