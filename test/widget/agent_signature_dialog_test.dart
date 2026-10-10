// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/agent_signature_prompt.dart';
import 'package:monkeyssh/domain/services/ssh_agent_forwarding.dart';
import 'package:monkeyssh/presentation/widgets/agent_forwarding_indicator.dart';
import 'package:monkeyssh/presentation/widgets/agent_signature_dialog.dart';

import '../helpers/recording_diagnostics_logger.dart';

SshAgentSignatureRequest _request({
  String username = 'git',
  Future<void>? connectionClosed,
}) => SshAgentSignatureRequest(
  hostLabel: 'build box',
  keyLabel: 'GitHub work',
  username: username,
  connectionClosed: connectionClosed ?? Completer<void>().future,
  isConnectionClosed: () => false,
);

SshAgentForwarding _forwarding({
  SshAgentSignatureConfirmer? confirm,
  bool confirmEachSignature = true,
}) => SshAgentForwarding(
  hostId: 1,
  hostLabel: 'build box',
  loadPolicy: () async => SshAgentForwardingPolicy(
    enabled: true,
    confirmEachSignature: confirmEachSignature,
  ),
  initiallyConfirmEachSignature: confirmEachSignature,
  confirm: confirm,
  diagnostics: RecordingDiagnosticsLogger(),
);

