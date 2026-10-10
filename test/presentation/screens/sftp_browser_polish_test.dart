import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/remote_archive_service.dart';
import 'package:monkeyssh/domain/services/remote_file_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/models/app_platform_file.dart';
import 'package:monkeyssh/presentation/screens/sftp_browser_view.dart';
import 'package:monkeyssh/presentation/screens/sftp_screen.dart';

const _home = '/home/demo';

const _freeState = MonetizationState(
  billingAvailability: MonetizationBillingAvailability.available,
  entitlements: MonetizationEntitlements.free(),
  offers: [],
  debugUnlockAvailable: false,
  debugUnlocked: false,
);

class _MockSshClient extends Mock implements SSHClient {
  @override
  Future<void> close() async {}
}

class _MockMonetizationService extends Mock implements MonetizationService {
  _MockMonetizationService() {
    when(() => currentState).thenReturn(_freeState);
  }
}

class _TestSessions extends ActiveSessionsNotifier {
  _TestSessions(this.session);

  final SshSession session;

  @override
  Map<int, SshConnectionState> build() => {
    session.connectionId: SshConnectionState.connected,
  };

  @override
  SshSession? getSession(int connectionId) =>
      connectionId == session.connectionId ? session : null;

  @override
  Future<void> syncBackgroundStatus() async {}
}

class _MemoryViewStore implements SftpBrowserViewStore {
  final saved = <int, SftpBrowserViewSettings>{};

  @override
  Future<SftpBrowserViewSettings> load(int hostId) async =>
      saved[hostId] ?? const SftpBrowserViewSettings();

  @override
  Future<void> save(int hostId, SftpBrowserViewSettings settings) async {
    saved[hostId] = settings;
  }

  final filters = <int, SftpBrowserFilter>{};

  /// Holds the saved-filter read until completed, to play a slow database.
  Completer<void>? filterReadGate;

  @override
  Future<SftpBrowserFilter?> loadFilter(int hostId) async {
    final saved = filters[hostId];
    await filterReadGate?.future;
    return saved;
  }

  @override
  Future<void> saveFilter(int hostId, SftpBrowserFilter? filter) async {
    if (filter == null) {
      filters.remove(hostId);
    } else {
      filters[hostId] = filter;
    }
  }
}

/// Flat host tree: files with sizes and folders, plus per-path failures.
class _HostSftp extends Fake implements SftpClient {
  _HostSftp({Map<String, int>? files, Set<String>? directories})
    : files = {...?files},
      directories = {_home, ...?directories};

  final Map<String, int> files;
  final Set<String> directories;
  final failures = <String, Object>{};
  final removed = <String>[];
  final renamed = <(String, String)>[];

  static Never _missing() =>
      // ignore: only_throw_errors, dartssh2 models protocol errors this way.
      throw SftpStatusError(SftpStatusCode.noSuchFile, 'No such file');

  void _failIfAsked(String path) {
    // ignore: only_throw_errors, dartssh2 models protocol errors this way.
    if (failures[path] case final failure?) throw failure;
  }

  SftpFileAttrs _attrs(String path) {
    if (directories.contains(path)) {
      return SftpFileAttrs(mode: const SftpFileMode.value(0x41ED));
    }
    if (files[path] case final size?) {
      return SftpFileAttrs(size: size, mode: const SftpFileMode.value(0x81A4));
    }
    _missing();
  }

  @override
  Future<String> absolute(String path) async => _home;

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async =>
      _attrs(path);

  @override
  Future<List<SftpName>> listdir(String path) async {
    if (!directories.contains(path)) _missing();
    return [
      for (final entry in {...directories, ...files.keys})
        if (entry.startsWith('$path/') &&
            !entry.substring(path.length + 1).contains('/'))
          SftpName(
            filename: entry.substring(path.length + 1),
            longname: entry,
            attr: _attrs(entry),
          ),
    ];
  }

  final removeGates = <String, Completer<void>>{};

