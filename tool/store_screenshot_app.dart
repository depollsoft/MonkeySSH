// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/app/app.dart';
import 'package:monkeyssh/app/app_metadata.dart';
import 'package:monkeyssh/app/router.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/host_key_prompt_handler_provider.dart';
import 'package:monkeyssh/domain/services/host_key_verification.dart';
import 'package:monkeyssh/domain/services/local_notification_service.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/terminal_notification.dart';
import 'package:monkeyssh/presentation/screens/agent_management_screen.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart'
    show storeDemoImagePasteCompleter;
import 'package:monkeyssh/presentation/widgets/display_fold.dart';

const _targetName = String.fromEnvironment('STORE_SCREENSHOT_TARGET');
const _selectedScene = String.fromEnvironment('STORE_SCREENSHOT_SCENE');
const _sshPort = int.fromEnvironment('STORE_SCREENSHOT_SSH_PORT');
const _sshUsername = String.fromEnvironment('STORE_SCREENSHOT_SSH_USERNAME');
const _sshPrivateKeyB64 = String.fromEnvironment(
  'STORE_SCREENSHOT_SSH_PRIVATE_KEY_B64',
);
const _sshHostKeyB64 = String.fromEnvironment(
  'STORE_SCREENSHOT_SSH_HOST_KEY_B64',
);
const _sshHostKeyFingerprint = String.fromEnvironment(
  'STORE_SCREENSHOT_SSH_HOST_KEY_FINGERPRINT',
);
const _muxSessionName = String.fromEnvironment('STORE_SCREENSHOT_MUX_SESSION');
const _workspacePath = String.fromEnvironment(
  'STORE_SCREENSHOT_WORKSPACE_PATH',
  defaultValue: '/Users/Shared/monkeyssh-release-workspace',
);
const _nativeCopilotPrompt =
    'Review this reconnect plan: keep the remote agent running, retry SSH with '
    'backoff, then resume the same conversation. Give four short test cases '
    'and a four-line retry example. Keep the reply under 90 words. '
    'Do not run tools, read files, or load skills.';
const _themeMode = String.fromEnvironment(
  'STORE_SCREENSHOT_THEME_MODE',
  defaultValue: 'dark',
);
const _terminalThemeLightId = 'clean-white';
const _terminalThemeDarkId = 'velvet';
const _postReadyCaptureDelay = Duration(
  milliseconds: int.fromEnvironment(
    'STORE_SCREENSHOT_SCENE_HOLD_MS',
    defaultValue: 6000,
  ),
);
const _videoDemoMode = bool.fromEnvironment('STORE_SCREENSHOT_VIDEO_DEMO');
const _lightDemoImageMode = bool.fromEnvironment(
  'STORE_SCREENSHOT_LIGHT_DEMO_IMAGE',
);
const _lightDemoImageOutput = String.fromEnvironment(
  'STORE_SCREENSHOT_LIGHT_DEMO_OUTPUT',
);
// Video-only prompts, always passed by scripts/generate_store_demo_videos.py.
const _copilotPrompt = String.fromEnvironment(
  'STORE_SCREENSHOT_COPILOT_PROMPT',
);
const _claudePrompt = String.fromEnvironment('STORE_SCREENSHOT_CLAUDE_PROMPT');
const _fallbackOffer = MonetizationOffer(
  id: 'fallback',
  productId: 'store-screenshot-fallback',
  billingPeriod: MonetizationBillingPeriod.monthly,
  planLabel: 'Monthly',
  priceLabel: r'$0.00',
  displayPriceLabel: r'$0.00 / month',
  rawPrice: 0,
  currencyCode: 'USD',
  currencySymbol: r'$',
);

class _MockMonetizationService extends Mock implements MonetizationService {}

class _NoOpLocalNotificationService extends LocalNotificationService {
  @override
  Future<bool> initialize() async => false;

  @override
  Future<void> showTmuxAlert({
    required int notificationId,
    required String title,
    required String body,
    required TmuxAlertNotificationPayload payload,
    String? subtitle,
    TerminalNotificationUrgency? urgency,
    TerminalNotificationSound? sound,
    Duration? timeout,
  }) async {}
}

class _ScreenshotTarget {
  const _ScreenshotTarget({required this.platform, required this.pathsByScene});

  final TargetPlatform platform;
  final List<List<String>> pathsByScene;
}

// Must match scripts/store_media.py. Readiness checks names, not a count that
// could be satisfied by duplicate, unrelated, or native chat windows.
const _requiredStoreAgentWindows = <String>{
  'copilot',
  'claude',
  'codex',
  'opencode',
  'antigravity',
  'cursor-agent',
  'pi',
};

const _sceneNames = <String>[
  'terminal_copilot',
  'hosts',
  'snippets',
  'monkeymux_windows',
  'sftp',
  'terminal_claude',
  'native_copilot',
  'agent_management',
];

/// How the iPhone Duo is held for a capture, and the window it gives the app.
enum _DuoPose {
  /// Folded shut: the outer display, upright, with the vertical bar.
  closed(Size(466, 678), null),

  /// Opened flat and held wide: the inner display; the crease is ignored.
  open(Size(951, 669), null),

  /// Half open and held like a book: pages side by side.
  book(Size(951, 669), Axis.vertical),

  /// Half open, turned upright and propped up like a laptop: pages stacked.
  propped(Size(669, 951), Axis.horizontal);

  const _DuoPose(this.window, this.foldAxis);

  final Size window;
  final Axis? foldAxis;
}

class _DuoScene {
  const _DuoScene(this.name, this.pose);

  final String name;
  final _DuoPose pose;
}

