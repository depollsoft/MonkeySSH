import 'dart:ui' show SemanticsAction;

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/presentation/screens/sftp_browser_view.dart';

SftpName _entry(
  String name, {
  bool directory = false,
  int? size,
  int? modified,
}) => SftpName(
  filename: name,
  longname: name,
  attr: SftpFileAttrs(
    size: size,
    modifyTime: modified,
    mode: SftpFileMode.value(directory ? 0x41ED : 0x81A4),
  ),
);

final _entries = [
  _entry('b.txt', size: 300, modified: 10),
  _entry('a.md', size: 100, modified: 30),
  _entry('C.dart', size: 200, modified: 20),
  _entry('.env', size: 5, modified: 40),
  _entry('src', directory: true, modified: 5),
  _entry('.git', directory: true, modified: 50),
];

List<String> _names(
  SftpBrowserViewSettings settings, {
  String filter = '',
  String? alwaysShow,
}) => applySftpBrowserView(
  _entries,
  settings,
  filter: filter,
  alwaysShow: alwaysShow,
).map((entry) => entry.filename).toList();

void main() {
  group('applySftpBrowserView', () {
    test('keeps folders first and sorts names in byte order by default', () {
      expect(_names(const SftpBrowserViewSettings()), [
        '.git',
        'src',
        '.env',
        'C.dart',
        'a.md',
        'b.txt',
      ]);
    });

    test('sorts files by size, modified time and type', () {
      expect(
        _names(const SftpBrowserViewSettings(sortField: SftpSortField.size)),
        ['.git', 'src', '.env', 'a.md', 'C.dart', 'b.txt'],
      );
      expect(
        _names(
          const SftpBrowserViewSettings(
            sortField: SftpSortField.modified,
            descending: true,
          ),
        ),
        ['.git', 'src', '.env', 'a.md', 'C.dart', 'b.txt'],
      );
      expect(
        _names(const SftpBrowserViewSettings(sortField: SftpSortField.type)),
        ['.git', 'src', '.env', 'C.dart', 'a.md', 'b.txt'],
      );
    });

    test('reverses within folders and files, keeping folders first', () {
      expect(_names(const SftpBrowserViewSettings(descending: true)), [
        'src',
        '.git',
        'b.txt',
        'a.md',
        'C.dart',
        '.env',
      ]);
    });

    test('hides dot files when asked', () {
      expect(_names(const SftpBrowserViewSettings(showHidden: false)), [
        'src',
        'C.dart',
        'a.md',
        'b.txt',
      ]);
    });

    test('filters names ignoring case and keeps an opened entry', () {
      const settings = SftpBrowserViewSettings(showHidden: false);
      expect(_names(settings, filter: ' C '), ['src', 'C.dart']);
      expect(_names(settings, filter: 'zzz'), isEmpty);
      expect(_names(settings, filter: 'zzz', alwaysShow: '.env'), ['.env']);
    });
  });

  group('SftpBrowserViewSettings', () {
    test('round-trips through JSON and ignores bad values', () {
      const settings = SftpBrowserViewSettings(
        sortField: SftpSortField.modified,
        descending: true,
        showHidden: false,
      );
      expect(SftpBrowserViewSettings.fromJson(settings.toJson()), settings);
      expect(
        SftpBrowserViewSettings.fromJson(const {
          'sort': 'colour',
          'descending': 1,
        }),
        const SftpBrowserViewSettings(),
      );
      expect(
        SftpBrowserViewSettings.fromJson('nonsense'),
        const SftpBrowserViewSettings(),
      );
    });

    test('describes the sort for buttons and screen readers', () {
      expect(
        describeSftpSort(
          const SftpBrowserViewSettings(
            sortField: SftpSortField.size,
            descending: true,
          ),
        ),
        'Sorted by size, largest first',
      );
    });
  });

  group('SettingsSftpBrowserViewStore', () {
    late AppDatabase db;
    late SettingsSftpBrowserViewStore store;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      store = SettingsSftpBrowserViewStore(SettingsService(db));
    });

    tearDown(() => db.close());

    test('keeps settings per host', () async {
      const sorted = SftpBrowserViewSettings(sortField: SftpSortField.size);
      const hidden = SftpBrowserViewSettings(showHidden: false);
      await store.save(1, sorted);
      await store.save(2, hidden);

      expect(await store.load(1), sorted);
      expect(await store.load(2), hidden);
      expect(await store.load(3), const SftpBrowserViewSettings());
    });

    test('keeps the filter per host with its folder', () async {
      await store.saveFilter(1, (directory: '/srv', query: 'log'));
      await store.saveFilter(2, (directory: '/tmp', query: 'x'));

      expect(await store.loadFilter(1), (directory: '/srv', query: 'log'));
      expect(await store.loadFilter(3), isNull);

      await store.saveFilter(1, null);
      expect(await store.loadFilter(1), isNull);
      expect(await store.loadFilter(2), (directory: '/tmp', query: 'x'));
    });

    test('drops a host entry when it returns to the defaults', () async {
      await store.save(1, const SftpBrowserViewSettings(descending: true));
      await store.save(1, const SftpBrowserViewSettings());

      expect(
        await SettingsService(db).getJson(sftpBrowserViewsSettingKey),
        isNull,
      );
    });
  });

  group('countSftpFilterMatches and filename highlights', () {
    test('counts eligible entries, matches and hidden matches separately', () {
      expect(
        countSftpFilterMatches(_entries, const SftpBrowserViewSettings(), 'c'),
        (matched: 2, total: 6, hiddenMatched: 0),
      );
      expect(
        countSftpFilterMatches(
          _entries,
          const SftpBrowserViewSettings(showHidden: false),
          'env',
        ),
        (matched: 0, total: 4, hiddenMatched: 1),
      );
    });

    test('splits case-insensitive matches into highlighted spans', () {
      const base = TextStyle(fontWeight: FontWeight.w400);
      const match = TextStyle(fontWeight: FontWeight.w700);
      final spans = buildHighlightedSftpFilenameSpans(
        filename: 'CHANGELOG.log',
        query: 'log',
        baseStyle: base,
        matchStyle: match,
      ).cast<TextSpan>();

      expect(
        [for (final s in spans) (s.text, s.style == match)],
        [('CHANGE', false), ('LOG', true), ('.', false), ('log', true)],
      );
    });
  });

  testWidgets('sort/view pill reflects active sort, order and hidden state', (
    tester,
  ) async {
    Future<void> pumpToolbar(
      SftpBrowserViewSettings settings, {
      String query = '',
      int? matchCount,
      int? totalCount,
      double width = 390,
      ValueChanged<String>? onFilterChanged,
    }) async {
      final controller = TextEditingController(text: query);
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: FluttyTheme.dark,
          home: Scaffold(
            body: SizedBox(
              width: width,
              child: SftpBrowserToolbar(
                filterController: controller,
                filterFocus: focus,
                onCloseFilter: () {
                  controller.clear();
                  onFilterChanged?.call('');
                },
                onFilterChanged: onFilterChanged ?? (_) {},
                settings: settings,
                onShowViewOptions: () {},
                matchCount: matchCount,
                totalCount: totalCount,
              ),
            ),
          ),
        ),
      );
    }

    await pumpToolbar(const SftpBrowserViewSettings());
    expect(find.text('name'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    expect(find.byIcon(Icons.visibility_off_outlined), findsNothing);

    await pumpToolbar(
      const SftpBrowserViewSettings(
        sortField: SftpSortField.size,
        descending: true,
        showHidden: false,
      ),
    );
    expect(find.text('size'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
    expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);

    // Shows match count when filtering and adapts cleanly on narrow widths.
    String? latestQuery;
    await pumpToolbar(
      const SftpBrowserViewSettings(),
      query: 'log',
      matchCount: 0,
      totalCount: 6,
      onFilterChanged: (q) => latestQuery = q,
    );
    final countText = tester.widget<Text>(
      find.byKey(const ValueKey('sftpFilterMatchCount')),
    );
    expect(countText.data, '0/6');

    // Escape clears a non-empty filter query.
    await tester.tap(find.byKey(const ValueKey('sftpFilterField')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(latestQuery, '');

    // Narrow viewport collapses sort label without overflow.
    await pumpToolbar(
      const SftpBrowserViewSettings(),
      width: 290,
      query: 'log',
      matchCount: 1,
      totalCount: 6,
    );
    expect(find.byIcon(Icons.tune), findsOneWidget);
    expect(find.text('1/6'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sort and view exposes a screen-reader tap action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(sftpFilterToolbarPreview());
    final button = find.bySemanticsLabel(RegExp('Sort and view:'));
    expect(
      tester
          .getSemantics(button)
          .getSemanticsData()
          .hasAction(SemanticsAction.tap),
      isTrue,
    );
    semantics.dispose();
  });
}
