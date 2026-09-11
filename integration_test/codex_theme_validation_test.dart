// ignore_for_file: implementation_imports, public_member_api_docs

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/models/terminal_theme.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart' as monkey_themes;
import 'package:monkeyssh/domain/services/host_key_prompt_handler_provider.dart';
import 'package:monkeyssh/domain/services/host_key_verification.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/src/ui/palette_builder.dart';
import 'package:xterm/xterm.dart' hide TerminalThemes;

import '../test/helpers/live_ssh_terminal_helpers.dart';
import '../test/helpers/terminal_theme_assertion_helpers.dart';

const _sshPort = int.fromEnvironment('CODEX_THEME_SSH_PORT');
const _sshUser = String.fromEnvironment('CODEX_THEME_SSH_USER');
const _sshPrivateKeyBase64 = String.fromEnvironment('CODEX_THEME_SSH_KEY_B64');
const _sshPublicKeyBase64 = String.fromEnvironment('CODEX_THEME_SSH_PUB_B64');
const _tmuxSessionName = String.fromEnvironment('CODEX_THEME_TMUX_SESSION');
const _tmuxWorkingDirectory = String.fromEnvironment('CODEX_THEME_WORKDIR');

bool get _hasValidationEnvironment =>
    _sshPort > 0 &&
    _sshUser.isNotEmpty &&
    _sshPrivateKeyBase64.isNotEmpty &&
    _sshPublicKeyBase64.isNotEmpty &&
    _tmuxSessionName.isNotEmpty &&
    _tmuxWorkingDirectory.isNotEmpty;

String get _deviceReachableHost =>
    Platform.isAndroid ? '10.0.2.2' : '127.0.0.1';