// Product page order. Must match DUO_SCREENSHOTS in
// scripts/validate_store_screenshots.py.
const _duoScenes = <_DuoScene>[
  _DuoScene('duo_book_terminal', _DuoPose.book),
  _DuoScene('duo_closed_terminal', _DuoPose.closed),
  _DuoScene('duo_propped_terminal', _DuoPose.propped),
  _DuoScene('duo_book_home', _DuoPose.book),
  _DuoScene('duo_open_native', _DuoPose.open),
  _DuoScene('duo_closed_windows', _DuoPose.closed),
  _DuoScene('duo_closed_hosts', _DuoPose.closed),
  _DuoScene('duo_closed_agent_management', _DuoPose.closed),
];

final _targets = <String, _ScreenshotTarget>{
  'ios_phone': _ScreenshotTarget(
    platform: TargetPlatform.iOS,
    pathsByScene: [
      for (var index = 1; index <= _sceneNames.length; index += 1)
        ['ios/fastlane/screenshots/en-US/${index.toString().padLeft(2, '0')}_iphone_6_9.png'],
    ],
  ),
  'ios_ipad': _ScreenshotTarget(
    platform: TargetPlatform.iOS,
    pathsByScene: [
      for (var index = 1; index <= _sceneNames.length; index += 1)
        ['ios/fastlane/screenshots/en-US/${index.toString().padLeft(2, '0')}_ipad_13.png'],
    ],
  ),
  'ios_duo': _ScreenshotTarget(
    platform: TargetPlatform.iOS,
    pathsByScene: [
      for (var index = 1; index <= _duoScenes.length; index += 1)
        ['ios/fastlane/screenshots/en-US/${index.toString().padLeft(2, '0')}_iphone_duo.png'],
    ],
  ),
  'android_phone': _ScreenshotTarget(
    platform: TargetPlatform.android,
    pathsByScene: [
      for (var index = 1; index <= _sceneNames.length; index += 1)
        [
          'android/fastlane/metadata-production/android/en-US/images/phoneScreenshots/$index.png',
          'android/fastlane/metadata-private/android/en-US/images/phoneScreenshots/$index.png',
        ],
    ],
  ),
  'android_7_tablet': _ScreenshotTarget(
    platform: TargetPlatform.android,
    pathsByScene: [
      for (var index = 1; index <= _sceneNames.length; index += 1)
        [
          'android/fastlane/metadata-production/android/en-US/images/sevenInchScreenshots/$index.png',
          'android/fastlane/metadata-private/android/en-US/images/sevenInchScreenshots/$index.png',
        ],
    ],
  ),
  'android_10_tablet': _ScreenshotTarget(
    platform: TargetPlatform.android,
    pathsByScene: [
      for (var index = 1; index <= _sceneNames.length; index += 1)
        [
          'android/fastlane/metadata-production/android/en-US/images/tenInchScreenshots/$index.png',
          'android/fastlane/metadata-private/android/en-US/images/tenInchScreenshots/$index.png',
        ],
    ],
  ),
};

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final target = _targets[_targetName];
  if (target == null) {
    stderr.writeln(
      'Unknown STORE_SCREENSHOT_TARGET "$_targetName". '
      'Expected one of: ${_targets.keys.join(', ')}',
    );
    exit(64);
  }
  if (_sshPort <= 0 ||
      _sshUsername.isEmpty ||
      _sshPrivateKeyB64.isEmpty ||
      _sshHostKeyB64.isEmpty ||
      _sshHostKeyFingerprint.isEmpty) {
    stderr.writeln(
      'STORE_SCREENSHOT_SSH_PORT, STORE_SCREENSHOT_SSH_USERNAME, '
      'STORE_SCREENSHOT_SSH_PRIVATE_KEY_B64, STORE_SCREENSHOT_SSH_HOST_KEY_B64, '
      'and STORE_SCREENSHOT_SSH_HOST_KEY_FINGERPRINT are required.',
    );
    exit(64);
  }
  const muxSessionName = _muxSessionName;
  if (muxSessionName.isEmpty) {
    stderr.writeln('STORE_SCREENSHOT_MUX_SESSION is required.');
    exit(64);
  }
  if (_workspacePath.isEmpty) {
    stderr.writeln('STORE_SCREENSHOT_WORKSPACE_PATH is required.');
    exit(64);
  }
  registerFallbackValue(MonetizationFeature.agentLaunchPresets);
  registerFallbackValue(_fallbackOffer);

  debugDefaultTargetPlatformOverride = target.platform;

  final database = AppDatabase.forTesting(NativeDatabase.memory());
  final secrets = SecretEncryptionService.forTesting();
  final terminalHostId = await _seedDatabase(
    database,
    secrets,
    target,
    muxSessionName,
  );
  final monetizationService = _createMonetizationService();

  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        secretEncryptionServiceProvider.overrideWithValue(secrets),
        appDisplayNameProvider.overrideWithValue(defaultAppName),
        hostKeyPromptHandlerProvider.overrideWith(
          (_) =>
              (_) async => HostKeyTrustDecision.trust,
        ),
        monetizationServiceProvider.overrideWithValue(monetizationService),
        monetizationStateProvider.overrideWith(
          (ref) => monetizationService.states,
        ),
        localNotificationServiceProvider.overrideWithValue(
          _NoOpLocalNotificationService(),
        ),
        sharedClipboardProvider.overrideWith((ref) async => false),
      ],
      child: _StoreScreenshotFlow(
        target: target,
        terminalHostId: terminalHostId,
      ),
    ),
  );
}

