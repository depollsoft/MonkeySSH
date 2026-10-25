import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/terminal_theme.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart';
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
  Widget withBar(
    Widget child, {
    SystemVerticalBar? bar = _bar,
    bool disableAnimations = false,
  }) => MaterialApp(
    builder: (context, navigator) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(disableAnimations: disableAnimations),
      child: SystemVerticalBarScope(bar: bar, child: navigator!),
    ),
    home: child,
  );

  // A screen whose app bar hands [actions] to the vertical bar, pushed with
  // [route] when 'open' is tapped.
  Widget pushes({
    required List<Widget> actions,
    SystemVerticalBar? bar = _bar,
    bool disableAnimations = false,
    PageRoute<void> Function(WidgetBuilder builder)? route,
  }) {
    Widget page(BuildContext context) => Scaffold(
      appBar: VerticalBarAppBar(
        AppBar(title: const Text('Agent'), actions: actions),
      ),
      body: const SizedBox.expand(),
    );
    return withBar(
      bar: bar,
      disableAnimations: disableAnimations,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(
            context,
          ).push(route?.call(page) ?? MaterialPageRoute<void>(builder: page)),
          child: const Text('open'),
        ),
      ),
    );
  }

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
      tooltip: name,
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

      // Neither Tab nor VoiceOver reaches a key out of sight.
      final semantics = tester.ensureSemantics();
      await tester.pump();
      final tooltips = <String>{};
      void visit(SemanticsNode node) {
        if (node.tooltip.isNotEmpty) tooltips.add(node.tooltip);
        node.visitChildren((child) {
          visit(child);
          return true;
        });
      }

      visit(tester.getSemantics(find.byType(VerticalBarRail)));
      expect(tooltips, {'back', 'keys', 'menu', 'keyboard'});
      final reached = <String>{};
      for (var step = 0; step < 8; step += 1) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final key = FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<IconButton>()
            ?.key;
        if (key is ValueKey<String>) reached.add(key.value);
      }
      expect(reached, {'back', 'keys', 'menu', 'keyboard'});
      semantics.dispose();
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
        pushes(
          bar: shortBar,
          actions: [
            action('Search chat', Icons.search),
            action('Windows', Icons.window_outlined),
            action('Save', Icons.save_outlined),
            // Its items join the menu, typed as the popup's own.
            PopupMenuButton<_ChatAction>(
              tooltip: 'Chat options',
              onSelected: (value) => pressed.add(value.name),
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: _ChatAction.export,
                  child: ListTile(
                    leading: Icon(Icons.ios_share),
                    title: Text('Export chat'),
                  ),
                ),
                PopupMenuItem(value: _ChatAction.fork, child: Text('Fork')),
              ],
            ),
          ],
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Two keys fit: Back, and a menu holding every action, with the
      // popup's items set apart at its end.
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.byTooltip('Search chat'), findsNothing);
      expect(find.byTooltip('Chat options'), findsNothing);
      await tester.tap(find.byTooltip('Show menu'));
      await tester.pumpAndSettle();
      for (final name in ['Search chat', 'Windows', 'Save', 'Export chat']) {
        expect(find.text(name), findsOneWidget, reason: name);
      }
      expect(find.text('Chat options'), findsNothing);
      expect(find.byType(SubmenuButton), findsNothing);
      final save = tester.getRect(find.widgetWithText(MenuItemButton, 'Save'));
      final divider = tester.getRect(find.byType(Divider));
      final export = tester.getRect(
        find.widgetWithText(MenuItemButton, 'Export chat'),
      );
      expect(divider.top, greaterThanOrEqualTo(save.bottom));
      expect(export.top, greaterThanOrEqualTo(divider.bottom));
      // The popup's list tile becomes the row's icon and label, so its row
      // is as tall as the rest.
      expect(find.byType(ListTile), findsNothing);
      expect(export.height, save.height);
      expect(
        find.descendant(
          of: find.widgetWithText(MenuItemButton, 'Export chat'),
          matching: find.byIcon(Icons.ios_share),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Windows'));
      await tester.pumpAndSettle();
      expect(pressed, ['Windows']);

      await tester.tap(find.byTooltip('Show menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export chat'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(pressed, ['Windows', 'export']);
    });

    testWidgets('folds a popup action into the menu it opens beside', (
      tester,
    ) async {
      // The native chat's actions with the keyboard up: room for three keys.
      useOuterDisplay(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 336);
      final pressed = <String>[];
      await tester.pumpWidget(
        pushes(
          actions: [
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: 'Search chat',
              onPressed: () => pressed.add('search'),
            ),
            IconButton(
              icon: const Icon(Icons.window_outlined),
              tooltip: 'MonkeyMux windows',
              onPressed: () => pressed.add('windows'),
            ),
            PopupMenuButton<_ChatAction>(
              icon: const Icon(Icons.more_vert),
              onSelected: (value) => pressed.add(value.name),
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: _ChatAction.export,
                  child: ListTile(
                    leading: Icon(Icons.ios_share),
                    title: Text('Export chat'),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Back, one menu key, and the action nearest the thumb: never a second
      // key that looks and reads the same as the menu key.
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.byTooltip('Show menu'), findsOneWidget);
      expect(find.byType(PopupMenuButton<_ChatAction>), findsNothing);
      expect(find.byTooltip('MonkeyMux windows'), findsOneWidget);
      await tester.tap(find.byTooltip('Show menu'));
      await tester.pumpAndSettle();
      expect(find.text('Search chat'), findsOneWidget);
      await tester.tap(find.text('Export chat'));
      await tester.pumpAndSettle();
      expect(pressed, ['export']);
    });

    testWidgets("styles the folded menu like the app's other menus", (
      tester,
    ) async {
      useOuterDisplay(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 360);
      await tester.pumpWidget(
        pushes(
          actions: [
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: 'Search chat',
              onPressed: () {},
            ),
            IconButton(
              icon: const Icon(Icons.save_outlined),
              tooltip: 'Save',
              onPressed: () {},
            ),
          ],
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Show menu'));
      await tester.pumpAndSettle();

      final colorScheme = Theme.of(tester.element(find.text('Agent')))
          .colorScheme;
      final panel = tester
          .widgetList<Material>(
            find.ancestor(
              of: find.text('Save'),
              matching: find.byType(Material),
            ),
          )
          .firstWhere((material) => material.type == MaterialType.canvas);
      expect(panel.color, colorScheme.surfaceContainerHighest);
      expect(
        panel.shape,
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colorScheme.outline),
        ),
      );
      expect(
        tester
            .getSize(
              find.descendant(
                of: find.widgetWithText(MenuItemButton, 'Save'),
                matching: find.byType(Material),
              ),
            )
            .height,
        44,
      );
    });

    testWidgets('gives text-button actions a key in the vertical bar', (
      tester,
    ) async {
      useOuterDisplay(tester);
      var saved = 0;
      await tester.pumpWidget(
        pushes(
          actions: [
            TextButton(
              onPressed: () => saved += 1,
              child: const Text('Import everything'),
            ),
            TextButton(onPressed: () => saved += 1, child: const Text('Save')),
          ],
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final colorScheme = Theme.of(tester.element(find.text('Agent')))
          .colorScheme;
      final save = find.widgetWithText(TextButton, 'Save');
      final key = tester.getRect(save);
      expect(key.height, verticalBarItemExtent);
      expect(key.width, inInclusiveRange(verticalBarItemExtent, 72));
      expect(key.center.dx, _bar.itemColumn.center.dx);
      expect(key.bottom, 644);
      final material = tester.widget<Material>(
        find.descendant(of: save, matching: find.byType(Material)),
      );
      expect(material.color, colorScheme.surfaceContainerHighest);
      expect(
        material.shape,
        StadiumBorder(side: BorderSide(color: colorScheme.outline)),
      );
      final label = tester.renderObject<RenderParagraph>(find.text('Save'));
      expect(
        contrastRatio(
          label.text.style!.color!,
          colorScheme.surfaceContainerHighest,
        ),
        greaterThanOrEqualTo(4.5),
      );

      // A label longer than the bar is wide scales down inside its key.
      final long = find.widgetWithText(TextButton, 'Import everything');
      expect(tester.getRect(long).width, lessThanOrEqualTo(72));
      expect(
        tester
            .getRect(long)
            .deflate(1)
            .contains(tester.getRect(find.text('Import everything')).topLeft),
        isTrue,
      );
      expect(
        tester.getRect(find.text('Import everything')).right,
        lessThanOrEqualTo(tester.getRect(long).right),
      );

      await tester.tap(save);
      expect(saved, 1);
    });

    testWidgets('folds Back into the menu when one key fits', (tester) async {
      useOuterDisplay(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 360);
      const shortBar = SystemVerticalBar(
        edge: SystemVerticalBarEdge.right,
        itemColumn: Rect.fromLTRB(396, 264, 440, 644),
      );
      await tester.pumpWidget(
        withBar(
          bar: shortBar,
          Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  fullscreenDialog: true,
                  builder: (context) => Scaffold(
                    appBar: VerticalBarAppBar(
                      AppBar(
                        title: const Text('Editor'),
                        actions: [
                          IconButton(
                            icon: const Icon(Icons.save_outlined),
                            tooltip: 'Save',
                            onPressed: () {},
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
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // A full-screen dialog has no edge swipe, so Close stays in reach.
      expect(find.byType(CloseButton), findsNothing);
      await tester.tap(find.byTooltip('Show menu'));
      await tester.pumpAndSettle();
      expect(find.text('Save'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Editor'), findsNothing);
    });

    testWidgets('keeps the actions across the top when no key fits', (
      tester,
    ) async {
      useOuterDisplay(tester);
      // A Live Activity's status cluster and a very tall keyboard leave the
      // bar's item column no room at all.
      tester.view.viewInsets = const FakeViewPadding(bottom: 420);
      const shortBar = SystemVerticalBar(
        edge: SystemVerticalBarEdge.right,
        itemColumn: Rect.fromLTRB(396, 264, 440, 644),
      );
      var saved = 0;
      await tester.pumpWidget(
        withBar(
          bar: shortBar,
          Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  fullscreenDialog: true,
                  builder: (context) => Scaffold(
                    appBar: VerticalBarAppBar(
                      AppBar(
                        title: const Text('Editor'),
                        actions: [
                          IconButton(
                            icon: const Icon(Icons.save_outlined),
                            tooltip: 'Save',
                            onPressed: () => saved += 1,
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
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final appBar = find.byType(AppBar);
      expect(find.byType(VerticalBarRail), findsNothing);
      expect(
        find.descendant(of: appBar, matching: find.byTooltip('Save')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Save'));
      expect(saved, 1);
      await tester.tap(
        find.descendant(of: appBar, matching: find.byType(CloseButton)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Editor'), findsNothing);
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

  group('VerticalBarRailPortal', () {
    // The rail's opacity, and whether it ignores taps, as the route fades it.
    Opacity railOpacity(WidgetTester tester) => tester.widget<Opacity>(
      find
          .ancestor(
            of: find.byType(VerticalBarRail),
            matching: find.byType(Opacity),
          )
          .first,
    );
    bool railIgnoresTaps(WidgetTester tester) => tester
        .widget<IgnorePointer>(
          find
              .ancestor(
                of: find.byType(VerticalBarRail),
                matching: find.byType(IgnorePointer),
              )
              .first,
        )
        .ignoring;

    Widget screen({
      required VoidCallback onFavorite,
      bool reduceMotion = false,
    }) => pushes(
      disableAnimations: reduceMotion,
      // Cupertino's 500 ms push, as on iOS.
      route: (builder) => CupertinoPageRoute<void>(builder: builder),
      actions: [
        IconButton(
          icon: const Icon(Icons.star_border),
          tooltip: 'Favorite',
          onPressed: onFavorite,
        ),
      ],
    );

    testWidgets('fades the rail in over the start of the push and takes '
        'taps once it shows', (tester) async {
      useOuterDisplay(tester);
      var favorites = 0;
      await tester.pumpWidget(screen(onFavorite: () => favorites += 1));
      await tester.tap(find.text('open'));
      await tester.pump();

      await tester.pump(const Duration(milliseconds: 75));
      // Eased out: more than half shown halfway through the fade.
      expect(railOpacity(tester).opacity, inExclusiveRange(0.5, 1));
      expect(railIgnoresTaps(tester), isTrue);

      await tester.pump(const Duration(milliseconds: 75));
      expect(railOpacity(tester).opacity, 1);
      expect(railIgnoresTaps(tester), isFalse);
      // The page is still sliding in, and the rail already takes taps.
      final route = ModalRoute.of(tester.element(find.text('Agent')))!;
      expect(route.animation!.value, lessThan(1));
      await tester.tap(find.byTooltip('Favorite'));
      expect(favorites, 1);
      await tester.pumpAndSettle();

      // Going back fades it out over the start of the pop.
      await tester.tap(find.byType(BackButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));
      expect(railOpacity(tester).opacity, inExclusiveRange(0, 0.5));
      expect(railIgnoresTaps(tester), isTrue);
      await tester.pump(const Duration(milliseconds: 75));
      expect(railOpacity(tester).opacity, 0);
      await tester.pumpAndSettle();
      expect(find.byType(VerticalBarRail), findsNothing);
    });

    testWidgets('fades the rail out while a route covers it', (tester) async {
      useOuterDisplay(tester);
      await tester.pumpWidget(screen(onFavorite: () {}));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      unawaited(
        Navigator.of(tester.element(find.text('Agent'))).push(
          CupertinoPageRoute<void>(
            builder: (context) => const Scaffold(body: Text('Details')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(railOpacity(tester).opacity, 0);
      expect(railIgnoresTaps(tester), isTrue);

      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.text('Details'))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(railOpacity(tester).opacity, 1);
      expect(railIgnoresTaps(tester), isFalse);
      await tester.pumpAndSettle();
    });

    testWidgets('switches the rail without a fade under reduced motion', (
      tester,
    ) async {
      useOuterDisplay(tester);
      await tester.pumpWidget(screen(onFavorite: () {}, reduceMotion: true));
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(railOpacity(tester).opacity, 1);
      expect(railIgnoresTaps(tester), isFalse);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(BackButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(railOpacity(tester).opacity, 0);
      expect(railIgnoresTaps(tester), isTrue);
      await tester.pumpAndSettle();
    });
  });

  group('VerticalBarTabs', () {
    const homeTabs = [
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
      VerticalBarTab(
        icon: Icons.key_outlined,
        selectedIcon: Icons.key_rounded,
        label: 'Keys',
      ),
      VerticalBarTab(
        icon: Icons.code_outlined,
        selectedIcon: Icons.code_rounded,
        label: 'Snippets',
      ),
    ];

    // The capsule against the right edge, as in the vertical bar.
    Widget tabs({
      List<VerticalBarTab> tabs = homeTabs,
      int selectedIndex = 0,
      ValueChanged<int>? onSelected,
      double textScale = 1,
      bool showsLabels = true,
      ThemeData? theme,
    }) => MaterialApp(
      theme: theme,
      themeAnimationDuration: Duration.zero,
      builder: (context, navigator) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: navigator!,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 12),
            child: VerticalBarTabs(
              tabs: tabs,
              selectedIndex: selectedIndex,
              onSelected: onSelected ?? (_) {},
              showsLabels: showsLabels,
            ),
          ),
        ),
      ),
    );

    testWidgets('reads as a tab bar and reports the picked destination', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      var picked = -1;
      await tester.pumpWidget(
        tabs(tabs: homeTabs.take(2).toList(), onSelected: (i) => picked = i),
      );

      expect(find.byIcon(Icons.dns_rounded), findsOneWidget);
      expect(find.byIcon(Icons.link_outlined), findsOneWidget);
      final bar = tester.getSemantics(find.byType(VerticalBarTabs));
      expect(bar.getSemanticsData().role, SemanticsRole.tabBar);
      expect(bar.childrenCount, 2);
      expect(
        tester.getSemantics(find.bySemanticsLabel(RegExp('^Hosts'))),
        matchesSemantics(
          label: 'Hosts\nTab 1 of 2',
          role: SemanticsRole.tab,
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          hasTapAction: true,
        ),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel(RegExp('^Connections'))),
        matchesSemantics(
          label: 'Connections\nTab 2 of 2',
          role: SemanticsRole.tab,
          isButton: true,
          hasSelectedState: true,
          hasTapAction: true,
        ),
      );
      await tester.tap(find.text('Connections'));
      expect(picked, 1);
      semantics.dispose();
    });

    testWidgets('sets labels from 11 to 13 pt, centred and inside the '
        'capsule, at every text size', (tester) async {
      for (final scale in [1.0, 1.15, 1.3, 2.0, 3.0]) {
        await tester.pumpWidget(tabs(textScale: scale));
        final capsule = tester.getRect(find.byType(VerticalBarTabs));
        final interior = Rect.fromLTRB(
          capsule.left + 2,
          capsule.top,
          capsule.right - 2,
          capsule.bottom,
        );
        for (final tab in homeTabs) {
          final label = find.text(tab.label);
          expect(tester.widget<Text>(label).style!.fontSize, 11);
          final rect = tester.getRect(label);
          final reason = '${tab.label} at $scale';
          expect(rect.height, lessThanOrEqualTo(13 * 1.1 + 0.1));
          expect(interior.contains(rect.topLeft), isTrue, reason: reason);
          expect(interior.contains(rect.bottomRight), isTrue, reason: reason);
          expect(
            rect.center.dx,
            closeTo(capsule.center.dx, 0.5),
            reason: reason,
          );
          // Each destination keeps its icon and label within its own 58 pt.
          final icon = tester.getRect(
            find.byIcon(tab == homeTabs.first ? tab.selectedIcon : tab.icon),
          );
          expect(rect.bottom - (icon.center.dy - 14), lessThanOrEqualTo(58));
        }
      }

      // A label with room follows the text size up to 13 pt, unshrunk.
      for (final (scale, size) in [(1.1, 11 * 1.1), (2.0, 13.0)]) {
        await tester.pumpWidget(tabs(textScale: scale));
        final keys = tester.renderObject<RenderParagraph>(find.text('Keys'));
        expect(keys.textScaler.scale(11), closeTo(size, 0.01));
        expect(
          tester.getRect(find.text('Keys')).width,
          closeTo(keys.size.width, 0.01),
        );
      }
    });

    testWidgets('shows the full-size name on long press beside the rail', (
      tester,
    ) async {
      await tester.pumpWidget(tabs(textScale: 2));
      final label = tester.getRect(find.text('Connections'));
      await tester.longPress(find.text('Connections'));
      await tester.pump(const Duration(milliseconds: 300));

      final capsule = tester.getRect(find.byType(VerticalBarTabs));
      final shown = find
          .text('Connections')
          .evaluate()
          .map(
            (element) =>
                tester.getRect(find.byElementPredicate((e) => e == element)),
          );
      final tooltip = shown.singleWhere((rect) => rect != label);
      // Unshrunk, at the user's text size, and clear of the thumb on the tab.
      expect(tooltip.height, greaterThan(label.height * 2));
      expect(tooltip.height, greaterThanOrEqualTo(11 * 2));
      expect(tooltip.right, lessThan(capsule.left));
      expect(tooltip.center.dy, closeTo(label.center.dy, 30));
    });

    testWidgets('shrinks to key-height destinations without labels', (
      tester,
    ) async {
      final picked = <int>[];
      await tester.pumpWidget(tabs(showsLabels: false, onSelected: picked.add));

      expect(
        tester.getSize(find.byType(VerticalBarTabs)).height,
        VerticalBarTabs.extentFor(4, showsLabels: false),
      );
      expect(find.text('Keys'), findsNothing);
      await tester.tap(find.byIcon(Icons.key_outlined));
      expect(picked, [2]);
      // The name stays in the long-press label.
      await tester.longPress(find.byIcon(Icons.key_outlined));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Keys'), findsOneWidget);
    });

    testWidgets('keeps labels and icons legible in every built-in theme', (
      tester,
    ) async {
      final themes = {
        'app dark': FluttyTheme.dark,
        'app light': FluttyTheme.light,
        for (final theme in TerminalThemes.darkThemes)
          theme.id: FluttyTheme.fromTerminalTheme(
            theme,
            brightness: Brightness.dark,
          ),
        for (final theme in TerminalThemes.lightThemes)
          theme.id: FluttyTheme.fromTerminalTheme(
            theme,
            brightness: Brightness.light,
          ),
      };
      for (final MapEntry(key: name, value: theme) in themes.entries) {
        await tester.pumpWidget(
          tabs(theme: theme, tabs: homeTabs.take(2).toList()),
        );
        final fill = theme.colorScheme.surfaceContainerHighest;
        final indicatorDecoration =
            tester
                    .widget<AnimatedContainer>(
                      find.ancestor(
                        of: find.byIcon(Icons.dns_rounded),
                        matching: find.byType(AnimatedContainer),
                      ),
                    )
                    .decoration!
                as ShapeDecoration;
        // The selection stays teal-led: the theme's own indicator pill.
        expect(
          indicatorDecoration.color,
          theme.navigationBarTheme.indicatorColor,
          reason: name,
        );
        final indicator = Color.alphaBlend(indicatorDecoration.color!, fill);
        double label(String text) => contrastRatio(
          tester.widget<Text>(find.text(text)).style!.color!,
          fill,
        );
        double icon(IconData data, Color background) => contrastRatio(
          tester.widget<Icon>(find.byIcon(data)).color!,
          background,
        );

        expect(
          label('Hosts'),
          greaterThanOrEqualTo(4.5),
          reason: '$name selected',
        );
        expect(
          label('Connections'),
          greaterThanOrEqualTo(4.5),
          reason: '$name unselected',
        );
        expect(
          icon(Icons.dns_rounded, indicator),
          greaterThanOrEqualTo(3),
          reason: '$name selected icon',
        );
        expect(
          icon(Icons.link_outlined, fill),
          greaterThanOrEqualTo(3),
          reason: '$name unselected icon',
        );
      }
    });
  });
}

enum _ChatAction { export, fork }
