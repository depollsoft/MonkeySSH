// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/app/app_link_handler.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/acp_recent_session.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/app_link.dart';
import 'package:monkeyssh/domain/models/host_cli_launch_preferences.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/services/acp_recent_sessions_service.dart';
import 'package:monkeyssh/domain/services/agent_launch_preset_service.dart';
import 'package:monkeyssh/domain/services/host_cli_launch_preferences_service.dart';
import 'package:monkeyssh/presentation/widgets/app_link_preset_sheet.dart';

import '../helpers/mocks.dart';
import '../helpers/recording_diagnostics_logger.dart';

class _MockRecentSessions extends Mock implements AcpRecentSessionsService {}

class _MockPresetService extends Mock implements AgentLaunchPresetService {}

class _MockCliPreferences extends Mock
    implements HostCliLaunchPreferencesService {}

class _RecordingEffects implements AppLinkEffects {
  final terminals = <String>[];
  final hostForms = <String>[];
  final messages = <String>[];
  final reviews = <AppLinkPresetReview>[];
  final launched = <Host>[];
  bool confirm = false;
  bool launchSucceeds = true;

  @override
  void openTerminal(String location) => terminals.add(location);

  @override
  void openNewHostForm(String sshUrl) => hostForms.add(sshUrl);

  @override
  void showMessage(String message) => messages.add(message);

  @override
  Future<bool> confirmPresetLaunch(AppLinkPresetReview review) async {
    reviews.add(review);
    return confirm;
  }

  @override
  Future<bool> launchPreset(Host host) async {
    launched.add(host);
    return launchSucceeds;
  }
}

Host _host({
  required int id,
  String label = 'build box',
  String hostname = 'build.example.com',
  String username = 'deploy',
  int port = 22,
  int? autoConnectSnippetId,
}) => Host(
  id: id,
  label: label,
  hostname: hostname,
  username: username,
  port: port,
  isFavorite: false,
  autoConnectRequiresConfirmation: false,
  autoForwardPorts: false,
  autoConnectSnippetId: autoConnectSnippetId,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  sortOrder: 0,
);

AcpRecentSessionRef _chat({
  required int hostId,
  required String sessionId,
  String providerId = 'claude',
  String bridgeId = 'bridge-1',
}) => AcpRecentSessionRef(
  hostId: hostId,
  providerId: providerId,
  bridgeId: bridgeId,
  acpSessionId: sessionId,
  createdAt: DateTime(2026),
  lastActivityAt: DateTime(2026),
);