MonetizationService _createMonetizationService() {
  const state = MonetizationState(
    billingAvailability: MonetizationBillingAvailability.unavailable,
    entitlements: MonetizationEntitlements.pro(),
    offers: [],
    debugUnlockAvailable: false,
    debugUnlocked: false,
  );
  final service = _MockMonetizationService();
  when(() => service.currentState).thenReturn(state);
  when(() => service.states).thenAnswer((_) => Stream.value(state));
  // ignore: unnecessary_lambdas
  when(() => service.initialize()).thenAnswer((_) => Future<void>.value());
  when(() => service.canUseFeature(any())).thenAnswer((_) async => true);
  when(() => service.purchaseOffer(any())).thenAnswer(
    (_) async => const MonetizationActionResult.cancelled(
      'Purchases are disabled for screenshots.',
    ),
  );
  // ignore: unnecessary_lambdas
  when(() => service.restorePurchases()).thenAnswer(
    (_) => Future.value(
      const MonetizationActionResult.cancelled(
        'Restore is disabled for screenshots.',
      ),
    ),
  );
  // ignore: unnecessary_lambdas
  when(() => service.dispose()).thenAnswer((_) => Future<void>.value());
  return service;
}

Future<int> _seedDatabase(
  AppDatabase database,
  SecretEncryptionService secrets,
  _ScreenshotTarget target,
  String muxSessionName,
) async {
  final keyRepository = KeyRepository(database, secrets);
  final hostRepository = HostRepository(database, secrets);
  final privateKey = utf8.decode(base64Decode(_sshPrivateKeyB64));
  final publicKey = _placeholderPublicKeyFromPrivateKey(privateKey);
  final hostname = target.platform == TargetPlatform.android
      ? '10.0.2.2'
      : '127.0.0.1';

  await database
      .into(database.knownHosts)
      .insert(
        KnownHostsCompanion.insert(
          hostname: hostname,
          port: _sshPort,
          keyType: 'ssh-ed25519',
          fingerprint: _sshHostKeyFingerprint,
          hostKey: _sshHostKeyB64,
        ),
      );

  final keyId = await keyRepository.insert(
    SshKeysCompanion.insert(
      name: 'Release workspace key',
      keyType: 'ed25519',
      publicKey: publicKey,
      privateKey: privateKey,
      fingerprint: const Value('SHA256:release-workspace-key'),
    ),
  );
  await keyRepository.insert(
    SshKeysCompanion.insert(
      name: 'Production deploy key',
      keyType: 'ed25519',
      publicKey: publicKey,
      privateKey: privateKey,
      fingerprint: const Value('SHA256:production-deploy'),
    ),
  );
  await keyRepository.insert(
    SshKeysCompanion.insert(
      name: 'Build runner key',
      keyType: 'rsa',
      publicKey: publicKey,
      privateKey: privateKey,
      fingerprint: const Value('SHA256:build-runner'),
    ),
  );
  await keyRepository.insert(
    SshKeysCompanion.insert(
      name: 'Emergency access key',
      keyType: 'ecdsa',
      publicKey: publicKey,
      privateKey: privateKey,
      fingerprint: const Value('SHA256:emergency-access'),
    ),
  );

  final groupId = await database
      .into(database.groups)
      .insert(
        GroupsCompanion.insert(
          name: 'Agent Workspaces',
          color: const Value('#00C9FF'),
          icon: const Value('terminal'),
        ),
      );

  final terminalHostId = await hostRepository.insert(
    HostsCompanion.insert(
      label: 'Agent MonkeyMux',
      hostname: hostname,
      port: const Value(_sshPort),
      username: _sshUsername,
      keyId: Value(keyId),
      groupId: Value(groupId),
      isFavorite: const Value(true),
      color: const Value('#00C9FF'),
      tags: const Value('agent,monkeymux,release'),
      notes: const Value('Local release-demo workspace for store captures.'),
      terminalThemeLightId: const Value(_terminalThemeLightId),
      terminalThemeDarkId: const Value(_terminalThemeDarkId),
      terminalFontFamily: const Value('monospace'),
      tmuxSessionName: Value(muxSessionName),
      tmuxWorkingDirectory: const Value(_workspacePath),
      remoteMuxBackend: Value(RemoteMuxBackend.monkeyMux.storageValue),
      sortOrder: const Value(0),
    ),
  );

  await hostRepository.insert(
    HostsCompanion.insert(
      label: 'Production bastion',
      hostname: 'bastion.internal',
      username: 'ops',
      keyId: Value(keyId),
      isFavorite: const Value(true),
      color: const Value('#34C759'),
      tags: const Value('prod,jump'),
      sortOrder: const Value(1),
    ),
  );

  await hostRepository.insert(
    HostsCompanion.insert(
      label: 'Build runner',
      hostname: 'runner.internal',
      username: 'ci',
      keyId: Value(keyId),
      color: const Value('#FF9500'),
      tags: const Value('ci,logs'),
      sortOrder: const Value(2),
    ),
  );

  await database
      .into(database.portForwards)
      .insert(
        PortForwardsCompanion.insert(
          name: 'Preview server',
          hostId: terminalHostId,
          forwardType: 'local',
          localPort: 5173,
          remoteHost: '127.0.0.1',
          remotePort: 5173,
          autoStart: const Value(false),
        ),
      );
  await database
      .into(database.portForwards)
      .insert(
        PortForwardsCompanion.insert(
          name: 'API dashboard',
          hostId: terminalHostId,
          forwardType: 'local',
          localPort: 8080,
          remoteHost: '127.0.0.1',
          remotePort: 8080,
        ),
      );
  await database
      .into(database.portForwards)
      .insert(
        PortForwardsCompanion.insert(
          name: 'Database tunnel',
          hostId: terminalHostId,
          forwardType: 'local',
          localPort: 5432,
          remoteHost: '127.0.0.1',
          remotePort: 5432,
          autoStart: const Value(false),
        ),
      );
  await database
      .into(database.portForwards)
      .insert(
        PortForwardsCompanion.insert(
          name: 'Metrics dashboard',
          hostId: terminalHostId,
          forwardType: 'local',
          localPort: 9090,
          remoteHost: '127.0.0.1',
          remotePort: 9090,
        ),
      );

  final snippets = [
    (
      name: 'Resume Copilot',
      command: 'copilot --no-remote --log-level default',
      description: 'Resume a Copilot CLI session in this MonkeyMux workspace.',
      autoExecute: false,
      usageCount: 18,
    ),
    (
      name: 'Open Claude Code',
      command: 'claude --bare --name Claude Code Workspace',
      description: 'Start Claude Code in a dedicated remote agent window.',
      autoExecute: false,
      usageCount: 12,
    ),
    (
      name: 'Attach MonkeyMux workspace',
      command: 'monkeymux attach $muxSessionName',
      description: 'Attach to the persistent remote agent workspace.',
      autoExecute: true,
      usageCount: 9,
    ),
    (
      name: 'List agent windows',
      command: 'monkeymux control --json $muxSessionName',
      description: 'Inspect active Copilot, Claude, Codex, OpenCode, and Antigravity windows.',
      autoExecute: false,
      usageCount: 7,
    ),
    (
      name: 'Open Antigravity review',
      command: 'agy --dangerously-skip-permissions',
      description: 'Start Antigravity in a new remote agent window.',
      autoExecute: false,
      usageCount: 6,
    ),
    (
      name: 'Follow deploy logs',
      command: 'tail -f logs/deploy.log',
      description: 'Stream release logs after reconnecting.',
      autoExecute: false,
      usageCount: 5,
    ),
    (
      name: 'Open preview tunnel',
      command: 'ssh -L 5173:127.0.0.1:5173 preview',
      description: 'Forward the preview server through SSH.',
      autoExecute: false,
      usageCount: 4,
    ),
  ];
  for (final (index, snippet) in snippets.indexed) {
    await database
        .into(database.snippets)
        .insert(
          SnippetsCompanion.insert(
            name: snippet.name,
            command: snippet.command,
            description: Value(snippet.description),
            autoExecute: Value(snippet.autoExecute),
            usageCount: Value(snippet.usageCount),
            sortOrder: Value(index),
          ),
        );
  }

  final settings = SettingsService(database);
  await settings.setString(SettingKeys.themeMode, _themeMode);
  await settings.setInt(SettingKeys.terminalFontSize, 13);
  await settings.setString(
    SettingKeys.defaultTerminalThemeLight,
    _terminalThemeLightId,
  );
  await settings.setString(
    SettingKeys.defaultTerminalThemeDark,
    _terminalThemeDarkId,
  );
  await settings.setBool(SettingKeys.terminalPathLinks, value: false);
  // The manager scene probes explicitly; background update timers add noise
  // while this capture flow navigates rapidly between routes.
  await settings.setBool(SettingKeys.agentUpdateNotifications, value: false);
  return terminalHostId;
}