void main() {
  group('AgentSignatureDialog', () {
    Future<Future<SshAgentSignatureDecision>> showPrompt(
      WidgetTester tester,
      SshAgentSignatureRequest request, {
      Duration timeout = const Duration(seconds: 60),
      bool armed = true,
    }) async {
      late Future<SshAgentSignatureDecision> result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => result = showAgentSignatureDialog(
                  context: context,
                  request: request,
                  timeout: timeout,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      if (armed) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      return result;
    }

    testWidgets('names the host, user and key, and allows on tap', (
      tester,
    ) async {
      final result = await showPrompt(tester, _request(username: 'deploy'));

      expect(
        find.textContaining('build box', findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining('deploy', findRichText: true), findsOneWidget);
      expect(find.text('GitHub work'), findsOneWidget);

      await tester.tap(find.byKey(const Key('agent-signature-allow')));
      await tester.pumpAndSettle();

      expect(await result, SshAgentSignatureDecision.approved);
    });

    testWidgets('denies, or denies and stops forwarding, on tap', (
      tester,
    ) async {
      var result = await showPrompt(tester, _request());
      await tester.tap(find.byKey(const Key('agent-signature-deny')));
      await tester.pumpAndSettle();
      expect(await result, SshAgentSignatureDecision.declined);

      result = await showPrompt(tester, _request());
      await tester.tap(find.byKey(const Key('agent-signature-stop')));
      await tester.pumpAndSettle();
      expect(await result, SshAgentSignatureDecision.stopForwarding);
    });

    testWidgets('ignores taps in the first half second', (tester) async {
      final result = await showPrompt(tester, _request(), armed: false);

      await tester.tap(find.byKey(const Key('agent-signature-allow')));
      await tester.pump();
      expect(find.byType(AgentSignatureDialog), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('agent-signature-deny')));
      await tester.pumpAndSettle();

      expect(await result, SshAgentSignatureDecision.declined);
    });

    testWidgets('refuses on its own when time runs out', (tester) async {
      final result = await showPrompt(
        tester,
        _request(),
        timeout: const Duration(seconds: 5),
      );

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      expect(find.byType(AgentSignatureDialog), findsNothing);
      expect(await result, SshAgentSignatureDecision.declined);
    });

    testWidgets('refuses when the app goes to the background', (tester) async {
      final result = await showPrompt(tester, _request());

      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.hidden);

      // Hidden apps draw no frames, but the prompt is already answered.
      expect(await result, SshAgentSignatureDecision.declined);
      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byType(AgentSignatureDialog), findsNothing);
    });

    testWidgets('refuses as soon as the app becomes inactive', (tester) async {
      final result = await showPrompt(tester, _request());

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();

      expect(await result, SshAgentSignatureDecision.declined);
      expect(find.byType(AgentSignatureDialog), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    testWidgets('refuses when the connection closes', (tester) async {
      final closed = Completer<void>();
      final result = await showPrompt(
        tester,
        _request(connectionClosed: closed.future),
      );

      closed.complete();
      await tester.pumpAndSettle();

      expect(find.byType(AgentSignatureDialog), findsNothing);
      expect(await result, SshAgentSignatureDecision.declined);
    });

    testWidgets('shows the requested user without hidden characters', (
      tester,
    ) async {
      await showPrompt(tester, _request(username: 'git\u001b[2J\u202Eabc'));

      expect(find.textContaining('\u001b', findRichText: true), findsNothing);
      expect(find.textContaining('\u202E', findRichText: true), findsNothing);
      expect(
        find.textContaining('git[2Jabc', findRichText: true),
        findsOneWidget,
      );
    });
  });

  group('sanitizeAgentSignatureUsername', () {
    test('removes controls, bidi and zero-width characters', () {
      expect(
        sanitizeAgentSignatureUsername(
          'ad\u202Emin\u2066x\u2069\u200B\u200D\uFEFF\u0085\u2028y',
        ),
        'adminxy',
      );
    });

    test('shortens long names without splitting a character', () {
      // A flag is two code points (four UTF-16 units) but one character.
      final name = '${'a' * 63}\u{1F1FA}\u{1F1F8}zzz';

      expect(
        sanitizeAgentSignatureUsername(name),
        '${'a' * 63}\u{1F1FA}\u{1F1F8}…',
      );
    });

    test('keeps short names as they are', () {
      expect(sanitizeAgentSignatureUsername('git'), 'git');
    });
  });

  testWidgets('the prompt handler refuses without a navigator', (tester) async {
    final handler = createAgentSignaturePromptHandler();

    expect(
      await handler(_request(), timeout: const Duration(seconds: 1)),
      SshAgentSignatureDecision.unavailable,
    );
  });

  group('AgentForwardingTitleSlot', () {
    Future<void> pumpTitle(
      WidgetTester tester,
      SshAgentForwarding? forwarding, {
      double width = 400,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: AgentForwardingTitleSlot(
                  forwarding: forwarding,
                  title: const Text(
                    'a fairly long host label',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('shows a labelled key and explains forwarding on tap', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pumpTitle(tester, _forwarding());

      expect(find.text('ssh-agent'), findsOneWidget);
      expect(find.byIcon(Icons.key_rounded), findsOneWidget);
      expect(
        find.bySemanticsLabel('SSH agent forwarding on. Show details'),
        findsOneWidget,
      );
      final size = tester.getSize(
        find.byKey(const Key('agent-forwarding-indicator')),
      );
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));

      await tester.tap(find.byKey(const Key('agent-forwarding-indicator')));
      await tester.pumpAndSettle();

      expect(find.text('agent forwarding'), findsOneWidget);
      expect(find.text('Each signature asks you first.'), findsOneWidget);
      expect(
        find.text('0 signatures on this connection.', findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining('in the background'), findsOneWidget);
      expect(find.textContaining('sleeps'), findsNothing);
      semantics.dispose();
    });

    testWidgets('never overflows or shrinks below a 44-point target', (
      tester,
    ) async {
      final forwarding = _forwarding();
      for (final width in [400.0, 160.0, 90.0, 50.0, 44.0, 43.0, 20.0, 0.0]) {
        await pumpTitle(tester, forwarding, width: width);
        expect(tester.takeException(), isNull, reason: 'width $width');
        final badge = find.byKey(const Key('agent-forwarding-indicator'));
        if (width < 44) {
          expect(badge, findsNothing, reason: 'width $width');
        } else {
          expect(
            tester.getSize(badge).width,
            greaterThanOrEqualTo(44),
            reason: 'width $width',
          );
        }
      }

      await pumpTitle(tester, forwarding, width: 90);
      expect(find.text('ssh-agent'), findsNothing);
      expect(find.byIcon(Icons.key_rounded), findsOneWidget);
    });

    testWidgets('the details sheet scrolls with large text in landscape', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(800, 360)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(800, 360),
            textScaler: TextScaler.linear(2),
          ),
          child: MaterialApp(
            home: Scaffold(
              body: AgentForwardingTitleSlot(
                forwarding: _forwarding(),
                title: const Text('host'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('agent-forwarding-indicator')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
    });

    testWidgets('hides the badge once forwarding stops', (tester) async {
      final forwarding = _forwarding(
        confirm: (_) async => SshAgentSignatureDecision.stopForwarding,
      );
      await pumpTitle(tester, forwarding);
      expect(find.byIcon(Icons.key_rounded), findsOneWidget);

      forwarding.stop();
      await tester.pump();

      expect(find.byIcon(Icons.key_rounded), findsNothing);
      expect(find.text('a fairly long host label'), findsOneWidget);
    });

    testWidgets('shows only the title without forwarding', (tester) async {
      await pumpTitle(tester, null);

      expect(find.byIcon(Icons.key_rounded), findsNothing);
      expect(find.text('a fairly long host label'), findsOneWidget);
    });
  });
}
