// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/iterm_color_scheme.dart';
import 'package:monkeyssh/domain/models/terminal_theme.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart';
import 'package:monkeyssh/domain/services/iterm_color_scheme_service.dart';
import 'package:monkeyssh/domain/services/terminal_theme_service.dart';
import 'package:monkeyssh/presentation/widgets/terminal_theme_picker.dart';
import 'package:monkeyssh/presentation/widgets/theme_preview_card.dart';

const _testThemes = [TerminalThemes.defaultDarkTheme, TerminalThemes.dracula];
const _remoteScheme = ItermColorSchemeMetadata(
  id: 'iterm2-remote-ocean',
  name: 'Remote Ocean',
  path: 'schemes/Remote Ocean.itermcolors',
);
final _remoteTheme = TerminalThemes.dracula.copyWith(
  id: _remoteScheme.id,
  name: _remoteScheme.name,
  isCustom: true,
);

void main() {
  setUpAll(() => registerFallbackValue(_remoteTheme));

  group('TerminalThemePicker', () {
    testWidgets(
      'previews installed themes instead of selecting in preview mode',
      (tester) async {
        final selectedThemes = <TerminalThemeData>[];
        final previewedThemes = <TerminalThemeData>[];

        await _pumpPicker(
          tester,
          onThemeSelected: selectedThemes.add,
          onThemePreviewed: previewedThemes.add,
          previewOnTap: true,
        );

        await tester.tap(find.text(TerminalThemes.dracula.name));
        await tester.pump();

        expect(selectedThemes, isEmpty);
        expect(previewedThemes.single.id, TerminalThemes.dracula.id);
      },
    );

    testWidgets('selects installed themes on tap outside preview mode', (
      tester,
    ) async {
      final selectedThemes = <TerminalThemeData>[];
      final previewedThemes = <TerminalThemeData>[];

      await _pumpPicker(
        tester,
        onThemeSelected: selectedThemes.add,
        onThemePreviewed: previewedThemes.add,
      );

      await tester.tap(find.text(TerminalThemes.dracula.name));
      await tester.pump();

      expect(selectedThemes.single.id, TerminalThemes.dracula.id);
      expect(previewedThemes, isEmpty);
    });

    testWidgets('matches installed themes ignoring surrounding whitespace', (
      tester,
    ) async {
      await _pumpPicker(
        tester,
        onThemeSelected: (_) {},
        liveSchemeService: _FakeItermColorSchemeService(),
      );

      await tester.enterText(find.byType(TextField), ' dracula ');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(ThemePreviewCard, TerminalThemes.dracula.name),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(
          ThemePreviewCard,
          TerminalThemes.defaultDarkTheme.name,
        ),
        findsNothing,
      );
    });

    testWidgets('previews downloadable live themes in preview mode', (
      tester,
    ) async {
      final previewedThemes = <TerminalThemeData>[];
      final liveSchemeService = _FakeItermColorSchemeService();

      await _pumpPicker(
        tester,
        onThemeSelected: (_) {},
        onThemePreviewed: previewedThemes.add,
        previewOnTap: true,
        liveSchemeService: liveSchemeService,
      );

      await tester.enterText(find.byType(TextField), 'remote');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      await tester.tap(find.text(_remoteScheme.name));
      await tester.pumpAndSettle();

      expect(liveSchemeService.loadedSchemeIds, [_remoteScheme.id]);
      expect(previewedThemes.single.id, _remoteTheme.id);
    });

    testWidgets('installed choice supersedes a delayed remote preview', (
      tester,
    ) async {
      final pendingTheme = Completer<TerminalThemeData>();
      final previewedThemes = <TerminalThemeData>[];
      await _pumpPicker(
        tester,
        onThemeSelected: (_) {},
        onThemePreviewed: previewedThemes.add,
        previewOnTap: true,
        liveSchemeService: _FakeItermColorSchemeService(pendingTheme.future),
      );
      await tester.enterText(find.byType(TextField), 'dracula');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(_remoteScheme.name));
      await tester.tap(find.text(_remoteScheme.name));
      await tester.pump();
      final installedTheme = find.widgetWithText(
        ThemePreviewCard,
        TerminalThemes.dracula.name,
      );
      await tester.ensureVisible(installedTheme);
      await tester.tap(installedTheme);
      await tester.pump();
      pendingTheme.complete(_remoteTheme);
      await tester.pumpAndSettle();

      expect(previewedThemes.map((theme) => theme.id), [
        TerminalThemes.dracula.id,
      ]);
      expect(find.text('Preview shown above'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dismissed import finishes saving without selecting a theme', (
      tester,
    ) async {
      final pendingTheme = Completer<TerminalThemeData>();
      final themeService = _MockTerminalThemeService();
      final selectedThemes = <TerminalThemeData>[];
      when(() => themeService.saveCustomTheme(any())).thenAnswer((_) async {});
      await _pumpPicker(
        tester,
        onThemeSelected: selectedThemes.add,
        liveSchemeService: _FakeItermColorSchemeService(pendingTheme.future),
        themeService: themeService,
      );
      await tester.enterText(find.byType(TextField), 'remote');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Import theme'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      pendingTheme.complete(_remoteTheme);
      await tester.pumpAndSettle();

      final saved =
          verify(
                () => themeService.saveCustomTheme(captureAny()),
              ).captured.single
              as TerminalThemeData;
      expect(saved.id, _remoteTheme.id);
      expect(saved.isCustom, isTrue);
      expect(selectedThemes, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dismissal during deletion avoids disposed provider access', (
      tester,
    ) async {
      final pendingDelete = Completer<void>();
      final themeService = _MockTerminalThemeService();
      when(
        () => themeService.deleteCustomTheme(_remoteTheme.id),
      ).thenAnswer((_) => pendingDelete.future);
      await _pumpPicker(
        tester,
        onThemeSelected: (_) {},
        themes: [_remoteTheme],
        themeService: themeService,
      );
      await tester.longPress(
        find.widgetWithText(ThemePreviewCard, _remoteTheme.name),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete theme'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      pendingDelete.complete();
      await tester.pumpAndSettle();

      verify(() => themeService.deleteCustomTheme(_remoteTheme.id)).called(1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dialog stays above keyboard and confirms previewed theme', (
      tester,
    ) async {
      final previewedThemes = <TerminalThemeData>[];
      TerminalThemeData? selectedTheme;

      tester.view
        ..physicalSize = const Size(390, 844)
        ..devicePixelRatio = 1
        ..viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(() {
        tester.view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio()
          ..resetViewInsets();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            allTerminalThemesProvider.overrideWith((ref) async => _testThemes),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  unawaited(
                    showThemePickerDialog(
                      context: context,
                      currentThemeId: TerminalThemes.defaultDarkTheme.id,
                      onThemePreviewed: previewedThemes.add,
                    ).then((theme) => selectedTheme = theme),
                  );
                },
                child: const Text('Open picker'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();

      final keyboardPadding = tester
          .widgetList<AnimatedPadding>(find.byType(AnimatedPadding))
          .where(
            (widget) => widget.padding == const EdgeInsets.only(bottom: 240),
          );
      expect(keyboardPadding, isNotEmpty);
      expect(find.text('Currently Selected'), findsOneWidget);
      expect(
        find.text('Tap a theme to preview it on this terminal.'),
        findsOneWidget,
      );

      final draculaCard = find.widgetWithText(
        ThemePreviewCard,
        TerminalThemes.dracula.name,
      );
      await tester.tapAt(tester.getTopLeft(draculaCard) + const Offset(24, 24));
      await tester.pumpAndSettle();

      expect(previewedThemes.single.id, TerminalThemes.dracula.id);
      expect(
        find.text('Previewing ${TerminalThemes.dracula.name}'),
        findsOneWidget,
      );

      await tester.tap(find.text('Use Theme'));
      await tester.pumpAndSettle();

      expect(selectedTheme?.id, TerminalThemes.dracula.id);
    });

    testWidgets('preview dialog peeks over the terminal without blank chrome', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(390, 844)
        ..devicePixelRatio = 1;
      addTearDown(() {
        tester.view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            allTerminalThemesProvider.overrideWith((ref) async => _testThemes),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  unawaited(
                    showThemePickerDialog(
                      context: context,
                      currentThemeId: TerminalThemes.defaultDarkTheme.id,
                      onThemePreviewed: (_) {},
                    ),
                  );
                },
                child: const Text('Open picker'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();

      final transparentBarrier = tester
          .widgetList<ModalBarrier>(find.byType(ModalBarrier))
          .where(
            (barrier) =>
                barrier.color == null || barrier.color == Colors.transparent,
          );
      expect(transparentBarrier, isNotEmpty);

      final sheetTop = tester.getTopLeft(find.byType(BottomSheet)).dy;
      final handleTop = tester
          .getTopLeft(
            find.byKey(const ValueKey('terminal-theme-picker-handle')),
          )
          .dy;

      expect(sheetTop, greaterThan(300));
      expect(handleTop - sheetTop, lessThan(24));
      expect(find.text('Currently Selected'), findsOneWidget);
    });
  });
}

Future<void> _pumpPicker(
  WidgetTester tester, {
  required ValueChanged<TerminalThemeData> onThemeSelected,
  ValueChanged<TerminalThemeData>? onThemePreviewed,
  ItermColorSchemeService? liveSchemeService,
  TerminalThemeService? themeService,
  List<TerminalThemeData> themes = _testThemes,
  bool previewOnTap = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        allTerminalThemesProvider.overrideWith((ref) async => themes),
        if (themeService != null)
          terminalThemeServiceProvider.overrideWithValue(themeService),
        if (liveSchemeService != null)
          itermColorSchemeServiceProvider.overrideWith(
            (ref) => liveSchemeService,
          ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            height: 844,
            child: TerminalThemePicker(
              selectedThemeId: TerminalThemes.defaultDarkTheme.id,
              onThemeSelected: onThemeSelected,
              onThemePreviewed: onThemePreviewed,
              previewOnTap: previewOnTap,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _MockTerminalThemeService extends Mock implements TerminalThemeService {}

class _FakeItermColorSchemeService extends ItermColorSchemeService {
  _FakeItermColorSchemeService([this._pendingTheme]);

  final loadedSchemeIds = <String>[];
  Future<TerminalThemeData>? _pendingTheme;

  @override
  Future<List<ItermColorSchemeMetadata>> searchSchemes(String query) async => [
    _remoteScheme,
  ];

  @override
  Future<TerminalThemeData> loadTheme(ItermColorSchemeMetadata scheme) async {
    if (_pendingTheme != null) {
      return _pendingTheme!;
    }
    loadedSchemeIds.add(scheme.id);
    _pendingTheme = Future.value(_remoteTheme);
    return _pendingTheme!;
  }
}
