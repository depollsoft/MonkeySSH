// fake_async is supplied by flutter_test; dependency manifests are outside this job.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/keyboard_toolbar.dart';
import 'package:monkeyssh/presentation/widgets/terminal_menu_style.dart';
import 'package:xterm/xterm.dart';

const _terminalShiftEnterNewlineInput = '\n';

String _terminalKeyOutput(
  TerminalKey key, {
  bool shift = false,
  bool alt = false,
  bool ctrl = false,
}) {
  final output = <String>[];
  Terminal(onOutput: output.add)
      .keyInput(key, shift: shift, alt: alt, ctrl: ctrl);
  return output.join();
}

/// The menu indicator in the corner of a key that opens a menu.
Finder _menuIndicator(String tooltip) => find.descendant(
  of: find.byTooltip(tooltip),
  matching: find.byIcon(Icons.more_horiz_rounded),
);

void registerKeyboardToolbarTests() {
  group('keyboard_toolbar', () {
    test('resolveTerminalTabInput returns plain tab by default', () {
      expect(resolveTerminalTabInput(shiftActive: false), '\t');
    });

    test(
      'resolveTerminalTabInput returns reverse-tab when shift is active',
      () {
        expect(resolveTerminalTabInput(shiftActive: true), '\x1b[Z');
      },
    );

    test('uses a single toolbar row in landscape', () {
      const mediaQuery = MediaQueryData(size: Size(844, 390));

      expect(shouldUseSingleRowKeyboardToolbar(mediaQuery), isTrue);
      expect(resolveKeyboardToolbarHeight(mediaQuery), 42);
    });

    test('uses two toolbar rows in portrait', () {
      const mediaQuery = MediaQueryData(
        size: Size(390, 844),
        padding: EdgeInsets.only(bottom: 34),
        viewPadding: EdgeInsets.only(bottom: 34),
      );

      expect(shouldUseSingleRowKeyboardToolbar(mediaQuery), isFalse);
      expect(resolveKeyboardToolbarHeight(mediaQuery), 118);
    });

    group('KeyboardToolbar', () {
      late Terminal terminal;

      setUp(() {
        terminal = Terminal(maxLines: 100);
      });

      testWidgets('keeps Paste and Enter on the right edge of their rows', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
          ),
        );

        const topRowOrder = [
          'Escape',
          'Tab',
          'Ctrl',
          'Alt',
          'Shift',
          'Pipe',
          'Slash',
          'Tilde',
          'Paste',
        ];
        const bottomRowOrder = [
          'Left',
          'Right',
          'Up',
          'Down',
          'Page Up',
          'Page Down',
          'Home',
          'End',
          'Enter',
        ];

        final topRowCenters = <String, Offset>{
          for (final label in topRowOrder)
            label: tester.getCenter(find.byTooltip(label)),
        };
        final bottomRowCenters = <String, Offset>{
          for (final label in bottomRowOrder)
            label: tester.getCenter(find.byTooltip(label)),
        };
        final actualTopRowOrder = topRowOrder.toList()
          ..sort(
            (a, b) => topRowCenters[a]!.dx.compareTo(topRowCenters[b]!.dx),
          );
        final actualBottomRowOrder = bottomRowOrder.toList()
          ..sort(
            (a, b) =>
                bottomRowCenters[a]!.dx.compareTo(bottomRowCenters[b]!.dx),
          );

        expect(actualTopRowOrder, topRowOrder);
        expect(actualBottomRowOrder, bottomRowOrder);
        expect(topRowCenters['Paste']!.dy, topRowCenters['Escape']!.dy);
        expect(bottomRowCenters['Enter']!.dy, bottomRowCenters['Left']!.dy);
        expect(
          bottomRowCenters['Enter']!.dy,
          greaterThan(topRowCenters['Paste']!.dy),
        );
      });

      testWidgets('keeps arrow keys to the left of PgUp/PgDn/Home/End/Enter', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
          ),
        );

        const expectedOrder = [
          'Left',
          'Right',
          'Up',
          'Down',
          'Page Up',
          'Page Down',
          'Home',
          'End',
          'Enter',
        ];
        final positions = <String, double>{
          for (final label in expectedOrder)
            label: tester.getCenter(find.byTooltip(label)).dx,
        };
        final actualOrder = expectedOrder.toList()
          ..sort((a, b) => positions[a]!.compareTo(positions[b]!));

        expect(actualOrder, expectedOrder);
      });

      testWidgets('renders a single landscape row for extra keys', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(size: Size(844, 390)),
              child: Scaffold(body: KeyboardToolbar(terminal: terminal)),
            ),
          ),
        );

        final escapeCenter = tester.getCenter(find.byTooltip('Escape'));
        final upCenter = tester.getCenter(find.byTooltip('Up'));
        final endCenter = tester.getCenter(find.byTooltip('End'));

        expect((escapeCenter.dy - upCenter.dy).abs(), lessThan(0.1));
        expect((escapeCenter.dy - endCenter.dy).abs(), lessThan(0.1));
      });

      testWidgets('keeps the landscape Enter key fully on screen', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(844, 390));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(size: Size(844, 390)),
              child: Scaffold(body: KeyboardToolbar(terminal: terminal)),
            ),
          ),
        );

        final enterRight = tester.getTopRight(find.byTooltip('Enter')).dx;

        expect(enterRight, lessThanOrEqualTo(844.001));
      });

      testWidgets(
        'controller preserves Ctrl state across toolbar rebuilds for system keyboard input',
        (tester) async {
          final controller = KeyboardToolbarController();
          addTearDown(controller.dispose);

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: KeyboardToolbar(
                  terminal: terminal,
                  controller: controller,
                ),
              ),
            ),
          );

          await tester.tap(find.byTooltip('Ctrl'));
          await tester.pump();

          expect(controller.isCtrlActive, isTrue);

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: KeyboardToolbar(
                  terminal: terminal,
                  controller: controller,
                ),
              ),
            ),
          );
          await tester.pump();

          expect(controller.applySystemKeyboardModifiers('b'), '\u0002');
          expect(controller.isCtrlActive, isFalse);
        },
      );

      test('system keyboard combines and consumes one-shot Ctrl+Alt', () {
        final controller = KeyboardToolbarController()
          ..toggleCtrl()
          ..toggleAlt();
        addTearDown(controller.dispose);

        expect(controller.applySystemKeyboardModifiers('b'), '\x1b\u0002');
        expect(controller.isCtrlActive, isFalse);
        expect(controller.isAltActive, isFalse);
        expect(controller.applySystemKeyboardModifiers('b'), 'b');
      });

      testWidgets('calls onKeyPressed callback', (tester) async {
        var callCount = 0;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: KeyboardToolbar(
                terminal: terminal,
                onKeyPressed: () => callCount++,
              ),
            ),
          ),
        );

        // Tap a key
        await tester.tap(find.text('/'));
        await tester.pump();

        expect(callCount, 1);
      });

      test('custom input sinks bypass the terminal', () {
        fakeAsync((async) {
          final terminalOutput = <String>[];
          final customTerminal = Terminal(onOutput: terminalOutput.add);
          final textInput = <String>[];
          final specialKeys = <TerminalKey>[];

          final controller = KeyboardToolbarController();
          addTearDown(controller.dispose);

          TerminalToolbarDispatcher(
              terminal: customTerminal,
              controller: controller,
              refocusTerminal: () {},
              lightImpact: () async {},
              onTextInput: textInput.add,
              onSpecialKey: specialKeys.add,
            )
            ..sendText('/')
            ..sendNavigationKey(TerminalKey.arrowLeft, '\x1b[D')
            ..sendEnter();
          async.flushMicrotasks();

          expect(textInput, ['/']);
          expect(specialKeys, [TerminalKey.arrowLeft, TerminalKey.enter]);
          expect(terminalOutput, isEmpty);
        });
      });

      testWidgets('modifier taps call onKeyPressed to reset IME context', (
        tester,
      ) async {
        var callCount = 0;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: KeyboardToolbar(
                terminal: terminal,
                onKeyPressed: () => callCount++,
              ),
            ),
          ),
        );

        await tester.tap(find.byTooltip('Ctrl'));
        await tester.pump();

        expect(callCount, 1);
      });

      testWidgets('special characters render correctly', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
          ),
        );

        expect(find.text('|'), findsOneWidget);
        expect(find.text('/'), findsOneWidget);
        expect(find.text('~'), findsOneWidget);
      });

      test('Tilde button sends a tilde character', () {
        fakeAsync((async) {
          final output = <String>[];
          terminal.onOutput = output.add;

          final controller = KeyboardToolbarController();
          addTearDown(controller.dispose);
          TerminalToolbarDispatcher(
            terminal: terminal,
            controller: controller,
            refocusTerminal: () {},
            lightImpact: () async {},
          ).sendText('~');
          async.flushMicrotasks();

          expect(output, contains('~'));
        });
      });

      testWidgets('Paste button invokes clipboard paste callback on tap', (
        tester,
      ) async {
        var pasteCount = 0;
        var keyPressedCount = 0;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: KeyboardToolbar(
                terminal: terminal,
                onKeyPressed: () => keyPressedCount++,
                onPasteRequested: () async => pasteCount++,
              ),
            ),
          ),
        );

        await tester.tap(find.byTooltip('Paste'));
        await tester.pump();

        expect(pasteCount, 1);
        expect(keyPressedCount, 1);
      });

      testWidgets(
        'Paste button shows an ellipsis long-press options indicator',
        (tester) async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
            ),
          );

          expect(_menuIndicator('Paste'), findsOneWidget);
        },
      );

      testWidgets('Paste long press opens an anchored drag-release menu', (
        tester,
      ) async {
        var mediaPasteCount = 0;
        var filePasteCount = 0;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  const Spacer(),
                  KeyboardToolbar(
                    terminal: terminal,
                    onPasteMediaRequested: () async => mediaPasteCount++,
                    onPasteFilesRequested: () async => filePasteCount++,
                  ),
                ],
              ),
            ),
          ),
        );

        final pasteCenter = tester.getCenter(find.byTooltip('Paste'));
        final gesture = await tester.startGesture(pasteCenter);
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
        await tester.pump();

        expect(find.text('Paste Media'), findsOneWidget);
        expect(find.text('Paste Files'), findsOneWidget);
        expect(
          tester.getCenter(find.text('Paste Media')).dy,
          lessThan(pasteCenter.dy),
        );

        await gesture.moveTo(tester.getCenter(find.text('Paste Media')));
        await tester.pump();
        await gesture.up();
        await tester.pump();

        expect(mediaPasteCount, 1);
        expect(filePasteCount, 0);
        expect(find.text('Paste Media'), findsNothing);
        expect(find.text('Paste Files'), findsNothing);
      });

      testWidgets('Paste long press uses terminal menu styling', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  const Spacer(),
                  KeyboardToolbar(
                    terminal: terminal,
                    onPasteMediaRequested: () async {},
                    onPasteFilesRequested: () async {},
                  ),
                ],
              ),
            ),
          ),
        );

        final pasteCenter = tester.getCenter(find.byTooltip('Paste'));
        final gesture = await tester.startGesture(pasteCenter);
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
        await tester.pump();

        final pasteMedia = find.text('Paste Media');
        final menuMaterial = tester.widget<Material>(
          find.ancestor(of: pasteMedia, matching: find.byType(Material)).first,
        );
        final menuContext = tester.element(pasteMedia);

        expect(
          menuMaterial.color,
          TerminalMenuStyles.surfaceColor(menuContext),
        );
        expect(menuMaterial.elevation, TerminalMenuStyles.elevation);
        expect(
          menuMaterial.shape,
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(
              TerminalMenuStyles.borderRadius,
            ),
          ),
        );
        expect(find.byType(Divider), findsNothing);

        await gesture.cancel();
        await tester.pump();
      });

      testWidgets('Paste long press releases over a top-level snippet', (
        tester,
      ) async {
        KeyboardToolbarSnippet? selectedSnippet;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  const Spacer(),
                  KeyboardToolbar(
                    terminal: terminal,
                    snippets: const [
                      KeyboardToolbarSnippet(
                        id: 1,
                        name: 'Top level',
                        command: 'git status',
                      ),
                    ],
                    onSnippetPasteRequested: (snippet) async {
                      selectedSnippet = snippet;
                    },
                  ),
                ],
              ),
            ),
          ),
        );

        final pasteCenter = tester.getCenter(find.byTooltip('Paste'));
        final gesture = await tester.startGesture(pasteCenter);
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
        await tester.pump();

        expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);

        await gesture.moveTo(tester.getCenter(find.text('Snippets')));
        await tester.pump();

        expect(find.text('Top level'), findsOneWidget);

        await gesture.moveTo(tester.getCenter(find.text('Top level')));
        await tester.pump();
        await gesture.up();
        await tester.pump();

        expect(selectedSnippet?.id, 1);
        expect(selectedSnippet?.command, 'git status');
        expect(find.text('Top level'), findsNothing);
      });

      testWidgets('Paste long press releases over a folder snippet', (
        tester,
      ) async {
        KeyboardToolbarSnippet? selectedSnippet;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  const Spacer(),
                  KeyboardToolbar(
                    terminal: terminal,
                    snippetFolders: const [
                      KeyboardToolbarSnippetFolder(id: 7, name: 'Deploy'),
                    ],
                    snippets: const [
                      KeyboardToolbarSnippet(
                        id: 2,
                        name: 'Restart API',
                        command: 'systemctl restart api',
                        folderId: 7,
                      ),
                    ],
                    onSnippetPasteRequested: (snippet) async {
                      selectedSnippet = snippet;
                    },
                  ),
                ],
              ),
            ),
          ),
        );

        final pasteCenter = tester.getCenter(find.byTooltip('Paste'));
        final gesture = await tester.startGesture(pasteCenter);
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
        await tester.pump();

        await gesture.moveTo(tester.getCenter(find.text('Snippets')));
        await tester.pump();

        expect(find.text('Deploy'), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('Deploy')).dx,
          lessThan(tester.getTopLeft(find.text('Snippets')).dx),
        );

        await gesture.moveTo(tester.getCenter(find.text('Deploy')));
        await tester.pump();

        expect(find.text('Restart API'), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('Restart API')).dx,
          lessThan(tester.getTopLeft(find.text('Snippets')).dx),
        );
        expect(
          tester.getTopLeft(find.text('Restart API')).dy,
          greaterThan(tester.getTopLeft(find.text('Deploy')).dy),
        );

        await gesture.moveTo(tester.getCenter(find.text('Restart API')));
        await tester.pump();
        await gesture.up();
        await tester.pump();

        expect(selectedSnippet?.id, 2);
        expect(selectedSnippet?.command, 'systemctl restart api');
        expect(find.text('Restart API'), findsNothing);
      });

      Future<TestGesture> longPressCtrl(WidgetTester tester) async {
        final gesture = await tester.startGesture(
          tester.getCenter(find.byTooltip('Ctrl')),
        );
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
        await tester.pump();
        return gesture;
      }

      Widget bottomAnchoredToolbar(KeyboardToolbar toolbar) => MaterialApp(
        home: Scaffold(body: Column(children: [const Spacer(), toolbar])),
      );

      testWidgets('Ctrl shows a long-press shortcuts indicator', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
          ),
        );

        expect(_menuIndicator('Ctrl'), findsOneWidget);
      });

      testWidgets('Ctrl long press sends the chord released over', (
        tester,
      ) async {
        final output = <String>[];
        terminal.onOutput = output.add;
        var keyPressedCount = 0;

        await tester.pumpWidget(
          bottomAnchoredToolbar(
            KeyboardToolbar(
              terminal: terminal,
              onKeyPressed: () => keyPressedCount++,
            ),
          ),
        );

        final ctrlRect = tester.getRect(find.byTooltip('Ctrl'));
        final gesture = await longPressCtrl(tester);

        final interrupt = find.text('\u2303C');
        expect(interrupt, findsOneWidget);
        expect(find.text('Interrupt'), findsOneWidget);
        expect(tester.getCenter(interrupt).dy, lessThan(ctrlRect.top));
        // Ctrl+C is the row nearest the finger.
        for (final shortcut in KeyboardToolbarCtrlShortcut.values) {
          expect(
            tester.getCenter(find.text(shortcut.symbol)).dy,
            lessThanOrEqualTo(tester.getCenter(interrupt).dy),
          );
        }

        await gesture.moveTo(tester.getCenter(interrupt));
        await tester.pump();
        await gesture.up();
        await tester.pump();

        expect(output, ['\x03']);
        expect(keyPressedCount, 1);
        expect(find.text('\u2303C'), findsNothing);
      });

      testWidgets('Ctrl long press released off the menu sends nothing', (
        tester,
      ) async {
        final output = <String>[];
        terminal.onOutput = output.add;
        final controller = KeyboardToolbarController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          bottomAnchoredToolbar(
            KeyboardToolbar(terminal: terminal, controller: controller),
          ),
        );

        final gesture = await longPressCtrl(tester);
        expect(find.text('\u2303C'), findsOneWidget);

        // Slide over Ctrl+C, then away before releasing.
        await gesture.moveTo(tester.getCenter(find.text('\u2303C')));
        await tester.pump();
        await gesture.moveTo(tester.getCenter(find.byTooltip('Ctrl')));
        await tester.pump();
        await gesture.up();
        await tester.pump();

        expect(output, isEmpty);
        expect(controller.isCtrlActive, isFalse);
        expect(find.text('\u2303C'), findsNothing);
      });

      testWidgets('Ctrl shortcuts become one row when a column cannot fit', (
        tester,
      ) async {
        // A landscape phone with the keyboard up leaves little room above the
        // toolbar; clamping the column down would put the finger inside it.
        const size = Size(844, 200);
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final output = <String>[];
        terminal.onOutput = output.add;

        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(size: size),
              child: Scaffold(
                body: Column(
                  children: [
                    const Spacer(),
                    KeyboardToolbar(terminal: terminal),
                  ],
                ),
              ),
            ),
          ),
        );

        final ctrlRect = tester.getRect(find.byTooltip('Ctrl'));
        final gesture = await longPressCtrl(tester);

        final interruptRect = tester.getRect(
          find
              .ancestor(
                of: find.text('\u2303C'),
                matching: find.byType(Container),
              )
              .first,
        );
        expect(interruptRect.bottom, lessThan(ctrlRect.top));
        expect(interruptRect.left, lessThanOrEqualTo(ctrlRect.center.dx));
        expect(interruptRect.right, greaterThan(ctrlRect.center.dx));
        for (final shortcut in KeyboardToolbarCtrlShortcut.values) {
          final center = tester.getCenter(find.text(shortcut.symbol));
          expect(center.dy, tester.getCenter(find.text('\u2303C')).dy);
          expect(
            center.dx,
            greaterThanOrEqualTo(tester.getCenter(find.text('\u2303C')).dx),
          );
        }

        await gesture.moveTo(
          Offset(ctrlRect.center.dx, interruptRect.center.dy),
        );
        await tester.pump();
        await gesture.up();
        await tester.pump();

        expect(output, ['\x03']);
      });

      for (final (name, surface, layoutSize) in const [
        ('a narrow landscape window', Size(360, 200), Size(360, 200)),
        // Two toolbar rows with the keyboard up leave no room for a column.
        (
          'a portrait phone with the keyboard up',
          Size(375, 300),
          Size(375, 667),
        ),
      ]) {
        testWidgets('Ctrl shortcuts row keeps Ctrl+C above Ctrl in $name', (
          tester,
        ) async {
          await tester.binding.setSurfaceSize(surface);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final output = <String>[];
          terminal.onOutput = output.add;

          await tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(size: layoutSize),
                child: Scaffold(
                  body: Column(
                    children: [
                      const Spacer(),
                      KeyboardToolbar(terminal: terminal),
                    ],
                  ),
                ),
              ),
            ),
          );

          final ctrlCenter = tester.getCenter(find.byTooltip('Ctrl'));
          final gesture = await tester.startGesture(ctrlCenter);
          await gesture.moveBy(const Offset(0, -30));
          await tester.pump();

          for (final shortcut in KeyboardToolbarCtrlShortcut.values) {
            final rect = tester.getRect(find.text(shortcut.symbol));
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(surface.width));
            expect(rect.center.dy, tester.getCenter(find.text('\u2303C')).dy);
          }

          // Straight up from the key, no sideways drift.
          await gesture.moveTo(
            Offset(ctrlCenter.dx, tester.getCenter(find.text('\u2303C')).dy),
          );
          await tester.pump();
          await gesture.up();
          await tester.pump();

          expect(output, ['\x03']);
        });
      }

      testWidgets('Ctrl shortcuts row fits large accessibility text', (
        tester,
      ) async {
        const size = Size(844, 200);
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        // The menu lives in the app overlay, above any MediaQuery in `home`.
        tester.platformDispatcher.textScaleFactorTestValue = 3;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(size: size),
              child: Scaffold(
                body: Column(
                  children: [
                    const Spacer(),
                    KeyboardToolbar(terminal: terminal),
                  ],
                ),
              ),
            ),
          ),
        );

        final gesture = await longPressCtrl(tester);

        expect(tester.takeException(), isNull);
        final ctrlTop = tester.getRect(find.byTooltip('Ctrl')).top;
        for (final shortcut in KeyboardToolbarCtrlShortcut.values) {
          expect(
            tester.getRect(find.text(shortcut.symbol)).bottom,
            lessThan(ctrlTop),
          );
        }

        await gesture.cancel();
        await tester.pump();
      });

      testWidgets('Ctrl shortcuts column fits large accessibility text', (
        tester,
      ) async {
        // The menu lives in the app overlay, above any MediaQuery in `home`.
        tester.platformDispatcher.textScaleFactorTestValue = 3;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

        await tester.pumpWidget(
          bottomAnchoredToolbar(KeyboardToolbar(terminal: terminal)),
        );

        final gesture = await longPressCtrl(tester);

        for (final shortcut in KeyboardToolbarCtrlShortcut.values) {
          for (final text in [shortcut.symbol, shortcut.description]) {
            final paragraph = tester.renderObject<RenderParagraph>(
              find.text(text),
            );
            expect(
              paragraph.textSize.height,
              lessThanOrEqualTo(TerminalMenuStyles.itemHeight),
            );
          }
        }

        await gesture.cancel();
        await tester.pump();
      });

      testWidgets('Ctrl shortcut rows are labels, not buttons', (tester) async {
        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(
          bottomAnchoredToolbar(KeyboardToolbar(terminal: terminal)),
        );

        final gesture = await longPressCtrl(tester);
        await gesture.moveTo(tester.getCenter(find.text('⌃C')));
        await tester.pump();

        expect(
          tester.getSemantics(find.bySemanticsLabel('Ctrl+C, Interrupt')),
          isSemantics(isButton: false, isSelected: true),
        );

        await gesture.cancel();
        await tester.pump();
        semantics.dispose();
      });

      testWidgets('a swipe lifting off the Ctrl menu without a move cancels', (
        tester,
      ) async {
        final output = <String>[];
        terminal.onOutput = output.add;

        await tester.pumpWidget(
          bottomAnchoredToolbar(KeyboardToolbar(terminal: terminal)),
        );

        final gesture = await tester.createGesture(pointer: 7);
        await gesture.down(tester.getCenter(find.byTooltip('Ctrl')));
        await gesture.moveBy(const Offset(0, -30));
        await tester.pump();
        final interrupt = tester.getCenter(find.text('⌃C'));
        await gesture.moveTo(interrupt);
        await tester.pump();
        // The lift lands above the menu with no move event before it.
        await tester.sendEventToBinding(
          PointerUpEvent(pointer: 7, position: Offset(interrupt.dx, 4)),
        );
        await tester.pump();

        expect(output, isEmpty);
        expect(find.text('⌃C'), findsNothing);
      });

      testWidgets('a tap after a Ctrl swipe chord does not lock Ctrl', (
        tester,
      ) async {
        final controller = KeyboardToolbarController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          bottomAnchoredToolbar(
            KeyboardToolbar(terminal: terminal, controller: controller),
          ),
        );

        await tester.tap(find.byTooltip('Ctrl'));
        await tester.pump();
        expect(controller.ctrlState, isFalse);

        final gesture = await tester.startGesture(
          tester.getCenter(find.byTooltip('Ctrl')),
        );
        await gesture.moveBy(const Offset(0, -30));
        await tester.pump();
        await gesture.moveTo(tester.getCenter(find.text('⌃D')));
        await tester.pump();
        await gesture.up();
        await tester.pump();
        expect(controller.isCtrlActive, isFalse);

        // Within the 300 ms double-tap window of the first tap.
        await tester.tap(find.byTooltip('Ctrl'));
        await tester.pump();

        expect(controller.ctrlState, isFalse);
      });

      testWidgets('the highlighted Ctrl shortcut keeps a full-opacity hint', (
        tester,
      ) async {
        await tester.pumpWidget(
          bottomAnchoredToolbar(KeyboardToolbar(terminal: terminal)),
        );

        final gesture = await longPressCtrl(tester);
        await gesture.moveTo(tester.getCenter(find.text('⌃C')));
        await tester.pump();

        Color hintColor(String text) =>
            tester.widget<Text>(find.text(text)).style!.color!;
        expect(hintColor('Interrupt').a, 1);
        expect(hintColor('End of input').a, lessThan(1));

        await gesture.cancel();
        await tester.pump();
      });

      testWidgets('Ctrl long press released in place sends nothing', (
        tester,
      ) async {
        const size = Size(844, 200);
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final output = <String>[];
        terminal.onOutput = output.add;

        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(size: size),
              child: Scaffold(
                body: Column(
                  children: [
                    const Spacer(),
                    KeyboardToolbar(terminal: terminal),
                  ],
                ),
              ),
            ),
          ),
        );

        final gesture = await longPressCtrl(tester);
        expect(find.text('\u2303C'), findsOneWidget);
        await gesture.up();
        await tester.pump();

        expect(output, isEmpty);
        expect(find.text('\u2303C'), findsNothing);
      });

      testWidgets('Ctrl long press menu hides when the gesture is cancelled', (
        tester,
      ) async {
        await tester.pumpWidget(
          bottomAnchoredToolbar(KeyboardToolbar(terminal: terminal)),
        );

        final gesture = await longPressCtrl(tester);
        expect(find.text('\u2303C'), findsOneWidget);

        await gesture.cancel();
        await tester.pump();

        expect(find.text('\u2303C'), findsNothing);
      });

      testWidgets('swiping up from Ctrl opens the menu without holding', (
        tester,
      ) async {
        final output = <String>[];
        terminal.onOutput = output.add;
        final controller = KeyboardToolbarController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          bottomAnchoredToolbar(
            KeyboardToolbar(terminal: terminal, controller: controller),
          ),
        );

        final gesture = await tester.startGesture(
          tester.getCenter(find.byTooltip('Ctrl')),
        );
        await gesture.moveBy(const Offset(0, -30));
        await tester.pump();

        expect(find.text('⌃C'), findsOneWidget);

        await gesture.moveTo(tester.getCenter(find.text('⌃C')));
        await tester.pump();
        await gesture.up();
        await tester.pump();

        expect(output, ['\x03']);
        expect(controller.isCtrlActive, isFalse);
        expect(find.text('⌃C'), findsNothing);
      });

      testWidgets('a fast swipe from Ctrl chooses the row it lands on', (
        tester,
      ) async {
        final output = <String>[];
        terminal.onOutput = output.add;

        await tester.pumpWidget(
          bottomAnchoredToolbar(KeyboardToolbar(terminal: terminal)),
        );

        // One move event lands straight on the lowest row.
        final ctrlRect = tester.getRect(find.byTooltip('Ctrl'));
        final gesture = await tester.startGesture(ctrlRect.center);
        await gesture.moveTo(
          Offset(
            ctrlRect.center.dx,
            ctrlRect.top - 8 - TerminalMenuStyles.itemHeight / 2,
          ),
        );
        await tester.pump();
        await gesture.up();
        await tester.pump();

        expect(output, ['\x03']);
      });

      testWidgets('a swipe past the top of the Ctrl menu sends nothing', (
        tester,
      ) async {
        final output = <String>[];
        terminal.onOutput = output.add;

        await tester.pumpWidget(
          bottomAnchoredToolbar(KeyboardToolbar(terminal: terminal)),
        );

        final gesture = await tester.startGesture(
          tester.getCenter(find.byTooltip('Ctrl')),
        );
        await gesture.moveBy(const Offset(0, -30));
        await tester.pump();
        final menuTop = tester.getTopLeft(find.text('⌃R')).dy;
        await gesture.moveTo(
          Offset(tester.getCenter(find.text('⌃R')).dx, menuTop - 60),
        );
        await tester.pump();
        await gesture.up();
        await tester.pump();

        expect(output, isEmpty);
        expect(find.text('⌃C'), findsNothing);
      });

      testWidgets('swiping down from Ctrl neither opens the menu nor toggles', (
        tester,
      ) async {
        final output = <String>[];
        terminal.onOutput = output.add;
        final controller = KeyboardToolbarController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  KeyboardToolbar(terminal: terminal, controller: controller),
                  const Spacer(),
                ],
              ),
            ),
          ),
        );

        final gesture = await tester.startGesture(
          tester.getCenter(find.byTooltip('Ctrl')),
        );
        await gesture.moveBy(const Offset(0, 30));
        await tester.pump();

        expect(find.text('⌃C'), findsNothing);

        await gesture.up();
        await tester.pump();

        expect(output, isEmpty);
        expect(controller.isCtrlActive, isFalse);
      });

      testWidgets('a cancelled swipe from Ctrl sends nothing', (tester) async {
        final output = <String>[];
        terminal.onOutput = output.add;

        await tester.pumpWidget(
          bottomAnchoredToolbar(KeyboardToolbar(terminal: terminal)),
        );

        final gesture = await tester.startGesture(
          tester.getCenter(find.byTooltip('Ctrl')),
        );
        await gesture.moveBy(const Offset(0, -30));
        await tester.pump();
        await gesture.moveTo(tester.getCenter(find.text('⌃C')));
        await tester.pump();
        await gesture.cancel();
        await tester.pump();

        expect(output, isEmpty);
        expect(find.text('⌃C'), findsNothing);
      });

      testWidgets('swiping up from Paste opens its menu without holding', (
        tester,
      ) async {
        var mediaPasteCount = 0;
        var clipboardPasteCount = 0;

        await tester.pumpWidget(
          bottomAnchoredToolbar(
            KeyboardToolbar(
              terminal: terminal,
              onPasteRequested: () async => clipboardPasteCount++,
              onPasteMediaRequested: () async => mediaPasteCount++,
              onPasteFilesRequested: () async {},
            ),
          ),
        );

        final gesture = await tester.startGesture(
          tester.getCenter(find.byTooltip('Paste')),
        );
        await gesture.moveBy(const Offset(0, -30));
        await tester.pump();

        expect(find.text('Paste Media'), findsOneWidget);

        await gesture.moveTo(tester.getCenter(find.text('Paste Media')));
        await tester.pump();
        await gesture.up();
        await tester.pump();

        expect(mediaPasteCount, 1);
        expect(clipboardPasteCount, 0);
        expect(find.text('Paste Media'), findsNothing);
      });

      testWidgets('Ctrl shortcuts are not offered for custom input sinks', (
        tester,
      ) async {
        await tester.pumpWidget(
          bottomAnchoredToolbar(
            KeyboardToolbar(
              terminal: terminal,
              onTextInput: (_) {},
              onSpecialKey: (_) {},
            ),
          ),
        );

        expect(_menuIndicator('Ctrl'), findsNothing);

        final gesture = await longPressCtrl(tester);
        expect(find.text('\u2303C'), findsNothing);
        await gesture.up();
        await tester.pump();
      });

      testWidgets('Ctrl exposes each shortcut as a semantics action', (
        tester,
      ) async {
        final output = <String>[];
        terminal.onOutput = output.add;
        final semantics = tester.ensureSemantics();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
          ),
        );

        final node = tester.getSemantics(find.byTooltip('Ctrl'));
        final data = node.getSemanticsData();
        const interruptAction = CustomSemanticsAction(label: 'Send Ctrl+C');
        final interruptId = CustomSemanticsAction.getIdentifier(
          interruptAction,
        );
        expect(data.customSemanticsActionIds, contains(interruptId));

        node.owner!.performAction(
          node.id,
          SemanticsAction.customAction,
          interruptId,
        );
        await tester.pump();

        expect(output, ['\x03']);
        semantics.dispose();
      });

      test('Ctrl shortcuts send legacy control bytes', () {
        fakeAsync((async) {
          final output = <String>[];
          terminal.onOutput = output.add;

          final controller = KeyboardToolbarController();
          addTearDown(controller.dispose);
          final dispatcher = TerminalToolbarDispatcher(
            terminal: terminal,
            controller: controller,
            refocusTerminal: () {},
            lightImpact: () async {},
          );

          for (final shortcut in KeyboardToolbarCtrlShortcut.values) {
            dispatcher.sendCtrlShortcut(shortcut);
          }
          async.flushMicrotasks();

          expect(output, ['\x12', '\x0c', '\x1a', '\x04', '\x03']);
        });
      });

      for (final (mode, expected) in const [
        ('', '\x03'),
        ('\x1b[>1u', '\x1b[99;5u'),
      ]) {
        test('Ctrl shortcuts send only the named chord (mode "$mode")', () {
          fakeAsync((async) {
            final output = <String>[];
            terminal
              ..onOutput = output.add
              ..write(mode);

            // Armed Alt and Shift would turn the named chord into a
            // different one, so they are consumed but not applied.
            final controller = KeyboardToolbarController()
              ..toggleAlt()
              ..toggleShift();
            addTearDown(controller.dispose);
            TerminalToolbarDispatcher(
              terminal: terminal,
              controller: controller,
              refocusTerminal: () {},
              lightImpact: () async {},
            ).sendCtrlShortcut(KeyboardToolbarCtrlShortcut.interrupt);
            async.flushMicrotasks();

            expect(output, [expected]);
            expect(controller.isAltActive, isFalse);
            expect(controller.isShiftActive, isFalse);
          });
        });
      }

      test('Ctrl shortcuts consume an armed one-shot Ctrl', () {
        fakeAsync((async) {
          final output = <String>[];
          terminal.onOutput = output.add;

          final controller = KeyboardToolbarController()..toggleCtrl();
          addTearDown(controller.dispose);
          TerminalToolbarDispatcher(
            terminal: terminal,
            controller: controller,
            refocusTerminal: () {},
            lightImpact: () async {},
          ).sendCtrlShortcut(KeyboardToolbarCtrlShortcut.endOfInput);
          async.flushMicrotasks();

          expect(output, ['\x04']);
          expect(controller.isCtrlActive, isFalse);
        });
      });

      Future<TestGesture> swipeUpFrom(
        WidgetTester tester,
        String tooltip,
      ) async {
        final gesture = await tester.startGesture(
          tester.getCenter(find.byTooltip(tooltip)),
        );
        await gesture.moveBy(const Offset(0, -30));
        await tester.pump();
        return gesture;
      }

      /// The center of the menu cell directly above a key, where a straight
      /// swipe up lands.
      Offset aboveKey(WidgetTester tester, String tooltip) {
        final rect = tester.getRect(find.byTooltip(tooltip));
        return Offset(
          rect.center.dx,
          rect.top -
              TerminalMenuStyles.cascadeGap -
              TerminalMenuStyles.itemHeight / 2,
        );
      }

      testWidgets('every menu key shows the same indicator', (tester) async {
        await tester.pumpWidget(
          bottomAnchoredToolbar(KeyboardToolbar(terminal: terminal)),
        );

        for (final tooltip in const [
          'Escape',
          'Tab',
          'Ctrl',
          'Pipe',
          'Slash',
          'Tilde',
          'Paste',
        ]) {
          expect(_menuIndicator(tooltip), findsOneWidget, reason: tooltip);
        }
        for (final tooltip in const ['Alt', 'Shift', 'Up', 'Enter']) {
          expect(_menuIndicator(tooltip), findsNothing, reason: tooltip);
        }
      });

      testWidgets('swiping up from Esc opens a grid of function keys', (
        tester,
      ) async {
        final output = <String>[];
        terminal.onOutput = output.add;

        await tester.pumpWidget(
          bottomAnchoredToolbar(KeyboardToolbar(terminal: terminal)),
        );

        final escapeRect = tester.getRect(find.byTooltip('Escape'));
        final gesture = await swipeUpFrom(tester, 'Escape');

        // F1-F4 sit in the row nearest Esc with F1 above it, then F5-F8 and
        // F9-F12, the groups of a physical keyboard.
        Offset center(String label) => tester.getCenter(find.text(label));
        expect(center('F1').dy, lessThan(escapeRect.top));
        expect(
          center('F1').dx,
          inInclusiveRange(escapeRect.left, escapeRect.right),
        );
        expect(center('F4').dy, center('F1').dy);
        expect(center('F4').dx, greaterThan(center('F1').dx));
        expect(center('F5').dx, center('F1').dx);
        expect(center('F5').dy, lessThan(center('F1').dy));
        expect(center('F9').dx, center('F1').dx);
        expect(center('F9').dy, lessThan(center('F5').dy));

        await gesture.moveTo(center('F5'));
        await tester.pump();
        await gesture.up();
        await tester.pump();

        expect(output, ['\x1b[15~']);
        expect(find.text('F5'), findsNothing);
      });

      for (final (height, rows) in const [(150.0, 2), (120.0, 1)]) {
        testWidgets(
          'the function key grid gives up rows to fit above Esc ($rows)',
          (tester) async {
            final size = Size(844, height);
            await tester.binding.setSurfaceSize(size);
            addTearDown(() => tester.binding.setSurfaceSize(null));

            await tester.pumpWidget(
              MaterialApp(
                home: MediaQuery(
                  data: MediaQueryData(size: size),
                  child: Scaffold(
                    body: Column(
                      children: [
                        const Spacer(),
                        KeyboardToolbar(terminal: terminal),
                      ],
                    ),
                  ),
                ),
              ),
            );

            final escapeTop = tester.getRect(find.byTooltip('Escape')).top;
            final gesture = await swipeUpFrom(tester, 'Escape');

            final rects = [
              for (var number = 1; number <= 12; number += 1)
                tester.getRect(find.text('F$number')),
            ];
            for (final rect in rects) {
              expect(rect.top, greaterThanOrEqualTo(0));
              expect(rect.bottom, lessThan(escapeTop));
              expect(rect.right, lessThanOrEqualTo(size.width));
            }
            expect(
              rects.map((rect) => rect.center.dy).toSet(),
              hasLength(rows),
            );

            await gesture.cancel();
            await tester.pump();
          },
        );
      }

      testWidgets('Esc and Tab menus released in place send nothing', (
        tester,
      ) async {
        final output = <String>[];
        terminal.onOutput = output.add;

        await tester.pumpWidget(
          bottomAnchoredToolbar(KeyboardToolbar(terminal: terminal)),
        );

        for (final (tooltip, item) in const [
          ('Escape', 'F1'),
          ('Tab', '⇧Tab'),
        ]) {
          final gesture = await tester.startGesture(
            tester.getCenter(find.byTooltip(tooltip)),
          );
          await tester.pump(
            kLongPressTimeout + const Duration(milliseconds: 1),
          );
          await tester.pump();
          expect(find.text(item), findsOneWidget);

          await gesture.up();
          await tester.pump();
          expect(find.text(item), findsNothing);
        }

        expect(output, isEmpty);
      });

      testWidgets('Esc still sends Escape on a tap', (tester) async {
        final output = <String>[];
        terminal.onOutput = output.add;

        await tester.pumpWidget(
          bottomAnchoredToolbar(KeyboardToolbar(terminal: terminal)),
        );

        await tester.tap(find.byTooltip('Escape'));
        // Escape refocuses the terminal after a short delay.
        await tester.pump(const Duration(milliseconds: 150));

        expect(output, ['\x1b']);
      });

      testWidgets('swiping up from Tab sends Shift+Tab', (tester) async {
        final output = <String>[];
        terminal.onOutput = output.add;

        await tester.pumpWidget(
          bottomAnchoredToolbar(KeyboardToolbar(terminal: terminal)),
        );

        final gesture = await tester.startGesture(
          tester.getCenter(find.byTooltip('Tab')),
        );
        await gesture.moveTo(aboveKey(tester, 'Tab'));
        await tester.pump();
        await gesture.up();
        await tester.pump();

        expect(output, ['\x1b[Z']);
      });

      testWidgets('a straight swipe up types the symbol nearest the key', (
        tester,
      ) async {
        final output = <String>[];
        terminal.onOutput = output.add;

        await tester.pumpWidget(
          bottomAnchoredToolbar(KeyboardToolbar(terminal: terminal)),
        );

        for (final tooltip in const ['Tilde', 'Slash', 'Pipe']) {
          final gesture = await tester.startGesture(
            tester.getCenter(find.byTooltip(tooltip)),
          );
          await gesture.moveTo(aboveKey(tester, tooltip));
          await tester.pump();
          await gesture.up();
          await tester.pump();
        }

        // A dash on ~, a backslash on /, and logic's & on |.
        expect(output, ['-', r'\', '&']);
      });

      testWidgets('symbol menus stack above their key', (tester) async {
        const size = Size(390, 844);
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final output = <String>[];
        terminal.onOutput = output.add;

        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(size: size),
              child: Scaffold(
                body: Column(
                  children: [
                    const Spacer(),
                    KeyboardToolbar(terminal: terminal),
                  ],
                ),
              ),
            ),
          ),
        );

        final tildeRect = tester.getRect(find.byTooltip('Tilde'));
        final gesture = await swipeUpFrom(tester, 'Tilde');

        // The dash is the row nearest the key and the rest stack upward
        // in one column over the key, so a straight swipe up chooses by
        // distance.
        Rect row(String symbol) => tester.getRect(
          find
              .ancestor(of: find.text(symbol), matching: find.byType(Container))
              .first,
        );
        var previous = tildeRect;
        for (final symbol in ['-', '_', '=', '+', '^', '`']) {
          final rect = row(symbol);
          expect(rect.bottom, lessThan(previous.top + 0.01), reason: symbol);
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(size.width));
          expect(
            tildeRect.center.dx,
            inInclusiveRange(rect.left, rect.right),
            reason: symbol,
          );
          previous = rect;
        }

        await gesture.moveTo(Offset(tildeRect.center.dx, row('=').center.dy));
        await tester.pump();
        await gesture.up();
        await tester.pump();

        expect(output, ['=']);
      });

      testWidgets('symbol rows are named for screen readers', (tester) async {
        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(
          bottomAnchoredToolbar(KeyboardToolbar(terminal: terminal)),
        );

        final gesture = await swipeUpFrom(tester, 'Tilde');
        expect(find.bySemanticsLabel('Dash'), findsOneWidget);

        await gesture.cancel();
        await tester.pump();
        semantics.dispose();
      });

      testWidgets('the highlight fills the whole menu row', (tester) async {
        await tester.pumpWidget(
          bottomAnchoredToolbar(KeyboardToolbar(terminal: terminal)),
        );

        for (final (tooltip, item) in const [
          ('Ctrl', '\u2303D'),
          ('Tab', '\u21e7Tab'),
          ('Slash', '*'),
        ]) {
          final gesture = await swipeUpFrom(tester, tooltip);
          await gesture.moveTo(tester.getCenter(find.text(item)));
          await tester.pump();

          final row = tester.getRect(
            find
                .ancestor(of: find.text(item), matching: find.byType(Container))
                .first,
          );
          expect(row.height, TerminalMenuStyles.itemHeight, reason: tooltip);

          await gesture.cancel();
          await tester.pump();
        }
      });

      Finder loupe() => find.byKey(const ValueKey('keyMenuLoupe'));
      String loupeText(WidgetTester tester) => tester
          .widget<RichText>(
            find.descendant(of: loupe(), matching: find.byType(RichText)),
          )
          .text
          .toPlainText();
      Rect menuRow(WidgetTester tester, String symbol) => tester.getRect(
        find
            .ancestor(of: find.text(symbol), matching: find.byType(Container))
            .first,
      );

      Future<void> pumpPhoneToolbar(WidgetTester tester, Size size) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(size: size),
              child: Scaffold(
                body: Column(
                  children: [
                    const Spacer(),
                    KeyboardToolbar(terminal: terminal),
                  ],
                ),
              ),
            ),
          ),
        );
      }

      testWidgets('a loupe shows the item under the thumb beside its row', (
        tester,
      ) async {
        await pumpPhoneToolbar(tester, const Size(390, 844));

        final tilde = tester.getCenter(find.byTooltip('Tilde'));
        final gesture = await swipeUpFrom(tester, 'Tilde');
        final finger = Offset(tilde.dx, menuRow(tester, '=').center.dy);
        await gesture.moveTo(finger);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(loupeText(tester), '=');
        final bubble = tester.getRect(loupe());
        final row = menuRow(tester, '=');
        // Level with the row, and on the side facing the middle of the
        // screen, clear of a thumb holding a key near the edge.
        expect(bubble.center.dy, moreOrLessEquals(row.center.dy));
        expect(bubble.right, lessThan(row.left));
        expect(bubble.contains(finger), isFalse);

        await gesture.cancel();
        await tester.pump();
      });

      testWidgets('the loupe follows the finger and leaves with it', (
        tester,
      ) async {
        await pumpPhoneToolbar(tester, const Size(390, 844));

        final gesture = await swipeUpFrom(tester, 'Slash');
        await gesture.moveTo(tester.getCenter(find.text('*')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        final first = tester.getRect(loupe());

        await gesture.moveTo(tester.getCenter(find.text(':')));
        await tester.pump();
        expect(loupeText(tester), ':');
        // Partway through the glide it is between the two rows.
        await tester.pump(const Duration(milliseconds: 40));
        final gliding = tester.getRect(loupe()).center.dy;
        final target = menuRow(tester, ':').center.dy;
        expect(gliding, lessThan(first.center.dy));
        expect(gliding, greaterThan(target));
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.getRect(loupe()).center.dy, moreOrLessEquals(target));

        // Sliding off the menu retracts it.
        await gesture.moveTo(tester.getCenter(find.byTooltip('Slash')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(loupe(), findsNothing);

        await gesture.cancel();
        await tester.pump();
      });

      testWidgets('the function key loupe sits beside the grid', (
        tester,
      ) async {
        await pumpPhoneToolbar(tester, const Size(390, 844));

        final gesture = await swipeUpFrom(tester, 'Escape');
        await gesture.moveTo(tester.getCenter(find.text('F6')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(loupeText(tester), 'F6');
        final bubble = tester.getRect(loupe());
        expect(bubble.left, greaterThan(menuRow(tester, 'F8').right));
        expect(
          bubble.center.dy,
          moreOrLessEquals(menuRow(tester, 'F6').center.dy),
        );

        await gesture.cancel();
        await tester.pump();
      });

      testWidgets('Ctrl and Tab menus show no loupe', (tester) async {
        await pumpPhoneToolbar(tester, const Size(390, 844));

        // Their rows are wide enough to hold the finger off the symbol.
        for (final (tooltip, item) in const [
          ('Ctrl', '\u2303D'),
          ('Tab', '\u21e7Tab'),
        ]) {
          final gesture = await swipeUpFrom(tester, tooltip);
          await gesture.moveTo(tester.getCenter(find.text(item)));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));

          expect(loupe(), findsNothing, reason: tooltip);

          await gesture.cancel();
          await tester.pump();
        }
      });

      testWidgets('with reduced motion the loupe appears in place', (
        tester,
      ) async {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await pumpPhoneToolbar(tester, const Size(390, 844));

        final gesture = await swipeUpFrom(tester, 'Slash');
        await gesture.moveTo(tester.getCenter(find.text('*')));
        await tester.pump();
        await tester.pump();

        expect(loupeText(tester), '*');
        final opacity = tester.widget<Opacity>(
          find.ancestor(of: loupe(), matching: find.byType(Opacity)).first,
        );
        expect(opacity.opacity, 1);
        expect(
          tester.getRect(loupe()).center.dy,
          moreOrLessEquals(menuRow(tester, '*').center.dy),
        );

        await gesture.cancel();
        await tester.pump();
      });

      testWidgets('symbol menus apply armed modifiers like their keys', (
        tester,
      ) async {
        final output = <String>[];
        terminal.onOutput = output.add;
        final controller = KeyboardToolbarController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          bottomAnchoredToolbar(
            KeyboardToolbar(terminal: terminal, controller: controller),
          ),
        );

        await tester.tap(find.byTooltip('Ctrl'));
        await tester.pump();

        final gesture = await tester.startGesture(
          tester.getCenter(find.byTooltip('Slash')),
        );
        await gesture.moveTo(aboveKey(tester, 'Slash'));
        await tester.pump();
        await gesture.up();
        await tester.pump();

        // Ctrl+\ is the terminal's quit character.
        expect(output, ['\x1c']);
        expect(controller.isCtrlActive, isFalse);
      });

      testWidgets('custom input sinks keep symbol menus only', (tester) async {
        final textInput = <String>[];
        final specialKeys = <TerminalKey>[];

        await tester.pumpWidget(
          bottomAnchoredToolbar(
            KeyboardToolbar(
              terminal: terminal,
              onTextInput: textInput.add,
              onSpecialKey: specialKeys.add,
            ),
          ),
        );

        for (final tooltip in const ['Escape', 'Tab', 'Ctrl']) {
          expect(_menuIndicator(tooltip), findsNothing, reason: tooltip);
        }
        expect(_menuIndicator('Slash'), findsOneWidget);

        // Without a menu, holding Esc still sends it once.
        final hold = await tester.startGesture(
          tester.getCenter(find.byTooltip('Escape')),
        );
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
        expect(find.text('F1'), findsNothing);
        await hold.up();
        await tester.pump();
        expect(specialKeys, [TerminalKey.escape]);

        final swipe = await tester.startGesture(
          tester.getCenter(find.byTooltip('Tilde')),
        );
        await swipe.moveTo(aboveKey(tester, 'Tilde'));
        await tester.pump();
        await swipe.up();
        await tester.pump();

        expect(textInput, ['-']);
      });

      testWidgets('menu keys expose their items as semantics actions', (
        tester,
      ) async {
        final output = <String>[];
        terminal.onOutput = output.add;
        final semantics = tester.ensureSemantics();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
          ),
        );

        for (final (tooltip, action) in const [
          ('Tilde', 'Send Dash'),
          ('Escape', 'Send F5'),
          ('Tab', 'Send Shift+Tab'),
        ]) {
          final node = tester.getSemantics(find.byTooltip(tooltip));
          final id = CustomSemanticsAction.getIdentifier(
            CustomSemanticsAction(label: action),
          );
          expect(
            node.getSemanticsData().customSemanticsActionIds,
            contains(id),
          );
          node.owner!.performAction(node.id, SemanticsAction.customAction, id);
          await tester.pump();
        }

        expect(output, ['-', '\x1b[15~', '\x1b[Z']);
        semantics.dispose();
      });

      for (final (tooltip, first, second) in const [
        ('Paste', 'Paste Media', 'Paste Files'),
        ('Ctrl', '⌃D', '⌃C'),
        ('Escape', 'F2', 'F3'),
        ('Tilde', '_', '='),
      ]) {
        testWidgets('the $tooltip menu ticks each item the finger crosses', (
          tester,
        ) async {
          final haptics = <String>[];
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'HapticFeedback.vibrate') {
                haptics.add(call.arguments as String);
              }
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );

          await tester.pumpWidget(
            bottomAnchoredToolbar(
              KeyboardToolbar(
                terminal: terminal,
                onPasteMediaRequested: () async {},
                onPasteFilesRequested: () async {},
              ),
            ),
          );

          final gesture = await swipeUpFrom(tester, tooltip);
          await gesture.moveTo(tester.getCenter(find.text(first)));
          await tester.pump();
          // Moving within an item does not tick again.
          await gesture.moveBy(const Offset(1, 1));
          await tester.pump();
          await gesture.moveTo(tester.getCenter(find.text(second)));
          await tester.pump();
          await gesture.up();
          await tester.pump();

          expect(haptics, [
            'HapticFeedbackType.mediumImpact',
            'HapticFeedbackType.selectionClick',
            'HapticFeedbackType.selectionClick',
            'HapticFeedbackType.lightImpact',
          ]);
        });
      }

      testWidgets('a swipe lifting off the Paste menu without a move cancels', (
        tester,
      ) async {
        var mediaPasteCount = 0;

        await tester.pumpWidget(
          bottomAnchoredToolbar(
            KeyboardToolbar(
              terminal: terminal,
              onPasteMediaRequested: () async => mediaPasteCount++,
              onPasteFilesRequested: () async {},
            ),
          ),
        );

        final gesture = await tester.createGesture(pointer: 7);
        await gesture.down(tester.getCenter(find.byTooltip('Paste')));
        await gesture.moveBy(const Offset(0, -30));
        await tester.pump();
        final media = tester.getCenter(find.text('Paste Media'));
        await gesture.moveTo(media);
        await tester.pump();
        // The lift lands above the menu with no move event before it.
        await tester.sendEventToBinding(
          PointerUpEvent(pointer: 7, position: Offset(media.dx, 4)),
        );
        await tester.pump();

        expect(mediaPasteCount, 0);
        expect(find.text('Paste Media'), findsNothing);
      });

      testWidgets(
        'the Paste menu opens beside the key when it cannot fit above',
        (tester) async {
          // Too short for the column above the key, though the overlay (which
          // spans the whole window, keyboard included) still fits it beside.
          const size = Size(844, 170);
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          var mediaPasteCount = 0;
          var filePasteCount = 0;

          await tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: const MediaQueryData(size: size),
                child: Scaffold(
                  body: Column(
                    children: [
                      const Spacer(),
                      KeyboardToolbar(
                        terminal: terminal,
                        onPasteMediaRequested: () async => mediaPasteCount++,
                        onPasteFilesRequested: () async => filePasteCount++,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );

          final pasteRect = tester.getRect(find.byTooltip('Paste'));
          Future<TestGesture> holdPaste() async {
            final gesture = await tester.startGesture(pasteRect.center);
            await tester.pump(
              kLongPressTimeout + const Duration(milliseconds: 1),
            );
            await tester.pump();
            return gesture;
          }

          var gesture = await holdPaste();
          for (final label in ['Snippets', 'Paste Media', 'Paste Files']) {
            final row = tester.getRect(
              find
                  .ancestor(
                    of: find.text(label),
                    matching: find.byType(Container),
                  )
                  .first,
            );
            expect(row.overlaps(pasteRect), isFalse);
            expect(row.top, greaterThanOrEqualTo(0));
            expect(row.bottom, lessThanOrEqualTo(size.height));
          }
          // Released in place, the finger was never over the menu.
          await gesture.up();
          await tester.pump();
          expect(filePasteCount, 0);
          expect(find.text('Paste Media'), findsNothing);

          gesture = await holdPaste();
          await gesture.moveTo(tester.getCenter(find.text('Paste Media')));
          await tester.pump();
          await gesture.up();
          await tester.pump();
          expect(mediaPasteCount, 1);
        },
      );

      testWidgets('a folded symbol stack has no empty rows', (tester) async {
        // Room for four rows above the toolbar: six symbols fold into two
        // columns, which need only three.
        const surface = Size(375, 300);
        await tester.binding.setSurfaceSize(surface);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(size: Size(375, 667)),
              child: Scaffold(
                body: Column(
                  children: [
                    const Spacer(),
                    KeyboardToolbar(terminal: terminal),
                  ],
                ),
              ),
            ),
          ),
        );

        final gesture = await swipeUpFrom(tester, 'Tilde');
        final rows = {
          for (final symbol in ['-', '_', '=', '+', '^', '`'])
            tester.getCenter(find.text(symbol)).dy,
        };
        final menu = tester.getRect(
          find
              .ancestor(of: find.text('-'), matching: find.byType(Material))
              .first,
        );
        expect(rows, hasLength(3));
        expect(menu.height, 3 * TerminalMenuStyles.itemHeight);

        await gesture.cancel();
        await tester.pump();
      });

      test('function keys carry armed modifiers', () {
        fakeAsync((async) {
          final output = <String>[];
          terminal.onOutput = output.add;

          final controller = KeyboardToolbarController();
          addTearDown(controller.dispose);
          final dispatcher = TerminalToolbarDispatcher(
            terminal: terminal,
            controller: controller,
            refocusTerminal: () {},
            lightImpact: () async {},
          )..sendFunctionKey(TerminalKey.f1);
          controller.toggleShift();
          dispatcher.sendFunctionKey(TerminalKey.f5);
          async.flushMicrotasks();

          expect(output, [
            '\x1bOP',
            _terminalKeyOutput(TerminalKey.f5, shift: true),
          ]);
          expect(output.last, '\x1b[15;2~');
          expect(controller.isShiftActive, isFalse);
        });
      });

      test('function keys use Kitty encoding when enabled', () {
        fakeAsync((async) {
          final output = <String>[];
          terminal
            ..onOutput = output.add
            ..write('\x1b[>1u');

          final controller = KeyboardToolbarController();
          addTearDown(controller.dispose);
          final dispatcher = TerminalToolbarDispatcher(
            terminal: terminal,
            controller: controller,
            refocusTerminal: () {},
            lightImpact: () async {},
          )..sendFunctionKey(TerminalKey.f1);
          controller.toggleShift();
          dispatcher.sendFunctionKey(TerminalKey.f1);
          async.flushMicrotasks();

          // Legacy F1 is SS3 P; Kitty's disambiguated form is CSI P.
          expect(output, ['\x1b[P', '\x1b[1;2P']);
        });
      });

      for (final (mode, expected) in const [
        ('', '\x1b[Z'),
        ('\x1b[>1u', '\x1b[9;2u'),
      ]) {
        test('Shift+Tab sends only the named chord (mode "$mode")', () {
          fakeAsync((async) {
            final output = <String>[];
            terminal
              ..onOutput = output.add
              ..write(mode);

            final controller = KeyboardToolbarController()..toggleCtrl();
            addTearDown(controller.dispose);
            TerminalToolbarDispatcher(
              terminal: terminal,
              controller: controller,
              refocusTerminal: () {},
              lightImpact: () async {},
            ).sendBackTab();
            async.flushMicrotasks();

            expect(output, [expected]);
            expect(controller.isCtrlActive, isFalse);
          });
        });
      }

      testWidgets('Enter button renders and triggers callback', (tester) async {
        var callCount = 0;
        final output = <String>[];
        terminal.onOutput = output.add;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: KeyboardToolbar(
                terminal: terminal,
                onKeyPressed: () => callCount++,
              ),
            ),
          ),
        );

        // Enter button uses an icon, find by tooltip
        final enterButton = find.byTooltip('Enter');
        expect(enterButton, findsOneWidget);

        await tester.tap(enterButton);
        await tester.pump();

        expect(callCount, 1);
        expect(output, contains(_terminalKeyOutput(TerminalKey.enter)));
      });

      testWidgets('Tab ignores the system keyboard shift state', (
        tester,
      ) async {
        final output = <String>[];
        terminal.onOutput = output.add;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
          ),
        );

        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.tap(find.byTooltip('Tab'));
        await tester.pump();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

        expect(output, contains('\t'));
        expect(output, isNot(contains('\x1b[Z')));
      });

      test('toolbar Shift still sends reverse-tab', () {
        fakeAsync((async) {
          final output = <String>[];
          terminal.onOutput = output.add;

          final controller = KeyboardToolbarController();
          addTearDown(controller.dispose);
          final dispatcher = TerminalToolbarDispatcher(
            terminal: terminal,
            controller: controller,
            refocusTerminal: () {},
            lightImpact: () async {},
          );

          controller.toggleShift();
          async.flushMicrotasks();
          dispatcher.sendTab();
          async.flushMicrotasks();

          expect(output, contains('\x1b[Z'));
        });
      });

      test('toolbar Escape and Tab use Kitty encoding when enabled', () {
        fakeAsync((async) {
          final output = <String>[];
          terminal
            ..onOutput = output.add
            ..write('\x1b[>31u');

          final controller = KeyboardToolbarController();
          addTearDown(controller.dispose);
          final dispatcher = TerminalToolbarDispatcher(
            terminal: terminal,
            controller: controller,
            refocusTerminal: () {},
            lightImpact: () async {},
          )..sendEscape();
          async.flushMicrotasks();
          dispatcher.sendTab();
          async.flushMicrotasks();
          controller.toggleShift();
          async.flushMicrotasks();
          dispatcher.sendTab();
          async.flushMicrotasks();

          expect(output, contains('\x1b[27u'));
          expect(output, contains('\x1b[9u'));
          expect(output, contains('\x1b[9;2u'));

          async.elapse(const Duration(milliseconds: 120));
        });
      });

      test('toolbar Shift applies to Enter', () {
        fakeAsync((async) {
          final output = <String>[];
          terminal.onOutput = output.add;

          final controller = KeyboardToolbarController();
          addTearDown(controller.dispose);
          final dispatcher = TerminalToolbarDispatcher(
            terminal: terminal,
            controller: controller,
            refocusTerminal: () {},
            lightImpact: () async {},
          );

          controller.toggleShift();
          async.flushMicrotasks();
          dispatcher.sendEnter();
          async.flushMicrotasks();

          expect(output, contains(_terminalShiftEnterNewlineInput));
        });
      });

      test('toolbar Alt+Enter keeps enqueue encoding in Kitty mode', () {
        fakeAsync((async) {
          final output = <String>[];
          terminal
            ..onOutput = output.add
            ..write('${String.fromCharCode(27)}[>1u');
          output.clear();

          final controller = KeyboardToolbarController();
          addTearDown(controller.dispose);
          final dispatcher = TerminalToolbarDispatcher(
            terminal: terminal,
            controller: controller,
            refocusTerminal: () {},
            lightImpact: () async {},
          );

          controller.toggleAlt();
          async.flushMicrotasks();
          dispatcher.sendEnter();
          async.flushMicrotasks();

          expect(output, contains('\x1b\r'));
        });
      });

      test('keeps bottom safe-area padding when keyboard is closed', () {
        const mediaQuery = MediaQueryData(
          padding: EdgeInsets.only(bottom: 34),
          viewPadding: EdgeInsets.only(bottom: 34),
        );

        expect(resolveKeyboardToolbarBottomInset(mediaQuery), 34);
      });

      test('drops bottom safe-area padding when keyboard is open', () {
        // The scaffold lifts the body above the keyboard and strips the bottom
        // view inset from it, so only the (already zeroed) padding remains.
        const mediaQuery = MediaQueryData(
          viewPadding: EdgeInsets.only(bottom: 34),
        );

        expect(resolveKeyboardToolbarBottomInset(mediaQuery), 0);
      });

      test('keeps bottom safe-area padding for an unlifted bottom inset', () {
        // A bottom view inset that survives into the body means the layout was
        // never lifted for it (stale platform inset, or
        // `resizeToAvoidBottomInset: false`), so the navigation bar is still on
        // screen even though `padding.bottom` reads zero.
        const mediaQuery = MediaQueryData(
          viewPadding: EdgeInsets.only(bottom: 34),
          viewInsets: EdgeInsets.only(bottom: 320),
        );

        expect(resolveKeyboardToolbarBottomInset(mediaQuery), 34);
        expect(resolveKeyboardToolbarHeight(mediaQuery), 118);
      });

      testWidgets('stays above the navigation bar for a stale bottom inset', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              // The keyboard is closed but the platform still reports its inset,
              // so the scaffold never lifted the body: the toolbar has to clear
              // the navigation bar itself.
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  padding: EdgeInsets.zero,
                  viewPadding: const EdgeInsets.only(bottom: 34),
                  viewInsets: const EdgeInsets.only(bottom: 320),
                ),
                child: Scaffold(
                  resizeToAvoidBottomInset: false,
                  body: Column(
                    children: [
                      const Expanded(child: SizedBox.expand()),
                      KeyboardToolbar(terminal: terminal),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );

        final bodyBottom = tester.getRect(find.byType(Scaffold)).bottom;
        final lastRowBottom = tester.getRect(find.byTooltip('Enter')).bottom;

        expect(bodyBottom - lastRowBottom, 34);
      });

      test('toolbar presses keep legacy sequences without Kitty key flags', () {
        fakeAsync((async) {
          final output = <String>[];
          terminal
            ..onOutput = output.add
            ..write('\x1b[=2u');

          final controller = KeyboardToolbarController();
          addTearDown(controller.dispose);
          final dispatcher = TerminalToolbarDispatcher(
            terminal: terminal,
            controller: controller,
            refocusTerminal: () {},
            lightImpact: () async {},
          );

          controller.toggleShift();
          async.flushMicrotasks();
          dispatcher.sendNavigationKey(TerminalKey.arrowUp, '\x1b[A');
          async.flushMicrotasks();

          expect(output, contains('\x1b[1;2A'));
          expect(output, isNot(contains('scrollLineUp')));
        });
      });

      for (final (name, key, mode, sequence, holdMs, cancel) in const [
        ('arrow keys repeat while held', 'Up', '', '\x1b[A', 160, false),
        (
          'arrow holds avoid Kitty event types in raw terminals',
          'Up',
          '\x1b[>31u',
          '\x1b[A',
          160,
          false,
        ),
        (
          'series navigation holds avoid Kitty event types',
          'Page Up',
          '\x1b[>31u',
          '\x1b[5~',
          160,
          false,
        ),
        (
          'repeating navigation stops when gesture is cancelled',
          'Right',
          '',
          '\x1b[C',
          120,
          true,
        ),
        (
          'repeating navigation stops when released',
          'Home',
          '',
          '\x1b[H',
          120,
          false,
        ),
      ]) {
        testWidgets(name, (tester) async {
          final output = <String>[];
          terminal
            ..onOutput = output.add
            ..write(mode);
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(body: KeyboardToolbar(terminal: terminal)),
            ),
          );

          final gesture = await tester.startGesture(
            tester.getCenter(find.byTooltip(key)),
          );
          await tester.pump(
            kLongPressTimeout + const Duration(milliseconds: 1),
          );
          await tester.pump(Duration(milliseconds: holdMs));
          if (cancel) {
            await gesture.cancel();
          } else {
            await gesture.up();
          }
          await tester.pump();

          final outputCount = output.where((value) => value == sequence).length;
          expect(outputCount, greaterThan(1));
          expect(output.where((value) => value.contains(':2')), isEmpty);
          await tester.pump(const Duration(milliseconds: 150));
          expect(
            output.where((value) => value == sequence).length,
            outputCount,
          );
        });
      }
    });
  });
}