String _placeholderPublicKeyFromPrivateKey(String privateKey) {
  final firstLine = privateKey
      .split('\n')
      .firstWhere(
        (line) => line.trim().isNotEmpty,
        orElse: () => 'release-workspace-key',
      );
  return 'ssh-ed25519 ${base64Encode(utf8.encode(firstLine))} release-workspace-key';
}

class _StoreScreenshotFlow extends ConsumerStatefulWidget {
  const _StoreScreenshotFlow({
    required this.target,
    required this.terminalHostId,
  });

  final _ScreenshotTarget target;
  final int terminalHostId;

  @override
  ConsumerState<_StoreScreenshotFlow> createState() =>
      _StoreScreenshotFlowState();
}

class _StoreScreenshotFlowState extends ConsumerState<_StoreScreenshotFlow> {
  Future<void>? _flow;
  int? _connectionId;
  Completer<void>? _demoImagePasteCompleter;
  AcpSessionKey? _nativeCopilotKey;

  @override
  void initState() {
    super.initState();
    _flow = _runFlow();
  }

  @override
  void dispose() {
    unawaited(_flow?.catchError((_) {}));
    if (_demoImagePasteCompleter != null &&
        !_demoImagePasteCompleter!.isCompleted) {
      _demoImagePasteCompleter!.completeError(
        StateError('Store demo ended before image paste completed.'),
      );
    }
    if (identical(storeDemoImagePasteCompleter, _demoImagePasteCompleter)) {
      storeDemoImagePasteCompleter = null;
    }
    super.dispose();
  }

  void _armDemoImagePasteWait() {
    final completer = Completer<void>();
    _demoImagePasteCompleter = completer;
    storeDemoImagePasteCompleter = completer;
  }

