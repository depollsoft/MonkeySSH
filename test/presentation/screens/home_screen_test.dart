import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/remote_multiplexer_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/providers/host_row_providers.dart';
import 'package:monkeyssh/presentation/view_models/mux_badge_controller.dart';

class _Mux extends Mock implements RemoteMultiplexerService {}

class _Session extends Mock implements SshSession {}

void main() {
  group('MuxBadgeController', () {
    late _Mux mux;
    late _Session session;
    late StreamController<TmuxWindowChangeEvent> events;
    late MuxBadgeController controller;
    late List<List<TmuxWindow>?> published;
    late RemoteMuxBackend backend;
    late int disconnected;
    setUp(() {
      mux = _Mux();
      session = _Session();
      backend = RemoteMuxBackend.tmux;
      disconnected = 0;
      published = [];
      events = StreamController<TmuxWindowChangeEvent>.broadcast(sync: true);
      when(() => session.connectionId).thenReturn(7);
      when(
        () => mux.watchWindowChanges(
          session,
          'work',
          extraFlags: any(named: 'extraFlags'),
        ),
      ).thenAnswer((_) => events.stream);
      when(
        () => mux.listWindows(
          session,
          'work',
          extraFlags: any(named: 'extraFlags'),
        ),
      ).thenAnswer(
        (_) async => const [
          TmuxWindow(index: 0, name: 'editor', isActive: true),
        ],
      );
      controller = MuxBadgeController(
        getSession: () => session,
        resolveBackend: (_) => backend,
        resolveSessionName: (_, _) async => 'work',
        serviceForBackend: (_) => mux,
        extraFlags: () => '-L test',
        onWindowsChanged: published.add,
        disconnect: (_) async => disconnected++,
      );
    });
    tearDown(() async {
      if (controller.mounted) controller.dispose();
      await events.close();
    });
    test(
      'queries and events publish the current backend and session',
      () async {
        await controller.queryTmux();
        expect(controller.queried, isTrue);
        expect(controller.sessionName, 'work');
        expect(controller.muxBackend, RemoteMuxBackend.tmux);
        expect(controller.windows!.single.name, 'editor');
        events.add(
          const TmuxWindowListEvent([
            TmuxWindow(index: 1, name: 'shell', isActive: true),
          ]),
        );
        expect(controller.windows!.single.name, 'shell');
        expect(published.last, controller.windows);
        verify(() => mux.listWindows(session, 'work', extraFlags: '-L test'))
            .called(1);
      },
    );
    test('disposal ignores an in-flight window result', () async {
      final result = Completer<List<TmuxWindow>>();
      final started = Completer<void>();
      when(() => mux.listWindows(session, 'work', extraFlags: '-L test'))
          .thenAnswer((_) {
            started.complete();
            return result.future;
          });
      final query = controller.queryTmux();
      await started.future;
      controller.dispose();
      result.complete(const [
        TmuxWindow(index: 0, name: 'late', isActive: true),
      ]);
      await query;
      expect(published, isEmpty);
      expect(controller.windows, isNull);
    });
    test('a stale overlapping refresh reloads the current query', () async {
      final stale = Completer<List<TmuxWindow>>();
      final started = Completer<void>();
      var calls = 0;
      when(() => mux.listWindows(session, 'work', extraFlags: '-L test'))
          .thenAnswer((_) {
            calls++;
            if (calls == 1) {
              started.complete();
              return stale.future;
            }
            return Future.value(const [
              TmuxWindow(index: 1, name: 'current', isActive: true),
            ]);
          });
      final currentPublished = Completer<void>();
      controller.addListener(() {
        if (controller.windows?.single.name == 'current' &&
            !currentPublished.isCompleted) {
          currentPublished.complete();
        }
      });
      final first = controller.queryTmux();
      await started.future;
      await controller.queryTmux();
      stale.complete(const [
        TmuxWindow(index: 0, name: 'stale', isActive: true),
      ]);
      await first;
      await currentPublished.future;
      expect(controller.windows!.single.name, 'current');
      expect(
        published.any((windows) => windows?.single.name == 'stale'),
        isFalse,
      );
      expect(calls, 2);
    });
    test('empty MonkeyMux results disconnect and omit tmux flags', () async {
      backend = RemoteMuxBackend.monkeyMux;
      when(() => mux.listWindows(session, 'work')).thenAnswer((_) async => []);
      await controller.queryTmux();
      expect(controller.muxBackend, RemoteMuxBackend.monkeyMux);
      expect(controller.windows, isEmpty);
      expect(controller.sessionName, 'work');
      expect(disconnected, 1);
      await controller.disconnectEndedMonkeyMuxSession(session);
      expect(disconnected, 1);
      verify(() => mux.listWindows(session, 'work')).called(1);
    });
  });

  group('HostRowData value equality', () {
    test('equal when all fields are identical', () {
      const a = HostRowData(
        connectionIds: [1, 2],
        isConnected: true,
        isConnectionStarting: false,
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: true,
      );
      const b = HostRowData(
        connectionIds: [1, 2],
        isConnected: true,
        isConnectionStarting: false,
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: true,
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('unequal when isConnected differs', () {
      const a = HostRowData(
        connectionIds: [],
        isConnected: true,
        isConnectionStarting: false,
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: false,
      );
      const b = HostRowData(
        connectionIds: [],
        isConnected: false,
        isConnectionStarting: false,
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: false,
      );

      expect(a, isNot(equals(b)));
    });

    test('unequal when connectionIds differ', () {
      const a = HostRowData(
        connectionIds: [1],
        isConnected: false,
        isConnectionStarting: false,
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: false,
      );
      const b = HostRowData(
        connectionIds: [2],
        isConnected: false,
        isConnectionStarting: false,
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: false,
      );

      expect(a, isNot(equals(b)));
    });

    test('unequal when connectionAttemptMessage differs', () {
      const a = HostRowData(
        connectionIds: [],
        isConnected: false,
        isConnectionStarting: true,
        connectionAttemptMessage: 'Connecting…',
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: false,
      );
      const b = HostRowData(
        connectionIds: [],
        isConnected: false,
        isConnectionStarting: true,
        connectionAttemptMessage: 'Authenticating…',
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: false,
      );

      expect(a, isNot(equals(b)));
    });

    test('unequal when isPinnedToHomeScreen differs', () {
      const a = HostRowData(
        connectionIds: [],
        isConnected: false,
        isConnectionStarting: false,
        previewEntries: [],
        isPinnedToHomeScreen: true,
        hasHostThemeAccess: false,
      );
      const b = HostRowData(
        connectionIds: [],
        isConnected: false,
        isConnectionStarting: false,
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: false,
      );

      expect(a, isNot(equals(b)));
    });

    test('connectionCount reflects connectionIds length', () {
      const data = HostRowData(
        connectionIds: [10, 20, 30],
        isConnected: true,
        isConnectionStarting: false,
        previewEntries: [],
        isPinnedToHomeScreen: false,
        hasHostThemeAccess: false,
      );

      expect(data.connectionCount, 3);
    });
  });
}
