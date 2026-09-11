// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_recent_session.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/host_cli_launch_preferences.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/models/terminal_progress.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/acp_provider_service.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/agent_launch_preset_service.dart';
import 'package:monkeyssh/domain/services/agent_session_discovery_service.dart';
import 'package:monkeyssh/domain/services/local_notification_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/tmux_service.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';
import 'package:monkeyssh/presentation/widgets/acp_mux_window_status_badge.dart';
import 'package:monkeyssh/presentation/widgets/acp_native_badge.dart';
import 'package:monkeyssh/presentation/widgets/agent_tool_icon.dart';
import 'package:monkeyssh/presentation/widgets/mux_window_status_badge.dart';
import 'package:monkeyssh/presentation/widgets/premium_badge.dart';
import 'package:monkeyssh/presentation/widgets/tmux_window_navigator.dart';
import 'package:monkeyssh/presentation/widgets/tmux_window_status_badge.dart';

import '../support/fake_acp_session_manager.dart';

class _TestConfirmMuxWindowCloseNotifier extends ConfirmMuxWindowCloseNotifier {
  @override
  bool build() => true;

  @override
  Future<void> setEnabled({required bool enabled}) async {
    state = enabled;
  }
}

class _ConfirmCloseHost extends ConsumerStatefulWidget {
  const _ConfirmCloseHost();

  @override
  ConsumerState<_ConfirmCloseHost> createState() => _ConfirmCloseHostState();
}