  @override
  Future<void> remove(String filename) async {
    await removeGates[filename]?.future;
    _failIfAsked(filename);
    if (files.remove(filename) == null) _missing();
    removed.add(filename);
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    _failIfAsked(oldPath);
    final size = files.remove(oldPath) ?? _missing();
    files[newPath] = size;
    renamed.add((oldPath, newPath));
  }

  @override
  Future<void> mkdir(String path, [SftpFileAttrs? attrs]) async {
    directories.add(path);
  }

  @override
  Future<void> setStat(String path, SftpFileAttrs attrs) async {}

  @override
  Future<void> rmdir(String dirname) async {
    directories.remove(dirname);
  }

  @override
  Future<void> close() async {}
}

/// Records transfers instead of touching SFTP handles.
class _TransferService extends RemoteFileService {
  final downloadFailures = <String, Object>{};
  final uploads = <String>[];
  Completer<void>? uploadGate;

  @override
  Future<void> downloadFile({
    required SftpClient sftp,
    required String remotePath,
    required String localPath,
    FutureOr<void> Function(int downloadedBytes)? onProgress,
    int? maxBytes,
    RemoteFileDownloadCancelToken? cancelToken,
  }) async {
    // ignore: only_throw_errors, dartssh2 models protocol errors this way.
    if (downloadFailures[remotePath] case final failure?) throw failure;
    File(localPath).writeAsStringSync(remotePath);
    await onProgress?.call(remotePath.length);
  }

  @override
  Future<void> uploadStream({
    required SftpClient sftp,
    required String remotePath,
    required Stream<List<int>> stream,
    bool applyPrivateMode = true,
    FutureOr<void> Function(int uploadedBytes)? onProgress,
  }) async {
    uploads.add(remotePath);
    await onProgress?.call(1);
    await uploadGate?.future;
    await onProgress?.call(2);
  }
}

class _Picker extends FilePickerPlatform {
  List<PlatformFile> files = [];
  String? directory;

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => files;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => directory;
}

