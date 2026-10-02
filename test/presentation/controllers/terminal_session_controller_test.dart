import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/terminal_wake_lock_service.dart';
import 'package:monkeyssh/presentation/controllers/terminal_session_controller.dart';

import 'terminal_wake_lock_service_cases.dart';

class _MockSshClient extends Mock implements SSHClient {}

SshSession _session(int id) => SshSession(
  connectionId: id,
  hostId: id,
  client: _MockSshClient(),
  config: const SshConnectionConfig(
    hostname: 'example.com',
    port: 22,
    username: 'test',
  ),
);

void main() {
  group('terminal_session_controller', () {
    late TerminalSessionController controller;
    late SshSession session;
    late int callbacks;

    setUp(() {
      callbacks = 0;
      session = _session(1);
      controller = TerminalSessionController(
        wakeLockService: TerminalWakeLockService(),
        wakeLockOwnerId: 0,
        readCurrentConnectionState: () => SshConnectionState.connected,
        getSession: (_) => session,
        connectionId: () => 1,
        hasActiveShell: () => true,
        hasError: () => false,
        isBackgrounded: () => false,
        onSessionMetadataChanged: () => callbacks++,
      )..observeSessionMetadata(session);
    });

    tearDown(() => controller.dispose());

    void changeMetadata(SshSession target, [int percentage = 10]) {
      target.debugHandlePrivateOsc('9', ['4', '1', '$percentage']);
    }

    testWidgets('clearing observation cancels pending metadata delivery', (
      tester,
    ) async {
      changeMetadata(session);
      await tester.pump(const Duration(milliseconds: 30));
      controller.clearObservedSession(session: session);
      expect(controller.observedSession, isNull);
      await tester.pump(const Duration(milliseconds: 100));
      expect(callbacks, 0);
      changeMetadata(session, 20);
      await tester.pump(const Duration(milliseconds: 100));
      expect(callbacks, 0);
    });

    testWidgets('unqualified clear cancels pending metadata delivery', (
      tester,
    ) async {
      changeMetadata(session);
      controller.clearObservedSession();
      await tester.pump(const Duration(milliseconds: 100));
      expect(callbacks, 0);
    });

    testWidgets('clearing another session preserves current pending delivery', (
      tester,
    ) async {
      changeMetadata(session);
      controller.clearObservedSession(session: _session(2));
      expect(controller.isObservingSession(session), isTrue);
      await tester.pump(const Duration(milliseconds: 100));
      expect(callbacks, 1);
    });

    testWidgets('replacement cancels old delivery and coalesces new metadata', (
      tester,
    ) async {
      changeMetadata(session);
      final replacement = _session(2);
      controller.observeSessionMetadata(replacement);
      await tester.pump(const Duration(milliseconds: 100));
      expect(callbacks, 0);
      changeMetadata(session, 20);
      changeMetadata(replacement);
      changeMetadata(replacement, 20);
      await tester.pump(const Duration(milliseconds: 74));
      expect(callbacks, 0);
      await tester.pump(const Duration(milliseconds: 1));
      expect(callbacks, 1);
    });

    testWidgets('dispose cancels pending metadata delivery', (tester) async {
      changeMetadata(session);
      controller.dispose();
      await tester.pump(const Duration(milliseconds: 100));
      expect(callbacks, 0);
    });
  });

  group('connected foreground time', () {
    late Stopwatch stopwatch;
    late TerminalSessionController controller;
    var connectionState = SshConnectionState.connected;
    var backgrounded = false;
    var hasError = false;

    setUp(() {
      stopwatch = Stopwatch();
      connectionState = SshConnectionState.connected;
      backgrounded = false;
      hasError = false;
      final session = _session(1);
      controller = TerminalSessionController(
        wakeLockService: TerminalWakeLockService(),
        wakeLockOwnerId: 0,
        readCurrentConnectionState: () => connectionState,
        getSession: (_) => session,
        connectionId: () => 1,
        hasActiveShell: () => true,
        hasError: () => hasError,
        isBackgrounded: () => backgrounded,
        onSessionMetadataChanged: () {},
        connectedTimeStopwatch: stopwatch,
      );
    });

    tearDown(() => controller.dispose());

    test('runs only while the shell is live in the foreground', () {
      controller.syncWakeLock();
      expect(stopwatch.isRunning, isTrue);

      backgrounded = true;
      controller.syncWakeLock();
      expect(stopwatch.isRunning, isFalse);

      backgrounded = false;
      controller.syncWakeLock();
      expect(stopwatch.isRunning, isTrue);

      hasError = true;
      controller.syncWakeLock();
      expect(stopwatch.isRunning, isFalse);

      hasError = false;
      controller.syncWakeLock(SshConnectionState.disconnected);
      expect(stopwatch.isRunning, isFalse);
    });

    test('does not depend on the wake lock setting', () {
      controller
        ..wakeLockEnabled = false
        ..syncWakeLock();
      expect(stopwatch.isRunning, isTrue);
    });
  });
  registerTerminalWakeLockServiceTests();
}