class _ConfirmCloseHostState extends ConsumerState<_ConfirmCloseHost> {
  var _confirmedCount = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        FilledButton(
          onPressed: () async {
            if (await confirmMuxWindowClose(
                  context: context,
                  ref: ref,
                  title: 'shell',
                ) &&
                mounted) {
              setState(() => _confirmedCount++);
            }
          },
          child: const Text('Request close'),
        ),
        Text('confirmed $_confirmedCount'),
      ],
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Widget tests do not run the native plugin registrant.
  AndroidFlutterLocalNotificationsPlugin.registerWith();

  testWidgets('native mux handle shows provider icon without window number', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: buildNativeAcpHandleIcon(
                theme: Theme.of(context),
                tool: AgentLaunchTool.cursorAgent,
              ),
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('native-acp-handle-icon')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('native-acp-handle-indicator')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('native-acp-handle-index')), findsNothing);
    expect(
      tester
          .widget<AgentToolIcon>(
            find.byKey(const ValueKey('native-acp-handle-icon')),
          )
          .tool,
      AgentLaunchTool.cursorAgent,
    );
  });

  group('TmuxWindowStatusBadge', () {
    testWidgets('shows waiting for the active idle window', (tester) async {
      const window = TmuxWindow(
        index: 0,
        name: 'claude',
        isActive: true,
        currentCommand: 'claude',
        idleSeconds: 120,
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: TmuxWindowStatusBadge(window: window)),
          ),
        ),
      );

      expect(find.text('waiting'), findsOneWidget);
      expect(find.byIcon(Icons.hourglass_bottom), findsOneWidget);
    });

    testWidgets('shows running for the active window by default', (
      tester,
    ) async {
      const window = TmuxWindow(index: 0, name: 'vim', isActive: true);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: TmuxWindowStatusBadge(window: window)),
          ),
        ),
      );

      expect(find.text('running'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });

    testWidgets('uses high-contrast container colors for alert badges', (
      tester,
    ) async {
      const scheme = ColorScheme.light(
        errorContainer: Color(0xFF112233),
        onErrorContainer: Color(0xFFF1E2D3),
      );
      const window = TmuxWindow(
        index: 2,
        name: 'logs',
        isActive: false,
        flags: '#!',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(colorScheme: scheme),
          home: const Scaffold(
            body: Center(child: TmuxWindowStatusBadge(window: window)),
          ),
        ),
      );

      final badge = tester.widget<DecoratedBox>(
        find.byType(DecoratedBox).first,
      );
      final decoration = badge.decoration as BoxDecoration;
      final icon = tester.widget<Icon>(find.byIcon(Icons.notifications_active));
      final text = tester.widget<Text>(find.text('alert'));

      expect(decoration.color, scheme.errorContainer);
      expect(icon.color, scheme.onErrorContainer);
      expect(text.style?.color, scheme.onErrorContainer);
    });
  });

  testWidgets('Don’t ask me again disables future mux close prompts', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          confirmMuxWindowCloseNotifierProvider.overrideWith(
            _TestConfirmMuxWindowCloseNotifier.new,
          ),
        ],
        child: const MaterialApp(home: _ConfirmCloseHost()),
      ),
    );

    await tester.tap(find.text('Request close'));
    await tester.pumpAndSettle();
    expect(find.text('Close window?'), findsOneWidget);
    expect(find.text('Don’t ask me again'), findsOneWidget);
    await tester.tap(find.text('Don’t ask me again'));
    await tester.tap(find.widgetWithText(FilledButton, 'Close window'));
    await tester.pumpAndSettle();

    expect(find.text('confirmed 1'), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(_ConfirmCloseHost)),
    );
    expect(container.read(confirmMuxWindowCloseNotifierProvider), isFalse);

    await tester.tap(find.text('Request close'));
    await tester.pumpAndSettle();
    expect(find.text('Close window?'), findsNothing);
    expect(find.text('confirmed 2'), findsOneWidget);
  });

  testWidgets('saved close preference is honored on the first app frame', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await SettingsService(
      db,
    ).setBool(SettingKeys.confirmMuxWindowClose, value: false);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(home: _ConfirmCloseHost()),
      ),
    );

    await tester.tap(find.text('Request close'));
    await tester.pumpAndSettle();

    expect(find.text('Close window?'), findsNothing);
    expect(find.text('confirmed 1'), findsOneWidget);
  });

  testWidgets('native mux badges show waiting and running', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              AcpMuxWindowStatusBadge(session: fakeAcpSession()),
              AcpMuxWindowStatusBadge(
                session: fakeAcpSession(
                  promptStatus: AcpPromptStatus.streaming,
                ),
              ),
              const AcpMuxWindowStatusBadge(fallbackLabel: 'native'),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(MuxWindowStatusBadge), findsNWidgets(3));
    expect(find.text('waiting'), findsOneWidget);
    expect(find.text('running'), findsOneWidget);
    expect(find.text('native'), findsOneWidget);
    expect(find.byIcon(Icons.hourglass_bottom), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
  });

  group('shared mux presentation', () {
    test(
      'synthetic numbers ignore activity order and skip server-owned sessions',
      () {
        final first = fakeAcpSession(key: fakeAcpKey(bridgeId: 'a'));
        final second = fakeAcpSession(key: fakeAcpKey(bridgeId: 'b'));
        final server = fakeAcpSession(key: fakeAcpKey(bridgeId: 'server'));
        final windows = [
          TmuxWindow(
            index: 7,
            name: 'native',
            isActive: false,
            nativeAcpBridgeId: server.key.bridgeId,
            nativeAcpProviderId: server.key.providerId,
          ),
        ];
        final initial = MuxWindowProjection(windows, [second, server, first]);
        final refreshed = MuxWindowProjection(windows, [
          first.copyWith(lastActivityAt: DateTime(2030)),
          second,
          server,
        ]);
        expect(initial.orphanSessions.map((session) => session.key), [
          first.key,
          second.key,
        ]);
        expect(initial.nativeIndices, {
          server.key: 7,
          first.key: 8,
          second.key: 9,
        });
        expect(refreshed.nativeIndices, initial.nativeIndices);
        expect(initial.sessionForWindow(windows.single), same(server));
      },
    );

    for (final inBar in [false, true]) {
      for (final identity in ['terminal', 'server native', 'tracked native']) {
        for (final isActive in [false, true]) {
          testWidgets(
            '$identity row inBar=$inBar active=$isActive retains identity progress and actions',
            (tester) async {
              final session = fakeAcpSession(
                title: 'Native work',
                promptStatus: AcpPromptStatus.streaming,
                plan: _halfFinishedPlan(AcpPlanPriority.high),
              );
              final window = TmuxWindow(
                index: 3,
                name: 'Terminal work',
                isActive: isActive,
                flags: '!',
                agentTool: AgentLaunchTool.codex,
                nativeAcpBridgeId: identity == 'server native'
                    ? session.key.bridgeId
                    : null,
                nativeAcpProviderId: identity == 'server native'
                    ? session.key.providerId
                    : null,
                terminalProgress: const TerminalProgress(
                  state: TerminalProgressState.normal,
                  percentage: 50,
                ),
              );
              final presentation = identity == 'tracked native'
                  ? MuxWindowPresentation.session(
                      session,
                      index: 3,
                      isActive: isActive,
                    )
                  : MuxWindowPresentation.window(
                      window,
                      session: identity == 'server native' ? session : null,
                      isActive: isActive,
                    );
              var taps = 0;
              var closes = 0;
              await tester.pumpWidget(
                MaterialApp(
                  home: Scaffold(
                    body: MuxWindowRow(
                      presentation: presentation,
                      inBar: inBar,
                      onTap: () => taps++,
                      onClose: () => closes++,
                    ),
                  ),
                ),
              );
              final icon = tester.widget<AgentToolIcon>(
                find.byType(AgentToolIcon),
              );
              final scheme = Theme.of(
                tester.element(find.byType(MuxWindowRow)),
              ).colorScheme;
              expect(
                icon.tool,
                identity == 'terminal'
                    ? AgentLaunchTool.codex
                    : AgentLaunchTool.copilotCli,
              );
              expect(
                icon.color,
                isActive ? scheme.primary : scheme.onSurfaceVariant,
              );
              expect(
                find.byType(AcpNativeBadge),
                identity == 'terminal' ? findsNothing : findsOneWidget,
              );
              expect(
                tester
                    .widget<LinearProgressIndicator>(
                      find.byType(LinearProgressIndicator),
                    )
                    .value,
                0.5,
              );
              expect(find.text('3'), findsOneWidget);
              if (identity == 'terminal') {
                expect(find.byIcon(Icons.notifications_active), findsOneWidget);
              }
              await tester.tap(find.text(presentation.title));
              expect(taps, 1);
              await tester.tap(find.byTooltip('Close window'));
              expect(closes, 1);
              expect(taps, 1);
            },
          );
        }
      }
      testWidgets(
        'unattached native window preserves terminal progress inBar=$inBar',
        (tester) async {
          final presentation = MuxWindowPresentation.window(
            const TmuxWindow(
              index: 4,
              name: 'Native',
              isActive: false,
              nativeAcpBridgeId: 'bridge',
              nativeAcpProviderId: AcpBuiltinProviderIds.codex,
              terminalProgress: TerminalProgress(
                state: TerminalProgressState.indeterminate,
              ),
            ),
            isActive: false,
          );
          await tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: const MediaQueryData(disableAnimations: true),
                child: Scaffold(
                  body: MuxWindowRow(
                    presentation: presentation,
                    inBar: inBar,
                    onTap: () {},
                    onClose: () {},
                  ),
                ),
              ),
            ),
          );
          expect(
            tester
                .widget<LinearProgressIndicator>(
                  find.byType(LinearProgressIndicator),
                )
                .value,
            0.5,
          );
          expect(find.text('native'), findsOneWidget);
        },
      );
    }
  });

  group('shared recent sessions', () {
    late _MockAgentSessionDiscoveryService discovery;
    late SshSession session;
    setUp(() {
      discovery = _MockAgentSessionDiscoveryService();
      session = _navigatorSession();
    });
    Widget recentHost({
      required bool inBar,
      required List<TmuxWindow> windows,
      AgentWindowModePreference mode = AgentWindowModePreference.preferTerminal,
      bool yolo = false,
      AgentLaunchTool? tool,
      ValueChanged<TmuxNavigatorAction>? onAction,
    }) => ProviderScope(
      overrides: [
        agentSessionDiscoveryServiceProvider.overrideWithValue(discovery),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MuxRecentSessionsSection(
              session: session,
              tmuxSessionName: 'main',
              remoteMuxBackend: RemoteMuxBackend.monkeyMux,
              scopeWorkingDirectory: '/explicit',
              liveWindows: windows,
              isProUser: true,
              startClisInYoloMode: yolo,
              preferredTool: tool,
              inBar: inBar,
              loadModePreference: () async => mode,
              onAction: onAction ?? (_) {},
              headerBuilder: (context, toggle, {required expanded}) =>
                  TextButton(onPressed: toggle, child: const Text('History')),
            ),
          ),
        ),
      ),
    );
    for (final inBar in [false, true]) {
      for (final (mode, forcePicker) in [
        (AgentWindowModePreference.preferNative, false),
        (AgentWindowModePreference.preferTerminal, false),
        (AgentWindowModePreference.preferNative, true),
        (AgentWindowModePreference.preferTerminal, true),
      ]) {
        testWidgets(
          'live-only history resumes with $mode forcePicker=$forcePicker inBar=$inBar',
          (tester) async {
            const liveWindow = TmuxWindow(
              index: 1,
              name: 'codex',
              isActive: true,
              currentPath: '/explicit',
              agentTool: AgentLaunchTool.codex,
              activeAgentSessionId: 'live-session',
              activeAgentSessionConfidence: AgentSessionConfidence.high,
              agentSessionTitle: 'Live-only work',
            );
            const info = ToolSessionInfo(
              toolName: 'Codex',
              sessionId: 'live-session',
              workingDirectory: '/explicit',
              summary: 'Live-only work',
            );
            when(
              () => discovery.discoverSessionsStream(
                session,
                workingDirectory: '/explicit',
                maxPerTool: any(named: 'maxPerTool'),
                toolName: any(named: 'toolName'),
              ),
            ).thenAnswer(
              (_) => Stream.value(DiscoveredSessionsResult(sessions: const [])),
            );
            when(
              () => discovery.buildResumeCommand(info, startInYoloMode: true),
            ).thenReturn('codex --yolo resume live-session');
            TmuxNavigatorAction? action;
            await tester.pumpWidget(
              recentHost(
                inBar: inBar,
                windows: const [liveWindow],
                mode: mode,
                yolo: true,
                tool: AgentLaunchTool.codex,
                onAction: (value) => action = value,
              ),
            );
            await tester.pumpAndSettle();
            verifyNever(
              () => discovery.discoverSessionsStream(
                session,
                workingDirectory: '/explicit',
                maxPerTool: any(named: 'maxPerTool'),
                toolName: any(named: 'toolName'),
              ),
            );
            await tester.tap(find.text('History'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Codex'));
            await tester.pumpAndSettle();
            final expectedNative =
                (mode == AgentWindowModePreference.preferNative) != forcePicker;
            if (forcePicker) {
              await tester.longPress(find.text('Live-only work'));
              await tester.pumpAndSettle();
              await tester.tap(
                find.text(expectedNative ? 'Native chat' : 'Terminal'),
              );
            } else {
              await tester.tap(find.text('Live-only work'));
            }
            await tester.pumpAndSettle();
            if (expectedNative) {
              expect(action, isA<TmuxResumeAcpSessionAction>());
              final native = action! as TmuxResumeAcpSessionAction;
              expect(native.providerId, AcpBuiltinProviderIds.codex);
              expect(native.acpSessionId, 'live-session');
              expect(native.workingDirectory, '/explicit');
            } else {
              expect(action, isA<TmuxResumeSessionAction>());
              final terminal = action! as TmuxResumeSessionAction;
              expect(
                terminal.resumeCommand,
                'codex --yolo resume live-session',
              );
              expect(terminal.workingDirectory, '/explicit');
            }
          },
        );
      }

      testWidgets(
        'explicit scope retains discovery across live-window changes inBar=$inBar',
        (tester) async {
          var loads = 0;
          when(
            () => discovery.discoverSessionsStream(
              session,
              workingDirectory: '/explicit',
              maxPerTool: any(named: 'maxPerTool'),
            ),
          ).thenAnswer((_) {
            loads++;
            return Stream.value(DiscoveredSessionsResult(sessions: const []));
          });
          var path = '/one';
          late StateSetter rebuild;
          await tester.pumpWidget(
            StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return recentHost(
                  inBar: inBar,
                  windows: [
                    TmuxWindow(
                      index: 1,
                      name: 'shell',
                      isActive: true,
                      currentPath: path,
                    ),
                  ],
                );
              },
            ),
          );
          await tester.pumpAndSettle();
          expect(loads, 0);
          await tester.tap(find.text('History'));
          await tester.pumpAndSettle();
          expect(loads, 1);
          rebuild(() => path = '/two');
          await tester.pumpAndSettle();
          expect(loads, 1);
          await tester.tap(find.text('History'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('History'));
          await tester.pumpAndSettle();
          expect(loads, 1);
        },
      );
    }
  });

  group('tmux navigator UI', () {
    late _MockTmuxService tmuxService;
    late _MockAgentLaunchPresetService presetService;
    late _MockAgentSessionDiscoveryService discoveryService;
    late SshSession session;

    Future<void> pumpNavigatorHost(
      WidgetTester tester, {
      required String tmuxSessionName,
      RemoteMuxBackend remoteMuxBackend = RemoteMuxBackend.tmux,
      bool startClisInYoloMode = false,
      bool isProUser = true,
      bool? confirmWindowClose,
      ValueChanged<TmuxNavigatorAction?>? onActionSelected,
      FakeAcpSessionManager? acpManager,
    }) async {
      final resolvedAcpManager = acpManager ?? FakeAcpSessionManager();
      addTearDown(resolvedAcpManager.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            if (confirmWindowClose != null)
              confirmMuxWindowCloseNotifierProvider.overrideWith(
                _TestConfirmMuxWindowCloseNotifier.new,
              ),
            acpSessionManagerProvider.overrideWithValue(resolvedAcpManager),
            acpProvidersProvider.overrideWith(
              (ref) => Stream.value(<AcpProvider>[
                for (final provider in acpBuiltinProviders) provider,
              ]),
            ),
            tmuxServiceProvider.overrideWithValue(tmuxService),
            agentLaunchPresetServiceProvider.overrideWithValue(presetService),
            agentSessionDiscoveryServiceProvider.overrideWithValue(
              discoveryService,
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () {
                    unawaited(
                      showTmuxNavigator(
                        context: context,
                        session: session,
                        tmuxSessionName: tmuxSessionName,
                        remoteMuxBackend: remoteMuxBackend,
                        remoteMultiplexerService: tmuxService,
                        isProUser: isProUser,
                        startClisInYoloMode: startClisInYoloMode,
                      ).then((action) => onActionSelected?.call(action)),
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump();
    }

    setUp(() {
      tmuxService = _MockTmuxService();
      presetService = _MockAgentLaunchPresetService();
      discoveryService = _MockAgentSessionDiscoveryService();
      session = _navigatorSession();
      when(
        () => presetService.getPresetForHost(session.hostId),
      ).thenAnswer((_) async => null);
      when(
        () => tmuxService.watchWindowChanges(session, any()),
      ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
    });

    for (final delayedMethod in ['requestPermissions', 'show']) {
      for (final retirement in [
        'activation',
        'removal',
        'disposal',
        'stable identity',
      ]) {
        testWidgets('bar cancels delayed $delayedMethod after $retirement', (
          tester,
        ) async {
          const channel = MethodChannel(
            'dexterous.com/flutter/local_notifications',
          );
          final previousPlatform = FlutterLocalNotificationsPlatform.instance;
          FlutterLocalNotificationsPlatform.instance =
              IOSFlutterLocalNotificationsPlugin();
          debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
          try {
            final notifications = LocalNotificationService();
            final pending = Completer<bool>();
            final delivered = <int>{};
            final shown = <int>[];
            final cancelled = <int>[];
            var started = false;
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              channel,
              (call) async {
                if (call.method == 'getNotificationAppLaunchDetails') {
                  return null;
                }
                if (call.method == delayedMethod && !started) {
                  started = true;
                  await pending.future;
                }
                if (call.method == 'show') {
                  final id = (call.arguments as Map)['id'] as int;
                  shown.add(id);
                  delivered.add(id);
                } else if (call.method == 'cancel') {
                  final id = call.arguments as int;
                  cancelled.add(id);
                  delivered.remove(id);
                }
                return true;
              },
            );
            final events = StreamController<TmuxWindowChangeEvent>();
            addTearDown(() async {
              await events.close();
              notifications.dispose();
              tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
                channel,
                null,
              );
              FlutterLocalNotificationsPlatform.instance = previousPlatform;
            });
            const shell = TmuxWindow(
              index: 0,
              id: '@1',
              name: 'shell',
              isActive: true,
            );
            const alert = TmuxWindow(
              index: 1,
              name: 'agent',
              isActive: false,
              flags: '!',
            );
            when(
              () => tmuxService.listWindows(session, 'main'),
            ).thenAnswer((_) async => [shell]);
            when(
              () => tmuxService.watchWindowChanges(session, 'main'),
            ).thenAnswer((_) => events.stream);
            when(
              () => tmuxService.prefetchInstalledAgentTools(session),
            ).thenAnswer((_) async {});
            final mux = tmuxService;
            await tester.pumpWidget(
              ProviderScope(
                overrides: [
                  tmuxServiceProvider.overrideWithValue(tmuxService),
                  agentLaunchPresetServiceProvider.overrideWithValue(
                    presetService,
                  ),
                  localNotificationServiceProvider.overrideWithValue(
                    notifications,
                  ),
                ],
                child: MaterialApp(
                  home: Scaffold(
                    body: Consumer(
                      builder: (context, ref, _) =>
                          buildTmuxExpandableBarTestHost(
                            ref: ref,
                            session: session,
                            remoteMultiplexerService: mux,
                          ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            events.add(const TmuxWindowListEvent([shell, alert]));
            await tester.pumpAndSettle();
            expect(started, isTrue);
            expect(cancelled, isEmpty);
            final oldId =
                Object.hash(session.hostId, session.connectionId, 'main', 1) &
                0x7fffffff;
            switch (retirement) {
              case 'activation':
                events.add(
                  TmuxWindowListEvent([
                    shell.copyWith(isActive: false),
                    alert.copyWith(isActive: true),
                  ]),
                );
              case 'removal':
                events.add(const TmuxWindowListEvent([shell]));
              case 'disposal':
                await tester.pumpWidget(const SizedBox.shrink());
              case 'stable identity':
                events.add(
                  TmuxWindowListEvent([shell, alert.copyWith(id: '@9')]),
                );
            }
            await tester.pump();
            pending.complete(true);
            await tester.pumpAndSettle();
            expect(shown, contains(oldId));
            expect(cancelled, [oldId]);
            expect(
              delivered,
              retirement == 'stable identity'
                  ? {
                      Object.hash(
                            session.hostId,
                            session.connectionId,
                            'main',
                            '@9',
                          ) &
                          0x7fffffff,
                    }
                  : isEmpty,
            );
            if (retirement == 'activation') {
              // An unchanged alert remains acknowledged after leaving the window.
              events.add(const TmuxWindowListEvent([shell, alert]));
              await tester.pumpAndSettle();
              expect(shown, [oldId]);
              expect(cancelled, [oldId]);
            }
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
            expect(delivered, isEmpty);
            expect(notifications.pendingNotificationOperationCount, 0);
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        });
      }
    }

    final windows = [
      const TmuxWindow(
        index: 0,
        name: 'vim',
        isActive: true,
        currentCommand: 'vim',
        currentPath: '/home/user/project',
        paneTitle: '✨ Editing main.dart',
      ),
      const TmuxWindow(
        index: 1,
        name: 'claude',
        isActive: false,
        currentCommand: 'claude',
        idleSeconds: 120,
      ),
      const TmuxWindow(index: 2, name: 'bash', isActive: false),
      const TmuxWindow(
        index: 3,
        name: 'htop',
        isActive: false,
        currentCommand: 'htop',
      ),
    ];

    for (final windowId in <String?>['@9', null]) {
      testWidgets('switch and close retain window ID $windowId', (
        tester,
      ) async {
        when(() => tmuxService.listWindows(session, 'main')).thenAnswer(
          (_) async => [
            windows.first,
            TmuxWindow(index: 1, id: windowId, name: 'target', isActive: false),
          ],
        );
        TmuxNavigatorAction? selected;
        await pumpNavigatorHost(
          tester,
          tmuxSessionName: 'main',
          confirmWindowClose: true,
          onActionSelected: (action) => selected = action,
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('target'));
        await tester.pumpAndSettle();
        expect(selected, isA<TmuxSwitchWindowAction>());
        final switchAction = selected! as TmuxSwitchWindowAction;
        expect(switchAction.windowIndex, 1);
        expect(switchAction.windowId, windowId);

        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Close window').last);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Close window'));
        await tester.pumpAndSettle();
        expect(selected, isA<TmuxCloseWindowAction>());
        final closeAction = selected! as TmuxCloseWindowAction;
        expect(closeAction.windowIndex, 1);
        expect(closeAction.windowId, windowId);
      });
    }

    testWidgets('shows MonkeyMux terminal shortcuts', (tester) async {
      const sessionName = 'main';

      when(
        () => tmuxService.listWindows(session, sessionName),
      ).thenAnswer((_) async => windows);

      await pumpNavigatorHost(
        tester,
        tmuxSessionName: sessionName,
        remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        confirmWindowClose: true,
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('monkeymux-shortcut-hint')),
        findsOneWidget,
      );
      expect(find.textContaining('Ctrl-B: c new'), findsOneWidget);
      expect(find.textContaining('& then y close'), findsOneWidget);
      expect(find.textContaining('d detach'), findsOneWidget);

      final closeButton = find.byTooltip('Close window').first;
      await tester.tap(closeButton);
      await tester.pumpAndSettle();
      expect(find.text('Close window?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('windows'), findsOneWidget);
    });

    testWidgets('new window picker stays above the visible keyboard', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(390, 844)
        ..devicePixelRatio = 1
        ..viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(() {
        tester.view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio()
          ..resetViewInsets();
      });

      const tmuxSessionName = 'main';

      when(
        () => tmuxService.detectInstalledAgentTools(session),
      ).thenAnswer((_) async => {AgentLaunchTool.claudeCode});

      when(
        () => tmuxService.listWindows(session, tmuxSessionName),
      ).thenAnswer((_) async => windows);
      when(
        () => discoveryService.discoverSessionsStream(
          session,
          workingDirectory: any(named: 'workingDirectory'),
          maxPerTool: any(named: 'maxPerTool'),
          toolName: any(named: 'toolName'),
        ),
      ).thenAnswer(
        (_) => Stream<DiscoveredSessionsResult>.value(
          DiscoveredSessionsResult(sessions: const <ToolSessionInfo>[]),
        ),
      );

      await pumpNavigatorHost(tester, tmuxSessionName: tmuxSessionName);

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New window'));
      await tester.pumpAndSettle();

      expect(find.text('Empty terminal'), findsOneWidget);
      expect(
        tester.getBottomLeft(find.text('Empty terminal')).dy,
        lessThan(844 - 240),
      );
      final keyboardPadding = tester
          .widgetList<AnimatedPadding>(find.byType(AnimatedPadding))
          .where(
            (widget) => widget.padding == const EdgeInsets.only(bottom: 240),
          );
      expect(keyboardPadding, isNotEmpty);
    });

    testWidgets('loads AI session providers only after expanding the section', (
      tester,
    ) async {
      const tmuxSessionName = 'main';

      when(
        () => tmuxService.detectInstalledAgentTools(session),
      ).thenAnswer((_) async => const <AgentLaunchTool>{});

      when(
        () => tmuxService.listWindows(session, tmuxSessionName),
      ).thenAnswer((_) async => windows);
      when(
        () => discoveryService.discoverSessionsStream(
          session,
          workingDirectory: any(named: 'workingDirectory'),
          maxPerTool: any(named: 'maxPerTool'),
          toolName: any(named: 'toolName'),
        ),
      ).thenAnswer(
        (_) => Stream<DiscoveredSessionsResult>.value(
          DiscoveredSessionsResult(sessions: const <ToolSessionInfo>[]),
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tmuxServiceProvider.overrideWithValue(tmuxService),
            agentLaunchPresetServiceProvider.overrideWithValue(presetService),
            agentSessionDiscoveryServiceProvider.overrideWithValue(
              discoveryService,
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () {
                    unawaited(
                      showTmuxNavigator(
                        context: context,
                        session: session,
                        tmuxSessionName: tmuxSessionName,
                        remoteMuxBackend: RemoteMuxBackend.tmux,
                        remoteMultiplexerService: tmuxService,
                        isProUser: true,
                        startClisInYoloMode: false,
                      ),
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Recent terminal sessions'),
        160,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Recent terminal sessions'), findsOneWidget);
      expect(find.text('Claude Code'), findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
      expect(find.byIcon(Icons.expand_less), findsNothing);
      verifyNever(
        () => discoveryService.discoverSessionsStream(
          session,
          workingDirectory: any(named: 'workingDirectory'),
          maxPerTool: any(named: 'maxPerTool'),
          toolName: any(named: 'toolName'),
        ),
      );
      verifyNever(() => tmuxService.detectInstalledAgentTools(session));

      await tester.scrollUntilVisible(
        find.text('Recent terminal sessions'),
        160,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pump();
      await tester.tap(find.text('Recent terminal sessions'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.expand_less), findsOneWidget);
      verify(
        () => discoveryService.discoverSessionsStream(
          session,
          workingDirectory: any(named: 'workingDirectory'),
          maxPerTool: any(named: 'maxPerTool'),
          toolName: any(named: 'toolName'),
        ),
      ).called(1);
    });

    testWidgets(
      'running Pi window remains discoverable when history scan is empty',
      (tester) async {
        const tmuxSessionName = 'main';
        const piWindows = <TmuxWindow>[
          TmuxWindow(
            index: 0,
            name: 'pi-live',
            isActive: true,
            currentCommand: 'pi',
            currentPath: '/home/demo/project',
            agentTool: AgentLaunchTool.pi,
            activeAgentSessionId: 'pi-session-id',
            activeAgentSessionConfidence: AgentSessionConfidence.high,
            lastActivityEpochSeconds: 1787301283,
          ),
        ];

        when(
          () => tmuxService.detectInstalledAgentTools(session),
        ).thenAnswer((_) async => const <AgentLaunchTool>{AgentLaunchTool.pi});

        when(
          () => tmuxService.listWindows(session, tmuxSessionName),
        ).thenAnswer((_) async => piWindows);
        when(
          () => discoveryService.discoverSessionsStream(
            session,
            workingDirectory: any(named: 'workingDirectory'),
            maxPerTool: any(named: 'maxPerTool'),
            toolName: any(named: 'toolName'),
          ),
        ).thenAnswer(
          (invocation) => Stream<DiscoveredSessionsResult>.value(
            DiscoveredSessionsResult(
              sessions: const <ToolSessionInfo>[],
              attemptedTools: invocation.namedArguments[#toolName] == null
                  ? const <String>[]
                  : <String>[invocation.namedArguments[#toolName] as String],
            ),
          ),
        );

        await pumpNavigatorHost(
          tester,
          tmuxSessionName: tmuxSessionName,
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        );

        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Recent terminal sessions'),
          160,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.tap(find.text('Recent terminal sessions'));
        await tester.pumpAndSettle();
        final piProviderTile = tester.widget<ListTile>(
          find.ancestor(
            of: find.text('Pi').last,
            matching: find.byType(ListTile),
          ),
        );
        expect(piProviderTile.onTap, isNotNull);
        piProviderTile.onTap!();
        await tester.pumpAndSettle();

        expect(find.text('Active Pi session'), findsOneWidget);
        expect(find.text('No recent sessions found.'), findsNothing);
      },
    );

    testWidgets('resumes a supported history session as native ACP', (
      tester,
    ) async {
      const tmuxSessionName = 'main';
      const codexSession = ToolSessionInfo(
        toolName: 'Codex',
        sessionId: 'codex-session',
        workingDirectory: '/home/demo/project',
        summary: 'Resume codex work',
      );
      TmuxNavigatorAction? selectedAction;

      when(
        () => tmuxService.detectInstalledAgentTools(session),
      ).thenAnswer((_) async => const <AgentLaunchTool>{});

      when(
        () => tmuxService.listWindows(session, tmuxSessionName),
      ).thenAnswer((_) async => windows);
      when(
        () => discoveryService.discoverSessionsStream(
          session,
          workingDirectory: any(named: 'workingDirectory'),
          maxPerTool: any(named: 'maxPerTool'),
          toolName: any(named: 'toolName'),
        ),
      ).thenAnswer((invocation) {
        final toolName = invocation.namedArguments[#toolName] as String?;
        return Stream<DiscoveredSessionsResult>.value(
          DiscoveredSessionsResult(
            sessions: toolName == 'Codex'
                ? const <ToolSessionInfo>[codexSession]
                : const <ToolSessionInfo>[],
            attemptedTools: toolName == null ? const <String>[] : [toolName],
          ),
        );
      });
      when(
        () => discoveryService.buildResumeCommand(
          codexSession,
          startInYoloMode: true,
        ),
      ).thenReturn("codex --yolo resume 'codex-session'");

      await pumpNavigatorHost(
        tester,
        tmuxSessionName: tmuxSessionName,
        remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        startClisInYoloMode: true,
        onActionSelected: (action) => selectedAction = action,
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Recent terminal sessions'),
        160,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pump();
      await tester.tap(find.text('Recent terminal sessions'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Codex'));
      await tester.pump();
      await tester.tap(find.text('Codex'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Resume codex work'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Native chat'));
      await tester.pumpAndSettle();

      expect(selectedAction, isA<TmuxResumeAcpSessionAction>());
      final resumeAction = selectedAction! as TmuxResumeAcpSessionAction;
      expect(resumeAction.providerId, AcpBuiltinProviderIds.codex);
      expect(resumeAction.acpSessionId, codexSession.sessionId);
      expect(resumeAction.workingDirectory, '/home/demo/project');
      verifyNever(
        () => discoveryService.buildResumeCommand(
          codexSession,
          startInYoloMode: true,
        ),
      );
    });

    for (final (dispose, fail) in [
      (true, false),
      (true, true),
      (false, true),
    ]) {
      testWidgets(
        dispose
            ? 'does not run queued reload after disposal, failure=$fail'
            : 'ignores late failure after a newer window snapshot',
        (tester) async {
          final events = StreamController<TmuxWindowChangeEvent>();
          addTearDown(events.close);
          final pending = Completer<List<TmuxWindow>>();

          when(
            () => tmuxService.detectInstalledAgentTools(session),
          ).thenAnswer((_) async => const <AgentLaunchTool>{});
          when(
            () => tmuxService.watchWindowChanges(session, 'main'),
          ).thenAnswer((_) => events.stream);
          when(
            () => tmuxService.listWindows(session, 'main'),
          ).thenAnswer((_) => pending.future);
          when(
            () => discoveryService.discoverSessionsStream(
              session,
              workingDirectory: any(named: 'workingDirectory'),
              maxPerTool: any(named: 'maxPerTool'),
              toolName: any(named: 'toolName'),
            ),
          ).thenAnswer(
            (_) => Stream.value(
              DiscoveredSessionsResult(sessions: const <ToolSessionInfo>[]),
            ),
          );
          await pumpNavigatorHost(tester, tmuxSessionName: 'main');
          await tester.tap(find.text('Open'));
          await tester.pump();
          events.add(
            dispose
                ? const TmuxWindowReloadEvent()
                : TmuxWindowListEvent(windows),
          );
          await tester.pump();
          if (dispose) {
            await tester.pumpWidget(const SizedBox.shrink());
          } else {
            expect(find.text('✨ Editing main.dart'), findsOneWidget);
          }
          if (fail) {
            pending.completeError(Exception('late window failure'));
          } else {
            pending.complete(windows);
          }
          await tester.pump();
          await tester.pump(const Duration(seconds: 2));
          expect(tester.takeException(), isNull);
          verify(() => tmuxService.listWindows(session, 'main')).called(1);
          if (!dispose) {
            expect(find.text('✨ Editing main.dart'), findsOneWidget);
            expect(find.byType(CircularProgressIndicator), findsNothing);
            await tester.pumpWidget(const SizedBox.shrink());
          }
        },
      );
    }

    testWidgets('recovers from a transient empty window reload', (
      tester,
    ) async {
      const tmuxSessionName = 'main';
      var listWindowsCallCount = 0;

      when(
        () => tmuxService.detectInstalledAgentTools(session),
      ).thenAnswer((_) async => const <AgentLaunchTool>{});

      when(() => tmuxService.listWindows(session, tmuxSessionName)).thenAnswer((
        _,
      ) {
        if (listWindowsCallCount++ == 0) {
          return Future<List<TmuxWindow>>.value(const <TmuxWindow>[]);
        }
        return Future<List<TmuxWindow>>.value(windows);
      });
      when(
        () => discoveryService.discoverSessionsStream(
          session,
          workingDirectory: any(named: 'workingDirectory'),
          maxPerTool: any(named: 'maxPerTool'),
          toolName: any(named: 'toolName'),
        ),
      ).thenAnswer(
        (_) => Stream<DiscoveredSessionsResult>.value(
          DiscoveredSessionsResult(sessions: const <ToolSessionInfo>[]),
        ),
      );

      await pumpNavigatorHost(tester, tmuxSessionName: tmuxSessionName);

      await tester.tap(find.text('Open'));
      await tester.pump();

      expect(find.text('✨ Editing main.dart'), findsNothing);

      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(find.text('✨ Editing main.dart'), findsOneWidget);
    });

    testWidgets('contains SSH channel errors while loading windows', (
      tester,
    ) async {
      const tmuxSessionName = 'main';

      when(
        () => tmuxService.detectInstalledAgentTools(session),
      ).thenAnswer((_) async => const <AgentLaunchTool>{});

      when(() => tmuxService.listWindows(session, tmuxSessionName)).thenAnswer(
        (_) => Future<List<TmuxWindow>>.error(
          SSHChannelOpenError(1, 'administratively prohibited'),
        ),
      );
      when(
        () => discoveryService.discoverSessionsStream(
          session,
          workingDirectory: any(named: 'workingDirectory'),
          maxPerTool: any(named: 'maxPerTool'),
          toolName: any(named: 'toolName'),
        ),
      ).thenAnswer(
        (_) => Stream<DiscoveredSessionsResult>.value(
          DiscoveredSessionsResult(sessions: const <ToolSessionInfo>[]),
        ),
      );

      await pumpNavigatorHost(tester, tmuxSessionName: tmuxSessionName);
      await tester.tap(find.text('Open'));
      await tester.pump();

      expect(tester.takeException(), isNull);
      verify(() => tmuxService.listWindows(session, tmuxSessionName)).called(1);
    });

    testWidgets('stops showing an indefinite spinner after repeated empties', (
      tester,
    ) async {
      const tmuxSessionName = 'main';

      when(
        () => tmuxService.detectInstalledAgentTools(session),
      ).thenAnswer((_) async => const <AgentLaunchTool>{});

      when(
        () => tmuxService.listWindows(session, tmuxSessionName),
      ).thenAnswer((_) async => const <TmuxWindow>[]);
      when(
        () => discoveryService.discoverSessionsStream(
          session,
          workingDirectory: any(named: 'workingDirectory'),
          maxPerTool: any(named: 'maxPerTool'),
          toolName: any(named: 'toolName'),
        ),
      ).thenAnswer(
        (_) => Stream<DiscoveredSessionsResult>.value(
          DiscoveredSessionsResult(sessions: const <ToolSessionInfo>[]),
        ),
      );

      await pumpNavigatorHost(tester, tmuxSessionName: tmuxSessionName);

      await tester.tap(find.text('Open'));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsWidgets);

      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      expect(find.text('Could not load tmux windows.'), findsOneWidget);
    });

    test('maps every verified ACP adapter to its terminal tool', () {
      final mapping = nativeAcpProvidersByTool([
        for (final provider in acpBuiltinProviders) provider,
      ]);

      expect(
        mapping[AgentLaunchTool.copilotCli],
        AcpBuiltinProviderIds.copilotCli,
      );
      expect(
        mapping[AgentLaunchTool.claudeCode],
        AcpBuiltinProviderIds.claudeAgent,
      );
      expect(mapping[AgentLaunchTool.codex], AcpBuiltinProviderIds.codex);
      expect(mapping[AgentLaunchTool.openCode], AcpBuiltinProviderIds.openCode);
      expect(
        mapping[AgentLaunchTool.cursorAgent],
        AcpBuiltinProviderIds.cursorAgent,
      );
      expect(
        mapping[AgentLaunchTool.antigravity],
        AcpBuiltinProviderIds.antigravity,
      );
      expect(mapping[AgentLaunchTool.pi], AcpBuiltinProviderIds.pi);
    });

    testWidgets('app preference opens native chat without prompting', (
      tester,
    ) async {
      TmuxNavigatorAction? result;
      await tester.pumpWidget(
        _pickerHost((context) async {
          result = await showTmuxNewWindowPicker(
            context: context,
            isProUser: true,
            startClisInYoloMode: false,
            agentWindowModePreference: AgentWindowModePreference.preferNative,
            installedToolsFuture: Future.value(const <AgentLaunchTool>{
              AgentLaunchTool.copilotCli,
            }),
            nativeAcpProviderIds: const <AgentLaunchTool, String>{
              AgentLaunchTool.copilotCli: AcpBuiltinProviderIds.copilotCli,
            },
          );
        }),
      );

      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);

      await tester.tap(find.text('Copilot CLI'));
      await tester.pumpAndSettle();

      expect(find.text('Terminal'), findsNothing);
      expect(result, isA<TmuxNewAcpSessionAction>());
    });

    testWidgets('free app preference opens terminal without prompting', (
      tester,
    ) async {
      TmuxNavigatorAction? result;
      await tester.pumpWidget(
        _pickerHost((context) async {
          result = await showTmuxNewWindowPicker(
            context: context,
            isProUser: false,
            startClisInYoloMode: false,
            agentWindowModePreference: AgentWindowModePreference.preferTerminal,
            installedToolsFuture: Future.value(const <AgentLaunchTool>{
              AgentLaunchTool.openCode,
            }),
            nativeAcpProviderIds: const <AgentLaunchTool, String>{
              AgentLaunchTool.openCode: AcpBuiltinProviderIds.openCode,
            },
          );
        }),
      );

      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);

      await tester.tap(find.text('OpenCode'));
      await tester.pumpAndSettle();

      expect(find.text('Native chat'), findsNothing);
      expect(result, isA<TmuxNewWindowAction>());
    });

    testWidgets('long press overrides the app preference for one launch', (
      tester,
    ) async {
      TmuxNavigatorAction? result;
      await tester.pumpWidget(
        _pickerHost((context) async {
          result = await showTmuxNewWindowPicker(
            context: context,
            isProUser: true,
            startClisInYoloMode: false,
            agentWindowModePreference: AgentWindowModePreference.preferNative,
            installedToolsFuture: Future.value(const <AgentLaunchTool>{
              AgentLaunchTool.copilotCli,
            }),
            nativeAcpProviderIds: const <AgentLaunchTool, String>{
              AgentLaunchTool.copilotCli: AcpBuiltinProviderIds.copilotCli,
            },
          );
        }),
      );

      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Copilot CLI'));
      await tester.pumpAndSettle();

      expect(find.text('Terminal'), findsOneWidget);
      expect(find.text('Native chat'), findsOneWidget);
      expect(find.text('Remember this choice'), findsOneWidget);

      await tester.tap(find.text('Terminal'));
      await tester.pumpAndSettle();
      expect(result, isA<TmuxNewWindowAction>());
    });

    testWidgets('ellipsis chooses a mode and remembers it app-wide', (
      tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      TmuxNavigatorAction? result;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(database)],
          child: _pickerHost((context) async {
            result = await showTmuxNewWindowPicker(
              context: context,
              isProUser: true,
              startClisInYoloMode: false,
              agentWindowModePreference:
                  AgentWindowModePreference.preferTerminal,
              installedToolsFuture: Future.value(const <AgentLaunchTool>{
                AgentLaunchTool.copilotCli,
              }),
              nativeAcpProviderIds: const <AgentLaunchTool, String>{
                AgentLaunchTool.copilotCli: AcpBuiltinProviderIds.copilotCli,
              },
            );
          }),
        ),
      );

      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('agent-window-mode-options-copilotCli')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Terminal'), findsOneWidget);
      expect(find.text('Native chat'), findsOneWidget);
      await tester.tap(find.text('Remember this choice'));
      await tester.pump();
      await tester.tap(find.text('Native chat'));
      await tester.pumpAndSettle();

      expect(result, isA<TmuxNewAcpSessionAction>());
      expect(
        await SettingsService(
          database,
        ).getString(SettingKeys.agentWindowModePreference),
        'native',
      );
    });

    testWidgets('free user can choose terminal for an ACP-capable tool', (
      tester,
    ) async {
      TmuxNavigatorAction? result;
      await tester.pumpWidget(
        _pickerHost((context) async {
          result = await showTmuxNewWindowPicker(
            context: context,
            isProUser: false,
            startClisInYoloMode: false,
            installedToolsFuture: Future.value(const <AgentLaunchTool>{
              AgentLaunchTool.copilotCli,
            }),
            nativeAcpProviderIds: const <AgentLaunchTool, String>{
              AgentLaunchTool.copilotCli: AcpBuiltinProviderIds.copilotCli,
            },
          );
        }),
      );

      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);

      await tester.tap(find.text('Copilot CLI'));
      await tester.pumpAndSettle();
      expect(find.text('Terminal'), findsOneWidget);
      expect(find.text('Native chat'), findsOneWidget);
      expect(find.byType(PremiumBadge), findsNothing);

      await tester.tap(find.text('Terminal'));
      await tester.pumpAndSettle();

      expect(result, isA<TmuxNewWindowAction>());
      expect(
        (result! as TmuxNewWindowAction).agentTool,
        AgentLaunchTool.copilotCli,
      );
    });

    testWidgets('terminal/native selector stays above the keyboard', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(390, 844)
        ..devicePixelRatio = 1
        ..viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(() {
        tester.view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio()
          ..resetViewInsets();
      });
      await tester.pumpWidget(
        _pickerHost(
          (context) => showTmuxNewWindowPicker(
            context: context,
            isProUser: true,
            startClisInYoloMode: false,
            installedToolsFuture: Future.value(const <AgentLaunchTool>{
              AgentLaunchTool.copilotCli,
            }),
            nativeAcpProviderIds: const <AgentLaunchTool, String>{
              AgentLaunchTool.copilotCli: AcpBuiltinProviderIds.copilotCli,
            },
          ),
        ),
      );

      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copilot CLI'));
      await tester.pumpAndSettle();

      final nativeChat = find.text('Native chat');
      expect(nativeChat, findsOneWidget);
      expect(tester.getBottomLeft(nativeChat).dy, lessThan(844 - 300));
      expect(
        tester
            .widgetList<AnimatedPadding>(find.byType(AnimatedPadding))
            .any(
              (widget) => widget.padding == const EdgeInsets.only(bottom: 300),
            ),
        isTrue,
      );
    });

    testWidgets('Pro user can choose terminal mode for an ACP-capable tool', (
      tester,
    ) async {
      TmuxNavigatorAction? result;
      await tester.pumpWidget(
        _pickerHost((context) async {
          result = await showTmuxNewWindowPicker(
            context: context,
            isProUser: true,
            startClisInYoloMode: false,
            installedToolsFuture: Future.value(const <AgentLaunchTool>{
              AgentLaunchTool.openCode,
            }),
            nativeAcpProviderIds: const <AgentLaunchTool, String>{
              AgentLaunchTool.openCode: AcpBuiltinProviderIds.openCode,
            },
          );
        }),
      );

      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OpenCode'));
      await tester.pumpAndSettle();
      final terminalTile = tester.widget<ListTile>(
        find.widgetWithText(ListTile, 'Terminal'),
      );
      expect(terminalTile.enabled, isTrue);

      await tester.tap(find.text('Terminal'));
      await tester.pumpAndSettle();

      expect(result, isA<TmuxNewWindowAction>());
      final action = result! as TmuxNewWindowAction;
      expect(action.windowName, 'opencode');
      expect(action.agentTool, AgentLaunchTool.openCode);
    });

    testWidgets('free tool without ACP support opens a terminal directly', (
      tester,
    ) async {
      TmuxNavigatorAction? result;
      await tester.pumpWidget(
        _pickerHost((context) async {
          result = await showTmuxNewWindowPicker(
            context: context,
            isProUser: false,
            startClisInYoloMode: false,
            installedToolsFuture: Future.value(const <AgentLaunchTool>{
              AgentLaunchTool.claudeCode,
            }),
          );
        }),
      );

      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Claude Code'));
      await tester.pumpAndSettle();

      expect(find.text('Native chat'), findsNothing);
      expect(result, isA<TmuxNewWindowAction>());
      expect(
        (result! as TmuxNewWindowAction).agentTool,
        AgentLaunchTool.claudeCode,
      );
    });

    testWidgets('tmux navigator remains terminal-only', (tester) async {
      const tmuxSessionName = 'main';
      TmuxNavigatorAction? selected;

      when(
        () => tmuxService.listWindows(session, tmuxSessionName),
      ).thenAnswer((_) async => windows);
      when(() => tmuxService.detectInstalledAgentTools(session)).thenAnswer(
        (_) async => const <AgentLaunchTool>{AgentLaunchTool.copilotCli},
      );

      await pumpNavigatorHost(
        tester,
        tmuxSessionName: tmuxSessionName,
        acpManager: FakeAcpSessionManager(
          sessions: [fakeAcpSession(title: 'Native only')],
        ),
        onActionSelected: (action) => selected = action,
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('agent windows'), findsNothing);

      await tester.tap(find.text('New window'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copilot CLI'));
      await tester.pumpAndSettle();

      expect(find.text('Native chat'), findsNothing);
      expect(selected, isA<TmuxNewWindowAction>());
    });

    testWidgets('free navigator offers recent terminal sessions with Pro', (
      tester,
    ) async {
      TmuxNavigatorAction? selected;

      when(
        () => tmuxService.listWindows(session, 'main'),
      ).thenAnswer((_) async => windows);

      await pumpNavigatorHost(
        tester,
        tmuxSessionName: 'main',
        isProUser: false,
        onActionSelected: (action) => selected = action,
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Recent terminal sessions'), findsOneWidget);
      expect(
        find.text('Discover and resume agent work across windows'),
        findsOneWidget,
      );

      final upgrade = find.byKey(
        const ValueKey('recent-terminal-sessions-upgrade'),
      );
      await tester.ensureVisible(upgrade);
      await tester.pumpAndSettle();
      await tester.tap(upgrade);
      await tester.pumpAndSettle();
      expect(selected, isA<TmuxUpgradeAction>());
      expect(
        (selected! as TmuxUpgradeAction).feature,
        MonetizationFeature.agentLaunchPresets,
      );
    });

    testWidgets('MonkeyMux omits the custom native provider action', (
      tester,
    ) async {
      await tester.pumpWidget(
        _pickerHost(
          (context) => showTmuxNewWindowPicker(
            context: context,
            isProUser: false,
            startClisInYoloMode: false,
            installedToolsFuture: Future.value(const <AgentLaunchTool>{}),
          ),
        ),
      );

      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();

      expect(find.text('Custom native chat'), findsNothing);
      expect(find.text('Choose an agent provider'), findsNothing);
      expect(find.text('Empty terminal'), findsOneWidget);
    });

    testWidgets('MonkeyMux navigator lists and opens native ACP sessions', (
      tester,
    ) async {
      const tmuxSessionName = 'main';
      final key = fakeAcpKey();
      final manager = FakeAcpSessionManager(
        sessions: [
          fakeAcpSession(
            key: key,
            title: 'Fix authentication',
            cwd: '/home/dev/monkeyssh',
            promptStatus: AcpPromptStatus.streaming,
            plan: _halfFinishedPlan(AcpPlanPriority.medium),
          ),
          fakeAcpSession(
            key: fakeAcpKey(acpSessionId: 'failed-session'),
            title: 'Failed native session',
            status: AcpConnectionStatus.failed,
          ),
        ],
        recents: [
          AcpRecentSessionRef(
            hostId: key.hostId,
            providerId: key.providerId,
            bridgeId: 'archived-bridge',
            acpSessionId: 'archived-session',
            title: 'Archived native session',
            cwd: '/home/dev/monkeyssh',
            createdAt: DateTime(2025),
            lastActivityAt: DateTime(2026),
          ),
        ],
      );
      TmuxNavigatorAction? selected;

      when(
        () => tmuxService.listWindows(session, tmuxSessionName),
      ).thenAnswer((_) async => windows);

      await pumpNavigatorHost(
        tester,
        tmuxSessionName: tmuxSessionName,
        remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        acpManager: manager,
        onActionSelected: (action) => selected = action,
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('agent windows'),
        160,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('agent windows'), findsOneWidget);
      expect(find.text('Fix authentication'), findsOneWidget);
      expect(find.text('Failed native session'), findsNothing);
      expect(find.text('Archived native session'), findsNothing);
      final nativeRow = find.byKey(ValueKey('native-acp-session-${key.value}'));
      expect(find.text('Copilot CLI · …/monkeyssh · working'), findsOneWidget);
      expect(
        find.descendant(of: nativeRow, matching: find.text('running')),
        findsOneWidget,
      );
      final numberSlot = find.byKey(
        ValueKey('native-acp-number-slot-${key.value}'),
      );
      expect(numberSlot, findsOneWidget);
      expect(
        find.descendant(of: numberSlot, matching: find.text('4')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: nativeRow,
          matching: find.byIcon(Icons.smart_toy_outlined),
        ),
        findsNothing,
      );
      final scheme = Theme.of(tester.element(nativeRow)).colorScheme;
      final tile = tester.widget<ListTile>(nativeRow);
      expect(tile.dense, isTrue);
      expect(tile.visualDensity, const VisualDensity(vertical: -2));
      expect(tester.getSize(numberSlot), const Size.square(24));
      final agentIcon = tester.widget<AgentToolIcon>(
        find.descendant(of: nativeRow, matching: find.byType(AgentToolIcon)),
      );
      expect(agentIcon.tool, AgentLaunchTool.copilotCli);
      expect(agentIcon.size, 16);
      expect(agentIcon.color, scheme.onSurfaceVariant);
      final subtitle = tester.widget<Text>(
        find.byKey(ValueKey('native-acp-subtitle-${key.value}')),
      );
      expect(subtitle.style?.color, scheme.onSurfaceVariant);
      expect(
        find.byKey(ValueKey('native-acp-indicator-${key.value}')),
        findsOneWidget,
      );
      expect(
        tester.getSize(
          find.byKey(ValueKey('native-acp-indicator-${key.value}')),
        ),
        const Size.square(12),
      );
      expect(
        find.byKey(ValueKey('native-acp-progress-${key.value}')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: nativeRow,
          matching: find.byTooltip('Close window'),
        ),
        findsOneWidget,
      );

      await tester.ensureVisible(find.text('Fix authentication'));
      await tester.pump();
      await tester.tap(find.text('Fix authentication'));
      await tester.pumpAndSettle();

      expect(selected, isA<TmuxOpenAcpSessionAction>());
      expect((selected! as TmuxOpenAcpSessionAction).key, key);
    });

    testWidgets(
      'durable native window keeps panel title badges and progress live',
      (tester) async {
        const tmuxSessionName = 'main';
        final key = fakeAcpKey();
        final manager = FakeAcpSessionManager(
          sessions: [
            fakeAcpSession(
              key: key,
              title: 'Live panel title',
              promptStatus: AcpPromptStatus.streaming,
              plan: _halfFinishedPlan(AcpPlanPriority.medium),
            ),
          ],
        );
        final windowEvents = StreamController<TmuxWindowChangeEvent>();
        addTearDown(windowEvents.close);
        var windows = <TmuxWindow>[
          TmuxWindow(
            index: 3,
            id: '@4',
            name: 'Copilot CLI',
            isActive: false,
            currentPath: '/home/dev/project',
            nativeAcpBridgeId: key.bridgeId,
            nativeAcpProviderId: key.providerId,
          ),
          const TmuxWindow(
            index: 4,
            id: '@5',
            name: 'Terminal Copilot',
            isActive: false,
            currentCommand: 'copilot',
            currentPath: '/home/dev/project',
            agentTool: AgentLaunchTool.copilotCli,
          ),
          const TmuxWindow(
            index: 5,
            id: '@6',
            name: 'zsh',
            isActive: true,
            currentCommand: 'zsh',
          ),
        ];
        TmuxNavigatorAction? selected;

        when(
          () => tmuxService.watchWindowChanges(session, tmuxSessionName),
        ).thenAnswer((_) => windowEvents.stream);
        when(
          () => tmuxService.listWindows(session, tmuxSessionName),
        ).thenAnswer((_) async => windows);

        await pumpNavigatorHost(
          tester,
          tmuxSessionName: tmuxSessionName,
          remoteMuxBackend: RemoteMuxBackend.monkeyMux,
          acpManager: manager,
          onActionSelected: (action) => selected = action,
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();

        expect(find.text('Live panel title'), findsOneWidget);
        expect(find.text('agent windows'), findsNothing);
        expect(
          find.byKey(const ValueKey('native-acp-window-indicator-3')),
          findsOneWidget,
        );
        final nativeBadge = find.byKey(
          const ValueKey('native-acp-window-indicator-3'),
        );
        expect(tester.getSize(nativeBadge), const Size.square(12));
        expect(
          find.ancestor(
            of: nativeBadge,
            matching: find.byType(AcpNativeBadgeOverlay),
          ),
          findsOneWidget,
        );
        final nativeRow = find.byKey(const ValueKey('tmux-window-3'));
        expect(
          find.descendant(of: nativeRow, matching: find.text('running')),
          findsOneWidget,
        );
        final scheme = Theme.of(tester.element(nativeRow)).colorScheme;
        final nativeIcon = tester.widget<AgentToolIcon>(
          find.byKey(const ValueKey('tmux-window-agent-icon-3')),
        );
        final terminalIcon = tester.widget<AgentToolIcon>(
          find.byKey(const ValueKey('tmux-window-agent-icon-4')),
        );
        expect(nativeIcon.color, scheme.onSurfaceVariant);
        expect(terminalIcon.color, nativeIcon.color);

        List<TmuxWindow> activityWindows({required bool active}) => [
          windows.first.copyWith(isActive: active),
          const TmuxWindow(
            index: 4,
            id: '@5',
            name: 'Terminal Copilot',
            isActive: false,
            agentTool: AgentLaunchTool.copilotCli,
          ),
          TmuxWindow(index: 5, id: '@6', name: 'zsh', isActive: !active),
        ];
        windows = activityWindows(active: true);
        windowEvents.add(TmuxWindowListEvent(windows));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          tester
              .widget<AgentToolIcon>(
                find.byKey(const ValueKey('tmux-window-agent-icon-3')),
              )
              .color,
          scheme.primary,
        );

        windows = activityWindows(active: false);
        windowEvents.add(TmuxWindowListEvent(windows));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          tester
              .widget<AgentToolIcon>(
                find.byKey(const ValueKey('tmux-window-agent-icon-3')),
              )
              .color,
          scheme.onSurfaceVariant,
        );
        expect(
          find.byKey(const ValueKey('native-acp-window-progress-3')),
          findsOneWidget,
        );

        manager.emit(
          AcpSessionManagerState(
            sessions: [
              fakeAcpSession(
                key: key,
                title: 'Live panel title',
                status: AcpConnectionStatus.reconnecting,
              ),
            ],
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        final reconnectingNativeIcon = tester.widget<AgentToolIcon>(
          find.byKey(const ValueKey('tmux-window-agent-icon-3')),
        );
        final nativeSubtitle = tester.widget<Text>(
          find.byKey(const ValueKey('tmux-window-subtitle-3')),
        );
        expect(reconnectingNativeIcon.color, scheme.onSurfaceVariant);
        expect(nativeSubtitle.style?.color, scheme.onSurfaceVariant);
        expect(
          tester
              .widget<AcpNativeBadge>(
                find.byKey(const ValueKey('native-acp-window-indicator-3')),
              )
              .color,
          scheme.onSurfaceVariant,
        );
        expect(find.text('reconnecting'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('native-acp-window-progress-3')),
          findsNothing,
        );

        manager.emit(
          AcpSessionManagerState(
            sessions: [
              fakeAcpSession(
                key: key,
                title: 'Synchronized panel title',
                promptStatus: AcpPromptStatus.streaming,
              ),
            ],
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('Live panel title'), findsNothing);
        expect(find.text('Synchronized panel title'), findsOneWidget);

        await tester.tap(find.text('Synchronized panel title'));
        await tester.pumpAndSettle();
        expect(selected, isA<TmuxOpenAcpWindowAction>());
        final action = selected! as TmuxOpenAcpWindowAction;
        expect(action.windowIndex, 3);
        expect(action.bridgeId, key.bridgeId);
        expect(action.providerId, key.providerId);
      },
    );
  });
}

class _MockTmuxService extends Mock implements TmuxService {}

class _MockAgentLaunchPresetService extends Mock
    implements AgentLaunchPresetService {}

class _MockAgentSessionDiscoveryService extends Mock
    implements AgentSessionDiscoveryService {}

class _MockSshClient extends Mock implements SSHClient {}

Widget _pickerHost(Future<void> Function(BuildContext) open) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () => unawaited(open(context)),
        child: const Text('Open picker'),
      ),
    ),
  ),
);

SshSession _navigatorSession() => SshSession(
  connectionId: 1,
  hostId: 1,
  client: _MockSshClient(),
  config: const SshConnectionConfig(
    hostname: 'example.com',
    port: 22,
    username: 'demo',
  ),
);

List<AcpPlanEntry> _halfFinishedPlan(AcpPlanPriority nextPriority) => [
  const AcpPlanEntry(
    content: 'done',
    priority: AcpPlanPriority.high,
    status: AcpPlanStatus.completed,
  ),
  AcpPlanEntry(
    content: 'next',
    priority: nextPriority,
    status: AcpPlanStatus.inProgress,
  ),
];