MonetizationState _proMonetizationState() => const MonetizationState(
  billingAvailability: MonetizationBillingAvailability.available,
  entitlements: MonetizationEntitlements.pro(),
  offers: [],
  debugUnlockAvailable: false,
  debugUnlocked: false,
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Codex input remains readable after tmux theme switches', (
    tester,
  ) async {
    if (!_hasValidationEnvironment) {
      markTestSkipped('CODEX_THEME_* dart-defines are not configured.');
      return;
    }

    expect(_sshPort, greaterThan(0));
    expect(_sshUser, isNotEmpty);
    expect(_sshPrivateKeyBase64, isNotEmpty);
    expect(_sshPublicKeyBase64, isNotEmpty);
    expect(_tmuxSessionName, isNotEmpty);
    expect(_tmuxWorkingDirectory, isNotEmpty);

    await tester.binding.setSurfaceSize(const Size(430, 932));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    if (Platform.isAndroid) {
      await binding.convertFlutterSurfaceToImage();
    }

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final encryptionService = SecretEncryptionService.forTesting();
    final hostRepository = HostRepository(db, encryptionService);
    final keyRepository = KeyRepository(db, encryptionService);

    await db
        .into(db.settings)
        .insertOnConflictUpdate(
          SettingsCompanion.insert(
            key: SettingKeys.defaultTerminalThemeLight,
            value: 'clean-white',
          ),
        );
    await db
        .into(db.settings)
        .insertOnConflictUpdate(
          SettingsCompanion.insert(
            key: SettingKeys.defaultTerminalThemeDark,
            value: 'ocean-dark',
          ),
        );

    final keyId = await keyRepository.insert(
      SshKeysCompanion.insert(
        name: 'Codex theme validation key',
        keyType: 'ed25519',
        publicKey: utf8.decode(base64Decode(_sshPublicKeyBase64)),
        privateKey: utf8.decode(base64Decode(_sshPrivateKeyBase64)),
        passphrase: const Value(null),
        fingerprint: const Value('codex-theme-validation'),
      ),
    );

    final hostId = await hostRepository.insert(
      HostsCompanion.insert(
        label: 'Codex theme validation',
        hostname: _deviceReachableHost,
        port: const Value(_sshPort),
        username: _sshUser,
        keyId: Value(keyId),
        password: const Value(null),
        autoConnectRequiresConfirmation: const Value(false),
        terminalThemeLightId: const Value('clean-white'),
        terminalThemeDarkId: const Value('ocean-dark'),
        tmuxSessionName: const Value(_tmuxSessionName),
        tmuxWorkingDirectory: const Value(_tmuxWorkingDirectory),
      ),
    );

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        secretEncryptionServiceProvider.overrideWithValue(encryptionService),
        hostKeyPromptHandlerProvider.overrideWithValue(
          (_) async => HostKeyTrustDecision.trust,
        ),
        monetizationStateProvider.overrideWith(
          (ref) => Stream<MonetizationState>.value(_proMonetizationState()),
        ),
      ],
    );
    addTearDown(container.dispose);

    final themeMode = ValueNotifier(ThemeMode.light);
    addTearDown(themeMode.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ValueListenableBuilder<ThemeMode>(
          valueListenable: themeMode,
          builder: (context, mode, child) => MaterialApp(
            theme: ThemeData.light(),
            darkTheme: ThemeData.dark(),
            themeMode: mode,
            home: child,
          ),
          child: TerminalScreen(hostId: hostId),
        ),
      ),
    );

    await pumpUntilConnected(
      tester,
      description: 'SSH connection to validation host',
    );
    await pumpUntilFound(tester, find.byType(MonkeyTerminalView));

    var terminal = terminalFromView(tester);
    await waitForTerminalText(
      tester,
      () => terminalFromView(tester),
      'Codex',
      description: 'Timed out waiting for Codex to render in tmux',
      timeout: const Duration(seconds: 90),
    );
    await pumpUntil(
      tester,
      () => terminalFromView(tester).reportFocusMode,
      description: 'Codex/tmux did not request terminal focus reports',
    );
    await binding.takeScreenshot('codex-clean-white-before-theme-change');

    final tokenSuffix = DateTime.now().millisecondsSinceEpoch
        .remainder(46656)
        .toRadixString(36);

    await _switchThemeMode(tester, themeMode, ThemeMode.dark);
    terminal = terminalFromView(tester);
    final darkToken = 'd$tokenSuffix';
    terminal.textInput(darkToken);
    await waitForTerminalText(
      tester,
      () => terminalFromView(tester),
      darkToken,
      description: 'Timed out waiting for dark-theme Codex input token',
    );
    terminal = terminalFromView(tester);
    final darkContrast = _minimumTokenContrast(
      terminal,
      monkey_themes.TerminalThemes.defaultDarkTheme,
      darkToken,
    );
    final darkSurface = composerSurfaceForToken(
      terminal,
      monkey_themes.TerminalThemes.defaultDarkTheme,
      darkToken,
    );
    expect(darkContrast, greaterThanOrEqualTo(4.5));
    expect(darkSurface.sampledCells, greaterThan(darkToken.length));
    expect(darkSurface.background.computeLuminance(), lessThan(0.45));
    await binding.takeScreenshot('codex-default-dark-readable');

    await _switchThemeMode(tester, themeMode, ThemeMode.light);
    terminal = terminalFromView(tester);
    final lightToken = '-l$tokenSuffix';
    terminal.textInput(lightToken);
    await waitForTerminalText(
      tester,
      () => terminalFromView(tester),
      lightToken,
      description: 'Timed out waiting for light-theme Codex input token',
    );
    terminal = terminalFromView(tester);
    final lightContrast = _minimumTokenContrast(
      terminal,
      monkey_themes.TerminalThemes.defaultLightTheme,
      lightToken,
    );
    final lightSurface = composerSurfaceForToken(
      terminal,
      monkey_themes.TerminalThemes.defaultLightTheme,
      lightToken,
    );
    expect(lightContrast, greaterThanOrEqualTo(4.5));
    expect(lightSurface.sampledCells, greaterThan(lightToken.length));
    expect(lightSurface.background.computeLuminance(), greaterThan(0.55));
    await binding.takeScreenshot('codex-default-light-readable');
  });
}

Future<void> _switchThemeMode(
  WidgetTester tester,
  ValueNotifier<ThemeMode> themeMode,
  ThemeMode mode,
) async {
  themeMode.value = mode;
  await tester.pumpAndSettle(const Duration(seconds: 1));
}

double _minimumTokenContrast(
  Terminal terminal,
  TerminalThemeData theme,
  String token,
) {
  final xtermTheme = theme.toXtermTheme();
  final palette = PaletteBuilder(xtermTheme).build();
  final cell = CellData.empty();

  for (var row = 0; row < terminal.buffer.lines.length; row += 1) {
    final line = terminal.buffer.lines[row];
    final text = line.getText(0, terminal.buffer.viewWidth);
    final startColumn = text.indexOf(token);
    if (startColumn == -1) {
      continue;
    }

    var minimum = double.infinity;
    for (var offset = 0; offset < token.length; offset += 1) {
      line.getCellData(startColumn + offset, cell);
      final colors = effectiveCellColors(cell, xtermTheme, palette);
      minimum = math.min(
        minimum,
        contrastRatio(colors.foreground, colors.background),
      );
    }
    return minimum;
  }

  fail('Could not find token "$token" in terminal buffer.');
}
