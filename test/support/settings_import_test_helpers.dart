// ignore_for_file: public_member_api_docs, use_super_parameters, deprecated_member_use

import 'dart:io' show Directory, File;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart';
import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/domain/services/secure_transfer_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/presentation/models/app_platform_file.dart';
import 'package:monkeyssh/presentation/providers/entity_list_providers.dart';

void setFakeFilePickerResult({required List<PlatformFile> result}) {
  final previous = FilePickerPlatform.instance;
  FilePickerPlatform.instance = _FakeFilePickerPlatform(result);
  addTearDown(() => FilePickerPlatform.instance = previous);
}

final class _FakeFilePickerPlatform extends FilePickerPlatform {
  _FakeFilePickerPlatform(this._files);

  final List<PlatformFile> _files;
  Future<List<PlatformFile>>? _materializedFiles;

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
  }) => _materializedFiles ??= _materializeFiles();

  Future<List<PlatformFile>> _materializeFiles() async {
    if (_files.isEmpty) {
      return const [];
    }
    final tempDirectory = await Directory.systemTemp.createTemp(
      'monkeyssh-file-picker-',
    );
    addTearDown(() => tempDirectory.delete(recursive: true));

    final files = <PlatformFile>[];
    for (var index = 0; index < _files.length; index++) {
      final pickedFile = _files[index];
      final bytes = await pickedFile.readAsBytes();
      final localFile = File('${tempDirectory.path}/$index-${pickedFile.name}');
      await localFile.writeAsBytes(bytes);
      files.add(
        AppPlatformFile(
          name: pickedFile.name,
          path: localFile.path,
          size: bytes.length,
        ),
      );
    }
    return files;
  }
}

class EntityProviderProbe extends ConsumerWidget {
  const EntityProviderProbe({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref
      ..watch(allHostsProvider)
      ..watch(allKeysProvider)
      ..watch(allGroupsProvider);
    return const SizedBox.shrink();
  }
}

class MockAuthStateNotifier extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.notConfigured;
}

class FakeAuthService extends AuthService {
  @override
  Future<bool> isAuthEnabled() async => false;

  @override
  Future<bool> isBiometricEnabled() async => false;

  @override
  Future<bool> isDeviceAuthSupported() async => false;

  @override
  Future<bool> isBiometricHardwareSupported() async => false;

  @override
  Future<bool> isBiometricAvailable() async => false;

  @override
  Future<List<BiometricType>> getAvailableBiometrics() async => [];

  @override
  Future<BiometricAvailability> getBiometricAvailability() async =>
      const BiometricAvailability(
        isDeviceAuthSupported: false,
        isBiometricHardwareSupported: false,
        enrolledBiometrics: [],
      );
}

class FakeSecureTransferService extends SecureTransferService {
  FakeSecureTransferService(
    AppDatabase db,
    KeyRepository keyRepository,
    HostRepository hostRepository, {
    required this.payload,
  }) : super(db, keyRepository, hostRepository);

  final TransferPayload payload;
  int importCallCount = 0;

  @override
  Future<TransferPayload> decryptPayload({
    required String encodedPayload,
    required String transferPassphrase,
  }) async => payload;

  @override
  Future<void> importFullMigrationPayload({
    required TransferPayload payload,
    required MigrationImportMode mode,
  }) async {
    importCallCount += 1;
  }
}

class StaticThemeModeNotifier extends ThemeModeNotifier {
  @override
  ThemeMode build() => ThemeMode.system;
}

class StaticTerminalThemesApplyToAppNotifier
    extends TerminalThemesApplyToAppNotifier {
  @override
  bool build() => true;
}

class StaticFontSizeNotifier extends FontSizeNotifier {
  @override
  double build() => 14;
}

class StaticFontFamilyNotifier extends FontFamilyNotifier {
  @override
  String build() => 'System Monospace';
}

class StaticCursorStyleNotifier extends CursorStyleNotifier {
  @override
  String build() => 'block';
}

class StaticBellSoundNotifier extends BellSoundNotifier {
  @override
  bool build() => true;
}

class StaticTerminalThemeSettingsNotifier
    extends TerminalThemeSettingsNotifier {
  @override
  TerminalThemeSettings build() => const TerminalThemeSettings(
    lightThemeId: TerminalThemes.defaultLightThemeId,
    darkThemeId: TerminalThemes.defaultDarkThemeId,
  );
}
