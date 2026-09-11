// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/acp_attachment.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_native_preview.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_recent_session.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_timeline.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';
import 'package:monkeyssh/domain/models/host_cli_launch_preferences.dart';
import 'package:monkeyssh/domain/services/acp_concurrency_policy.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/host_cli_launch_preferences_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/screens/agent_chat_screen.dart';
import 'package:monkeyssh/presentation/widgets/acp_chat_typography.dart';
import 'package:monkeyssh/presentation/widgets/acp_composer.dart';
import 'package:monkeyssh/presentation/widgets/acp_inline_image.dart';
import 'package:monkeyssh/presentation/widgets/acp_message_thread.dart';
import 'package:monkeyssh/presentation/widgets/acp_permission_surface.dart';
import 'package:monkeyssh/presentation/widgets/cursor_block.dart';
import 'package:monkeyssh/presentation/widgets/terminal_pinch_zoom_gesture_handler.dart';

import '../support/fake_acp_session_manager.dart';

class _MockSshService extends Mock implements SshService {}

class _MockHostCliLaunchPreferencesService extends Mock
    implements HostCliLaunchPreferencesService {}

class _MockSshSession extends Mock implements SshSession {}

class _FakeSftpClient extends Fake implements SftpClient {}

class _MockSftpClient extends Mock implements SftpClient {}

class _MockSftpFile extends Mock implements SftpFile {}

