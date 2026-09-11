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

const _sshPort = int.fromEnvironment('TUI_THEME_PROOF_SSH_PORT');
const _sshUser = String.fromEnvironment('TUI_THEME_PROOF_SSH_USER');
const _sshPrivateKeyBase64 = String.fromEnvironment(
  'TUI_THEME_PROOF_SSH_KEY_B64',
);
const _sshPublicKeyBase64 = String.fromEnvironment(
  'TUI_THEME_PROOF_SSH_PUB_B64',
);
const _workdir = String.fromEnvironment('TUI_THEME_PROOF_WORKDIR');
const _codexPlainCommand = String.fromEnvironment(
  'TUI_THEME_PROOF_CODEX_PLAIN_COMMAND',
);
const _opencodePlainCommand = String.fromEnvironment(
  'TUI_THEME_PROOF_OPENCODE_PLAIN_COMMAND',
);
const _codexTmuxSession = String.fromEnvironment(
  'TUI_THEME_PROOF_CODEX_TMUX_SESSION',
);
const _opencodeTmuxSession = String.fromEnvironment(
  'TUI_THEME_PROOF_OPENCODE_TMUX_SESSION',
);
const _proofCaseFilter = String.fromEnvironment('TUI_THEME_PROOF_CASE_FILTER');

bool get _hasValidationEnvironment =>
    _sshPort > 0 &&
    _sshUser.isNotEmpty &&
    _sshPrivateKeyBase64.isNotEmpty &&
    _sshPublicKeyBase64.isNotEmpty &&
    _workdir.isNotEmpty &&
    _codexPlainCommand.isNotEmpty &&
    _opencodePlainCommand.isNotEmpty &&
    _codexTmuxSession.isNotEmpty &&
    _opencodeTmuxSession.isNotEmpty;

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

  for (final proofCase in const [
    _ProofCase(
      id: 'codex-plain',
      label: 'Codex plain',
      expectedText: 'OpenAI Codex',
      tokenPrefix: 'cp',
      startupCommand: _codexPlainCommand,
    ),
    _ProofCase(
      id: 'codex-tmux',
      label: 'Codex tmux',
      expectedText: 'OpenAI Codex',
      tokenPrefix: 'ct',
      tmuxSessionName: _codexTmuxSession,
    ),
    _ProofCase(
      id: 'opencode-plain',
      label: 'OpenCode plain',
      expectedText: 'OpenCode Zen',
      tokenPrefix: 'op',
      startupCommand: _opencodePlainCommand,
    ),
    _ProofCase(
      id: 'opencode-tmux',
      label: 'OpenCode tmux',
      expectedText: 'OpenCode Zen',
      tokenPrefix: 'ot',
      tmuxSessionName: _opencodeTmuxSession,
    ),
  ]) {
    testWidgets('${proofCase.label} follows light and dark terminal themes', (
      tester,
    ) async {
      if (_proofCaseFilter.isNotEmpty && proofCase.id != _proofCaseFilter) {
        markTestSkipped('TUI_THEME_PROOF_CASE_FILTER=$_proofCaseFilter');
        return;
      }
      if (!_hasValidationEnvironment) {
        markTestSkipped('TUI_THEME_PROOF_* dart-defines are not configured.');
        return;
      }

      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      if (Platform.isAndroid) {
        await binding.convertFlutterSurfaceToImage();
      }

      final terminal = await _pumpProofTerminal(tester, proofCase);
      if (proofCase.startupCommand != null) {
        await tester.pump(const Duration(seconds: 1));
        terminalFromView(tester).textInput('${proofCase.startupCommand}\r');
      }
      await waitForTerminalText(
        tester,
        () => terminalFromView(tester),
        proofCase.expectedText,
        description: 'Timed out waiting for ${proofCase.label}',
        timeout: const Duration(seconds: 90),
      );
      await _waitForOpenCodeThemeSurface(
        tester,
        proofCase,
        monkey_themes.TerminalThemes.defaultLightTheme,
        minBackgroundLuminance: 0.55,
        description: '${proofCase.label} initial light surface',
      );
      await _waitForOpenCodeViewportBackground(
        tester,
        proofCase,
        monkey_themes.TerminalThemes.defaultLightTheme,
        maxOppositeThemeFraction: 0.18,
        description: '${proofCase.label} initial light viewport',
      );
      await binding.takeScreenshot('${proofCase.id}-light-before');

      final suffix = DateTime.now().millisecondsSinceEpoch
          .remainder(46656)
          .toRadixString(36);

      await _assertThemeSwitchReadable(
        tester,
        binding,
        terminal.container,
        proofCase: proofCase,
        suffix: suffix,
        step: const _ProofThemeStep(
          mode: ThemeMode.dark,
          id: 'dark-readable',
          tokenInfix: 'd1',
          theme: monkey_themes.TerminalThemes.defaultDarkTheme,
          maxBackgroundLuminance: 0.45,
        ),
      );
      await _assertThemeSwitchReadable(
        tester,
        binding,
        terminal.container,
        proofCase: proofCase,
        suffix: suffix,
        step: const _ProofThemeStep(
          mode: ThemeMode.light,
          id: 'light-readable',
          tokenInfix: 'l1',
          theme: monkey_themes.TerminalThemes.defaultLightTheme,
          minBackgroundLuminance: 0.55,
        ),
      );
      await _assertThemeSwitchReadable(
        tester,
        binding,
        terminal.container,
        proofCase: proofCase,
        suffix: suffix,
        step: const _ProofThemeStep(
          mode: ThemeMode.dark,
          id: 'dark-readable-again',
          tokenInfix: 'd2',
          theme: monkey_themes.TerminalThemes.defaultDarkTheme,
          maxBackgroundLuminance: 0.45,
        ),
      );
      await _assertThemeSwitchReadable(
        tester,
        binding,
        terminal.container,
        proofCase: proofCase,
        suffix: suffix,
        step: const _ProofThemeStep(
          mode: ThemeMode.light,
          id: 'light-readable-again',
          tokenInfix: 'l2',
          theme: monkey_themes.TerminalThemes.defaultLightTheme,
          minBackgroundLuminance: 0.55,
        ),
      );
    });
  }
}