  Future<void> _waitForDemoImagePaste() async {
    final completer = _demoImagePasteCompleter;
    if (completer == null) {
      throw StateError('Demo image paste wait was not armed.');
    }
    await completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException(
        'Timed out waiting for store demo image paste to finish.',
      ),
    );
  }

  @override
  Widget build(BuildContext context) => const FluttyApp();

  Future<void> _runFlow() async {
    try {
      await _waitForApp();
      if (_lightDemoImageMode) {
        await _runLightDemoImageFlow();
      } else if (_videoDemoMode) {
        await _runVideoDemoFlow();
      } else if (_targetName == 'ios_duo') {
        await _runDuoScreenshotFlow();
      } else {
        await _runScreenshotFlow();
      }

      debugPrintSynchronously('STORE_SCREENSHOT_DONE');
      await ref.read(databaseProvider).close();
      exit(0);
    } on Object catch (error, stackTrace) {
      debugPrintSynchronously('STORE_SCREENSHOT_ERROR $error');
      debugPrintSynchronously('$stackTrace');
      await ref.read(databaseProvider).close();
      exit(1);
    }
  }

  /// Captures one light-mode hosts screenshot used as the Copilot CLI demo image.
  Future<void> _runLightDemoImageFlow() async {
    if (_lightDemoImageOutput.isEmpty) {
      throw StateError('STORE_SCREENSHOT_LIGHT_DEMO_OUTPUT is required.');
    }
    // Hosts is a full-app light chrome surface, so it contrasts strongly when
    // Copilot renders the PNG inside the dark terminal theme.
    _go('/');
    await Future<void>.delayed(const Duration(seconds: 3));
    FocusManager.instance.primaryFocus?.unfocus();
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final payload = {
      'scene': 'light_demo_hosts',
      'index': 1,
      'paths': [_lightDemoImageOutput],
    };
    debugPrintSynchronously('STORE_SCREENSHOT_READY ${jsonEncode(payload)}');
    await Future<void>.delayed(const Duration(milliseconds: 2200));
  }

  Future<void> _runScreenshotFlow() async {
    final terminalHostId = widget.terminalHostId;
    await _connect(terminalHostId);
    // Warm the MonkeyMux control channel so the window switcher scene renders
    // the full window list and Claude selection lands, even on slower devices.
    await _ensureMuxReady();

    // A targeted Claude retry needs no native session or unrelated navigation.
    if (_selectedScene == 'terminal_claude') {
      await _selectClaudeWindow();
      _go('/terminal/$terminalHostId?connectionId=$_connectionId');
      await Future<void>.delayed(const Duration(seconds: 4));
      await _announceScene(_sceneNames.indexOf(_selectedScene));
      return;
    }

    final nativeKey = await _ensureNativeCopilotSession();
    _clearNativeFocus();
    await _selectMonkeyMuxWindow('copilot');
    _go('/terminal/$terminalHostId?connectionId=$_connectionId');
    await Future<void>.delayed(const Duration(seconds: 3));
    await _announceScene(0);

    _go('/');
    await Future<void>.delayed(const Duration(seconds: 2));
    await _announceScene(1);

    _go('/snippets');
    await Future<void>.delayed(const Duration(seconds: 2));
    await _announceScene(2);

    _go(
      '/terminal/$terminalHostId?connectionId=$_connectionId'
      '&expandTmux=1',
    );
    await Future<void>.delayed(const Duration(seconds: 4));
    // Phone shows the beginning; tablets show the end of the same live list.
    // Together the store screenshot set exposes every required agent family.
    await _scrollMuxWindows(
      toEnd: !{'ios_phone', 'android_phone'}.contains(_targetName),
    );
    await _announceScene(3);

    _go(
      '/sftp/$terminalHostId?connectionId=$_connectionId'
      '&path=${Uri.encodeComponent(_workspacePath)}',
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    await _announceScene(4);

    await _selectClaudeWindow();
    _go('/terminal/$terminalHostId?connectionId=$_connectionId');
    await Future<void>.delayed(const Duration(seconds: 4));
    await _announceScene(5);

    _focusNativeCopilot(nativeKey);
    _go('/');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    _go('/terminal/$terminalHostId?connectionId=$_connectionId');
    await Future<void>.delayed(const Duration(seconds: 4));
    await _announceScene(6);

    await _openAgentManagement();
    await _announceScene(7);
  }

  /// Pushes Agent Management and waits for its live version probes.
  Future<void> _openAgentManagement() async {
    final session = ref
        .read(activeSessionsProvider.notifier)
        .getSession(_connectionId!);
    if (session == null) {
      throw StateError('SSH session not available for Agent Management.');
    }
    final refreshed = Completer<void>();
    // Use the production screen and live SSH probes, never preview runtimes.
    // Only inspect versions here; capture must not install or update local CLIs.
    unawaited(
      Navigator.of(appNavigatorKey.currentContext!).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => AgentManagementScreen(
            session: session,
            onRuntimesRefreshed: (runtimes) {
              if (refreshed.isCompleted) return;
              final installed = runtimes.where(
                (runtime) => runtime.installedVersion?.isNotEmpty ?? false,
              );
              if (installed.length < 2) {
                refreshed.completeError(
                  StateError('Agent Management did not detect live versions.'),
                );
              } else {
                refreshed.complete();
              }
            },
          ),
        ),
      ),
    );
    await refreshed.future.timeout(const Duration(seconds: 120));
    await Future<void>.delayed(const Duration(seconds: 2));
  }

  /// Captures the iPhone Duo set, grouped by pose so the hinge moves as
  /// little as possible: open, book, propped, then closed, which ends on
  /// Agent Management because its route stays pushed.
  Future<void> _runDuoScreenshotFlow() async {
    final terminalHostId = widget.terminalHostId;
    await _connect(terminalHostId);
    await _ensureMuxReady();
    final base = '/terminal/$terminalHostId?connectionId=$_connectionId';

    if (_duoSceneSelected('duo_open_native')) {
      final nativeKey = await _ensureNativeCopilotSession();
      _focusNativeCopilot(nativeKey);
      _go(base);
      await _setDuoPose(_DuoPose.open);
      await Future<void>.delayed(const Duration(seconds: 2));
      await _announceDuoScene('duo_open_native');
      _clearNativeFocus();
      // The terminal shows the native chat until it is rebuilt.
      _go('/');
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    if (_duoSceneSelected('duo_book_terminal') ||
        _duoSceneSelected('duo_propped_terminal')) {
      await _selectClaudeWindow();
    }
    if (_duoSceneSelected('duo_book_terminal')) {
      _go(base);
      await _setDuoPose(_DuoPose.book);
      await Future<void>.delayed(const Duration(seconds: 3));
      await _announceDuoScene('duo_book_terminal');
    }
    if (_duoSceneSelected('duo_book_home')) {
      _go('/');
      await _setDuoPose(_DuoPose.book);
      await Future<void>.delayed(const Duration(seconds: 2));
      await _announceDuoScene('duo_book_home');
    }
    if (_duoSceneSelected('duo_propped_terminal')) {
      _go(base);
      await _setDuoPose(_DuoPose.propped);
      await Future<void>.delayed(const Duration(seconds: 3));
      await _announceDuoScene('duo_propped_terminal');
    }

    if (_duoSceneSelected('duo_closed_terminal')) {
      await _selectMonkeyMuxWindow('copilot');
      _go(base);
      await _setDuoPose(_DuoPose.closed);
      await Future<void>.delayed(const Duration(seconds: 3));
      await _announceDuoScene('duo_closed_terminal');
    }
    if (_duoSceneSelected('duo_closed_windows')) {
      _go('$base&expandTmux=1');
      await _setDuoPose(_DuoPose.closed);
      await Future<void>.delayed(const Duration(seconds: 4));
      await _scrollMuxWindows(toEnd: false);
      await _announceDuoScene('duo_closed_windows');
    }
    if (_duoSceneSelected('duo_closed_hosts')) {
      _go('/');
      await _setDuoPose(_DuoPose.closed);
      await Future<void>.delayed(const Duration(seconds: 2));
      await _announceDuoScene('duo_closed_hosts');
    }
    if (_duoSceneSelected('duo_closed_agent_management')) {
      _go(base);
      await _setDuoPose(_DuoPose.closed);
      await _openAgentManagement();
      await _announceDuoScene('duo_closed_agent_management');
    }
  }

  bool _duoSceneSelected(String name) =>
      _selectedScene.isEmpty || _selectedScene == name;

  /// Asks the capture driver to move the hinge, then waits until the app's
  /// window holds that pose. The driver presses Device Hub's preset; when the
  /// window comes out turned the wrong way, this asks it to rotate as well.
  Future<void> _setDuoPose(_DuoPose pose) async {
    if (_duoPoseReached(pose)) return;
    debugPrintSynchronously(
      'STORE_SCREENSHOT_POSE ${jsonEncode({'pose': pose.name})}',
    );
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    var nextRotation = DateTime.now().add(const Duration(seconds: 5));
    var rotations = 0;
    DateTime? reachedAt;
    var description = '';
    while (true) {
      final now = DateTime.now();
      final current = _duoWindowDescription();
      if (current != description) {
        description = current;
        debugPrintSynchronously('iPhone Duo $description');
      }
      // Device Hub's presets sweep the hinge, and opening moves the app to the
      // inner display, so the window can pass through the pose on the way.
      if (_duoPoseReached(pose)) {
        reachedAt ??= now;
        if (now.difference(reachedAt) >= const Duration(seconds: 3)) return;
      } else {
        reachedAt = null;
      }
      if (now.isAfter(deadline)) {
        throw TimeoutException(
          'iPhone Duo did not hold the ${pose.name} pose: $description',
        );
      }
      final window = _duoMediaQuery()?.size;
      final turned =
          window != null &&
          (window.width - pose.window.height).abs() < 1 &&
          (window.height - pose.window.width).abs() < 1;
      if (turned && now.isAfter(nextRotation)) {
        // Upside down is unsupported on iPhone, so three turns cover any start.
        if (rotations == 3) {
          throw StateError(
            'iPhone Duo stayed turned after three rotations: $description',
          );
        }
        rotations += 1;
        debugPrintSynchronously(
          'STORE_SCREENSHOT_POSE ${jsonEncode({'rotate': true})}',
        );
        nextRotation = now.add(const Duration(seconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  bool _duoPoseReached(_DuoPose pose) {
    final mediaQuery = _duoMediaQuery();
    if (mediaQuery == null) return false;
    final window = mediaQuery.size;
    if ((window.width - pose.window.width).abs() >= 1 ||
        (window.height - pose.window.height).abs() >= 1) {
      return false;
    }
    return resolveDisplayFold(mediaQuery)?.axis == pose.foldAxis;
  }

  // Read below PlatformDisplayFeaturesMediaQuery, which adds the fold the
  // iPhone Duo reports outside the engine.
  MediaQueryData? _duoMediaQuery() => appNavigatorKey.currentContext
      ?.getInheritedWidgetOfExactType<MediaQuery>()
      ?.data;

  String _duoWindowDescription() {
    final mediaQuery = _duoMediaQuery();
    if (mediaQuery == null) return 'no window';
    final fold = resolveDisplayFold(mediaQuery);
    final features = [
      for (final feature in mediaQuery.displayFeatures)
        '${feature.type.name} ${feature.state.name}',
    ];
    return 'window ${mediaQuery.size}, fold ${fold?.axis.name ?? 'none'} '
        '$features';
  }

  Future<void> _announceDuoScene(String name) async {
    final index = _duoScenes.indexWhere((scene) => scene.name == name);
    final scene = _duoScenes[index];
    // Navigating can rebuild the window, and the hinge or rotation can still
    // change after the pose was first reached.
    await _setDuoPose(scene.pose);
    if (!_duoPoseReached(scene.pose)) {
      throw StateError(
        '$name needs the ${scene.pose.name} pose: ${_duoWindowDescription()}',
      );
    }
    FocusManager.instance.primaryFocus?.unfocus();
    final payload = {
      'scene': name,
      'index': index + 1,
      'pose': scene.pose.name,
      'paths': widget.target.pathsByScene[index],
    };
    debugPrintSynchronously('STORE_SCREENSHOT_READY ${jsonEncode(payload)}');
    await Future<void>.delayed(_postReadyCaptureDelay);
  }

  Future<void> _runVideoDemoFlow() async {
    final terminalHostId = widget.terminalHostId;
    await _connect(terminalHostId);
    // The slower iOS simulator can lag on MonkeyMux control-channel setup; wait
    // for windows to enumerate so the switcher renders and window selection
    // never stalls the recorded flow.
    await _ensureMuxReady();

    // The video briefly leaves the terminal route between native and CLI
    // windows. Keep its control observer alive while the capture driver is
    // still issuing commands, even when no terminal widget is subscribed.
    final session = ref
        .read(activeSessionsProvider.notifier)
        .getSession(_connectionId!)!;
    final subscription = ref
        .read(monkeyMuxServiceProvider)
        .watchWindowChanges(session, _muxSessionName)
        .listen((_) {});
    try {
      await _runVideoDemoScenes(terminalHostId);
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> _runVideoDemoScenes(int terminalHostId) async {
    final base = '/terminal/$terminalHostId?connectionId=$_connectionId';

    // Beat 1: a real Copilot ACP session in the embedded native agent window.
    final nativeKey = await _ensureNativeCopilotSession();
    _focusNativeCopilot(nativeKey);
    _go(base);
    await Future<void>.delayed(const Duration(milliseconds: 2200));
    _emitBeat(1); // Recording starts on the first beat marker.
    await Future<void>.delayed(const Duration(milliseconds: 2200));

    // Beat 2: Claude Code remains available as a full terminal agent.
    _clearNativeFocus();
    _go('/');
    await Future<void>.delayed(const Duration(milliseconds: 350));
    await _selectMonkeyMuxWindow('claude');
    _emitBeat(2);
    _go('$base&showKeyboard=1');
    await Future<void>.delayed(const Duration(milliseconds: 650));
    await _typePrompt(_claudePrompt);
    await _hideKeyboard();
    await Future<void>.delayed(const Duration(milliseconds: 2400));

    // Beat 3: show the MonkeyMux window list, then open OpenCode in the same
    // persistent SSH workspace before moving to the next captioned beat.
    _emitBeat(3);
    _go('$base&expandTmux=1');
    await _scrollMuxWindows(toEnd: false);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    await _scrollMuxWindows(toEnd: true);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    await _selectMonkeyMuxWindow('opencode');
    _go(base);
    await _hideKeyboard();
    await Future<void>.delayed(const Duration(milliseconds: 1600));

    // Beat 4: paste a real screenshot into Copilot CLI and wait until the
    // inline image has finished uploading and rendering.
    await _selectMonkeyMuxWindow('copilot');
    _emitBeat(4);
    _armDemoImagePasteWait();
    _go('$base&pasteDemoImage=1');
    await _hideKeyboard();
    await _waitForDemoImagePaste();
    await Future<void>.delayed(const Duration(milliseconds: 700));

    // Beat 5: prompt Copilot against the pasted screenshot.
    _emitBeat(5);
    _go('$base&showKeyboard=1');
    await Future<void>.delayed(const Duration(milliseconds: 650));
    await _typePrompt(_copilotPrompt);
    await _hideKeyboard();
    await Future<void>.delayed(const Duration(milliseconds: 2400));
  }

  Future<AcpSessionKey> _ensureNativeCopilotSession() async {
    final existing = _nativeCopilotKey;
    if (existing != null) return existing;
    final manager = ref.read(acpSessionManagerProvider);
    final result = await manager.startNewSession(
      hostId: widget.terminalHostId,
      providerId: AcpBuiltinProviderIds.copilotCli,
      cwd: _workspacePath,
      providerLabelOverride: 'Copilot CLI · Native',
    );
    final key = switch (result) {
      AcpSessionLaunchStarted(:final key) => key,
      AcpSessionLaunchFailed(:final error) => throw StateError(
        'Native Copilot session failed: ${error.message}',
      ),
      AcpSessionLaunchBlocked() => throw StateError(
        'Native Copilot session was blocked.',
      ),
    };
    await manager
        .prompt(key, const [AcpTextContent(_nativeCopilotPrompt)])
        .timeout(const Duration(seconds: 90));
    _nativeCopilotKey = key;
    return key;
  }

  void _focusNativeCopilot(AcpSessionKey key) {
    final connectionId = _connectionId;
    if (connectionId == null) {
      throw StateError('SSH connection is unavailable for native Copilot.');
    }
    ref
        .read(activeSessionsProvider.notifier)
        .updateSessionNativeAcpFocus(
          connectionId,
          key: key,
          displayTitle: 'Copilot CLI · Native',
        );
  }

  void _clearNativeFocus() {
    final connectionId = _connectionId;
    if (connectionId == null) return;
    ref
        .read(activeSessionsProvider.notifier)
        .updateSessionNativeAcpFocus(connectionId, key: null);
  }

  /// Emits an ordered promo beat marker. The compositor records the wall-clock
  /// offset of each beat (relative to beat 1, when recording starts) so the
  /// caption track stays synced to what is actually on screen.
  void _emitBeat(int beat) {
    debugPrintSynchronously(
      'STORE_SCREENSHOT_READY ${jsonEncode({'beat': beat})}',
    );
  }

  /// Polls MonkeyMux until its windows enumerate so the window switcher and
  /// programmatic window selection are both ready before the flow relies on
  /// them. Bounded so a stalled control channel can never hang the recording.
  Future<void> _ensureMuxReady() async {
    final session = ref
        .read(activeSessionsProvider.notifier)
        .getSession(_connectionId!);
    if (session == null) {
      throw StateError('SSH session not available for store demo.');
    }
    final muxService = ref.read(monkeyMuxServiceProvider);
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    var windowCount = 0;
    var missing = _requiredStoreAgentWindows;
    String? lastError;
    while (DateTime.now().isBefore(deadline)) {
      try {
        final windows = await muxService
            .listWindows(session, _muxSessionName)
            .timeout(const Duration(seconds: 8));
        final names = windows.map((window) => window.name).toSet();
        windowCount = windows.length;
        missing = _requiredStoreAgentWindows.difference(names);
        if (names.containsAll(_requiredStoreAgentWindows)) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          return;
        }
      } on Object catch (error) {
        // Installer messages contain fixed text and platform/exit-status values.
        // Other exceptions may contain remote content, so report only their type.
        lastError = error is MonkeyMuxInstallException
            ? error.message
            : error.runtimeType.toString();
        // Keep polling until the deadline; transient control-channel errors are
        // expected while the session is still warming up.
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw TimeoutException(
      'MonkeyMux windows did not become ready. '
      'count=$windowCount missing=${missing.join(",")} error=$lastError',
    );
  }

  Future<void> _scrollMuxWindows({required bool toEnd}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      ScrollableState? list;
      void findScrollable(Element element) {
        if (element is StatefulElement && element.state is ScrollableState) {
          list = element.state as ScrollableState;
          return;
        }
        element.visitChildren(findScrollable);
      }

      void findList(Element element) {
        if (element.widget.key == const ValueKey('tmux-window-list')) {
          element.visitChildren(findScrollable);
          return;
        }
        element.visitChildren(findList);
      }

      WidgetsBinding.instance.rootElement?.visitChildren(findList);
      final position = list?.position;
      if (position != null && position.hasContentDimensions) {
        await position.animateTo(
          toEnd ? position.maxScrollExtent : position.minScrollExtent,
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeInOut,
        );
        await Future<void>.delayed(const Duration(milliseconds: 400));
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw TimeoutException('Live MonkeyMux window list is unavailable.');
  }

  Future<void> _hideKeyboard() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    await Future<void>.delayed(const Duration(milliseconds: 450));
  }

  Future<void> _connect(int terminalHostId) async {
    if (_connectionId != null) {
      return;
    }
    final result = await ref
        .read(activeSessionsProvider.notifier)
        .connect(terminalHostId);
    if (!result.success || result.connectionId == null) {
      throw StateError(result.error ?? 'SSH connection did not open.');
    }
    _connectionId = result.connectionId;
  }

  Future<void> _selectClaudeWindow() async {
    await _selectMonkeyMuxWindow('claude');
  }

  Future<void> _selectMonkeyMuxWindow(String windowName) async {
    final session = ref
        .read(activeSessionsProvider.notifier)
        .getSession(_connectionId!);
    if (session == null) {
      throw StateError('SSH session not available for store demo.');
    }
    final mux = ref.read(monkeyMuxServiceProvider);
    final windows = await mux
        .listWindows(session, _muxSessionName)
        .timeout(const Duration(seconds: 8));
    // Agent additions/removals change indices. Resolve the live named window
    // so screenshots and video beats cannot silently land on another agent.
    final window = windows.singleWhere((window) => window.name == windowName);
    await mux
        .selectWindow(session, _muxSessionName, window.index)
        .timeout(const Duration(seconds: 8));
  }

  Future<void> _waitForApp() async {
    while (appNavigatorKey.currentContext == null) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }

  Future<void> _announceScene(int index) async {
    if (_selectedScene.isNotEmpty && _sceneNames[index] != _selectedScene) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    final payload = {
      'scene': _sceneNames[index],
      'index': index + 1,
      'paths': widget.target.pathsByScene[index],
    };
    debugPrintSynchronously('STORE_SCREENSHOT_READY ${jsonEncode(payload)}');
    await Future<void>.delayed(_postReadyCaptureDelay);
  }

  Future<void> _typePrompt(String prompt) async {
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    var terminal = ref
        .read(activeSessionsProvider.notifier)
        .getSession(_connectionId!)
        ?.terminal;
    while (terminal?.onOutput == null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      terminal = ref
          .read(activeSessionsProvider.notifier)
          .getSession(_connectionId!)
          ?.terminal;
    }
    final onOutput = terminal?.onOutput;
    if (onOutput == null) {
      throw StateError('Terminal input is not ready for store demo prompt.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
    for (final rune in prompt.runes) {
      onOutput(String.fromCharCode(rune));
      await Future<void>.delayed(const Duration(milliseconds: 24));
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
    onOutput('\r');
    // Keep this short so the caller can hide the keyboard quickly; the live
    // agent response is then revealed (keyboard-free) during the beat hold.
    await Future<void>.delayed(const Duration(milliseconds: 600));
  }

  void _go(String location) {
    final context = appNavigatorKey.currentContext;
    if (context == null) {
      throw StateError('Navigator context is unavailable.');
    }
    GoRouter.of(context).go(location);
  }
}