void main() {
  late MockHostRepository hosts;
  late _MockRecentSessions recentSessions;
  late _MockPresetService presets;
  late _MockCliPreferences cliPreferences;
  late MockMonetizationService monetization;
  late _RecordingEffects effects;
  late RecordingDiagnosticsLogger diagnostics;
  late AppLinkHandler handler;

  setUpAll(() {
    registerFallbackValue(MonetizationFeature.autoConnectAutomation);
  });

  setUp(() {
    hosts = MockHostRepository();
    monetization = MockMonetizationService();
    when(() => monetization.canUseFeature(any())).thenAnswer((_) async => true);
    recentSessions = _MockRecentSessions();
    presets = _MockPresetService();
    cliPreferences = _MockCliPreferences();
    effects = _RecordingEffects();
    diagnostics = RecordingDiagnosticsLogger();
    handler = AppLinkHandler(
      hostRepository: hosts,
      recentSessions: recentSessions,
      presetService: presets,
      cliLaunchPreferences: cliPreferences,
      monetization: monetization,
      effects: effects,
      newTapId: () => 'tap',
      diagnostics: diagnostics,
    );
    when(() => hosts.getById(any())).thenAnswer((_) async => null);
    when(() => hosts.getAll()).thenAnswer((_) async => const <Host>[]);
    when(() => recentSessions.list()).thenAnswer((_) async => const []);
    when(() => presets.getPresetStateForHost(any()))
        .thenAnswer((_) async => (preset: null, isUnsupported: false));
    when(() => cliPreferences.getPreferencesForHost(any()))
        .thenAnswer((_) async => const HostCliLaunchPreferences());
  });

  group('rejected links', () {
    test('explain that the link cannot be opened', () async {
      final outcome = await handler.handle(
        const RejectedAppLink(AppLinkRejection.unknownAction),
      );

      expect(outcome, AppLinkOutcome.rejected);
      expect(effects.messages, [AppLinkMessages.invalid]);
      expect(effects.terminals, isEmpty);
    });

    test('call out embedded credentials', () async {
      await handler.handle(
        const RejectedAppLink(AppLinkRejection.embeddedCredentials),
      );

      expect(effects.messages, [AppLinkMessages.embeddedCredentials]);
      expect(effects.hostForms, isEmpty);
    });
  });

  group('open links', () {
    test('open the host terminal marked as a link tap', () async {
      when(() => hosts.getById(3)).thenAnswer((_) async => _host(id: 3));

      final outcome = await handler.handle(const OpenHostAppLink(hostId: 3));

      expect(outcome, AppLinkOutcome.opened);
      expect(effects.terminals, ['/terminal/3?linkTap=tap']);
      expect(effects.messages, isEmpty);
    });

    test('carry the window index to the terminal', () async {
      when(() => hosts.getById(3)).thenAnswer((_) async => _host(id: 3));

      await handler.handle(const OpenHostAppLink(hostId: 3, windowIndex: 2));

      final location = Uri.parse(effects.terminals.single);
      expect(location.path, '/terminal/3');
      expect(location.queryParameters, {'tmuxWindow': '2', 'linkTap': 'tap'});
    });

    test('report an unknown host instead of navigating', () async {
      final outcome = await handler.handle(const OpenHostAppLink(hostId: 99));

      expect(outcome, AppLinkOutcome.hostMissing);
      expect(effects.messages, [AppLinkMessages.hostMissing]);
      expect(effects.terminals, isEmpty);
    });
  });

  group('chat links', () {
    test('open the native chat inside its terminal', () async {
      when(() => hosts.getById(4)).thenAnswer((_) async => _host(id: 4));
      when(() => recentSessions.list()).thenAnswer(
        (_) async => [
          _chat(hostId: 5, sessionId: 'abc'),
          _chat(hostId: 4, sessionId: 'abc', providerId: 'codex'),
          _chat(hostId: 4, sessionId: 'abc', providerId: 'older'),
        ],
      );

      final outcome = await handler.handle(
        const OpenChatAppLink(hostId: 4, sessionId: 'abc'),
      );

      expect(outcome, AppLinkOutcome.opened);
      final location = Uri.parse(effects.terminals.single);
      expect(location.path, '/terminal/4');
      expect(location.queryParameters, {
        'p': 'codex',
        'b': 'bridge-1',
        's': 'abc',
        'linkTap': 'tap',
      });
    });

    test('report a chat this device does not know', () async {
      when(() => hosts.getById(4)).thenAnswer((_) async => _host(id: 4));
      when(() => recentSessions.list())
          .thenAnswer((_) async => [_chat(hostId: 5, sessionId: 'abc')]);

      final outcome = await handler.handle(
        const OpenChatAppLink(hostId: 4, sessionId: 'abc'),
      );

      expect(outcome, AppLinkOutcome.chatMissing);
      expect(effects.messages, [AppLinkMessages.chatMissing]);
      expect(effects.terminals, isEmpty);
    });

    test('report an unknown host before looking up chats', () async {
      final outcome = await handler.handle(
        const OpenChatAppLink(hostId: 4, sessionId: 'abc'),
      );

      expect(outcome, AppLinkOutcome.hostMissing);
      expect(effects.messages, [AppLinkMessages.hostMissing]);
      verifyNever(() => recentSessions.list());
    });
  });

  group('preset links', () {
    const preset = AgentLaunchPreset(
      tool: AgentLaunchTool.claudeCode,
      workingDirectory: '~/src/app',
    );

    void stubPreset(
      AgentLaunchPreset? value, {
      int hostId = 7,
      bool yolo = false,
      int? snippetId,
    }) {
      when(() => hosts.getById(hostId)).thenAnswer(
        (_) async => _host(id: hostId, autoConnectSnippetId: snippetId),
      );
      when(() => presets.getPresetStateForHost(hostId))
          .thenAnswer((_) async => (preset: value, isUnsupported: false));
      when(() => cliPreferences.getPreferencesForHost(hostId)).thenAnswer(
        (_) async => HostCliLaunchPreferences(startInYoloMode: yolo),
      );
    }

    test('show the exact command and launch only after Run', () async {
      stubPreset(preset);
      effects.confirm = true;

      final outcome = await handler.handle(
        const LaunchPresetAppLink(presetId: 7),
      );

      expect(outcome, AppLinkOutcome.presetLaunched);
      final review = effects.reviews.single;
      expect(review.hostLabel, 'build box');
      expect(review.tool, AgentLaunchTool.claudeCode);
      expect(review.command, buildAgentLaunchCommand(preset));
      expect(review.yoloMode, isFalse);
      expect(effects.launched.single.id, 7);
    });

    test('include YOLO flags in the reviewed command', () async {
      stubPreset(preset, yolo: true);
      effects.confirm = true;

      await handler.handle(const LaunchPresetAppLink(presetId: 7));

      final review = effects.reviews.single;
      expect(review.yoloMode, isTrue);
      expect(review.command, contains('--dangerously-skip-permissions'));
      expect(
        review.command,
        buildAgentLaunchCommand(preset, startInYoloMode: true),
      );
      expect(review.yoloSwitches, ['--dangerously-skip-permissions']);
    });

    test('report a launch whose connection did not open', () async {
      stubPreset(preset);
      effects
        ..confirm = true
        ..launchSucceeds = false;

      final outcome = await handler.handle(
        const LaunchPresetAppLink(presetId: 7),
      );

      expect(outcome, AppLinkOutcome.presetNotLaunched);
    });

    test('refuse a Pro-only preset before showing a review', () async {
      stubPreset(preset);
      when(
        () => monetization.canUseFeature(
          MonetizationFeature.autoConnectAutomation,
        ),
      ).thenAnswer((_) async => false);
      effects.confirm = true;

      final outcome = await handler.handle(
        const LaunchPresetAppLink(presetId: 7),
      );

      expect(outcome, AppLinkOutcome.presetNeedsPro);
      expect(effects.messages, [AppLinkMessages.presetNeedsPro]);
      expect(effects.reviews, isEmpty);
      expect(effects.launched, isEmpty);
    });

    test('review MonkeyMux presets on Free, which run without Pro', () async {
      stubPreset(
        const AgentLaunchPreset(
          tool: AgentLaunchTool.codex,
          tmuxSessionName: 'agents',
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        ),
      );
      when(() => monetization.canUseFeature(any()))
          .thenAnswer((_) async => false);

      await handler.handle(const LaunchPresetAppLink(presetId: 7));

      expect(effects.reviews, hasLength(1));
    });

    for (final (arguments, switches) in [
      ('--model gpt-6 --yolo', ['--yolo']),
      ("'--allow-all-tools'", ['--allow-all-tools']),
      ('--allow-all', ['--allow-all']),
    ]) {
      test(
        'flag YOLO switches passed as extra arguments: $arguments',
        () async {
          stubPreset(
            AgentLaunchPreset(
              tool: AgentLaunchTool.copilotCli,
              additionalArguments: arguments,
            ),
          );

          await handler.handle(const LaunchPresetAppLink(presetId: 7));

          final review = effects.reviews.single;
          expect(review.yoloMode, isTrue);
          // The warning names the switch the command really carries.
          expect(review.yoloSwitches, switches);
        },
      );
    }

    test('never launch when the review is cancelled', () async {
      stubPreset(preset, yolo: true);

      final outcome = await handler.handle(
        const LaunchPresetAppLink(presetId: 7),
      );

      expect(outcome, AppLinkOutcome.presetDeclined);
      expect(effects.reviews, hasLength(1));
      expect(effects.launched, isEmpty);
      expect(effects.terminals, isEmpty);
    });

    test('describe the preset workspace session', () async {
      stubPreset(
        const AgentLaunchPreset(
          tool: AgentLaunchTool.codex,
          tmuxSessionName: 'agents',
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        ),
      );

      await handler.handle(const LaunchPresetAppLink(presetId: 7));

      final review = effects.reviews.single;
      expect(review.muxSessionName, 'agents');
      expect(review.muxBackend, RemoteMuxBackend.monkeyMux);
    });

    test('report a missing preset without reviewing anything', () async {
      stubPreset(null);

      final outcome = await handler.handle(
        const LaunchPresetAppLink(presetId: 7),
      );

      expect(outcome, AppLinkOutcome.presetMissing);
      expect(effects.messages, [AppLinkMessages.presetMissing]);
      expect(effects.reviews, isEmpty);
      expect(effects.launched, isEmpty);
    });

    test('report a missing host as a missing preset', () async {
      final outcome = await handler.handle(
        const LaunchPresetAppLink(presetId: 7),
      );

      expect(outcome, AppLinkOutcome.presetMissing);
      expect(effects.messages, [AppLinkMessages.presetMissing]);
    });

    test('refuse hosts whose auto-connect runs a snippet instead', () async {
      stubPreset(preset, snippetId: 12);
      effects.confirm = true;

      final outcome = await handler.handle(
        const LaunchPresetAppLink(presetId: 7),
      );

      expect(outcome, AppLinkOutcome.presetMissing);
      expect(effects.reviews, isEmpty);
      expect(effects.launched, isEmpty);
    });
  });

  group('ssh links', () {
    test('open the one saved host that matches', () async {
      when(() => hosts.getAll()).thenAnswer(
        (_) async => [
          _host(id: 1, hostname: 'other.example.com'),
          _host(id: 2, hostname: 'Build.Example.com', port: 2222),
          _host(id: 3, port: 2200),
        ],
      );

      final outcome = await handler.handle(
        const SshHostAppLink(
          hostname: 'build.example.com',
          port: 2222,
          username: 'deploy',
        ),
      );

      expect(outcome, AppLinkOutcome.opened);
      expect(effects.terminals, ['/terminal/2?linkTap=tap']);
      expect(effects.hostForms, isEmpty);
    });

    test('open the add-host form when no saved host matches', () async {
      when(() => hosts.getAll())
          .thenAnswer((_) async => [_host(id: 1, username: 'root')]);

      final outcome = await handler.handle(
        const SshHostAppLink(hostname: 'build.example.com', username: 'deploy'),
      );

      expect(outcome, AppLinkOutcome.hostFormOpened);
      expect(effects.hostForms, ['ssh://deploy@build.example.com']);
      expect(effects.terminals, isEmpty);
    });

    test('use the form when several saved hosts match', () async {
      when(
        () => hosts.getAll(),
      ).thenAnswer((_) async => [_host(id: 1, username: 'root'), _host(id: 2)]);

      final outcome = await handler.handle(
        const SshHostAppLink(hostname: 'build.example.com'),
      );

      expect(outcome, AppLinkOutcome.hostFormOpened);
      expect(effects.hostForms, ['ssh://build.example.com']);
    });
  });

  test('diagnostics record categories, never link content', () async {
    when(() => hosts.getById(4)).thenAnswer((_) async => _host(id: 4));
    when(
      () => recentSessions.list(),
    ).thenAnswer((_) async => [_chat(hostId: 4, sessionId: 'secret-session')]);
    when(() => hosts.getAll()).thenAnswer((_) async => const <Host>[]);

    await handler.handle(
      const OpenChatAppLink(hostId: 4, sessionId: 'secret-session'),
    );
    await handler.handle(
      const SshHostAppLink(hostname: 'private.example.com', username: 'alice'),
    );

    final logged = diagnostics.events.map((event) => event.searchableText);
    expect(logged, hasLength(2));
    for (final text in logged) {
      expect(text, isNot(contains('secret-session')));
      expect(text, isNot(contains('private.example.com')));
      expect(text, isNot(contains('alice')));
      expect(text, isNot(contains('build')));
    }
  });
}
