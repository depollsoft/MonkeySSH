import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/controllers/terminal_visibility_controller.dart';
import 'package:xterm/xterm.dart';

import '../../helpers/mocks.dart';

/// A terminal with visibility reports on, recording the reports it sends.
({Terminal terminal, List<String> reports}) _reportingTerminal() {
  final reports = <String>[];
  final terminal = Terminal()
    ..onOutput = reports.add
    ..write('\x1b[?2033h');
  reports.clear();
  return (terminal: terminal, reports: reports);
}

const _visible = '\x1b[?999;1n';
const _hidden = '\x1b[?999;2n';

SshSession _session(int connectionId) => SshSession(
  connectionId: connectionId,
  hostId: 1,
  client: MockSshClient(),
  config: const SshConnectionConfig(
    hostname: 'example.com',
    port: 22,
    username: 'tester',
  ),
);

void main() {
  group('TerminalVisibilityController', () {
    late List<(int, bool)> sessionChanges;
    late TerminalVisibilityController controller;

    setUp(() {
      sessionChanges = [];
      controller = TerminalVisibilityController(
        onSessionVisibilityChanged: (session, {required visible}) =>
            sessionChanges.add((session.connectionId, visible)),
      );
    });

    test('hides the terminal only while the app is known to be away', () {
      final (:terminal, :reports) = _reportingTerminal();
      controller.show(terminal, null);
      expect(terminal.visible, isTrue);

      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        controller.lifecycleState = state;
      }
      expect(reports, [_hidden, _visible]);
    });

    test('hides the terminal while a route covers the screen', () {
      final (:terminal, :reports) = _reportingTerminal();
      controller
        ..show(terminal, null)
        ..onstage = false;
      expect(terminal.visible, isFalse);
      controller.onstage = true;
      expect(reports, [_hidden, _visible]);
    });

    test('hides the terminal and session it stops showing', () {
      final first = _reportingTerminal();
      final second = _reportingTerminal();
      final sessionA = _session(1);
      final sessionB = _session(2);

      controller.show(first.terminal, sessionA);
      sessionChanges.clear();
      controller.show(second.terminal, sessionB);
      expect(first.terminal.visible, isFalse);
      expect(first.reports, [_hidden]);
      expect(second.terminal.visible, isTrue);
      expect(sessionChanges, [(1, false), (2, true)]);

      sessionChanges.clear();
      controller.dispose();
      expect(second.terminal.visible, isFalse);
      expect(sessionChanges, [(2, false)]);
    });

    test('a terminal attaching to its session reports no change', () {
      final (:terminal, :reports) = _reportingTerminal();
      controller
        ..show(terminal, null)
        ..show(terminal, _session(3));
      expect(reports, isEmpty);
      expect(sessionChanges, [(3, true)]);
    });

    test('a terminal stays visible while any screen shows it', () {
      final (:terminal, :reports) = _reportingTerminal();
      final session = _session(4);
      final covered = TerminalVisibilityController(
        onSessionVisibilityChanged: (session, {required visible}) =>
            sessionChanges.add((session.connectionId, visible)),
      )..show(terminal, session);
      controller.show(terminal, session);
      covered.onstage = false;
      expect(terminal.visible, isTrue);

      // The top screen goes away after the one below is back on stage.
      covered.onstage = true;
      controller.dispose();
      expect(terminal.visible, isTrue);
      expect(sessionChanges.last, (4, true));
      expect(reports, isEmpty);

      covered.dispose();
      expect(terminal.visible, isFalse);
      expect(sessionChanges.last, (4, false));
      expect(reports, [_hidden]);
    });

    testWidgets('an opaque route turns TickerMode off for the screen below', (
      tester,
    ) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      final onstage = <bool>[];
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          home: _OnstageProbe(onChanged: onstage.add),
        ),
      );
      expect(onstage, [true]);

      unawaited(
        navigatorKey.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => const SizedBox()),
        ),
      );
      await tester.pumpAndSettle();
      expect(onstage.last, isFalse);

      unawaited(
        showDialog<void>(
          context: navigatorKey.currentContext!,
          builder: (_) => const SizedBox(),
        ),
      );
      await tester.pumpAndSettle();
      navigatorKey.currentState!
        ..pop()
        ..pop();
      await tester.pumpAndSettle();
      expect(onstage.last, isTrue);

      // A dialog leaves the screen below on stage.
      unawaited(
        showDialog<void>(
          context: navigatorKey.currentContext!,
          builder: (_) => const SizedBox(),
        ),
      );
      await tester.pumpAndSettle();
      expect(onstage.last, isTrue);
    });
  });
}

class _OnstageProbe extends StatefulWidget {
  const _OnstageProbe({required this.onChanged});

  final ValueChanged<bool> onChanged;

  @override
  State<_OnstageProbe> createState() => _OnstageProbeState();
}

class _OnstageProbeState extends State<_OnstageProbe> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.onChanged(TickerMode.valuesOf(context).enabled);
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}
