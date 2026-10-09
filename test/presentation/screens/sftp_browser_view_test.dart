import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
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

    test('drops a host entry when it returns to the defaults', () async {
      await store.save(1, const SftpBrowserViewSettings(descending: true));
      await store.save(1, const SftpBrowserViewSettings());

      expect(
        await SettingsService(db).getJson(sftpBrowserViewsSettingKey),
        isNull,
      );
    });
  });
}
