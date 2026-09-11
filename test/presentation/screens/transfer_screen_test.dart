import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/presentation/models/app_platform_file.dart';
import 'package:monkeyssh/presentation/screens/transfer_screen.dart';
import 'package:monkeyssh/presentation/widgets/file_picker_helpers.dart';

import 'package:package_info_plus/package_info_plus.dart';

class _MockXFile extends Mock implements XFile {}

class _TransferFilePicker extends FilePickerPlatform {
  PlatformFile? selectedFile;
  int selections = 0;
  Future<Uri?> Function(Uint8List)? save;

  @override
  Future<PlatformFile?> pickFile({
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
    selections++;
    return selectedFile;
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
  }) => save!(bytes);
}

class _MockAuthService extends Mock implements AuthService {}

class _UnlockedAuthStateNotifier extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.unlocked;
}

void main() {
  late _MockAuthService authService;
  late ProviderContainer container;
  late BuildContext context;

  setUp(() {
    authService = _MockAuthService();
    container = ProviderContainer(
      overrides: [
        authStateProvider.overrideWith(_UnlockedAuthStateNotifier.new),
      ],
    );
  });

  tearDown(() {
    container.dispose();
  });

  group('transfer file IO', () {
    late _TransferFilePicker picker;

    setUp(() {
      final previous = FilePickerPlatform.instance;
      picker = _TransferFilePicker();
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = previous);
      PackageInfo.setMockInitialValues(
        appName: 'MonkeySSH',
        packageName: 'test',
        version: '1.0',
        buildNumber: '1',
        buildSignature: '',
      );
    });

    Future<void> build(WidgetTester tester) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (buildContext) {
              context = buildContext;
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    testWidgets('imports a single memory file and permits cancellation', (
      tester,
    ) async {
      await build(tester);
      picker.selectedFile = AppPlatformFile(
        name: 'vault.monkeysshx',
        bytes: Uint8List.fromList([111, 107]),
      );
      expect(await pickTransferPayloadFromFile(context), 'ok');
      picker.selectedFile = null;
      expect(await pickTransferPayloadFromFile(context), isNull);
      expect(picker.selections, 2);
    });

    for (final failure in ['utf8', 'oversize', 'read']) {
      testWidgets('rejects $failure payloads while reading the stream', (
        tester,
      ) async {
        await build(tester);
        final file = _MockXFile();
        var cancelled = false;
        var chunksRead = 0;
        when(file.openRead).thenAnswer(
          (_) => switch (failure) {
            'utf8' => Stream.value(Uint8List.fromList([255])),
            'oversize' =>
              Stream<Uint8List>.multi((controller) {
                controller
                  ..onCancel = () async {
                    cancelled = true;
                  }
                  ..add(Uint8List(10 * 1024 * 1024))
                  ..add(Uint8List(1))
                  ..add(Uint8List(1))
                  ..close();
              }).map((chunk) {
                chunksRead++;
                return chunk;
              }),
            _ => Stream.error(const FileSystemException('unreadable')),
          },
        );
        picker.selectedFile = AppPlatformFile(
          name: 'vault.monkeysshx',
          xFile: file,
        );
        expect(await pickTransferPayloadFromFile(context), isNull);
        if (failure == 'oversize') {
          expect(cancelled, isTrue);
          expect(chunksRead, 2);
        }
        await tester.pump();
        expect(
          find.text(switch (failure) {
            'utf8' =>
              'That isn’t a valid MonkeySSH transfer file. Export it again from MonkeySSH.',
            'oversize' => 'Transfer file is too large',
            _ =>
              'Couldn’t read that file. Pick a .monkeysshx file exported from MonkeySSH.',
          }),
          findsOneWidget,
        );
      });
    }

    for (final outcome in ['saved', 'cancelled', 'failure']) {
      testWidgets('handles picker export $outcome without rewriting the file', (
        tester,
      ) async {
        await build(tester);
        var saves = 0;
        picker.save = (bytes) async {
          saves++;
          expect(bytes, [111, 107]);
          if (outcome == 'failure') {
            throw PlatformException(code: 'save_failed');
          }
          return outcome == 'saved'
              ? Uri.file('/nonexistent/export.monkeysshx')
              : null;
        };
        await saveTransferPayloadToFile(
          context: context,
          payload: 'ok',
          defaultFileName: 'export',
        );
        await tester.pump();
        expect(saves, 1);
        expect(
          find.text(switch (outcome) {
            'saved' =>
              'Encrypted file saved: file:///nonexistent/export.monkeysshx',
            'cancelled' => 'Export cancelled',
            _ =>
              'Couldn’t write the transfer file. Free up space and try again.',
          }),
          findsOneWidget,
        );
      });
    }
  });

  group('sanitizeTransferFileBaseName', () {
    test('replaces reserved filename characters and whitespace', () {
      expect(
        sanitizeTransferFileBaseName('host: prod/app? key*'),
        'host-prod-app-key',
      );
    });

    test('falls back when the suggestion is empty after sanitizing', () {
      expect(
        sanitizeTransferFileBaseName(r'  <>:"/\|?*  '),
        'monkeyssh-transfer',
      );
    });

    test('strips leading and trailing dots and separators', () {
      expect(sanitizeTransferFileBaseName('.. key export ..'), 'key-export');
    });
  });

  group('export destination', () {
    test('uses the share sheet only for native iOS exports', () {
      expect(useShareSheetForPlatform(TargetPlatform.iOS), isTrue);
      expect(useShareSheetForPlatform(TargetPlatform.android), isFalse);
      expect(
        useShareSheetForPlatform(TargetPlatform.iOS, isWeb: true),
        isFalse,
      );
    });
  });

  group('picker helpers', () {
    test('uses the native unfiltered picker on iOS', () {
      expect(
        pickerFileTypeForCustomExtension(TargetPlatform.iOS),
        FileType.any,
      );
      expect(
        pickerAllowedExtensionsForCustomExtension(TargetPlatform.iOS, const [
          monkeySshTransferFileExtension,
        ]),
        isNull,
      );
    });

    test('uses filtered custom extensions on non-iOS platforms', () {
      expect(
        pickerFileTypeForCustomExtension(TargetPlatform.android),
        FileType.custom,
      );
      expect(
        pickerAllowedExtensionsForCustomExtension(
          TargetPlatform.android,
          const [monkeySshTransferFileExtension],
        ),
        const [monkeySshTransferFileExtension],
      );
    });

    test('validates extensions from file metadata, name, or path', () {
      expect(
        platformFileMatchesExpectedExtension(
          AppPlatformFile(name: 'vault.MONKEYSSHX', size: 1),
          monkeySshTransferFileExtension,
        ),
        isTrue,
      );
      expect(
        platformFileMatchesExpectedExtension(
          AppPlatformFile(
            name: 'vault',
            path: '/tmp/vault.monkeysshx',
            size: 1,
          ),
          monkeySshTransferFileExtension,
        ),
        isTrue,
      );
      expect(
        platformFileMatchesExpectedExtension(
          AppPlatformFile(name: 'vault.txt', size: 1),
          monkeySshTransferFileExtension,
        ),
        isFalse,
      );
    });
  });

  testWidgets(
    'fails closed when the app re-locks during biometric transfer auth',
    (tester) async {
      when(() => authService.isAuthEnabled()).thenAnswer((_) async => true);
      when(
        () => authService.getAuthMethod(),
      ).thenAnswer((_) async => AuthMethod.biometric);
      when(
        () => authService.authenticateWithBiometrics(
          reason: any(named: 'reason'),
        ),
      ).thenAnswer((_) async {
        container.read(authStateProvider.notifier).lockForAutoLock();
        return true;
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Builder(
              builder: (buildContext) {
                context = buildContext;
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      final result = await authorizeSensitiveTransferExport(
        context: context,
        authService: authService,
        readAuthState: () => container.read(authStateProvider),
        reason: 'Authenticate to export migration package',
      );

      expect(result, isFalse);
      expect(container.read(authStateProvider), AuthState.locked);
    },
  );
}
