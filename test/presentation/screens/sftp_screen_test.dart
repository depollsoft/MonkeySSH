import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/remote_file_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/models/app_platform_file.dart';
import 'package:monkeyssh/presentation/screens/sftp_screen.dart';

const _proMonetizationState = MonetizationState(
  billingAvailability: MonetizationBillingAvailability.available,
  entitlements: MonetizationEntitlements.pro(),
  offers: [],
  debugUnlockAvailable: false,
  debugUnlocked: false,
);

final _onePixelPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/luzp0wAAAABJRU5ErkJggg==',
);

class _MockSshClient extends Mock implements SSHClient {
  @override
  Future<void> close() async {}
}

Future<void> _completeSftpClose(Invocation _) async {}

class _MockSftpClient extends Mock implements SftpClient {
  _MockSftpClient() {
    when(close).thenAnswer(_completeSftpClose);
  }
}

class _MockRemoteFileService extends Mock implements RemoteFileService {}

class _ControlledDownloadService extends RemoteFileService {
  final started = Completer<void>();
  final completion = Completer<void>();
  RemoteFileDownloadCancelToken? cancelToken;

  @override
  Future<void> downloadFile({
    required SftpClient sftp,
    required String remotePath,
    required String localPath,
    FutureOr<void> Function(int downloadedBytes)? onProgress,
    int? maxBytes,
    RemoteFileDownloadCancelToken? cancelToken,
  }) async {
    this.cancelToken = cancelToken;
    File(localPath).writeAsBytesSync([1, 2, 3]);
    started.complete();
    await completion.future;
  }
}

class _PopObserver extends NavigatorObserver {
  int pops = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pops++;
  }
}

class _MockXFile extends Mock implements XFile {}

class _SftpFilePicker extends FilePickerPlatform {
  List<PlatformFile> files = [];
  Uri? saveDestination;
  Uint8List? savedBytes;
  bool failSave = false;
  Exception? pickError;
  Exception? saveError;

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    if (pickError != null) {
      throw pickError!;
    }
    return files;
  }

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    savedBytes = bytes;
    if (saveError != null) {
      throw saveError!;
    }
    if (failSave) {
      throw const FileSystemException('provider rejected save');
    }
    if (saveDestination?.scheme == 'file') {
      await File.fromUri(saveDestination!).writeAsBytes(bytes);
    }
    return saveDestination;
  }
}

class _MockSftpFile extends Mock implements SftpFile {}

class _MockMonetizationService extends Mock implements MonetizationService {
  _MockMonetizationService() {
    when(() => currentState).thenReturn(_proMonetizationState);
  }
}

SshSession _sftpSession(SSHClient client) => SshSession(
  connectionId: 7,
  hostId: 1,
  client: client,
  config: const SshConnectionConfig(
    hostname: 'demo.example.com',
    port: 22,
    username: 'demo',
  ),
);

class _TestActiveSessionsNotifier extends ActiveSessionsNotifier {
  _TestActiveSessionsNotifier(this.session);

  final SshSession session;

  @override
  Map<int, SshConnectionState> build() => <int, SshConnectionState>{
    session.connectionId: SshConnectionState.connected,
  };

  @override
  SshSession? getSession(int connectionId) =>
      connectionId == session.connectionId ? session : null;

  @override
  Future<void> syncBackgroundStatus() async {}
}

Widget _buildSftpTestApp({
  required SshSession session,
  required Widget child,
  RemoteFileService? remoteFileService,
  MonetizationService? monetizationService,
  NavigatorObserver? observer,
}) => ProviderScope(
  overrides: [
    if (remoteFileService != null)
      remoteFileServiceProvider.overrideWithValue(remoteFileService),
    activeSessionsProvider.overrideWith(
      () => _TestActiveSessionsNotifier(session),
    ),
    monetizationServiceProvider.overrideWithValue(
      monetizationService ?? _MockMonetizationService(),
    ),
    monetizationStateProvider.overrideWith(
      (ref) => Stream.value(_proMonetizationState),
    ),
  ],
  child: MaterialApp(home: child, navigatorObservers: [?observer]),
);

SftpFileAttrs _fileAttrs({int? size}) =>
    SftpFileAttrs(size: size, mode: const SftpFileMode.value(1 << 15));

SftpName _fileEntry(String name, {int? size}) => SftpName(
  filename: name,
  longname: name,
  attr: _fileAttrs(size: size),
);

class _SftpSelectionHost extends StatefulWidget {
  const _SftpSelectionHost({
    required this.hostId,
    required this.connectionId,
    required this.constraints,
  });

  final int hostId;
  final int connectionId;
  final RemoteFilePickerConstraints constraints;

  @override
  State<_SftpSelectionHost> createState() => _SftpSelectionHostState();
}

class _SftpSelectionHostState extends State<_SftpSelectionHost> {
  Object? _result = _pendingResult;
  bool _pickerOpen = true;

  @override
  Widget build(BuildContext context) => Navigator(
    pages: [
      MaterialPage<void>(
        key: const ValueKey<String>('selection-base'),
        child: Scaffold(
          body: Center(
            child: Text(switch (_result) {
              _PendingSelectionResult() => 'pending',
              null => 'cancelled',
              final List<RemoteFileSelection> files =>
                files.map((file) => file.remotePath).join('|'),
              final Object other => other.toString(),
            }),
          ),
        ),
      ),
      if (_pickerOpen)
        MaterialPage<void>(
          key: const ValueKey<String>('selection-picker'),
          child: SftpScreen(
            hostId: widget.hostId,
            connectionId: widget.connectionId,
            selectionConstraints: widget.constraints,
            showCloseButton: true,
          ),
        ),
    ],
    // ignore: deprecated_member_use
    onPopPage: (route, result) {
      if (!route.didPop(result)) {
        return false;
      }
      setState(() {
        _pickerOpen = false;
        _result = result;
      });
      return true;
    },
  );
}

class _PublicSftpSelectionHost extends StatefulWidget {
  const _PublicSftpSelectionHost({
    required this.hostId,
    required this.connectionId,
    required this.startDirectory,
  });

  final int hostId;
  final int connectionId;
  final String startDirectory;

  @override
  State<_PublicSftpSelectionHost> createState() =>
      _PublicSftpSelectionHostState();
}

class _PublicSftpSelectionHostState extends State<_PublicSftpSelectionHost> {
  List<RemoteFileSelection>? _result;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        const TextField(key: ValueKey('picker-source-field'), autofocus: true),
        FilledButton(
          onPressed: () async {
            final result = await showRemoteFilePicker(
              context: context,
              hostId: widget.hostId,
              connectionId: widget.connectionId,
              startDirectory: widget.startDirectory,
              constraints: const RemoteFilePickerConstraints(
                allowMultiple: true,
              ),
            );
            if (mounted) {
              setState(() => _result = result);
            }
          },
          child: const Text('Open remote picker'),
        ),
        Text(
          _result?.map((file) => file.remotePath).join('|') ?? 'no selection',
        ),
      ],
    ),
  );
}

class _PendingSelectionResult {
  const _PendingSelectionResult();
}

const _pendingResult = _PendingSelectionResult();

Future<_MockSftpClient> _pumpCrashlyticsBrowser(
  WidgetTester tester, {
  List<SftpName>? entries,
  RemoteFileService? remoteFiles,
}) async {
  final ssh = _MockSshClient();
  final sftp = _MockSftpClient();
  final monetization = _MockMonetizationService();
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
  when(() => monetization.currentState).thenReturn(_proMonetizationState);
  when(ssh.sftp).thenAnswer((_) async => sftp);
  when(() => sftp.absolute('.')).thenAnswer((_) async => '/home/demo');
  when(
    () => sftp.listdir('/home/demo'),
  ).thenAnswer((_) async => entries ?? [_fileEntry('notes.txt')]);
  if (remoteFiles is _MockRemoteFileService) {
    when(
      () => remoteFiles.resolveInitialDirectory(sftp),
    ).thenAnswer((_) async => '/home/demo');
  }
  await tester.pumpWidget(
    _buildSftpTestApp(
      session: session,
      monetizationService: monetization,
      remoteFileService: remoteFiles,
      child: const SftpScreen(hostId: 1, connectionId: 7),
    ),
  );
  await tester.pumpAndSettle();
  return sftp;
}