class _ProofCase {
  const _ProofCase({
    required this.id,
    required this.label,
    required this.expectedText,
    required this.tokenPrefix,
    this.startupCommand,
    this.tmuxSessionName,
  });

  final String id;
  final String label;
  final String expectedText;
  final String tokenPrefix;
  final String? startupCommand;
  final String? tmuxSessionName;
}

class _ProofThemeStep {
  const _ProofThemeStep({
    required this.mode,
    required this.id,
    required this.tokenInfix,
    required this.theme,
    this.minBackgroundLuminance,
    this.maxBackgroundLuminance,
  });

  final ThemeMode mode;
  final String id;
  final String tokenInfix;
  final TerminalThemeData theme;
  final double? minBackgroundLuminance;
  final double? maxBackgroundLuminance;
}

Future<void> _assertThemeSwitchReadable(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
  ProviderContainer container, {
  required _ProofCase proofCase,
  required String suffix,
  required _ProofThemeStep step,
}) async {
  await _switchThemeMode(tester, container, step.mode);
  final token = '${proofCase.tokenPrefix}${step.tokenInfix}$suffix';
  terminalFromView(tester).textInput(token);
  await waitForTerminalText(
    tester,
    () => terminalFromView(tester),
    token,
    description: 'Timed out waiting for ${proofCase.label} ${step.id} token',
  );
  final terminal = terminalFromView(tester);
  final contrast = _minimumTokenContrast(terminal, step.theme, token);
  final surface = composerSurfaceForToken(terminal, step.theme, token);
  await _waitForOpenCodeThemeSurface(
    tester,
    proofCase,
    step.theme,
    minBackgroundLuminance: step.minBackgroundLuminance,
    maxBackgroundLuminance: step.maxBackgroundLuminance,
    description: '${proofCase.label} ${step.id} app surface',
  );
  await _waitForOpenCodeViewportBackground(
    tester,
    proofCase,
    step.theme,
    maxOppositeThemeFraction: step.theme.isDark ? 0.08 : 0.18,
    description: '${proofCase.label} ${step.id} viewport',
  );
  await binding.takeScreenshot('${proofCase.id}-${step.id}');

  expect(contrast, greaterThanOrEqualTo(3.0));
  expect(surface.sampledCells, greaterThan(token.length));
  final minBackgroundLuminance = step.minBackgroundLuminance;
  if (minBackgroundLuminance != null) {
    expect(
      surface.background.computeLuminance(),
      greaterThan(minBackgroundLuminance),
    );
  }
  final maxBackgroundLuminance = step.maxBackgroundLuminance;
  if (maxBackgroundLuminance != null) {
    expect(
      surface.background.computeLuminance(),
      lessThan(maxBackgroundLuminance),
    );
  }

  debugPrint(
    '${proofCase.id} ${step.id} contrast=$contrast '
    'surface=${surface.background}',
  );
}