ProviderContainer _container(
  _HostSftp sftp, {
  required _MemoryViewStore store,
  RemoteFileService? files,
  RemoteCommandRunner? runner,
}) {
  final ssh = _MockSshClient();
  when(ssh.sftp).thenAnswer((_) async => sftp);
  final session = SshSession(
    connectionId: 7,
    hostId: 1,
    client: ssh,
    config: const SshConnectionConfig(
      hostname: 'demo.example.com',
      port: 22,
      username: 'demo',
    ),
  );
  addTearDown(session.close);
  final container = ProviderContainer(
    overrides: [
      activeSessionsProvider.overrideWith(() => _TestSessions(session)),
      monetizationServiceProvider.overrideWithValue(_MockMonetizationService()),
      monetizationStateProvider.overrideWith((ref) => Stream.value(_freeState)),
      sftpBrowserViewStoreProvider.overrideWithValue(store),
      if (files != null) remoteFileServiceProvider.overrideWithValue(files),
      if (runner != null)
        remoteCommandRunnerFactoryProvider.overrideWithValue((_) => runner),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pumpBrowser(
  WidgetTester tester,
  ProviderContainer container, {
  int hostId = 1,
  TargetPlatform platform = TargetPlatform.android,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(platform: platform),
        home: SftpScreen(
          key: ValueKey(hostId),
          hostId: hostId,
          connectionId: 7,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

List<String> _listedNames(WidgetTester tester, Iterable<String> candidates) {
  final shown = [
    for (final name in candidates)
      if (find.text(name).evaluate().isNotEmpty)
        (name, tester.getTopLeft(find.text(name).first).dy),
  ]..sort((a, b) => a.$2.compareTo(b.$2));
  return [for (final (name, _) in shown) name];
}

Future<void> _selectFiles(WidgetTester tester, List<String> names) async {
  await tester.tap(find.byTooltip('Select files'));
  await tester.pumpAndSettle();
  for (final name in names) {
    await tester.tap(find.text(name));
    await tester.pump();
  }
}

Finder _barAction(String label) => find.widgetWithText(TextButton, label);

void main() {
  setUpAll(() {
    registerFallbackValue(Uint8List(0));
  });

  testWidgets('sort, hidden-file and filter settings persist per host', (
    tester,
  ) async {
    final sftp = _HostSftp(
      files: {'$_home/.env': 5, '$_home/big.log': 900, '$_home/small.txt': 10},
      directories: {'$_home/src'},
    );
    final store = _MemoryViewStore();
    final container = _container(sftp, store: store);
    const names = ['src', '.env', 'big.log', 'small.txt'];
    await _pumpBrowser(tester, container);
    expect(_listedNames(tester, names), names);

    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Size'));
    await tester.tap(find.text('Reverse order'));
    await tester.tap(find.text('Show hidden files'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pumpAndSettle();

    expect(_listedNames(tester, names), ['src', 'big.log', 'small.txt']);
    expect(
      store.saved[1],
      const SftpBrowserViewSettings(
        sortField: SftpSortField.size,
        descending: true,
        showHidden: false,
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('sftpFilterField')),
      'BIG',
    );
    await tester.pumpAndSettle();
    expect(_listedNames(tester, names), ['big.log']);

    // Reopening the browser for the same host restores all three.
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpBrowser(tester, container);
    expect(_listedNames(tester, names), ['big.log']);
    expect(find.widgetWithText(TextField, 'BIG'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear filter'));
    await tester.pumpAndSettle();
    expect(_listedNames(tester, names), ['src', 'big.log', 'small.txt']);

    // Another host keeps its own defaults.
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpBrowser(tester, container, hostId: 2);
    expect(_listedNames(tester, names), names);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a filter with no matches offers to clear it', (tester) async {
    final sftp = _HostSftp(files: {'$_home/notes.txt': 1});
    await _pumpBrowser(tester, _container(sftp, store: _MemoryViewStore()));

    await tester.enterText(find.byKey(const ValueKey('sftpFilterField')), 'zz');
    await tester.pumpAndSettle();
    expect(find.text('no matches'), findsOneWidget);
    await tester.tap(find.text('Clear filter'));
    await tester.pumpAndSettle();
    expect(find.text('notes.txt'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('several files delete in one action with per-file results', (
    tester,
  ) async {
    final sftp = _HostSftp(
      files: {'$_home/a.txt': 1, '$_home/b.txt': 2, '$_home/c.txt': 3},
    );
    sftp.failures['$_home/b.txt'] = SftpStatusError(
      SftpStatusCode.permissionDenied,
      'denied',
    );
    await _pumpBrowser(tester, _container(sftp, store: _MemoryViewStore()));

    await _selectFiles(tester, ['a.txt', 'b.txt']);
    expect(find.text('2 files selected'), findsOneWidget);
    await tester.tap(_barAction('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete 2 files'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(sftp.removed, ['$_home/a.txt']);
    expect(find.text('Delete results'), findsOneWidget);
    expect(find.text('Failed: Permission denied'), findsOneWidget);
    expect(find.text('Done'), findsWidgets);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Close'),
      ),
    );
    await tester.pumpAndSettle();
    // The file that failed stays selected for another try.
    expect(find.text('1 file selected'), findsOneWidget);
    expect(find.text('c.txt'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('several files download in one action with per-file results', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('sftp-batch-test-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final saveDirectory = Directory('${temp.path}/saved')..createSync();
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => temp.path,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final picker = _Picker()..directory = saveDirectory.path;
    final previous = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = previous);
    File('${saveDirectory.path}/a.txt').writeAsStringSync('already here');
    final sftp = _HostSftp(
      files: {'$_home/a.txt': 1, '$_home/b.txt': 2, '$_home/c.txt': 3},
    );
    final transfers = _TransferService()
      ..downloadFailures['$_home/b.txt'] = SftpStatusError(
        SftpStatusCode.noSuchFile,
        'gone',
      );
    await _pumpBrowser(
      tester,
      _container(sftp, store: _MemoryViewStore(), files: transfers),
      platform: TargetPlatform.linux,
    );

    await _selectFiles(tester, ['a.txt', 'b.txt', 'c.txt']);
    await tester.runAsync(() async {
      await tester.tap(_barAction('Download'));
      for (var i = 0; i < 200; i++) {
        await tester.pump();
        if (find.text('Download results').evaluate().isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();

    expect(find.text('Download results'), findsOneWidget);
    expect(find.text('Failed: No longer exists'), findsOneWidget);
    final saved = saveDirectory.listSync().map((e) => e.uri.pathSegments.last);
    expect(saved, unorderedEquals(['a.txt', 'a (2).txt', 'c.txt']));
    expect(
      File('${saveDirectory.path}/a.txt').readAsStringSync(),
      'already here',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cancelling an upload removes the partial file', (tester) async {
    final picker = _Picker()
      ..files = [
        AppPlatformFile(
          name: 'first.txt',
          bytes: Uint8List.fromList([1, 2, 3, 4]),
        ),
        AppPlatformFile(name: 'second.txt', bytes: Uint8List.fromList([2])),
      ];
    final previous = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = previous);
    final sftp = _HostSftp(files: {'$_home/first.txt': 0});
    final transfers = _TransferService()..uploadGate = Completer<void>();
    await _pumpBrowser(
      tester,
      _container(sftp, store: _MemoryViewStore(), files: transfers),
    );

    await tester.tap(find.byTooltip('Upload files'));
    await tester.pumpAndSettle();
    expect(find.text('uploading 1 of 2'), findsOneWidget);
    expect(find.byTooltip('Upload files'), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    await tester.pump();
    transfers.uploadGate!.complete();
    await tester.pumpAndSettle();

    expect(transfers.uploads, ['$_home/first.txt']);
    expect(sftp.removed, ['$_home/first.txt']);
    expect(find.text('Upload cancelled'), findsOneWidget);
    expect(find.byTooltip('Upload files'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('selected files move into another folder without replacing', (
    tester,
  ) async {
    final sftp = _HostSftp(
      files: {'$_home/a.txt': 1, '$_home/b.txt': 2, '$_home/docs/b.txt': 9},
      directories: {'$_home/docs'},
    );
    await _pumpBrowser(tester, _container(sftp, store: _MemoryViewStore()));

    await _selectFiles(tester, ['a.txt', 'b.txt']);
    await tester.tap(_barAction('Move'));
    await tester.pumpAndSettle();
    expect(find.text('move 2 files'), findsOneWidget);
    await tester.tap(find.text('docs'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Move here'));
    await tester.pumpAndSettle();

    expect(sftp.renamed, [('$_home/a.txt', '$_home/docs/a.txt')]);
    expect(sftp.files['$_home/docs/b.txt'], 9);
    expect(sftp.files['$_home/b.txt'], 2);
    expect(
      find.text('Failed: A file with this name is already here'),
      findsOne,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('extract here refuses an archive that escapes its folder', (
    tester,
  ) async {
    final scripts = <String>[];
    Future<RemoteCommandResult> runner(
      String script, {
      required Duration timeout,
      required int maxOutputBytes,
    }) async {
      scripts.add(script);
      final marker = RegExp("m='([^']+)'").firstMatch(script)!.group(1);
      RemoteCommandResult finish(String output) =>
          RemoteCommandResult(exitCode: 0, stdout: '$output\n$marker 0\n');
      if (script.contains('command -v')) return finish('4242');
      if (script.contains('unzip -Z1')) {
        return finish('../../.ssh/authorized_keys');
      }
      if (script.contains('unzip -Z ')) {
        return finish(
          '-rw-r--r--  3.0 unx       10 tx defN 26-Oct-01 12:00 '
          '../../.ssh/authorized_keys',
        );
      }
      return finish('');
    }

    final sftp = _HostSftp(files: {'$_home/evil.zip': 10});
    await _pumpBrowser(
      tester,
      _container(sftp, store: _MemoryViewStore(), runner: runner),
    );

    await tester.longPress(find.text('evil.zip'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Extract here'));
    await tester.pumpAndSettle();

    expect(
      find.text('The archive has entries that would land outside this folder.'),
      findsOneWidget,
    );
    expect(scripts.where((script) => script.contains('unzip -qq')), isEmpty);
    expect(sftp.directories, {_home});
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('android sharing gets one unique file per selection', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('sftp-share-test-');
    addTearDown(() => temp.deleteSync(recursive: true));
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    const share = MethodChannel('dev.fluttercommunity.plus/share');
    final messenger = tester.binding.defaultBinaryMessenger
      ..setMockMethodCallHandler(pathProvider, (_) async => temp.path);
    final shared = <String>[];
    messenger.setMockMethodCallHandler(share, (call) async {
      final arguments = call.arguments as Map<Object?, Object?>;
      shared.addAll((arguments['paths']! as List<Object?>).cast<String>());
      return 'dev.fluttercommunity.plus/share/success';
    });
    addTearDown(() {
      messenger
        ..setMockMethodCallHandler(pathProvider, null)
        ..setMockMethodCallHandler(share, null);
    });
    final sftp = _HostSftp(
      files: {'$_home/README.md': 1, '$_home/docs/README.md': 2},
      directories: {'$_home/docs'},
    );
    final transfers = _TransferService();
    await _pumpBrowser(
      tester,
      _container(sftp, store: _MemoryViewStore(), files: transfers),
    );

    await _selectFiles(tester, ['README.md']);
    await tester.tap(find.text('docs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('README.md'));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(_barAction('Download'));
      for (var i = 0; i < 200 && shared.isEmpty; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();

    // share_plus copies attachments into one folder by base name, so equal
    // names would share the last file twice.
    expect(shared, hasLength(2));
    final names = shared.map((file) => file.split('/').last).toSet();
    expect(names, {'README.md', 'README (2).md'});
    final contents = await tester.runAsync(
      () => Future.wait(shared.map((file) => File(file).readAsString())),
    );
    expect(contents!.toSet(), {'$_home/README.md', '$_home/docs/README.md'});
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cancelling after the last chunk keeps the finished file', (
    tester,
  ) async {
    final picker = _Picker()
      ..files = [
        AppPlatformFile(name: 'first.txt', bytes: Uint8List.fromList([1, 2])),
        AppPlatformFile(name: 'second.txt', bytes: Uint8List.fromList([3])),
      ];
    final previous = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = previous);
    final sftp = _HostSftp(files: {'$_home/first.txt': 0});
    final transfers = _TransferService()..uploadGate = Completer<void>();
    await _pumpBrowser(
      tester,
      _container(sftp, store: _MemoryViewStore(), files: transfers),
    );

    await tester.tap(find.byTooltip('Upload files'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    await tester.pump();
    transfers.uploadGate!.complete();
    await tester.pumpAndSettle();

    expect(sftp.removed, isEmpty);
    expect(transfers.uploads, ['$_home/first.txt']);
    expect(find.text('Upload cancelled. Uploaded 1 of 2 files.'), findsOne);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a failure followed by a cancel still lists every file', (
    tester,
  ) async {
    final sftp = _HostSftp(
      files: {'$_home/a.txt': 1, '$_home/b.txt': 2, '$_home/c.txt': 3},
    );
    sftp.failures['$_home/a.txt'] = SftpStatusError(
      SftpStatusCode.permissionDenied,
      'denied',
    );
    final gate = Completer<void>();
    sftp.removeGates['$_home/b.txt'] = gate;
    await _pumpBrowser(tester, _container(sftp, store: _MemoryViewStore()));

    await _selectFiles(tester, ['a.txt', 'b.txt', 'c.txt']);
    await tester.tap(_barAction('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    await tester.pump();
    gate.complete();
    await tester.pumpAndSettle();

    expect(find.text('Delete results'), findsOneWidget);
    expect(find.text('Failed: Permission denied'), findsOneWidget);
    expect(find.text('Skipped: Cancelled'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the filter survives a restart for the same folder', (
    tester,
  ) async {
    final sftp = _HostSftp(
      files: {'$_home/notes.txt': 1, '$_home/build.log': 2},
      directories: {'/home', '$_home/src'},
    );
    final store = _MemoryViewStore();
    await _pumpBrowser(tester, _container(sftp, store: store));
    await tester.enterText(
      find.byKey(const ValueKey('sftpFilterField')),
      'notes',
    );
    await tester.pumpAndSettle();
    expect(store.filters[1], (directory: _home, query: 'notes'));

    // A fresh provider container stands in for an app restart.
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpBrowser(tester, _container(sftp, store: store));
    expect(find.widgetWithText(TextField, 'notes'), findsOneWidget);
    expect(find.text('build.log'), findsNothing);

    // Opening another folder clears it for good.
    await tester.tap(find.text('home'));
    await tester.pumpAndSettle();
    expect(store.filters, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('file actions that change things wait for a running batch', (
    tester,
  ) async {
    final picker = _Picker()
      ..files = [
        AppPlatformFile(
          name: 'upload.txt',
          bytes: Uint8List.fromList([1, 2, 3, 4]),
        ),
      ];
    final previous = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = previous);
    final sftp = _HostSftp(files: {'$_home/notes.txt': 1});
    final transfers = _TransferService()..uploadGate = Completer<void>();
    await _pumpBrowser(
      tester,
      _container(sftp, store: _MemoryViewStore(), files: transfers),
    );

    await tester.tap(find.byTooltip('Upload files'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('notes.txt'));
    await tester.pumpAndSettle();

    for (final label in ['Edit', 'Download', 'Rename', 'Delete']) {
      final tile = tester.widget<ListTile>(
        find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
      );
      expect(tile.enabled, isFalse, reason: label);
    }
    expect(find.text('Select'), findsNothing);
    final info = tester.widget<ListTile>(
      find.ancestor(of: find.text('Info'), matching: find.byType(ListTile)),
    );
    expect(info.enabled, isTrue);

    await tester.tap(find.text('Info'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    transfers.uploadGate!.complete();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a slow saved-filter read never undoes a clear', (tester) async {
    final sftp = _HostSftp(
      files: {'$_home/notes.txt': 1, '$_home/build.log': 2},
    );
    final store = _MemoryViewStore()
      ..filters[1] = (directory: _home, query: 'notes')
      ..filterReadGate = Completer<void>();
    await _pumpBrowser(tester, _container(sftp, store: store));

    final field = find.byKey(const ValueKey('sftpFilterField'));
    await tester.enterText(field, 'log');
    await tester.pump();
    await tester.enterText(field, '');
    await tester.pump();
    store.filterReadGate!.complete();
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('build.log'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a filter saved for another folder waits for that folder', (
    tester,
  ) async {
    final sftp = _HostSftp(
      files: {'$_home/src/main.dart': 1, '$_home/src/notes.md': 2},
      directories: {'$_home/src'},
    );
    final store = _MemoryViewStore()
      ..filters[1] = (directory: '$_home/src', query: 'main');
    await _pumpBrowser(tester, _container(sftp, store: store));

    // Opening at the start folder keeps it.
    expect(store.filters[1], (directory: '$_home/src', query: 'main'));

    await tester.tap(find.text('src'));
    await tester.pumpAndSettle();
    expect(find.text('main.dart'), findsOneWidget);
    expect(find.text('notes.md'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a move with only skips still lists what happened', (
    tester,
  ) async {
    final sftp = _HostSftp(files: {'$_home/a.txt': 1});
    await _pumpBrowser(tester, _container(sftp, store: _MemoryViewStore()));

    await _selectFiles(tester, ['a.txt']);
    await tester.tap(_barAction('Move'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Move here'));
    await tester.pumpAndSettle();

    expect(find.text('Move results'), findsOneWidget);
    expect(find.text('Skipped: Already in this folder'), findsOneWidget);
    expect(find.textContaining('failed'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