// Stream cancellation and filesystem IO can complete outside the widget test's
// fake clock. Drain both event loops until the operation reaches its observable
// outcome; pumpAndSettle alone can return before either has finished.
Future<void> _pumpUntilSftpState(
  WidgetTester tester,
  bool Function() isReady, {
  required String reason,
}) async {
  for (var attempt = 0; attempt < 500; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    if (isReady()) {
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  await tester.pump();
  expect(isReady(), isTrue, reason: reason);
}

void main() {
  setUpAll(() {
    registerFallbackValue(SftpFileOpenMode.read);
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(SftpFileAttrs());
  });

  group('SFTP path helpers', () {
    test('parentRemotePath resolves POSIX parents', () {
      expect(parentRemotePath('/tmp/monkeyssh'), '/tmp');
      expect(parentRemotePath('/tmp'), '/');
      expect(parentRemotePath('/'), '/');
    });

    test('parentRemotePath resolves Windows drive parents', () {
      expect(parentRemotePath('C:/Users/demo'), 'C:/Users');
      expect(parentRemotePath('C:/Users'), 'C:/');
      expect(parentRemotePath('C:/'), 'C:/');
      expect(parentRemotePath('/C:/Users/demo'), '/C:/Users');
      expect(parentRemotePath('/C:/Users'), '/C:/');
      expect(parentRemotePath('/C:/'), '/C:/');
    });

    test('breadcrumbs preserve Windows drive roots', () {
      expect(buildSftpBreadcrumbItems('C:/Users/demo'), [
        (path: 'C:/', label: 'C:/'),
        (path: 'C:/Users', label: 'Users'),
        (path: 'C:/Users/demo', label: 'demo'),
      ]);
      expect(buildSftpBreadcrumbItems('/C:/Users/demo'), [
        (path: '/C:/', label: '/C:/'),
        (path: '/C:/Users', label: 'Users'),
        (path: '/C:/Users/demo', label: 'demo'),
      ]);
    });

    test('pushSftpPathHistory appends new locations without duplicates', () {
      expect(pushSftpPathHistory(const ['/tmp'], '/tmp'), ['/tmp']);
      expect(pushSftpPathHistory(const ['/tmp'], '/tmp/monkeyssh'), [
        '/tmp',
        '/tmp/monkeyssh',
      ]);
    });

    test('popSftpPathHistory keeps at least one history entry', () {
      expect(popSftpPathHistory(const ['/']), ['/']);
      expect(popSftpPathHistory(const ['/', '/tmp', '/tmp/monkeyssh']), [
        '/',
        '/tmp',
      ]);
    });

    test('requested directories open directly without file highlighting', () {
      expect(
        resolveRequestedSftpNavigationTarget('/var/log', isDirectory: true),
        (directoryPath: '/var/log', highlightedFileName: null),
      );
    });

    test('requested files target their parent directory and file row', () {
      expect(
        resolveRequestedSftpNavigationTarget(
          '/var/log/app.log',
          isDirectory: false,
        ),
        (directoryPath: '/var/log', highlightedFileName: 'app.log'),
      );
    });

    test('location shortcuts normalize and de-duplicate paths', () {
      expect(
        resolveSftpLocationShortcuts(
          homeDirectory: '/home/depoll',
          connectionStartDirectory: '/home/depoll/./',
          tmuxPaneDirectory: '/home/depoll/project',
        ),
        ['/home/depoll', '/home/depoll/project'],
      );
    });

    test('location shortcuts keep Windows home directories', () {
      expect(
        resolveSftpLocationShortcuts(
          homeDirectory: r'C:\Users\depoll',
          connectionStartDirectory: 'C:/Users/depoll/./',
          tmuxPaneDirectory: 'C:/Users/depoll/project',
        ),
        ['C:/Users/depoll', 'C:/Users/depoll/project'],
      );
    });

    test('scrolls upward when the highlighted file is above the viewport', () {
      expect(
        resolveSftpHighlightedFileScrollOffset(
          highlightedIndex: 2,
          currentOffset: 300,
          itemExtentEstimate: 64,
          viewportExtent: 240,
          maxScrollExtent: 2000,
        ),
        112,
      );
    });

    test(
      'scrolls downward when the highlighted file is below the viewport',
      () {
        expect(
          resolveSftpHighlightedFileScrollOffset(
            highlightedIndex: 12,
            currentOffset: 120,
            itemExtentEstimate: 64,
            viewportExtent: 240,
            maxScrollExtent: 2000,
          ),
          608,
        );
      },
    );

    test(
      'keeps the current offset when the highlighted file is already visible',
      () {
        expect(
          resolveSftpHighlightedFileScrollOffset(
            highlightedIndex: 4,
            currentOffset: 180,
            itemExtentEstimate: 64,
            viewportExtent: 240,
            maxScrollExtent: 2000,
          ),
          180,
        );
      },
    );

    test('detects previewable image file names including svg', () {
      expect(isPreviewableImageFileName('screenshot.png'), isTrue);
      expect(isPreviewableImageFileName('diagram.svg'), isTrue);
      expect(isPreviewableImageFileName('notes.txt'), isFalse);
    });

    test('detects previewable video file names', () {
      expect(isPreviewableVideoFileName('screen-recording.mp4'), isTrue);
      expect(isPreviewableVideoFileName('clip.MOV'), isTrue);
      expect(isPreviewableVideoFileName('capture.m4v'), isTrue);
      expect(isPreviewableVideoFileName('browser.webm'), isTrue);
      expect(isPreviewableVideoFileName('notes.txt'), isFalse);
    });

    test('resolves video MIME candidates from file names', () {
      expect(remoteVideoMimeTypeForFileName('recording.mp4'), 'video/mp4');
      expect(
        remoteVideoMimeTypeForFileName('recording.mov'),
        'video/quicktime',
      );
      expect(remoteVideoMimeTypeForFileName('recording.m4v'), 'video/x-m4v');
      expect(remoteVideoMimeTypeForFileName('recording.webm'), 'video/webm');
      expect(remoteVideoMimeTypeForFileName('notes.txt'), isNull);
    });

    test('infers MIME types from previewable remote file names', () {
      expect(inferRemoteFileMimeType('diagram.svg'), 'image/svg+xml');
      expect(inferRemoteFileMimeType('photo.JPG'), 'image/jpeg');
      expect(inferRemoteFileMimeType('clip.webm'), 'video/webm');
      expect(inferRemoteFileMimeType('notes.txt'), isNull);
    });

    test('toggles remote file selection while preserving selection order', () {
      const alpha = RemoteFileSelection(
        remotePath: '/home/demo/alpha.txt',
        displayName: 'alpha.txt',
      );
      const beta = RemoteFileSelection(
        remotePath: '/home/demo/beta.txt',
        displayName: 'beta.txt',
      );

      expect(
        toggleRemoteFileSelection(
          currentSelection: const [alpha],
          file: beta,
          allowMultiple: true,
        ),
        const [alpha, beta],
      );
      expect(
        toggleRemoteFileSelection(
          currentSelection: const [alpha, beta],
          file: alpha,
          allowMultiple: true,
        ),
        const [beta],
      );
      expect(
        toggleRemoteFileSelection(
          currentSelection: const [alpha],
          file: beta,
          allowMultiple: false,
        ),
        const [beta],
      );
      expect(
        toggleRemoteFileSelection(
          currentSelection: const [beta],
          file: beta,
          allowMultiple: false,
        ),
        isEmpty,
      );
    });

    test(
      'describes disabled remote file selections from filters and limits',
      () {
        const alpha = RemoteFileSelection(
          remotePath: '/home/demo/alpha.txt',
          displayName: 'alpha.txt',
        );
        const beta = RemoteFileSelection(
          remotePath: '/home/demo/beta.txt',
          displayName: 'beta.txt',
        );
        const blocked = RemoteFileSelection(
          remotePath: '/home/demo/blocked.png',
          displayName: 'blocked.png',
        );
        final constraints = RemoteFilePickerConstraints(
          allowMultiple: true,
          maxSelectionCount: 1,
          selectionAvailability: (file) => file.displayName.endsWith('.png')
              ? 'Only text attachments are supported.'
              : null,
        );

        expect(
          resolveRemoteFileSelectionDisabledReason(
            constraints: constraints,
            currentSelection: const [alpha],
            candidate: beta,
          ),
          'You can select up to 1 file.',
        );
        expect(
          resolveRemoteFileSelectionDisabledReason(
            constraints: constraints,
            currentSelection: const [alpha],
            candidate: blocked,
          ),
          'Only text attachments are supported.',
        );
      },
    );

    test('builds selection semantics labels, hints, and touch tooltips', () {
      expect(
        remoteFileSelectionSemanticsLabel(
          isDirectory: true,
          fileName: 'docs',
          isSelected: false,
        ),
        'Open folder docs',
      );
      expect(
        remoteFileSelectionSemanticsHint(isDirectory: true, isSelected: false),
        'Opens this folder.',
      );
      expect(
        remoteFileSelectionSemanticsLabel(
          isDirectory: false,
          fileName: 'notes.txt',
          isSelected: false,
        ),
        'Select remote file notes.txt',
      );
      expect(
        remoteFileSelectionSemanticsHint(isDirectory: false, isSelected: true),
        'Removes this file from the current selection.',
      );
      expect(
        remoteFileSelectionTooltip(
          isDirectory: false,
          fileName: 'notes.txt',
          isSelected: true,
        ),
        'Deselect notes.txt',
      );
      expect(
        remoteFileSelectionTooltip(
          isDirectory: false,
          fileName: 'blocked.png',
          isSelected: false,
          disabledReason: 'Only text attachments are supported.',
        ),
        'blocked.png is unavailable: Only text attachments are supported.',
      );
    });

    test('rejects known oversized video previews', () {
      expect(
        isRemoteVideoPreviewSizeAllowed(maxRemoteVideoPreviewBytes),
        isTrue,
      );
      expect(
        isRemoteVideoPreviewSizeAllowed(maxRemoteVideoPreviewBytes + 1),
        isFalse,
      );

      expect(
        remoteVideoPreviewTooLargeMessage(
          sizeBytes: maxRemoteVideoPreviewBytes + 1,
        ),
        allOf(
          contains('Video is too large to preview here'),
          contains('100.0 MB'),
          contains('Download it instead'),
        ),
      );
    });

    test('detects svg file names', () {
      expect(isSvgFileName('diagram.svg'), isTrue);
      expect(isSvgFileName('diagram.SVG'), isTrue);
      expect(isSvgFileName('diagram.png'), isFalse);
    });

    test('detects video fixtures for placeholder icon coverage', () {
      expect(isPreviewableVideoFileName('demo.mp4'), isTrue);
      expect(isPreviewableVideoFileName('demo.MOV'), isTrue);
      expect(isPreviewableVideoFileName('demo.webm'), isTrue);
      expect(isPreviewableVideoFileName('demo.avi'), isFalse);
      expect(isPreviewableVideoFileName('demo.png'), isFalse);
      expect(
        resolveSftpFileIcon(isDirectory: false, filename: 'demo.mp4'),
        Icons.video_file,
      );
      expect(
        resolveSftpFileIcon(isDirectory: false, filename: 'diagram.svg'),
        Icons.image,
      );
    });

    test('builds shell-safe clipboard text for copied remote paths', () {
      expect(
        buildSftpCopyPathClipboardText(
          directory: '/home/demo/Project Files',
          filename: "today's notes.txt",
        ),
        r"'/home/demo/Project Files/today'\''s notes.txt'",
      );
    });

    test('blocks oversized image previews before reading remote bytes', () {
      expect(
        resolveSftpImagePreviewBlockMessage(byteCount: 10 * 1024 * 1024 + 1),
        'File is too large to preview here (max 10 MB)',
      );
      expect(
        resolveSftpImagePreviewBlockMessage(byteCount: 10 * 1024 * 1024),
        isNull,
      );
    });

    test('blocks oversized and binary text edits', () {
      expect(
        resolveSftpTextEditBlockMessage(byteCount: 1024 * 1024 + 1),
        'File is too large to edit here (max 1 MB)',
      );
      expect(
        resolveSftpTextEditBlockMessage(
          byteCount: 4,
          loadedBytes: Uint8List.fromList([0x66, 0x6f, 0x00, 0x6f]),
        ),
        'Binary files cannot be edited here',
      );
      expect(
        resolveSftpTextEditBlockMessage(
          byteCount: 5,
          loadedBytes: Uint8List.fromList('hello'.codeUnits),
        ),
        isNull,
      );
    });

    test('rejects picker names that can escape the upload directory', () {
      expect(validateSftpUploadFileName('notes.txt'), isNull);
      expect(validateSftpUploadFileName('..'), isNotNull);
      expect(validateSftpUploadFileName('../authorized_keys'), isNotNull);
      expect(validateSftpUploadFileName(r'..\authorized_keys'), isNotNull);
      expect(validateSftpUploadFileName('/tmp/payload'), isNotNull);
      expect(validateSftpUploadFileName('bad\x00name'), isNotNull);
    });

    test('does not echo unsafe upload names in validation feedback', () {
      expect(
        resolveUnsafeSftpUploadNameMessage([
          AppPlatformFile(name: '../authorized_keys', size: 0),
        ]),
        'The selected file has an unsafe name',
      );
      expect(
        resolveUnsafeSftpUploadNameMessage([
          AppPlatformFile(name: '../one', size: 0),
          AppPlatformFile(name: r'..\two', size: 0),
        ]),
        '2 selected files have unsafe names',
      );
    });

    test('validates new folder names before creating directories', () {
      expect(validateSftpDirectoryName(''), 'Folder name is required');
      expect(validateSftpDirectoryName('  '), 'Folder name is required');
      expect(
        validateSftpDirectoryName('nested/folder'),
        'Folder name cannot contain /',
      );
      expect(
        validateSftpDirectoryName('..'),
        'Choose a folder name, not a navigation shortcut',
      );
      expect(validateSftpDirectoryName('release'), isNull);
    });

    test('includes remote paths in copy and create feedback', () {
      expect(
        sftpCopyPathSnackBarMessage('/var/www/site config'),
        'Copied shell-safe path for "/var/www/site config"',
      );
      expect(
        sftpCreatedDirectorySnackBarMessage('/var/www/releases'),
        'Created folder "/var/www/releases"',
      );
    });

    test('bounds stale SFTP operations with a timeout', () async {
      final completer = Completer<String>();

      await expectLater(
        withSftpOperationTimeout(
          completer.future,
          timeout: const Duration(milliseconds: 1),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('describes stale SFTP timeout recovery', () {
      expect(
        sftpTimeoutMessage('listing "/home/demo"'),
        'Timed out listing "/home/demo". The SSH connection may be stale; reconnect and try again.',
      );
    });

    test('resolves directory taps as navigation', () {
      expect(
        resolveSftpFileTapIntent(isDirectory: true, filename: 'Documents'),
        SftpFileTapIntent.navigate,
      );
    });

    test('resolves image taps as preview', () {
      expect(
        resolveSftpFileTapIntent(isDirectory: false, filename: 'diagram.png'),
        SftpFileTapIntent.preview,
      );
    });

    test('resolves video taps as video preview', () {
      expect(
        resolveSftpFileTapIntent(
          isDirectory: false,
          filename: 'screen-recording.mp4',
        ),
        SftpFileTapIntent.previewVideo,
      );
    });

    test('resolves preview kind for row action availability', () {
      expect(
        resolveSftpPreviewKind(isDirectory: true, filename: 'clip.mp4'),
        isNull,
      );
      expect(
        resolveSftpPreviewKind(isDirectory: false, filename: 'diagram.png'),
        SftpPreviewKind.image,
      );
      expect(
        resolveSftpPreviewKind(isDirectory: false, filename: 'clip.webm'),
        SftpPreviewKind.video,
      );
      expect(
        resolveSftpPreviewKind(isDirectory: false, filename: 'notes.txt'),
        isNull,
      );
    });

    test('resolves other file taps as edit', () {
      expect(
        resolveSftpFileTapIntent(isDirectory: false, filename: 'notes.txt'),
        SftpFileTapIntent.edit,
      );
    });

    testWidgets('video preview errors show metadata and fallback actions', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: buildRemoteVideoPreviewErrorForTesting(
            fileName: 'screen-recording.mp4',
            remotePath: '/home/depoll/screen-recording.mp4',
            localPath: 'build/sftp-video-preview-test/screen-recording.mp4',
            errorMessage: 'Unsupported codec',
            sizeBytes: 42,
            modifiedAt: DateTime.utc(2024, 1, 2, 3, 4, 5),
            mimeType: 'video/mp4',
          ),
        ),
      );

      expect(find.text('Could not play video preview'), findsOneWidget);
      expect(find.text('Unsupported codec'), findsOneWidget);
      expect(
        find.text('/home/depoll/screen-recording.mp4'),
        findsAtLeastNWidgets(1),
      );
      expect(find.text('42 B'), findsOneWidget);
      expect(find.text('video/mp4'), findsOneWidget);
      expect(find.text('Cached copy'), findsOneWidget);
      expect(find.text('Save copy'), findsOneWidget);
      expect(find.text('Open/Share'), findsOneWidget);
    });

    testWidgets(
      'requested image files open directly and return to a highlighted row',
      (tester) async {
        final sshClient = _MockSshClient();
        final sftp = _MockSftpClient();
        final remoteFile = _MockSftpFile();
        final session = _sftpSession(sshClient);
        when(sshClient.sftp).thenAnswer((_) async => sftp);
        when(() => sftp.absolute('.')).thenAnswer((_) async => '/home/demo');
        when(() => sftp.stat('/home/demo/picture.png')).thenAnswer(
          (_) async => SftpFileAttrs(
            size: _onePixelPngBytes.length,
            mode: const SftpFileMode.value(1 << 15),
          ),
        );
        when(() => sftp.listdir('/home/demo')).thenAnswer(
          (_) async => [
            SftpName(
              filename: 'picture.png',
              longname: 'picture.png',
              attr: SftpFileAttrs(
                size: _onePixelPngBytes.length,
                mode: const SftpFileMode.value(1 << 15),
              ),
            ),
          ],
        );
        when(
          () => sftp.open('/home/demo/picture.png'),
        ).thenAnswer((_) async => remoteFile);
        when(
          () => remoteFile.readBytes(length: any(named: 'length')),
        ).thenAnswer((_) async => _onePixelPngBytes);
        when(remoteFile.close).thenAnswer((_) async {});

        await tester.pumpWidget(
          _buildSftpTestApp(
            session: session,
            child: const SftpScreen(
              hostId: 1,
              connectionId: 7,
              initialPath: '/home/demo/picture.png',
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('/home/demo/picture.png'), findsOneWidget);

        Navigator.of(tester.element(find.text('/home/demo/picture.png'))).pop();
        await tester.pumpAndSettle();

        final tile = tester.widget<ListTile>(
          find.ancestor(
            of: find.text('picture.png'),
            matching: find.byType(ListTile),
          ),
        );
        expect(tile.tileColor, isNotNull);
        verify(() => sftp.open('/home/demo/picture.png')).called(1);
      },
    );

    testWidgets('cancelling remote file picker returns null', (tester) async {
      final sshClient = _MockSshClient();
      final sftp = _MockSftpClient();
      final session = _sftpSession(sshClient);
      addTearDown(session.close);
      when(sshClient.sftp).thenAnswer((_) async => sftp);
      when(() => sftp.absolute('.')).thenAnswer((_) async => '/home/demo');
      when(
        () => sftp.listdir('/home/demo'),
      ).thenAnswer((_) async => [_fileEntry('notes.txt', size: 7)]);

      await tester.pumpWidget(
        _buildSftpTestApp(
          session: session,
          child: const _SftpSelectionHost(
            hostId: 1,
            connectionId: 7,
            constraints: RemoteFilePickerConstraints(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('cancelled'), findsOneWidget);
    });

    testWidgets(
      'public remote picker dismisses input, lists workspace files, and returns selection',
      (tester) async {
        final sshClient = _MockSshClient();
        final sftp = _MockSftpClient();
        final session = _sftpSession(sshClient);
        addTearDown(session.close);
        when(sshClient.sftp).thenAnswer((_) async => sftp);
        when(() => sftp.absolute('.')).thenAnswer((_) async => '/home/demo');
        when(() => sftp.stat('/repo')).thenAnswer(
          (_) async => SftpFileAttrs(mode: const SftpFileMode.value(1 << 14)),
        );
        when(
          () => sftp.listdir('/repo'),
        ).thenAnswer((_) async => [_fileEntry('notes.txt', size: 7)]);

        await tester.pumpWidget(
          _buildSftpTestApp(
            session: session,
            child: const _PublicSftpSelectionHost(
              hostId: 1,
              connectionId: 7,
              startDirectory: '/repo',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.testTextInput.isVisible, isTrue);

        await tester.tap(find.text('Open remote picker'));
        await tester.pump();
        await tester.pumpAndSettle();

        expect(tester.testTextInput.isVisible, isFalse);
        expect(find.textContaining('Select files'), findsOneWidget);
        verify(() => sftp.listdir('/repo')).called(1);
        expect(find.text('notes.txt'), findsOneWidget);
        await tester.tap(find.text('notes.txt'));
        await tester.pump();
        await tester.tap(find.widgetWithText(FilledButton, 'Select 1 file'));
        await tester.pumpAndSettle();

        expect(find.text('/repo/notes.txt'), findsOneWidget);
      },
    );

    for (final inaccessible in [false, true]) {
      testWidgets(
        'public picker recovers from a ${inaccessible ? 'denied' : 'missing'} starting directory',
        (tester) async {
          final sshClient = _MockSshClient();
          final sftp = _MockSftpClient();
          final session = _sftpSession(sshClient);
          addTearDown(session.close);
          when(sshClient.sftp).thenAnswer((_) async => sftp);
          when(() => sftp.absolute('.')).thenAnswer((_) async => '/home/demo');
          if (inaccessible) {
            when(() => sftp.stat('/repo')).thenAnswer(
              (_) async =>
                  SftpFileAttrs(mode: const SftpFileMode.value(1 << 14)),
            );
            when(() => sftp.listdir('/repo')).thenThrow(
              SftpStatusError(SftpStatusCode.permissionDenied, 'denied'),
            );
          } else {
            when(
              () => sftp.stat('/repo'),
            ).thenThrow(SftpStatusError(SftpStatusCode.noSuchFile, 'missing'));
          }
          when(() => sftp.listdir('/')).thenAnswer(
            (_) async => [
              SftpName(
                filename: 'fallback',
                longname: 'fallback',
                attr: SftpFileAttrs(mode: const SftpFileMode.value(1 << 14)),
              ),
            ],
          );
          when(
            () => sftp.listdir('/fallback'),
          ).thenAnswer((_) async => [_fileEntry('notes.txt', size: 7)]);
          await tester.pumpWidget(
            _buildSftpTestApp(
              session: session,
              child: const _PublicSftpSelectionHost(
                hostId: 1,
                connectionId: 7,
                startDirectory: '/repo',
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Open remote picker'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.textContaining('Select files'), findsOneWidget);
          await tester.tap(find.text('fallback'));
          await tester.pumpAndSettle();
          expect(find.text('notes.txt'), findsOneWidget);
          if (inaccessible) {
            await tester.tap(find.text('Cancel'));
            await tester.pumpAndSettle();
            expect(find.text('no selection'), findsOneWidget);
          } else {
            await tester.tap(find.text('notes.txt'));
            await tester.pump();
            await tester.tap(
              find.widgetWithText(FilledButton, 'Select 1 file'),
            );
            await tester.pumpAndSettle();
            expect(find.text('/fallback/notes.txt'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final fails in [false, true]) {
      testWidgets(
        'video cancellation pops once when download ${fails ? 'fails' : 'succeeds'} during exit',
        (tester) async {
          final directory = Directory.systemTemp.createTempSync(
            'sftp-cache-test-',
          );
          addTearDown(() => directory.deleteSync(recursive: true));
          const channel = MethodChannel('plugins.flutter.io/path_provider');
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            (_) async => directory.path,
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null),
          );
          final sshClient = _MockSshClient();
          final sftp = _MockSftpClient();
          final session = _sftpSession(sshClient);
          addTearDown(session.close);
          when(sshClient.sftp).thenAnswer((_) async => sftp);
          when(() => sftp.absolute('.')).thenAnswer((_) async => '/home/demo');
          when(
            () => sftp.listdir('/home/demo'),
          ).thenAnswer((_) async => [_fileEntry('clip.mp4', size: 3)]);
          // Create completers in the runAsync zone where they are awaited.
          final service = (await tester.runAsync(
            () async => _ControlledDownloadService(),
          ))!;
          final observer = _PopObserver();
          await tester.pumpWidget(
            _buildSftpTestApp(
              session: session,
              remoteFileService: service,
              observer: observer,
              child: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) =>
                            const SftpScreen(hostId: 1, connectionId: 7),
                      ),
                    ),
                    child: const Text('Open browser'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open browser'));
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            await tester.tap(find.text('clip.mp4'));
            await service.started.future.timeout(const Duration(seconds: 5));
          });
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));
          expect(find.text('Loading video preview'), findsOneWidget);
          await tester.tap(find.text('Cancel'));
          expect(observer.pops, 1);
          expect(
            () => service.cancelToken!.throwIfCancelled(),
            throwsA(isA<RemoteFileDownloadCancelledException>()),
          );
          await tester.runAsync(() async {
            if (fails) {
              service.completion.completeError(
                const FileSystemException('write failed'),
              );
            } else {
              service.completion.complete();
            }
            await Future<void>.delayed(const Duration(milliseconds: 20));
          });
          await tester.pump();
          expect(observer.pops, 1);
          expect(find.text('Loading video preview'), findsOneWidget);
          await tester.pumpAndSettle();
          expect(find.byType(SftpScreen), findsOneWidget);
          expect(find.text('Video preview cancelled'), findsOneWidget);
          expect(
            directory.listSync(recursive: true).whereType<File>(),
            isEmpty,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('normal mode still previews tapped image files', (
      tester,
    ) async {
      final sshClient = _MockSshClient();
      final sftp = _MockSftpClient();
      final remoteFile = _MockSftpFile();
      final session = _sftpSession(sshClient);
      addTearDown(session.close);
      when(sshClient.sftp).thenAnswer((_) async => sftp);
      when(() => sftp.absolute('.')).thenAnswer((_) async => '/home/demo');
      when(() => sftp.listdir('/home/demo')).thenAnswer(
        (_) async => [
          _fileEntry('picture.png', size: _onePixelPngBytes.length),
        ],
      );
      when(
        () => sftp.open('/home/demo/picture.png'),
      ).thenAnswer((_) async => remoteFile);
      when(
        () => remoteFile.readBytes(length: any(named: 'length')),
      ).thenAnswer((_) async => _onePixelPngBytes);
      when(remoteFile.close).thenAnswer((_) async {});

      await tester.pumpWidget(
        _buildSftpTestApp(
          session: session,
          child: const SftpScreen(hostId: 1, connectionId: 7),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('picture.png'));
      await tester.pumpAndSettle();

      expect(find.text('/home/demo/picture.png'), findsOneWidget);
      verify(() => sftp.open('/home/demo/picture.png')).called(1);
    });

    testWidgets('normal mode shows 0 B for files with unknown size', (
      tester,
    ) async {
      final sshClient = _MockSshClient();
      final sftp = _MockSftpClient();
      final session = _sftpSession(sshClient);
      addTearDown(session.close);
      when(sshClient.sftp).thenAnswer((_) async => sftp);
      when(() => sftp.absolute('.')).thenAnswer((_) async => '/home/demo');
      when(
        () => sftp.listdir('/home/demo'),
      ).thenAnswer((_) async => [_fileEntry('notes.txt')]);

      await tester.pumpWidget(
        _buildSftpTestApp(
          session: session,
          child: const SftpScreen(hostId: 1, connectionId: 7),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('notes.txt'), findsOneWidget);
      expect(find.text('0 B'), findsOneWidget);
    });

    testWidgets('handles stale SSH errors while opening the browser', (
      tester,
    ) async {
      final sshClient = _MockSshClient();
      final session = _sftpSession(sshClient);
      when(sshClient.sftp).thenThrow(SSHStateError('Transport is closed'));
      addTearDown(session.close);

      await tester.pumpWidget(
        _buildSftpTestApp(
          session: session,
          child: const SftpScreen(hostId: 1, connectionId: 7),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          'SFTP connection failed. Check the connection and try again.',
        ),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });

    for (final replacementReady in [false, true]) {
      for (final oldOutcome in ['client', 'error', 'timeout']) {
        testWidgets('failed SFTP browser waiter preserves '
            '${replacementReady ? 'cached' : 'pending'} replacement '
            'after late $oldOutcome and Retry', (tester) async {
          final sshClient = _MockSshClient();
          final oldClient = _MockSftpClient();
          final replacement = _MockSftpClient();
          final oldOpen = Completer<SftpClient>();
          final newOpen = Completer<SftpClient>();
          final session = _sftpSession(sshClient);
          addTearDown(session.close);
          var opens = 0;
          when(
            sshClient.sftp,
          ).thenAnswer((_) => opens++ == 0 ? oldOpen.future : newOpen.future);
          when(
            () => replacement.absolute('.'),
          ).thenAnswer((_) async => '/home/demo');
          when(
            () => replacement.listdir('/home/demo'),
          ).thenAnswer((_) async => [_fileEntry('replacement.txt')]);

          // The browser joins another consumer's shared pending open.
          final oldFuture = session.sftp();
          await tester.pumpWidget(
            _buildSftpTestApp(
              session: session,
              child: const SftpScreen(hostId: 1, connectionId: 7),
            ),
          );
          await tester.pump();
          expect(opens, 1);

          // That consumer times out and starts a replacement while the
          // browser still awaits the old open.
          session.discardSftpOpen(oldFuture);
          final next = session.sftp();
          if (replacementReady) {
            newOpen.complete(replacement);
            await tester.pump();
            expect(await next, same(replacement));
          }

          if (oldOutcome == 'timeout') {
            await tester.pump(const Duration(seconds: 11));
          } else if (oldOutcome == 'error') {
            oldOpen.completeError(SSHStateError('Old channel failed'));
          } else {
            oldOpen.complete(oldClient);
          }
          await tester.pumpAndSettle();

          // Exercise _handleConnectFailure, including its null-client
          // cleanup, rather than stopping at the service's rejected future.
          expect(
            find.text(
              oldOutcome == 'timeout'
                  ? sftpTimeoutMessage('opening the SFTP browser')
                  : 'SFTP connection failed. Check the connection and try again.',
            ),
            findsOneWidget,
          );
          if (!replacementReady) {
            expect(session.sftp(), same(next));
            newOpen.complete(replacement);
            await tester.pump();
          }
          expect(await next, same(replacement));
          if (oldOutcome == 'timeout') {
            oldOpen.complete(oldClient);
            await tester.pump();
          }
          expect(await session.sftp(), same(replacement));
          verifyNever(replacement.close);
          if (oldOutcome != 'error') {
            verify(oldClient.close).called(1);
          }

          await tester.tap(find.text('Retry'));
          await tester.pumpAndSettle();
          expect(find.text('replacement.txt'), findsOneWidget);
          expect(opens, 2);
          verifyNever(replacement.close);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }

    for (final outcome in ['success', 'failure', 'timeout', 'reconnect']) {
      testWidgets('newer navigation supersedes older $outcome', (tester) async {
        final sshClient = _MockSshClient();
        final sftp = _MockSftpClient();
        final freshSftp = _MockSftpClient();
        final older = Completer<List<SftpName>>();
        final newer = Completer<List<SftpName>>();
        final reconnect = Completer<SftpClient>();
        final session = _sftpSession(sshClient);
        addTearDown(session.close);
        var opens = 0;
        when(sshClient.sftp).thenAnswer(
          (_) => opens++ == 0 ? Future.value(sftp) : reconnect.future,
        );
        when(() => sftp.absolute('.')).thenAnswer((_) async => '/home/demo');
        when(
          () => sftp.listdir('/home/demo'),
        ).thenAnswer((_) async => [_fileEntry('initial.txt')]);
        when(() => sftp.listdir('/home')).thenAnswer((_) => older.future);
        when(() => sftp.listdir('/')).thenAnswer((_) => newer.future);
        when(() => freshSftp.listdir('/')).thenAnswer((_) => newer.future);
        when(
          () => freshSftp.listdir('/home/demo'),
        ).thenAnswer((_) async => [_fileEntry('initial.txt')]);
        await tester.pumpWidget(
          _buildSftpTestApp(
            session: session,
            child: const SftpScreen(hostId: 1, connectionId: 7),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('home'));
        await tester.pump();
        if (outcome == 'reconnect') {
          older.completeError(SSHStateError('closed'));
          await tester.pump();
        }
        await tester.tap(find.text('/'));
        await tester.pump();
        if (outcome == 'reconnect') {
          reconnect.complete(freshSftp);
          await tester.pump();
        }
        newer.complete([_fileEntry('newer.txt')]);
        await tester.pumpAndSettle();
        if (outcome == 'success') {
          older.complete([_fileEntry('older.txt')]);
        } else if (outcome == 'failure') {
          older.completeError(SSHStateError('stale failure'));
        } else if (outcome == 'timeout') {
          older.completeError(TimeoutException('stale timeout'));
        }
        await tester.pumpAndSettle();
        expect(find.text('newer.txt'), findsOneWidget);
        expect(find.text('older.txt'), findsNothing);
        expect(find.text('home'), findsNothing);
        expect(opens, outcome == 'reconnect' ? 2 : 1);
        verifyNever(() => freshSftp.listdir('/home'));
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(find.text('initial.txt'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    for (final code in [
      SftpStatusCode.failure,
      SftpStatusCode.permissionDenied,
      SftpStatusCode.noSuchFile,
    ]) {
      testWidgets('directory delete reports SFTP status $code', (tester) async {
        final sftp = await _pumpCrashlyticsBrowser(
          tester,
          entries: [
            SftpName(
              filename: 'folder',
              longname: 'folder',
              attr: SftpFileAttrs(mode: const SftpFileMode.value(1 << 14)),
            ),
          ],
        );
        final deletion = Completer<void>();
        when(
          () => sftp.rmdir('/home/demo/folder'),
        ).thenAnswer((_) => deletion.future);
        await tester.longPress(find.text('folder'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'Delete'));
        await tester.pumpAndSettle();
        expect(find.text('Deleted "folder"'), findsNothing);
        deletion.completeError(SftpStatusError(code, 'delete rejected'));
        await tester.pumpAndSettle();
        expect(
          find.text(
            code == SftpStatusCode.noSuchFile
                ? 'Item no longer exists. Refresh the folder and try again.'
                : 'Could not delete folder. Make sure it is empty and you have permission.',
          ),
          findsOneWidget,
        );
        expect(find.text('folder'), findsOneWidget);
        expect(tester.takeException(), isNull);
        verify(() => sftp.rmdir('/home/demo/folder')).called(1);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('upload picker platform failure returns with feedback', (
      tester,
    ) async {
      final picker = _SftpFilePicker()
        ..pickError = PlatformException(code: 'provider_failed');
      final previous = FilePickerPlatform.instance;
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = previous);
      final sftp = await _pumpCrashlyticsBrowser(tester);
      await tester.tap(find.byTooltip('Upload files'));
      await tester.pumpAndSettle();
      expect(
        find.text('Could not open the file picker. Try again.'),
        findsOneWidget,
      );
      verifyNever(() => sftp.open(any(), mode: any(named: 'mode')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    for (final failure in <Object>[
      SftpStatusError(SftpStatusCode.permissionDenied, 'denied'),
      SSHStateError('closed'),
      Exception('upload failed'),
      NoSuchMethodError.withInvocation(Object(), Invocation.method(#write, [])),
    ]) {
      for (final hasEarlierSuccess in [false, true]) {
        testWidgets('upload handles ${failure.runtimeType} and stops the batch'
            '${hasEarlierSuccess ? ' after an earlier success' : ''}', (
          tester,
        ) async {
          final picker = _SftpFilePicker()
            ..files = [
              AppPlatformFile(
                name: 'first.txt',
                bytes: Uint8List.fromList([1]),
              ),
              AppPlatformFile(
                name: 'second.txt',
                bytes: Uint8List.fromList([2]),
              ),
              if (hasEarlierSuccess)
                AppPlatformFile(
                  name: 'third.txt',
                  bytes: Uint8List.fromList([3]),
                ),
            ];
          final previous = FilePickerPlatform.instance;
          FilePickerPlatform.instance = picker;
          addTearDown(() => FilePickerPlatform.instance = previous);
          final sftp = await _pumpCrashlyticsBrowser(tester);
          final failedFile = _MockSftpFile();
          final failedName = hasEarlierSuccess ? 'second.txt' : 'first.txt';
          final skippedName = hasEarlierSuccess ? 'third.txt' : 'second.txt';
          final successfulFile = _MockSftpFile();
          if (hasEarlierSuccess) {
            when(
              () => sftp.open('/home/demo/first.txt', mode: any(named: 'mode')),
            ).thenAnswer((_) async => successfulFile);
            when(
              () => successfulFile.writeBytes(
                any(),
                offset: any(named: 'offset'),
              ),
            ).thenAnswer((_) async {});
            when(successfulFile.close).thenAnswer((_) async {});
            when(
              () => sftp.setStat('/home/demo/first.txt', any()),
            ).thenAnswer((_) async {});
          }
          when(
            () => sftp.open('/home/demo/$failedName', mode: any(named: 'mode')),
          ).thenAnswer((_) async => failedFile);
          when(
            () => failedFile.writeBytes(any(), offset: any(named: 'offset')),
          ).thenAnswer((_) => Future<void>.error(failure));
          when(failedFile.close).thenAnswer((_) async {});
          final message = hasEarlierSuccess
              ? 'Uploaded 1 of 3 files. Upload failed. Check the connection and try again.'
              : 'Upload failed. Check the connection and try again.';
          await tester.tap(find.byTooltip('Upload files'));
          await _pumpUntilSftpState(
            tester,
            () => find.text(message).evaluate().isNotEmpty,
            reason: 'The failed write must reach the upload failure SnackBar.',
          );
          await tester.pumpAndSettle();
          expect(
            find.descendant(
              of: find.byType(SnackBar),
              matching: find.text(message),
            ),
            findsOneWidget,
          );
          expect(
            find.text('Uploaded ${picker.files.length} files'),
            findsNothing,
          );
          verify(() => failedFile.writeBytes(any())).called(1);
          verify(failedFile.close).called(1);
          verifyNever(() => sftp.setStat('/home/demo/$failedName', any()));
          verifyNever(
            () =>
                sftp.open('/home/demo/$skippedName', mode: any(named: 'mode')),
          );
          if (hasEarlierSuccess) {
            verify(() => successfulFile.writeBytes(any())).called(1);
            verify(successfulFile.close).called(1);
            verify(() => sftp.setStat('/home/demo/first.txt', any())).called(1);
          }
          verify(
            () => sftp.listdir('/home/demo'),
          ).called(hasEarlierSuccess ? 2 : 1);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }

    testWidgets('copy path platform failure is handled', (tester) async {
      await _pumpCrashlyticsBrowser(tester);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            throw PlatformException(code: 'clipboard_unavailable');
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.longPress(find.text('notes.txt'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy as path'));
      await tester.pumpAndSettle();
      expect(find.text('Could not copy the path. Try again.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    for (final action in ['rename', 'mkdir', 'delete', 'open']) {
      testWidgets('$action handles asynchronous SSH errors', (tester) async {
        final sftp = await _pumpCrashlyticsBrowser(tester);
        final failure = SSHStateError('transport closed');
        when(
          () => sftp.rename('/home/demo/notes.txt', '/home/demo/renamed.txt'),
        ).thenAnswer((_) => Future<void>.error(failure));
        when(
          () => sftp.mkdir('/home/demo/new-folder'),
        ).thenAnswer((_) => Future<void>.error(failure));
        when(
          () => sftp.remove('/home/demo/notes.txt'),
        ).thenAnswer((_) => Future<void>.error(failure));
        when(
          () => sftp.open('/home/demo/notes.txt'),
        ).thenAnswer((_) => Future<SftpFile>.error(failure));
        if (action == 'mkdir') {
          await tester.tap(find.byTooltip('New folder'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), 'new-folder');
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(FilledButton, 'Create'));
        } else if (action == 'open') {
          await tester.tap(find.text('notes.txt'));
        } else {
          await tester.longPress(find.text('notes.txt'));
          await tester.pumpAndSettle();
          await tester.tap(find.text(action == 'rename' ? 'Rename' : 'Delete'));
          await tester.pumpAndSettle();
          if (action == 'rename') {
            await tester.enterText(find.byType(TextField), 'renamed.txt');
            await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
          } else {
            await tester.tap(find.widgetWithText(TextButton, 'Delete'));
          }
        }
        await tester.pumpAndSettle();
        expect(
          find.text(switch (action) {
            'rename' =>
              'Could not rename item. Check permissions and try again.',
            'mkdir' =>
              'Could not create folder. Check permissions and try again.',
            'delete' =>
              'Could not delete item. Check permissions and try again.',
            _ => 'Could not save changes. Check permissions and try again.',
          }),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets(
      'video cancellation owns a failed remote close and removes cache',
      (tester) async {
        final directory = Directory.systemTemp.createTempSync(
          'sftp-cancel-test-',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        const channel = MethodChannel('plugins.flutter.io/path_provider');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (_) async => directory.path,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        final sftp = await _pumpCrashlyticsBrowser(
          tester,
          entries: [_fileEntry('movie.mp4', size: 10)],
        );
        final file = _MockSftpFile();
        final reading = Completer<void>();
        final stream = StreamController<Uint8List>();
        when(
          () => sftp.open('/home/demo/movie.mp4'),
        ).thenAnswer((_) async => file);
        when(file.read).thenAnswer((_) {
          reading.complete();
          return stream.stream;
        });
        when(file.close).thenAnswer((_) async {
          stream.addError(SSHStateError('read closed'));
          await stream.close();
          // ignore: only_throw_errors, dartssh2 models SSH errors as interfaces.
          throw SSHStateError('close failed');
        });
        await tester.tap(find.text('movie.mp4'));
        await _pumpUntilSftpState(
          tester,
          () =>
              reading.isCompleted &&
              directory.listSync(recursive: true).whereType<File>().isNotEmpty,
          reason:
              'The preview must start reading and create a cache before cancellation.',
        );
        expect(find.text('Loading video preview'), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await _pumpUntilSftpState(
          tester,
          () => find.text('Video preview cancelled').evaluate().isNotEmpty,
          reason:
              'Cancellation must finish remote-close and local-cache cleanup.',
        );
        await tester.pumpAndSettle();
        expect(find.text('Video preview cancelled'), findsOneWidget);
        expect(find.text('Loading video preview'), findsNothing);
        expect(find.text('movie.mp4'), findsOneWidget);
        expect(directory.listSync(recursive: true).whereType<File>(), isEmpty);
        verify(file.close).called(1);
        expect(stream.hasListener, isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    for (final failRead in [false, true]) {
      testWidgets(
        'upload keeps its directory and handles stream failure: $failRead',
        (tester) async {
          final sshClient = _MockSshClient();
          final sftp = _MockSftpClient();

          final remoteFiles = _MockRemoteFileService();
          final session = _sftpSession(sshClient);
          addTearDown(session.close);
          final picker = _SftpFilePicker();
          final previous = FilePickerPlatform.instance;
          FilePickerPlatform.instance = picker;
          addTearDown(() => FilePickerPlatform.instance = previous);
          final broken = _MockXFile();
          when(broken.length).thenAnswer((_) async => 1);
          when(broken.openRead).thenAnswer(
            (_) => Stream.error(const FileSystemException('read failed')),
          );
          picker.files = [
            AppPlatformFile(name: 'first.txt', bytes: Uint8List.fromList([1])),
            if (failRead)
              AppPlatformFile(name: 'second.txt', xFile: broken)
            else
              AppPlatformFile(
                name: 'second.txt',
                bytes: Uint8List.fromList([2]),
              ),
            if (failRead)
              AppPlatformFile(
                name: 'third.txt',
                bytes: Uint8List.fromList([3]),
              ),
          ];
          when(sshClient.sftp).thenAnswer((_) async => sftp);
          when(() => sftp.absolute('.')).thenAnswer((_) async => '/home/demo');
          when(
            () => sftp.listdir(any()),
          ).thenAnswer((_) async => [_fileEntry('notes.txt')]);
          when(
            () => remoteFiles.resolveInitialDirectory(sftp),
          ).thenAnswer((_) async => '/home/demo');
          registerFallbackValue(const Stream<List<int>>.empty());
          final firstUpload = Completer<void>();
          final destinations = <String>[];
          final contents = <List<int>>[];
          when(
            () => remoteFiles.uploadStream(
              sftp: sftp,
              remotePath: any(named: 'remotePath'),
              stream: any(named: 'stream'),
            ),
          ).thenAnswer((invocation) async {
            destinations.add(invocation.namedArguments[#remotePath] as String);
            contents.add(
              await (invocation.namedArguments[#stream] as Stream<List<int>>)
                  .expand((chunk) => chunk)
                  .toList(),
            );
            if (destinations.length == 1) {
              await firstUpload.future;
            }
          });
          await tester.pumpWidget(
            _buildSftpTestApp(
              session: session,
              remoteFileService: remoteFiles,
              child: const SftpScreen(hostId: 1, connectionId: 7),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Upload files'));
          await tester.pump();
          expect(destinations, ['/home/demo/first.txt']);
          await tester.tap(find.text('home'));
          await tester.pumpAndSettle();
          firstUpload.complete();
          await tester.pumpAndSettle();
          expect(destinations, [
            '/home/demo/first.txt',
            '/home/demo/second.txt',
          ]);
          // Navigation lists /home once; batch completion refreshes it again,
          // including when only the first file was uploaded successfully.
          verify(() => sftp.listdir('/home')).called(2);
          expect(
            contents,
            failRead
                ? [
                    [1],
                  ]
                : [
                    [1],
                    [2],
                  ],
          );
          expect(
            find.text(
              failRead
                  ? 'Uploaded 1 of 3 files. '
                        'Upload failed. Check the connection and try again.'
                  : 'Uploaded 2 files',
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }

    testWidgets('reopens SFTP when the directory channel goes stale', (
      tester,
    ) async {
      final sshClient = _MockSshClient();
      final staleSftp = _MockSftpClient();
      final freshSftp = _MockSftpClient();
      final session = _sftpSession(sshClient);
      var sftpOpenAttempts = 0;
      when(sshClient.sftp).thenAnswer((_) async {
        sftpOpenAttempts++;
        return sftpOpenAttempts == 1 ? staleSftp : freshSftp;
      });
      when(() => staleSftp.absolute('.')).thenAnswer((_) async => '/home/demo');
      when(
        () => staleSftp.listdir('/home/demo'),
      ).thenThrow(SSHStateError('Connection closed'));
      when(staleSftp.close).thenAnswer((_) async {});
      when(() => freshSftp.listdir('/home/demo')).thenAnswer(
        (_) async => [
          SftpName(
            filename: 'notes.txt',
            longname: 'notes.txt',
            attr: SftpFileAttrs(mode: const SftpFileMode.value(1 << 15)),
          ),
        ],
      );

      await tester.pumpWidget(
        _buildSftpTestApp(
          session: session,
          child: const SftpScreen(hostId: 1, connectionId: 7),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('notes.txt'), findsOneWidget);
      expect(sftpOpenAttempts, 2);
      verify(staleSftp.close).called(1);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('opens a Windows remote home directory from SFTP realpath', (
      tester,
    ) async {
      final sshClient = _MockSshClient();
      final sftp = _MockSftpClient();

      final session = SshSession(
        connectionId: 7,
        hostId: 1,
        client: sshClient,
        config: const SshConnectionConfig(
          hostname: 'windows.example.com',
          port: 22,
          username: 'demo',
        ),
      );
      when(sshClient.sftp).thenAnswer((_) async => sftp);
      when(() => sftp.absolute('.')).thenAnswer((_) async => r'C:\Users\demo');
      when(() => sftp.listdir('C:/Users/demo')).thenAnswer(
        (_) async => [
          SftpName(
            filename: 'Documents',
            longname: 'Documents',
            attr: SftpFileAttrs(mode: const SftpFileMode.value(1 << 14)),
          ),
          SftpName(
            filename: 'notes.txt',
            longname: 'notes.txt',
            attr: SftpFileAttrs(mode: const SftpFileMode.value(1 << 15)),
          ),
        ],
      );

      await tester.pumpWidget(
        _buildSftpTestApp(
          session: session,
          child: const SftpScreen(hostId: 1, connectionId: 7),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('C:/'), findsOneWidget);
      expect(find.text('Users'), findsOneWidget);
      expect(find.text('demo'), findsOneWidget);
      expect(find.text('Documents'), findsOneWidget);
      expect(find.text('notes.txt'), findsOneWidget);
      verify(() => sftp.listdir('C:/Users/demo')).called(1);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    for (final destination in [
      'file',
      'content',
      'android-path',
      'cancel',
      'failure',
      'picker-platform-failure',
      'share-platform-failure',
      'large-desktop',
      'large-mobile',
      'share-cancel',
    ]) {
      testWidgets('video export preserves bytes and cleans up: $destination', (
        tester,
      ) async {
        final cacheDirectory = Directory.systemTemp.createTempSync(
          'sftp-export-test-',
        );
        addTearDown(() => cacheDirectory.deleteSync(recursive: true));
        final cachedFile = File('${cacheDirectory.path}/cached-preview.mp4')
          ..writeAsBytesSync([1, 2, 3]);
        final large =
            destination.startsWith('large-') ||
            destination == 'share-cancel' ||
            destination == 'share-platform-failure';
        final mobileShare =
            destination == 'large-mobile' ||
            destination == 'share-cancel' ||
            destination == 'share-platform-failure';
        if (large) {
          cachedFile.openSync(mode: FileMode.append)
            ..truncateSync(10 * 1024 * 1024 + 1)
            ..closeSync();
        }
        final exportedFile = File('${cacheDirectory.path}/export.mp4');
        final picker = _SftpFilePicker()
          ..failSave = destination == 'failure'
          ..saveError = destination == 'picker-platform-failure'
              ? PlatformException(code: 'save_failed')
              : null
          ..saveDestination = switch (destination) {
            'content' => Uri.parse('content://documents/primary/export.mp4'),
            'android-path' => Uri.parse('/document/primary:export.mp4'),
            'cancel' => null,
            _ => exportedFile.absolute.uri,
          };
        final previous = FilePickerPlatform.instance;
        FilePickerPlatform.instance = picker;
        addTearDown(() => FilePickerPlatform.instance = previous);
        final shareCalls = <MethodCall>[];
        const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          shareChannel,
          (call) async {
            shareCalls.add(call);
            if (destination == 'share-platform-failure') {
              throw PlatformException(code: 'share_failed');
            }
            return destination == 'share-cancel' ? '' : 'saved';
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            shareChannel,
            null,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              platform: destination == 'large-desktop'
                  ? TargetPlatform.linux
                  : TargetPlatform.android,
            ),
            home: buildRemoteVideoPreviewErrorForTesting(
              fileName: 'cached-preview.mp4',
              remotePath: '/home/depoll/cached-preview.mp4',
              localPath: cachedFile.path,
              errorMessage: 'Unsupported codec',
              sizeBytes: 3,
              mimeType: 'video/mp4',
            ),
          ),
        );
        expect(cachedFile.existsSync(), isTrue);
        final saveButton = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'Save copy'),
        );
        await tester.runAsync(saveButton.onPressed! as Future<void> Function());
        await tester.pumpAndSettle();
        if (mobileShare) {
          expect(picker.savedBytes, isNull);
          expect(shareCalls, hasLength(1));
          expect((shareCalls.single.arguments as Map)['paths'], [
            cachedFile.path,
          ]);
        } else {
          expect(picker.savedBytes, large ? isEmpty : [1, 2, 3]);
          expect(shareCalls, isEmpty);
        }
        if (destination == 'file') {
          expect(exportedFile.readAsBytesSync(), [1, 2, 3]);
        } else if (destination == 'large-desktop') {
          expect(exportedFile.lengthSync(), 10 * 1024 * 1024 + 1);
          expect(exportedFile.readAsBytesSync().take(3), [1, 2, 3]);
        }
        if ([
          'file',
          'content',
          'android-path',
          'large-desktop',
        ].contains(destination)) {
          expect(find.text('Saved "cached-preview.mp4"'), findsOneWidget);
        } else if ([
          'failure',
          'picker-platform-failure',
          'share-platform-failure',
        ].contains(destination)) {
          expect(
            find.text('Could not export the file. Try again.'),
            findsOneWidget,
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
        expect(cachedFile.existsSync(), destination == 'large-mobile');
        if (destination == 'file') {
          expect(exportedFile.readAsBytesSync(), [1, 2, 3]);
        }
      });
    }
  });
}