Future<void> _waitForOpenCodeThemeSurface(
  WidgetTester tester,
  _ProofCase proofCase,
  TerminalThemeData theme, {
  required String description,
  double? minBackgroundLuminance,
  double? maxBackgroundLuminance,
}) async {
  if (!proofCase.id.startsWith('opencode-')) {
    return;
  }

  await pumpUntil(
    tester,
    () {
      final surface = _surfaceForTextOrNull(
        terminalFromView(tester),
        theme,
        proofCase.expectedText,
      );
      if (surface == null) {
        return false;
      }
      final luminance = surface.background.computeLuminance();
      if (minBackgroundLuminance != null &&
          luminance <= minBackgroundLuminance) {
        return false;
      }
      if (maxBackgroundLuminance != null &&
          luminance >= maxBackgroundLuminance) {
        return false;
      }
      return true;
    },
    description: description,
    timeout: const Duration(seconds: 20),
  );

  final surface = _surfaceForTextOrNull(
    terminalFromView(tester),
    theme,
    proofCase.expectedText,
  );
  debugPrint('${proofCase.id} $description appSurface=${surface?.background}');
}

Future<void> _waitForOpenCodeViewportBackground(
  WidgetTester tester,
  _ProofCase proofCase,
  TerminalThemeData theme, {
  required double maxOppositeThemeFraction,
  required String description,
}) async {
  if (!proofCase.id.startsWith('opencode-')) {
    return;
  }

  await pumpUntil(
    tester,
    () {
      final stats = _viewportBackgroundStats(terminalFromView(tester), theme);
      return stats.oppositeThemeFraction <= maxOppositeThemeFraction;
    },
    description: description,
    timeout: const Duration(seconds: 20),
  );

  final stats = _viewportBackgroundStats(terminalFromView(tester), theme);
  debugPrint(
    '${proofCase.id} $description oppositeThemeFraction='
    '${stats.oppositeThemeFraction} opposite=${stats.oppositeThemeCells} '
    'sampled=${stats.sampledCells}',
  );
}

