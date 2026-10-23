import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/system_vertical_bar.dart';

// iPhone Duo's outer display, as the iOS 27.1 simulator reports it: a vertical
// bar down the right edge whose item column starts below the status cluster
// and ends above the home indicator.
const _outerDisplay = Size(466, 678);
const _bar = SystemVerticalBar(
  edge: SystemVerticalBarEdge.right,
  itemColumn: Rect.fromLTRB(396, 174, 440, 644),
);
const _outerPadding = EdgeInsets.only(right: 84, bottom: 34);

void main() {
  void useOuterDisplay(WidgetTester tester) {
    tester.view
      ..physicalSize = _outerDisplay
      ..devicePixelRatio = 1
      ..padding = const FakeViewPadding(right: 84, bottom: 34)
      ..viewPadding = const FakeViewPadding(right: 84, bottom: 34);
    addTearDown(tester.view.reset);
  }

  // As in the app, the scope sits above the navigator, so pushed routes see
  // the bar too.
  Widget withBar(Widget child, {SystemVerticalBar? bar = _bar}) => MaterialApp(
    builder: (context, navigator) =>
        SystemVerticalBarScope(bar: bar, child: navigator!),
    home: child,
  );

  group('resolveVerticalBarColumn', () {
    const mediaQuery = MediaQueryData(
      size: _outerDisplay,
      padding: _outerPadding,
    );

    test('uses the item column while the keyboard is down', () {
      expect(resolveVerticalBarColumn(_bar, mediaQuery), _bar.itemColumn);
    });

    test('ends the column above the keyboard', () {
      final column = resolveVerticalBarColumn(
        _bar,
        mediaQuery.copyWith(viewInsets: const EdgeInsets.only(bottom: 265)),
      );
      expect(column.top, 174);
      expect(column.bottom, 678 - 265 - verticalBarKeyboardGap);
      expect(verticalBarItemCapacity(column), 4);
    });

    test('keeps the column under the keyboard for tab bars', () {
      expect(
        resolveVerticalBarColumn(
          _bar,
          mediaQuery.copyWith(viewInsets: const EdgeInsets.only(bottom: 265)),
          avoidsKeyboard: false,
        ),
        _bar.itemColumn,
      );
    });

    test('never inverts when the keyboard covers the whole column', () {
      final column = resolveVerticalBarColumn(
        _bar,
        mediaQuery.copyWith(viewInsets: const EdgeInsets.only(bottom: 600)),
      );
      expect(column.height, 0);
      expect(verticalBarItemCapacity(column), 0);
    });
  });

  group('VerticalBarRail', () {
    Widget rail({
      List<Widget> leading = const [],
      List<Widget> trailing = const [],
    }) => withBar(
      Builder(
        builder: (context) => Stack(
          children: [
            VerticalBarRail(bar: _bar, leading: leading, trailing: trailing),
          ],
        ),
      ),
    );

    IconButton key(String name) => IconButton(
      key: ValueKey(name),
      icon: const Icon(Icons.circle),
      onPressed: () {},
    );

    testWidgets('puts leading keys under the status cluster and trailing '
        'keys at the bottom, centred on the item column', (tester) async {
      useOuterDisplay(tester);
      await tester.pumpWidget(
        rail(leading: [key('back')], trailing: [key('files'), key('menu')]),
      );

      final back = tester.getRect(find.byKey(const ValueKey('back')));
      final files = tester.getRect(find.byKey(const ValueKey('files')));
      final menu = tester.getRect(find.byKey(const ValueKey('menu')));
      expect(back.top, 174);
      expect(back.center.dx, _bar.itemColumn.center.dx);
      expect(back.size, const Size.square(verticalBarItemExtent));
      expect(menu.bottom, 644);
      expect(files.bottom, menu.top - verticalBarItemGap);
      expect(menu.center.dx, _bar.itemColumn.center.dx);
    });

    testWidgets('leaves out the topmost trailing keys when short of room', (
      tester,
    ) async {
      useOuterDisplay(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 265);
      await tester.pumpWidget(
        rail(
          leading: [key('back')],
          trailing: [
            key('windows'),
            key('files'),
            key('keys'),
            key('menu'),
            key('keyboard'),
          ],
        ),
      );

      // Four keys fit above the keyboard: Back and the three nearest the
      // thumb.
      expect(
        tester.getRect(find.byKey(const ValueKey('keyboard'))).bottom,
        678 - 265 - verticalBarKeyboardGap,
      );
      for (final shown in ['back', 'keys', 'menu', 'keyboard']) {
        expect(
          tester.getRect(find.byKey(ValueKey(shown))).top,
          greaterThanOrEqualTo(174),
          reason: shown,
        );
      }
      for (final hidden in ['windows', 'files']) {
        expect(
          tester.getRect(find.byKey(ValueKey(hidden))).bottom,
          lessThan(0),
          reason: hidden,
        );
        await tester.tap(find.byKey(ValueKey(hidden)), warnIfMissed: false);
      }
    });
  });

  group('VerticalBarAppBar', () {
    Widget screen({SystemVerticalBar? bar = _bar, VoidCallback? onSave}) =>
        withBar(
          bar: bar,
          Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => Scaffold(
                    appBar: VerticalBarAppBar(
                      AppBar(
                        title: const Text('Edit Host'),
                        actions: [
                          IconButton(
                            icon: const Icon(Icons.star_border),
                            tooltip: 'Favorite',
                            onPressed: onSave,
                          ),
                        ],
                      ),
                    ),
                    body: const SizedBox.expand(),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        );

    testWidgets('moves Back and the actions into the vertical bar', (
      tester,
    ) async {
      useOuterDisplay(tester);
      var saved = 0;
      await tester.pumpWidget(screen(onSave: () => saved += 1));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Edit Host'), findsOneWidget);
      final appBar = find.byType(AppBar);
      expect(
        find.descendant(of: appBar, matching: find.byType(IconButton)),
        findsNothing,
      );
      final back = tester.getRect(find.byType(BackButton));
      expect(back.top, 174);
      expect(back.center.dx, _bar.itemColumn.center.dx);
      final favorite = tester.getRect(find.byTooltip('Favorite'));
      expect(favorite.bottom, 644);

      await tester.tap(find.byTooltip('Favorite'));
      expect(saved, 1);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Edit Host'), findsNothing);
      expect(find.byTooltip('Favorite'), findsNothing);
    });

    testWidgets('gathers the actions it has no room for into a menu', (
      tester,
    ) async {
      // A Live Activity lengthens the status cluster and the keyboard is up:
      // room for two keys.
      useOuterDisplay(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 265);
      const shortBar = SystemVerticalBar(
        edge: SystemVerticalBarEdge.right,
        itemColumn: Rect.fromLTRB(396, 264, 440, 644),
      );
      final pressed = <String>[];
      IconButton action(String name, IconData icon) => IconButton(
        icon: Icon(icon),
        tooltip: name,
        onPressed: () => pressed.add(name),
      );
      await tester.pumpWidget(
        withBar(
          bar: shortBar,
          Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => Scaffold(
                    appBar: VerticalBarAppBar(
                      AppBar(
                        title: const Text('Agent'),
                        actions: [
                          action('Search chat', Icons.search),
                          action('Windows', Icons.window_outlined),
                          action('Save', Icons.save_outlined),
                        ],
                      ),
                    ),
                    body: const SizedBox.expand(),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byType(BackButton), findsOneWidget);
      expect(find.byTooltip('Search chat'), findsNothing);
      await tester.tap(find.byTooltip('Show menu'));
      await tester.pumpAndSettle();
      for (final name in ['Search chat', 'Windows', 'Save']) {
        expect(find.text(name), findsOneWidget, reason: name);
      }
      await tester.tap(find.text('Windows'));
      await tester.pumpAndSettle();
      expect(pressed, ['Windows']);
    });

    testWidgets('is the plain app bar without a vertical bar', (tester) async {
      await tester.pumpWidget(screen(bar: null));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final appBar = find.byType(AppBar);
      expect(
        find.descendant(of: appBar, matching: find.byTooltip('Favorite')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: appBar, matching: find.byType(BackButton)),
        findsOneWidget,
      );
    });
  });

  testWidgets('VerticalBarTabs reports the picked destination', (tester) async {
    var picked = -1;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: VerticalBarTabs(
            tabs: const [
              VerticalBarTab(
                icon: Icons.dns_outlined,
                selectedIcon: Icons.dns_rounded,
                label: 'Hosts',
              ),
              VerticalBarTab(
                icon: Icons.link_outlined,
                selectedIcon: Icons.link,
                label: 'Connections',
              ),
            ],
            selectedIndex: 0,
            onSelected: (index) => picked = index,
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.dns_rounded), findsOneWidget);
    expect(find.byIcon(Icons.link_outlined), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Hosts')),
      matchesSemantics(
        label: 'Hosts',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        hasTapAction: true,
      ),
    );
    await tester.tap(find.text('Connections'));
    expect(picked, 1);
  });
}
