// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/tmux_service.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';

class TerminalScreenMuxFixture {
  TerminalScreenMuxFixture({
    required this.database,
    required this.hostRepository,
    required this.monetizationService,
    required this.monetizationState,
    required this.activeSessions,
    required this.host,
    required this.session,
    required this.sessionName,
    required this.tmuxService,
    required this.monkeyMuxService,
  }) {
    addTearDown(dispose);
  }

  final AppDatabase database;
  final HostRepository hostRepository;
  final MonetizationService monetizationService;
  final MonetizationState monetizationState;
  final ActiveSessionsNotifier Function() activeSessions;
  final Host host;
  final SshSession session;
  final String sessionName;
  final TmuxService tmuxService;
  final MonkeyMuxService monkeyMuxService;
  final windowEvents = StreamController<TmuxWindowChangeEvent>();

  /// Closes the window-event stream without awaiting delivery: a
  /// single-subscription controller that was never listened to (for
  /// example when the tmux backend is active) never completes `close()`.
  void dispose() => unawaited(windowEvents.close());

  void stubPrefetch() {
    when(
      () => tmuxService.prefetchInstalledAgentTools(session),
    ).thenAnswer((_) async {});
  }

  void stubForegroundClient() {
    when(
      () => monkeyMuxService.hasForegroundClientOrThrow(
        session,
        sessionName,
        extraFlags: any(named: 'extraFlags'),
      ),
    ).thenAnswer((_) async => true);
  }

  void stubWindows(List<TmuxWindow> Function() windows) {
    when(
      () => monkeyMuxService.listWindows(
        session,
        sessionName,
        extraFlags: any(named: 'extraFlags'),
      ),
    ).thenAnswer((_) async => windows());
  }

  void stubWindowEvents() {
    when(
      () => monkeyMuxService.watchWindowChanges(
        session,
        sessionName,
        extraFlags: any(named: 'extraFlags'),
      ),
    ).thenAnswer((_) => windowEvents.stream);
  }

  void stubPaneContext() {
    when(
      () => monkeyMuxService.currentPaneContext(
        session,
        sessionName,
        priority: any(named: 'priority'),
        extraFlags: any(named: 'extraFlags'),
      ),
    ).thenAnswer((_) async => null);
  }

  void stubThemeRefresh() {
    when(
      () => monkeyMuxService.refreshTerminalTheme(
        session,
        sessionName,
        any(),
        extraFlags: any(named: 'extraFlags'),
        forceForegroundRedraw: any(named: 'forceForegroundRedraw'),
      ),
    ).thenAnswer((_) async {});
  }

  Future<void> pump(
    WidgetTester tester, {
    List<Override> overrides = const [],
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          hostRepositoryProvider.overrideWithValue(hostRepository),
          monetizationServiceProvider.overrideWithValue(monetizationService),
          monetizationStateProvider.overrideWith(
            (ref) => Stream.value(monetizationState),
          ),
          sharedClipboardProvider.overrideWith((ref) async => false),
          activeSessionsProvider.overrideWith(activeSessions),
          tmuxServiceProvider.overrideWithValue(tmuxService),
          monkeyMuxServiceProvider.overrideWithValue(monkeyMuxService),
          ...overrides,
        ],
        child: MaterialApp(
          home: TerminalScreen(
            hostId: host.id,
            connectionId: session.connectionId,
          ),
        ),
      ),
    );
  }
}