Widget _wrap(
  FakeAcpSessionManager manager, {
  Size size = const Size(390, 800),
  AcpSessionKey? routeKey,
  bool hasActiveSshSession = false,
  bool embedded = false,
  bool connectOnMount = true,
  double? preferredFontSize,
  String? preferredFontFamily,
  ValueChanged<double>? onFontSizeCommitted,
  AcpChatPreviewChanged? onPreviewChanged,
  AcpChatNativePreviewChanged? onNativePreviewChanged,
  AcpChatScrollState? initialScrollState,
  AcpChatScrollChanged? onScrollChanged,
  SftpClient? sftpClient,
  AcpChatAttachmentActionsBuilder? attachmentActionsBuilder,
  EdgeInsets mediaPadding = EdgeInsets.zero,
}) {
  final ssh = _MockSshService();
  final launchPreferences = _MockHostCliLaunchPreferencesService();
  final key = routeKey ?? fakeAcpKey();
  final sshSession = _MockSshSession();
  when(() => sshSession.connectionId).thenReturn(7);
  when(() => sshSession.hostId).thenReturn(key.hostId);
  when(
    sshSession.sftp,
  ).thenAnswer((_) async => sftpClient ?? _FakeSftpClient());
  when(() => ssh.getSessionsForHost(any())).thenReturn(
    hasActiveSshSession ? <SshSession>[sshSession] : const <SshSession>[],
  );
  when(
    () => launchPreferences.getPreferencesForHost(any()),
  ).thenAnswer((_) async => const HostCliLaunchPreferences());
  return ProviderScope(
    overrides: [
      acpSessionManagerProvider.overrideWithValue(manager),
      sshServiceProvider.overrideWithValue(ssh),
      hostCliLaunchPreferencesServiceProvider.overrideWithValue(
        launchPreferences,
      ),
    ],
    child: MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          padding: mediaPadding,
          viewPadding: mediaPadding,
        ),
        child: AgentChatScreen(
          hostId: key.hostId,
          providerId: key.providerId,
          bridgeId: key.bridgeId,
          acpSessionId: key.acpSessionId,
          attachmentActionsBuilder:
              attachmentActionsBuilder ??
              (_, _) => const AcpComposerAttachmentActions(),
          embedded: embedded,
          connectOnMount: connectOnMount,
          preferredFontSize: preferredFontSize,
          preferredFontFamily: preferredFontFamily,
          onFontSizeCommitted: onFontSizeCommitted,
          onPreviewChanged: onPreviewChanged,
          onNativePreviewChanged: onNativePreviewChanged,
          initialScrollState: initialScrollState,
          onScrollChanged: onScrollChanged,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('unrelated session updates do not rebuild the conversation', (
    tester,
  ) async {
    final current = fakeAcpSession(
      timeline: fakeAcpTimeline('Current conversation'),
    );
    final other = fakeAcpSession(key: fakeAcpKey(acpSessionId: 'other'));
    final manager = FakeAcpSessionManager(sessions: [current, other]);
    await tester.pumpWidget(_wrap(manager));
    await tester.pumpAndSettle();
    final thread = tester.widget<AcpMessageThread>(
      find.byType(AcpMessageThread),
    );
    manager.emit(
      AcpSessionManagerState(
        sessions: [
          current,
          other.copyWith(timeline: fakeAcpTimeline('Unrelated update')),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(
      identical(
        tester.widget<AcpMessageThread>(find.byType(AcpMessageThread)),
        thread,
      ),
      isTrue,
    );
    manager.emit(
      AcpSessionManagerState(
        sessions: [
          current.copyWith(timeline: fakeAcpTimeline('Current updated')),
          other,
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Current updated'), findsOneWidget);
  });

  testWidgets('renders the live timeline and composer on mobile', (
    tester,
  ) async {
    final session = fakeAcpSession(
      timeline: fakeAcpTimeline('Hello from the agent'),
    );
    await tester.pumpWidget(_wrap(FakeAcpSessionManager(sessions: [session])));
    await tester.pumpAndSettle();

    expect(find.byType(AcpMessageThread), findsOneWidget);
    expect(
      tester.widget<AcpMessageThread>(find.byType(AcpMessageThread)).onTapLink,
      isNotNull,
    );
    expect(find.textContaining('Hello from the agent'), findsOneWidget);
    expect(find.byType(AcpComposer), findsOneWidget);
    expect(find.byTooltip('MonkeyMux windows'), findsOneWidget);
    expect(find.byTooltip('Session settings'), findsNothing);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Session settings'), findsOneWidget);
  });

  testWidgets('empty state exposes accelerators and fallback YOLO mode', (
    tester,
  ) async {
    final manager = FakeAcpSessionManager(sessions: [fakeAcpSession()]);
    await tester.pumpWidget(_wrap(manager));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Switch agent session'), findsOneWidget);
    expect(find.textContaining('Type / for commands'), findsOneWidget);
    expect(find.textContaining('Ctrl/⌘ + Enter'), findsOneWidget);
    expect(find.textContaining('pinch to resize'), findsOneWidget);
    expect(find.textContaining('title for sessions'), findsOneWidget);
    expect(find.textContaining('windows stay in the top bar'), findsOneWidget);
    expect(find.text('Ask'), findsOneWidget);
    expect(find.text('Permission'), findsNothing);

    await tester.tap(find.byTooltip('Change permission'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('YOLO').last);
    await tester.pumpAndSettle();
    expect(manager.autoApprovePermissionSets, [true]);
  });

  testWidgets('publishes a throttled native connection preview', (
    tester,
  ) async {
    final previews = <String?>[];
    final nativePreviews = <AcpNativePreviewSnapshot?>[];
    final previewKeys = <AcpSessionKey>[];
    final session = fakeAcpSession(
      timeline: fakeAcpTimeline('Preview from the native agent'),
    );
    await tester.pumpWidget(
      _wrap(
        FakeAcpSessionManager(sessions: [session]),
        embedded: true,
        onPreviewChanged: (key, preview) {
          previewKeys.add(key);
          previews.add(preview);
        },
        onNativePreviewChanged: (_, preview) => nativePreviews.add(preview),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(previews, isNotEmpty);
    expect(previewKeys.single.value, fakeAcpKey().value);
    expect(previews.last, contains('Preview from the native agent'));
    expect(nativePreviews, isNotEmpty);
    expect(
      nativePreviews.last!.lines.any(
        (line) =>
            line.kind == AcpNativePreviewKind.agent &&
            line.text.contains('Preview from the native agent'),
      ),
      isTrue,
    );
  });

  testWidgets('Pi model picker reads scope metadata and expands all models', (
    tester,
  ) async {
    final sftp = _MockSftpClient();
    final settingsFile = _MockSftpFile();
    final settingsBytes = Uint8List.fromList(
      utf8.encode('{"enabledModels":["anthropic/*:high"]}'),
    );
    const globalSettingsPath = '/home/demo/.pi/agent/settings.json';
    when(() => sftp.absolute('.')).thenAnswer((_) async => '/home/demo');
    when(() => sftp.stat(any(), followLink: false)).thenAnswer((
      invocation,
    ) async {
      final path = invocation.positionalArguments.single as String;
      if (path == globalSettingsPath) {
        return SftpFileAttrs(size: settingsBytes.length);
      }
      throw StateError('missing optional project settings');
    });
    when(
      () => sftp.open(globalSettingsPath),
    ).thenAnswer((_) async => settingsFile);
    when(settingsFile.read).thenAnswer((_) => Stream.value(settingsBytes));
    when(settingsFile.close).thenAnswer((_) async {});

    final key = fakeAcpKey(providerId: AcpBuiltinProviderIds.pi);
    final manager = FakeAcpSessionManager(
      sessions: [
        fakeAcpSession(
          key: key,
          providerLabel: 'Pi',
          configOptions: const [
            AcpSelectConfigOption(
              id: 'model',
              name: 'Model',
              category: 'model',
              currentValue: 'anthropic/claude-sonnet',
              options: [
                AcpConfigValue(
                  value: 'anthropic/claude-sonnet',
                  name: 'anthropic/Claude Sonnet',
                ),
                AcpConfigValue(value: 'openai/gpt-5', name: 'openai/GPT-5'),
                AcpConfigValue(
                  value: 'google/gemini-pro',
                  name: 'google/Gemini Pro',
                ),
              ],
            ),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      _wrap(
        manager,
        routeKey: key,
        hasActiveSshSession: true,
        sftpClient: sftp,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Change model'));
    await tester.pumpAndSettle();
    expect(find.text('Model'), findsOneWidget);
    expect(find.text('Scoped models'), findsOneWidget);
    expect(find.text('anthropic/Claude Sonnet'), findsNWidgets(2));
    expect(find.text('openai/GPT-5'), findsNothing);
    expect(find.text('google/Gemini Pro'), findsNothing);

    await tester.tap(find.text('Show all models'));
    await tester.pumpAndSettle();
    expect(find.text('All models'), findsOneWidget);
    expect(find.text('anthropic/Claude Sonnet'), findsNWidgets(2));
    expect(find.text('openai/GPT-5'), findsOneWidget);
    expect(find.text('google/Gemini Pro'), findsOneWidget);
  });

  testWidgets(
    'keeps session controls reachable in a scrollable row at 320 px',
    (tester) async {
      final manager = FakeAcpSessionManager(
        sessions: [
          fakeAcpSession(
            configOptions: const [
              AcpSelectConfigOption(
                id: 'model',
                name: 'Model',
                currentValue: 'sonnet',
                category: 'model',
                options: [
                  AcpConfigValue(value: 'sonnet', name: 'Sonnet'),
                  AcpConfigValue(value: 'opus', name: 'Opus'),
                ],
              ),
              AcpSelectConfigOption(
                id: 'effort',
                name: 'Reasoning effort',
                currentValue: 'medium',
                category: 'thought',
                options: [
                  AcpConfigValue(value: 'medium', name: 'Medium'),
                  AcpConfigValue(value: 'high', name: 'High'),
                ],
              ),
              AcpBooleanConfigOption(
                id: 'yolo',
                name: 'Auto-approve',
                category: 'permissions',
                currentValue: false,
              ),
              AcpSelectConfigOption(
                id: 'fast-mode',
                name: 'Fast mode',
                currentValue: 'off',
                category: 'model_config',
                options: [
                  AcpConfigValue(value: 'off', name: 'Off'),
                  AcpConfigValue(value: 'on', name: 'On'),
                ],
              ),
            ],
            modeState: const AcpSessionModeState(
              currentModeId: 'code',
              availableModes: [
                AcpSessionMode(id: 'code', name: 'Code'),
                AcpSessionMode(id: 'ask', name: 'Ask'),
              ],
            ),
          ),
        ],
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(320, 640));
      await tester.pumpWidget(
        _wrap(
          manager,
          size: const Size(320, 640),
          embedded: true,
          preferredFontSize: 20,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(AgentChatScreen)).width, 320);
      expect(tester.takeException(), isNull);

      expect(find.byType(AppBar), findsNothing);
      expect(find.text('Sonnet'), findsOneWidget);
      expect(find.text('Medium'), findsOneWidget);
      final controls = find.byKey(const ValueKey('acp-composer-controls'));
      final scrollable = find.descendant(
        of: controls,
        matching: find.byType(Scrollable),
      );
      expect(scrollable, findsOneWidget);
      final scrollState = tester.state<ScrollableState>(scrollable);
      expect(scrollState.position.pixels, 0);
      expect(scrollState.position.maxScrollExtent, greaterThan(0));
      final viewport = tester.getRect(controls);
      for (final label in ['Sonnet', 'Medium']) {
        expect(find.text(label).hitTestable(), findsOneWidget);
        expect(
          viewport.overlaps(tester.getRect(find.text(label))),
          isTrue,
          reason: '$label should be visible before scrolling',
        );
      }
      expect(find.text('Model'), findsNothing);
      expect(find.text('Effort'), findsNothing);
      expect(find.text('Mode'), findsNothing);
      expect(find.text('Permission'), findsNothing);
      final permissionPill = find.byKey(const ValueKey('permission-mode-pill'));
      final modelPill = find.byKey(
        const ValueKey('acp-quick-selector-pill-Model'),
      );
      final effortPill = find.byKey(
        const ValueKey('acp-quick-selector-pill-Effort'),
      );
      expect(tester.getSize(modelPill).height, 40);
      expect(
        tester.getTopLeft(effortPill).dx - tester.getTopRight(modelPill).dx,
        FluttyTheme.spacingXs,
        reason: 'selector pills should flow without fixed-width dead space',
      );
      final selectorContext = tester.element(find.text('Sonnet'));
      final modelInk = tester.widget<Ink>(modelPill);
      final modelDecoration = modelInk.decoration! as BoxDecoration;
      expect(
        modelDecoration.color,
        Theme.of(selectorContext).colorScheme.surfaceContainerHighest,
      );
      expect(modelDecoration.border, isNull);
      expect(modelDecoration.borderRadius, BorderRadius.circular(12));
      final modelLabel = tester.widget<Text>(find.text('Sonnet'));
      expect(
        modelLabel.style?.fontFamily,
        isNot(AcpChatTypography.monoStyleOf(selectorContext).fontFamily),
      );
      expect(modelLabel.style?.fontSize, 12);
      expect(modelLabel.style?.height, 1.15);
      expect(modelLabel.style?.fontWeight, FontWeight.w600);
      expect(MediaQuery.of(selectorContext).textScaler.scale(14), 14);

      // Scroll the actual selector viewport so lazy children must be built and
      // revealed, rather than counting cached children outside the viewport.
      for (final entry in const {
        'model': 'Sonnet',
        'effort': 'Medium',
        'mode': 'Code',
        'permission': 'Ask',
      }.entries) {
        final pill = find.byTooltip('Change ${entry.key}');
        final pillLabel = find.text(entry.value);
        await tester.scrollUntilVisible(pill, 80, scrollable: scrollable);
        await tester.pumpAndSettle();
        expect(pillLabel, findsOneWidget);
        expect(pillLabel.hitTestable(), findsOneWidget);
        expect(pill.hitTestable(), findsOneWidget);
        final pillRect = tester.getRect(pill);
        expect(pillRect.left, greaterThanOrEqualTo(viewport.left));
        expect(pillRect.right, lessThanOrEqualTo(viewport.right));
      }
      expect(tester.getSize(permissionPill).height, 44);
      expect(
        find.ancestor(of: permissionPill, matching: find.byType(ListView)),
        findsOneWidget,
        reason:
            'permission belongs in the same scrolling row as every selector',
      );
      final surface = find.byKey(const ValueKey('acp-composer-surface'));
      expect(find.ancestor(of: controls, matching: surface), findsOneWidget);

      await tester.scrollUntilVisible(
        find.byTooltip('Change model'),
        -80,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Sonnet')).dy,
        greaterThan(tester.getTopLeft(find.byType(AcpComposer)).dy),
      );

      await tester.tap(find.byTooltip('Change model'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Opus').last);
      await tester.pumpAndSettle();
      expect(manager.configOptionSets, contains(('model', 'opus')));

      await tester.scrollUntilVisible(
        find.byTooltip('Change effort'),
        80,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Change effort'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('High').last);
      await tester.pumpAndSettle();
      expect(manager.configOptionSets, contains(('effort', 'high')));

      await tester.scrollUntilVisible(
        find.byTooltip('Change mode'),
        80,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Change mode'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ask').last);
      await tester.pumpAndSettle();
      expect(manager.modeSets, contains('ask'));

      await tester.scrollUntilVisible(
        find.byTooltip('Change fast mode'),
        80,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(find.text('Off'), findsOneWidget);
      await tester.tap(find.byTooltip('Change fast mode'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('On').last);
      await tester.pumpAndSettle();
      expect(manager.configOptionSets, contains(('fast-mode', 'on')));

      await tester.scrollUntilVisible(
        find.byTooltip('Change permission'),
        -80,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Change permission'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('YOLO').last);
      await tester.pumpAndSettle();
      expect(manager.configOptionSets, contains(('yolo', true)));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('permission pill preserves provider-supported modes', (
    tester,
  ) async {
    final manager = FakeAcpSessionManager(
      sessions: [
        fakeAcpSession(
          configOptions: const [
            AcpSelectConfigOption(
              id: 'approval-mode',
              name: 'Approval mode',
              category: 'permission',
              currentValue: 'ask',
              options: [
                AcpConfigValue(value: 'ask', name: 'Ask'),
                AcpConfigValue(value: 'auto', name: 'YOLO'),
                AcpConfigValue(value: 'plan', name: 'Plan only'),
              ],
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(_wrap(manager, embedded: true));
    await tester.pumpAndSettle();

    expect(find.text('Ask'), findsOneWidget);
    expect(find.text('Permission'), findsNothing);
    await tester.tap(find.byTooltip('Change permission'));
    await tester.pumpAndSettle();
    expect(find.text('Permission'), findsOneWidget);
    expect(find.text('YOLO'), findsOneWidget);
    expect(find.text('Plan only'), findsOneWidget);
    await tester.tap(find.text('Plan only'));
    await tester.pumpAndSettle();
    expect(manager.configOptionSets, contains(('approval-mode', 'plan')));
  });

  testWidgets('legacy thinking levels render as Effort, not Mode', (
    tester,
  ) async {
    final manager = FakeAcpSessionManager(
      sessions: [
        fakeAcpSession(
          modeState: const AcpSessionModeState(
            currentModeId: 'medium',
            availableModes: [
              AcpSessionMode(id: 'low', name: 'Low'),
              AcpSessionMode(id: 'medium', name: 'Medium'),
              AcpSessionMode(id: 'high', name: 'High'),
            ],
          ),
        ),
      ],
    );
    await tester.pumpWidget(_wrap(manager, embedded: true));
    await tester.pumpAndSettle();

    expect(find.text('Medium'), findsOneWidget);
    expect(find.byTooltip('Change effort'), findsOneWidget);
    expect(find.byTooltip('Change mode'), findsNothing);
    await tester.tap(find.byTooltip('Change effort'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('High').last);
    await tester.pumpAndSettle();
    expect(manager.modeSets, contains('high'));
  });

  testWidgets('generic mode-shaped effort levels do not create a Mode pill', (
    tester,
  ) async {
    final manager = FakeAcpSessionManager(
      sessions: [
        fakeAcpSession(
          configOptions: const [
            AcpSelectConfigOption(
              id: 'session-mode',
              name: 'Mode',
              currentValue: 'medium',
              category: 'mode',
              options: [
                AcpConfigValue(value: 'low', name: 'Low'),
                AcpConfigValue(value: 'medium', name: 'Medium'),
                AcpConfigValue(value: 'high', name: 'High'),
              ],
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(_wrap(manager, embedded: true));
    await tester.pumpAndSettle();

    expect(find.text('Medium'), findsOneWidget);
    expect(find.byTooltip('Change effort'), findsOneWidget);
    expect(find.byTooltip('Change mode'), findsNothing);
    await tester.tap(find.byTooltip('Change effort'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('High').last);
    await tester.pumpAndSettle();
    expect(manager.configOptionSets, contains(('session-mode', 'high')));
  });

  testWidgets('standalone pills respect SafeArea and default/off stays Mode', (
    tester,
  ) async {
    final manager = FakeAcpSessionManager(
      sessions: [
        fakeAcpSession(
          configOptions: const [
            AcpSelectConfigOption(
              id: 'interaction-mode',
              name: 'Mode',
              currentValue: 'default',
              category: 'mode',
              options: [
                AcpConfigValue(value: 'default', name: 'Default'),
                AcpConfigValue(value: 'off', name: 'Off'),
              ],
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      _wrap(manager, mediaPadding: const EdgeInsets.only(bottom: 34)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Default'), findsOneWidget);
    expect(find.byTooltip('Change mode'), findsOneWidget);
    expect(find.byTooltip('Change effort'), findsNothing);
    final pillSafeAreas = tester
        .widgetList<SafeArea>(
          find.ancestor(
            of: find.text('Default'),
            matching: find.byType(SafeArea),
          ),
        )
        .where((safeArea) => safeArea.bottom);
    expect(pillSafeAreas, isNotEmpty);
  });

  testWidgets('opens an inline image in a sized interactive viewer', (
    tester,
  ) async {
    const png =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
        'AAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
    final session = fakeAcpSession(
      timeline: AcpTimeline(
        entries: [
          AcpMessageEntry(
            role: AcpMessageRole.user,
            order: 0,
            content: const [AcpImageContent(data: png, mimeType: 'image/png')],
          ),
        ],
      ),
    );
    await tester.pumpWidget(_wrap(FakeAcpSessionManager(sessions: [session])));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
    final inlineImage = tester.widget<AcpInlineImage>(
      find.byType(AcpInlineImage),
    );
    inlineImage.onTap!(inlineImage.image);
    await tester.pumpAndSettle();

    expect(find.byType(InteractiveViewer), findsOneWidget);
    final interactive = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    expect(interactive.minScale, 0.5);
    expect(interactive.maxScale, 8);
    expect(interactive.panEnabled, isTrue);
    expect(interactive.scaleEnabled, isTrue);
    expect(interactive.clipBehavior, Clip.none);
    final dialog = tester.widget<Dialog>(find.byType(Dialog));
    expect(dialog.backgroundColor, Colors.black);
    final viewerImage = tester
        .widgetList<AcpInlineImage>(find.byType(AcpInlineImage))
        .last;
    expect(viewerImage.showFrame, isFalse);
    expect(find.byTooltip('Close image'), findsOneWidget);
    final viewerSize = tester.getSize(
      find.byKey(const ValueKey('acp-image-viewer')),
    );
    expect(viewerSize.width, greaterThan(0));
    expect(viewerSize.height, greaterThan(0));
    expect(find.byType(Image), findsNWidgets(2));
  });

  testWidgets('renders a persistent session rail on wide layouts', (
    tester,
  ) async {
    final session = fakeAcpSession();
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1100, 800));
    await tester.pumpWidget(
      _wrap(
        FakeAcpSessionManager(sessions: [session]),
        size: const Size(1100, 800),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(AgentChatScreen)).width, 1100);
    expect(tester.takeException(), isNull);

    expect(find.text('sessions'), findsOneWidget);
    expect(find.text('ready when you are'), findsOneWidget);
  });

  testWidgets('shows inline recovery when a live session fails', (
    tester,
  ) async {
    final manager = FakeAcpSessionManager(
      sessions: [fakeAcpSession(status: AcpConnectionStatus.failed)],
    );
    await tester.pumpWidget(_wrap(manager));
    await tester.pumpAndSettle();

    expect(find.text('agent connection failed'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Reconnect'), findsOneWidget);
  });

  testWidgets('externally owned reconnect does not launch a duplicate', (
    tester,
  ) async {
    final manager = FakeAcpSessionManager();
    await tester.pumpWidget(
      _wrap(manager, embedded: true, connectOnMount: false),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(manager.reconnects, isEmpty);
  });

  testWidgets('adopts the replacement bridge key after resuming an expired '
      'bridge', (tester) async {
    final oldKey = fakeAcpKey(bridgeId: 'expired-bridge');
    final resumedKey = fakeAcpKey(bridgeId: 'replacement-bridge');
    final now = DateTime(2026);
    final resumedSession = fakeAcpSession(
      key: resumedKey,
      timeline: fakeAcpTimeline('Recovered session'),
    );
    final manager =
        FakeAcpSessionManager(
            recents: [
              AcpRecentSessionRef(
                hostId: oldKey.hostId,
                providerId: oldKey.providerId,
                bridgeId: oldKey.bridgeId,
                acpSessionId: oldKey.acpSessionId,
                cwd: '/repo',
                createdAt: now,
                lastActivityAt: now,
              ),
            ],
          )
          ..reconnectSessionResult = AcpSessionLaunchStarted(resumedKey)
          ..reconnectSessionState = resumedSession;

    await tester.pumpWidget(
      _wrap(manager, routeKey: oldKey, hasActiveSshSession: true),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Recovered session'), findsOneWidget);
    expect(find.byType(AcpComposer), findsOneWidget);
    expect(find.text('Reconnect'), findsNothing);
    expect(manager.selected, contains(resumedKey.value));
    expect(manager.selected, isNot(contains(oldKey.value)));
    expect(manager.reconnects, hasLength(1));
    expect(manager.reconnects.single.bridgeId, oldKey.bridgeId);
  });

  testWidgets('surfaces a pending permission and resolves with the exact '
      'option id', (tester) async {
    final manager = FakeAcpSessionManager(
      sessions: [
        fakeAcpSession(
          pendingPermissions: [
            AcpPendingPermission(
              requestKey: 'req-1',
              sessionId: 'session-1',
              toolCallId: 'tool-1',
              options: const [
                AcpPermissionOption(
                  id: 'allow-1',
                  name: 'Allow once',
                  kind: AcpPermissionOptionKind.allowOnce,
                ),
              ],
              requestedAt: DateTime(2026),
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(_wrap(manager));
    await tester.pumpAndSettle();

    expect(find.byType(AcpPermissionSurface), findsOneWidget);
    expect(find.text('Allow once'), findsOneWidget);

    await tester.tap(find.text('Allow once'));
    await tester.pumpAndSettle();

    expect(manager.permissionResponses, [('req-1', 'allow-1')]);
  });

  testWidgets('pending write offers explicit in-chat content review', (
    tester,
  ) async {
    final manager = FakeAcpSessionManager(
      sessions: [
        fakeAcpSession(
          pendingWrites: [
            AcpPendingWrite(
              requestKey: 'write-1',
              sessionId: 'session-1',
              path: '/repo/lib/main.dart',
              contentByteLength: 18,
              requestedAt: DateTime(2026),
            ),
          ],
        ),
      ],
    )..pendingWriteContents['write-1'] = 'updated contents';
    await tester.pumpWidget(_wrap(manager));
    await tester.pumpAndSettle();

    expect(find.text('Write to main.dart'), findsOneWidget);
    expect(find.text('updated contents'), findsNothing);
    await tester.tap(find.text('Review changes'));
    await tester.pump();
    expect(find.text('updated contents'), findsOneWidget);
  });

  testWidgets('cancelling delete keeps the remote session', (tester) async {
    final key = fakeAcpKey();
    final manager = FakeAcpSessionManager(
      sessions: [
        fakeAcpSession(key: key, capabilities: fakeAcpForkCapabilities()),
      ],
    );
    await tester.pumpWidget(_wrap(manager));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete session'));
    await tester.pumpAndSettle();

    expect(find.text('Delete session?'), findsOneWidget);
    expect(find.textContaining('cannot be undone'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(manager.deleted, isEmpty);
    expect(find.byType(AcpComposer), findsOneWidget);
  });

  testWidgets('a failed fork surfaces a safe error snackbar', (tester) async {
    final manager =
        FakeAcpSessionManager(
            sessions: [fakeAcpSession(capabilities: fakeAcpForkCapabilities())],
          )
          ..forkResults.add(
            const AcpSessionLaunchFailed(
              null,
              AcpSessionError(
                kind: AcpSessionErrorKind.unknown,
                message: 'Fork could not start.',
              ),
            ),
          );
    await tester.pumpWidget(_wrap(manager));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fork session'));
    await tester.pumpAndSettle();

    expect(manager.forkCount, 1);
    expect(find.text('Fork could not start.'), findsOneWidget);
  });

  testWidgets('a blocked fork stops the blocking session and retries after '
      'stop-and-continue', (tester) async {
    final currentKey = fakeAcpKey();
    final blockingKey = fakeAcpKey(acpSessionId: 'blocking');
    final manager =
        FakeAcpSessionManager(
            sessions: [
              fakeAcpSession(
                key: currentKey,
                capabilities: fakeAcpForkCapabilities(),
              ),
              fakeAcpSession(key: blockingKey, title: 'Busy session'),
            ],
          )
          ..forkResults.addAll([
            AcpSessionLaunchBlocked(
              AcpConcurrencyRequiresChoice(
                blockingSessionKeys: [blockingKey.value],
              ),
            ),
            const AcpSessionLaunchFailed(
              null,
              AcpSessionError(
                kind: AcpSessionErrorKind.unknown,
                message: 'Retry failed.',
              ),
            ),
          ]);
    await tester.pumpWidget(_wrap(manager));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fork session'));
    await tester.pumpAndSettle();

    // The shared concurrency choice is presented.
    expect(find.text('Stop and continue free'), findsOneWidget);
    await tester.tap(find.text('Stop and continue free'));
    await tester.pumpAndSettle();

    // The blocking session was stopped and the fork was retried.
    expect(manager.stopped, contains(blockingKey.value));
    expect(manager.forkCount, 2);
    expect(find.text('Retry failed.'), findsOneWidget);
  });

  testWidgets('a free fork never offers to stop its own parent session', (
    tester,
  ) async {
    final currentKey = fakeAcpKey();
    final manager =
        FakeAcpSessionManager(
            sessions: [
              fakeAcpSession(
                key: currentKey,
                capabilities: fakeAcpForkCapabilities(),
              ),
            ],
          )
          ..forkResults.add(
            AcpSessionLaunchBlocked(
              AcpConcurrencyRequiresChoice(
                blockingSessionKeys: [currentKey.value],
              ),
            ),
          );
    await tester.pumpWidget(_wrap(manager));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fork session'));
    await tester.pumpAndSettle();

    expect(find.text('Stop and continue free'), findsNothing);
    expect(find.text('Unlock parallel native chats'), findsOneWidget);
    expect(find.textContaining('keeps the parent connected'), findsOneWidget);
    expect(manager.stopped, isEmpty);
  });

  testWidgets(
    'embedded native chat keeps prose proportional and machine text configured',
    (tester) async {
      final session = fakeAcpSession(
        timeline: fakeAcpTimeline('Scaled native response'),
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(1100, 800));
      await tester.pumpWidget(
        _wrap(
          FakeAcpSessionManager(sessions: [session]),
          size: const Size(1100, 800),
          embedded: true,
          preferredFontSize: 20,
          preferredFontFamily: 'Roboto Mono',
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(AgentChatScreen)).width, 1100);
      expect(tester.takeException(), isNull);

      expect(find.text('sessions'), findsNothing);
      expect(find.byType(AppBar), findsNothing);
      expect(find.byTooltip('MonkeyMux windows'), findsNothing);
      final threadContext = tester.element(find.byType(AcpMessageThread));
      expect(
        MediaQuery.of(threadContext).textScaler.scale(14),
        closeTo(20, 0.01),
      );
      expect(
        AcpChatTypography.monoStyleOf(threadContext).fontFamily,
        contains('RobotoMono'),
      );
      expect(
        Theme.of(threadContext).textTheme.bodyMedium?.fontFamily,
        isNot(contains('RobotoMono')),
        reason: 'terminal font settings must not replace proportional prose',
      );
    },
  );

  testWidgets('pinch zoom resizes native chat and commits the font size', (
    tester,
  ) async {
    final committed = <double>[];
    final session = fakeAcpSession(
      timeline: fakeAcpTimeline('Pinch-resizable response'),
    );
    await tester.pumpWidget(
      _wrap(
        FakeAcpSessionManager(sessions: [session]),
        embedded: true,
        preferredFontSize: 14,
        onFontSizeCommitted: committed.add,
      ),
    );
    await tester.pumpAndSettle();

    final target = find.byType(TerminalPinchZoomGestureHandler);
    final center = tester.getCenter(target);
    final first = await tester.createGesture(pointer: 21);
    final second = await tester.createGesture(pointer: 22);
    await first.down(center - const Offset(30, 0));
    await second.down(center + const Offset(30, 0));
    await tester.pump();
    await second.moveTo(center + const Offset(60, 0));
    await tester.pump();

    expect(find.text('21 pt'), findsOneWidget);
    final threadContext = tester.element(find.byType(AcpMessageThread));
    expect(MediaQuery.of(threadContext).textScaler.scale(14), closeTo(21, 0.1));

    await first.up();
    await second.up();
    await tester.pump();
    expect(committed.single, closeTo(21, 0.1));
  });

  testWidgets('native chat shows working state and determinate plan progress', (
    tester,
  ) async {
    final session = fakeAcpSession(
      promptStatus: AcpPromptStatus.streaming,
      plan: const [
        AcpPlanEntry(
          content: 'done',
          priority: AcpPlanPriority.high,
          status: AcpPlanStatus.completed,
        ),
        AcpPlanEntry(
          content: 'next',
          priority: AcpPlanPriority.medium,
          status: AcpPlanStatus.inProgress,
        ),
      ],
      timeline: fakeAcpTimeline('Working response'),
    );
    await tester.pumpWidget(
      _wrap(FakeAcpSessionManager(sessions: [session]), embedded: true),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('agent is working'), findsNothing);
    final cursor = find.byKey(const ValueKey('acp-running-cursor'));
    expect(cursor, findsOneWidget);
    expect(find.byType(CursorBlock), findsOneWidget);
    expect(
      tester.getTopLeft(cursor).dy,
      greaterThan(tester.getBottomLeft(find.text('Working response')).dy),
      reason: 'the running cursor belongs below transcript content',
    );
    final statusStripProgress = tester
        .widgetList<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator),
        )
        .where((indicator) => indicator.minHeight == 2);
    expect(
      statusStripProgress,
      isEmpty,
      reason: 'embedded status progress belongs to terminal chrome only',
    );
  });

  testWidgets('sticky prompt tap escapes live auto-scroll', (tester) async {
    final entries = <AcpTimelineEntry>[
      AcpMessageEntry(
        order: 0,
        role: AcpMessageRole.user,
        messageId: 'sticky-user',
        content: const [AcpTextContent('take me back to this prompt')],
      ),
      AcpMessageEntry(
        order: 1,
        role: AcpMessageRole.agent,
        messageId: 'long-response',
        content: [
          AcpTextContent(
            List.generate(
              24,
              (index) => 'Response paragraph $index with enough words to wrap.',
            ).join('\n\n'),
          ),
        ],
      ),
    ];
    final manager = FakeAcpSessionManager(
      sessions: [fakeAcpSession(timeline: AcpTimeline(entries: entries))],
    );
    await tester.pumpWidget(_wrap(manager, embedded: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    final scrollable = find.descendant(
      of: find.byType(AcpMessageThread),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable.first).position;
    expect(position.pixels, closeTo(position.maxScrollExtent, 1));
    position.jumpTo(100);
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('acp-sticky-user-prompt')),
      findsOneWidget,
    );
    expect(
      find.text('take me back to this prompt', skipOffstage: false),
      findsOneWidget,
    );

    final threadContext = tester.element(find.byType(AcpMessageThread));
    ScrollStartNotification(
      metrics: position,
      context: threadContext,
      dragDetails: DragStartDetails(),
    ).dispatch(threadContext);
    ScrollEndNotification(
      metrics: FixedScrollMetrics(
        minScrollExtent: position.minScrollExtent,
        maxScrollExtent: position.maxScrollExtent,
        pixels: position.maxScrollExtent,
        viewportDimension: position.viewportDimension,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1,
      ),
      context: threadContext,
    ).dispatch(threadContext);
    ScrollMetricsNotification(
      metrics: position,
      context: threadContext,
    ).dispatch(threadContext);
    await tester.tap(find.byKey(const ValueKey('acp-sticky-user-prompt')));
    await tester.pumpAndSettle();

    expect(position.pixels, lessThan(40));
    expect(find.text('take me back to this prompt'), findsOneWidget);
    expect(find.byTooltip('Jump to latest'), findsOneWidget);
  });

  testWidgets('user scrolling up is not overridden by streaming updates', (
    tester,
  ) async {
    final key = fakeAcpKey();
    final entries = <AcpTimelineEntry>[
      for (var index = 0; index < 30; index++)
        AcpMessageEntry(
          order: index,
          role: AcpMessageRole.agent,
          messageId: 'message-$index',
          content: [AcpTextContent('Response line $index ' * 4)],
        ),
    ];
    final session = fakeAcpSession(
      key: key,
      promptStatus: AcpPromptStatus.streaming,
      timeline: AcpTimeline(entries: entries),
    );
    final manager = FakeAcpSessionManager(sessions: [session]);
    await tester.pumpWidget(_wrap(manager, embedded: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final scrollable = find.descendant(
      of: find.byType(AcpMessageThread),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable.first).position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    await tester.drag(find.byType(AcpMessageThread), const Offset(0, 40));
    await tester.pump();
    final userPosition = position.pixels;
    expect(userPosition, lessThan(position.maxScrollExtent));

    final threadContext = tester.element(find.byType(AcpMessageThread));
    final horizontalMetrics = FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 100,
      pixels: 100,
      viewportDimension: 100,
      axisDirection: AxisDirection.right,
      devicePixelRatio: 1,
    );
    ScrollStartNotification(
      metrics: horizontalMetrics,
      context: threadContext,
      dragDetails: DragStartDetails(),
    ).dispatch(threadContext);
    ScrollEndNotification(
      metrics: horizontalMetrics,
      context: threadContext,
    ).dispatch(threadContext);
    await tester.pump();

    final updated = session.copyWith(
      timeline: AcpTimeline(
        entries: [
          ...entries,
          AcpMessageEntry(
            order: 31,
            role: AcpMessageRole.agent,
            messageId: 'new-message',
            content: const [AcpTextContent('New streaming output')],
          ),
        ],
      ),
      lastActivityAt: DateTime(2026, 1, 2),
    );
    manager.emit(AcpSessionManagerState(sessions: [updated]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(position.pixels, closeTo(userPosition, 1));
    expect(find.byTooltip('Jump to latest'), findsOneWidget);
  });

  testWidgets('embedded long conversation mounts only its recent tail', (
    tester,
  ) async {
    final entries = <AcpTimelineEntry>[
      for (var index = 0; index < 200; index++)
        AcpMessageEntry(
          order: index,
          role: AcpMessageRole.agent,
          messageId: 'long-$index',
          content: [AcpTextContent('Long conversation response $index')],
        ),
    ];
    final manager = FakeAcpSessionManager(
      sessions: [fakeAcpSession(timeline: AcpTimeline(entries: entries))],
    );

    await tester.pumpWidget(_wrap(manager, embedded: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final transcript = find.descendant(
      of: find.byType(AcpMessageThread),
      matching: find.byType(CustomScrollView),
    );
    expect(tester.widget<CustomScrollView>(transcript).semanticChildCount, 48);
    expect(find.text('Long conversation response 0'), findsNothing);
  });

  testWidgets('embedded native chat restores scroll position after remount', (
    tester,
  ) async {
    final entries = <AcpTimelineEntry>[
      for (var index = 0; index < 40; index++)
        AcpMessageEntry(
          order: index,
          role: AcpMessageRole.agent,
          messageId: 'retained-$index',
          content: [AcpTextContent('Retained response $index ' * 5)],
        ),
    ];
    final manager = FakeAcpSessionManager(
      sessions: [fakeAcpSession(timeline: AcpTimeline(entries: entries))],
    );
    AcpChatScrollState? retained;
    await tester.pumpWidget(
      _wrap(
        manager,
        embedded: true,
        onScrollChanged: (_, state) => retained = state,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final scrollable = find.descendant(
      of: find.byType(AcpMessageThread),
      matching: find.byType(Scrollable),
    );
    final firstPosition = tester
        .state<ScrollableState>(scrollable.first)
        .position;
    expect(firstPosition.pixels, closeTo(firstPosition.maxScrollExtent, 1));
    firstPosition.jumpTo(firstPosition.maxScrollExtent);
    await tester.pump();
    await tester.drag(find.byType(AcpMessageThread), const Offset(0, 420));
    await tester.pump();
    expect(retained?.autoScroll, isFalse);
    final expectedOffset = retained!.offset;

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      _wrap(
        manager,
        embedded: true,
        initialScrollState: retained,
        onScrollChanged: (_, state) => retained = state,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final restoredScrollable = find.descendant(
      of: find.byType(AcpMessageThread),
      matching: find.byType(Scrollable),
    );
    final restoredPosition = tester
        .state<ScrollableState>(restoredScrollable.first)
        .position;

    final clampedOffset = expectedOffset.clamp(
      restoredPosition.minScrollExtent,
      restoredPosition.maxScrollExtent,
    );
    expect(restoredPosition.pixels, closeTo(clampedOffset, 1));
    expect(find.byTooltip('Jump to latest'), findsOneWidget);
  });

  testWidgets('remote selection adds a visible composer attachment', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        FakeAcpSessionManager(sessions: [fakeAcpSession()]),
        embedded: true,
        attachmentActionsBuilder: (_, _) => AcpComposerAttachmentActions(
          pickRemoteFiles: (_) async => [
            const AcpAttachmentCandidate.remoteFile(
              name: 'report.txt',
              remotePath: '/repo/report.txt',
              sizeBytes: 42,
              mimeType: 'text/plain',
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Add to prompt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remote file (SFTP)'));
    await tester.pumpAndSettle();

    expect(find.text('report.txt'), findsOneWidget);
    expect(
      tester.widget<AcpComposer>(find.byType(AcpComposer)).useBottomSafeArea,
      isFalse,
    );
  });

  testWidgets('waiting for input takes priority over native working state', (
    tester,
  ) async {
    final session = fakeAcpSession(
      promptStatus: AcpPromptStatus.streaming,
      pendingWrites: [
        AcpPendingWrite(
          requestKey: 'write-1',
          sessionId: 'session-1',
          path: '/repo/file.dart',
          contentByteLength: 12,
          requestedAt: DateTime(2026),
        ),
      ],
    );
    await tester.pumpWidget(
      _wrap(FakeAcpSessionManager(sessions: [session]), embedded: true),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('waiting for input'), findsOneWidget);
    expect(find.text('agent is working'), findsNothing);
    expect(find.byType(AcpPermissionSurface), findsOneWidget);
  });

  testWidgets('two-finger tap without scaling does not pin a font override', (
    tester,
  ) async {
    final committed = <double>[];
    await tester.pumpWidget(
      _wrap(
        FakeAcpSessionManager(sessions: [fakeAcpSession()]),
        embedded: true,
        preferredFontSize: 14,
        onFontSizeCommitted: committed.add,
      ),
    );
    await tester.pumpAndSettle();

    final center = tester.getCenter(
      find.byType(TerminalPinchZoomGestureHandler),
    );
    final first = await tester.createGesture(pointer: 31);
    final second = await tester.createGesture(pointer: 32);
    await first.down(center - const Offset(30, 0));
    await second.down(center + const Offset(30, 0));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pump();

    expect(committed, isEmpty);
  });
}