Future<({ProviderContainer container})> _pumpProofTerminal(
  WidgetTester tester,
  _ProofCase proofCase,
) async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
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
      name: '${proofCase.label} proof key',
      keyType: 'ed25519',
      publicKey: utf8.decode(base64Decode(_sshPublicKeyBase64)),
      privateKey: utf8.decode(base64Decode(_sshPrivateKeyBase64)),
      passphrase: const Value(null),
      fingerprint: Value('${proofCase.id}-proof'),
    ),
  );

  final hostId = await hostRepository.insert(
    HostsCompanion.insert(
      label: '${proofCase.label} proof',
      hostname: _deviceReachableHost,
      port: const Value(_sshPort),
      username: _sshUser,
      keyId: Value(keyId),
      password: const Value(null),
      autoConnectRequiresConfirmation: const Value(false),
      terminalThemeLightId: const Value('clean-white'),
      terminalThemeDarkId: const Value('ocean-dark'),
      tmuxSessionName: Value(proofCase.tmuxSessionName),
      tmuxWorkingDirectory: const Value(_workdir),
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
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
    container.dispose();
    await db.close();
  });

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: Consumer(
        builder: (context, ref, child) {
          final themeMode = ref.watch(themeModeNotifierProvider);
          return MaterialApp(
            theme: ThemeData.light(),
            darkTheme: ThemeData.dark(),
            themeMode: themeMode,
            home: child,
          );
        },
        child: TerminalScreen(hostId: hostId),
      ),
    ),
  );
  await container
      .read(themeModeNotifierProvider.notifier)
      .setThemeMode(ThemeMode.light);
  await tester.pumpAndSettle();

  await pumpUntilConnected(tester, description: 'SSH connection to proof host');
  await pumpUntilFound(tester, find.byType(MonkeyTerminalView));
  return (container: container);
}

Future<void> _switchThemeMode(
  WidgetTester tester,
  ProviderContainer container,
  ThemeMode mode,
) async {
  await container.read(themeModeNotifierProvider.notifier).setThemeMode(mode);
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
      final column = startColumn + offset;
      if (row == terminal.buffer.absoluteCursorY &&
          column == terminal.buffer.cursorX) {
        continue;
      }
      line.getCellData(column, cell);
      final colors = effectiveCellColors(cell, xtermTheme, palette);
      minimum = math.min(
        minimum,
        contrastRatio(colors.foreground, colors.background),
      );
    }
    if (minimum == double.infinity) {
      continue;
    }
    return minimum;
  }

  fail('Could not find token "$token" in terminal buffer.');
}

({Color background})? _surfaceForTextOrNull(
  Terminal terminal,
  TerminalThemeData theme,
  String text,
) {
  final xtermTheme = theme.toXtermTheme();
  final palette = PaletteBuilder(xtermTheme).build();
  final cell = CellData.empty();

  for (var row = 0; row < terminal.buffer.lines.length; row += 1) {
    final line = terminal.buffer.lines[row];
    final lineText = line.getText(0, terminal.buffer.viewWidth);
    final startColumn = lineText.indexOf(text);
    if (startColumn == -1) {
      continue;
    }

    line.getCellData(startColumn, cell);
    return (
      background: effectiveCellColors(cell, xtermTheme, palette).background,
    );
  }

  return null;
}

({int sampledCells, int oppositeThemeCells, double oppositeThemeFraction})
_viewportBackgroundStats(Terminal terminal, TerminalThemeData theme) {
  final xtermTheme = theme.toXtermTheme();
  final palette = PaletteBuilder(xtermTheme).build();
  final cell = CellData.empty();
  var sampledCells = 0;
  var oppositeThemeCells = 0;
  final startRow = terminal.buffer.scrollBack;
  final endRow = startRow + terminal.buffer.viewHeight;

  for (var row = startRow; row < endRow; row += 1) {
    final line = terminal.buffer.lines[row];
    for (var column = 0; column < terminal.buffer.viewWidth; column += 1) {
      line.getCellData(column, cell);
      final background = effectiveCellColors(
        cell,
        xtermTheme,
        palette,
      ).background;
      final luminance = background.computeLuminance();
      final oppositeTheme = theme.isDark ? luminance > 0.55 : luminance < 0.20;
      sampledCells += 1;
      if (oppositeTheme) {
        oppositeThemeCells += 1;
      }
    }
  }

  return (
    sampledCells: sampledCells,
    oppositeThemeCells: oppositeThemeCells,
    oppositeThemeFraction: sampledCells == 0
        ? 0
        : oppositeThemeCells / sampledCells,
  );
}
