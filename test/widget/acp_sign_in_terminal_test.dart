// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/acp_authentication.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/presentation/widgets/acp_sign_in_terminal.dart';

import '../helpers/mocks.dart';

final class _FakeSignInProcess implements AcpSignInProcess {
  final outputController = StreamController<List<int>>.broadcast();
  final exit = Completer<int?>();
  final List<List<int>> written = <List<int>>[];
  final List<(int, int)> resizes = <(int, int)>[];
  bool closed = false;

  @override
  Stream<List<int>> get output => outputController.stream;

  @override
  Future<int?> get exitStatus => exit.future;

  @override
  void write(List<int> bytes) => written.add(bytes);

  @override
  void resize(int columns, int rows) => resizes.add((columns, rows));

  @override
  void close() {
    closed = true;
    if (!exit.isCompleted) exit.complete(null);
  }

  void emit(String text) => outputController.add(utf8.encode(text));
}

final _launch = AcpTerminalAuthLaunch.forMethod(
  hostId: 1,
  providerId: 'builtin:copilot-cli',
  providerLabel: 'Copilot CLI',
  method: const AcpAuthMethod(
    id: 'terminal-login',
    name: 'Log in from the terminal',
    type: AcpAuthMethod.terminalType,
    description: 'Follow the prompts to finish signing in.',
    args: ['--login'],
  ),
  launchArgv: const ['copilot', '--acp'],
  workingDirectory: '/repo',
);

Future<({List<_FakeSignInProcess> processes, bool? Function() result})> _open(
  WidgetTester tester,
) async {
  final processes = <_FakeSignInProcess>[];
  bool? result;
  var completed = false;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            result = await showAcpSignInTerminal(
              context,
              launch: _launch,
              start: ({required columns, required rows}) async {
                final process = _FakeSignInProcess();
                processes.add(process);
                return process;
              },
            );
            completed = true;
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return (processes: processes, result: () => completed ? result : null);
}

void main() {
  test('SSH sign-in keeps output sent before the terminal listens', () async {
    registerFallbackValue(const SSHPtyConfig());
    final session = MockSshSession();
    final channel = MockSSHSession();
    final stdout = StreamController<Uint8List>()
      ..add(Uint8List.fromList(utf8.encode('Open https://example.com/dev\n')));
    when(() => channel.stdout).thenAnswer((_) => stdout.stream);
    when(() => channel.stderr).thenAnswer((_) => const Stream.empty());
    when(channel.close).thenAnswer((_) {});
    when(() => session.execute(any(), pty: any(named: 'pty')))
        .thenAnswer((_) async => channel);

    final process = await startAcpSignInOverSsh(
      session,
      'login',
      columns: 80,
      rows: 24,
    );
    // The channel's buffered output is delivered before anything listens,
    // as it is while the sign-in screen is still awaiting the start.
    await pumpEventQueue();
    final received = <int>[];
    process.output.listen(received.addAll);
    await pumpEventQueue();

    expect(utf8.decode(received), 'Open https://example.com/dev\n');
    process.close();
    await stdout.close();
  });

  testWidgets('a zero exit status closes the terminal as signed in', (
    tester,
  ) async {
    final opened = await _open(tester);
    final process = opened.processes.single;

    expect(find.text('Sign in to Copilot CLI'), findsOneWidget);
    expect(find.text('Log in from the terminal'), findsOneWidget);
    expect(
      find.text('Follow the prompts to finish signing in.'),
      findsOneWidget,
    );
    expect(find.text('sign-in running · tap to type'), findsOneWidget);

    process.emit(
      'Open \x1b[4mhttps://example.com/device?code=AB12\x1b[0m.\r\n',
    );
    await tester.pump();
    expect(find.text('https://example.com/device?code=AB12'), findsOneWidget);

    process.exit.complete(0);
    await tester.pumpAndSettle();

    expect(opened.result(), isTrue);
    expect(find.text('Sign in to Copilot CLI'), findsNothing);
    expect(process.closed, isTrue);
  });

  test('opens only http(s) addresses with a host', () {
    expect(acpSignInWebLink('https://example.com/device'), isNotNull);
    expect(acpSignInWebLink('HTTP://example.com'), isNotNull);
    expect(acpSignInWebLink('custom:https://example.com'), isNull);
    expect(acpSignInWebLink('javascript:alert(1)//https://x'), isNull);
    expect(acpSignInWebLink('https:///no-host'), isNull);
    expect(acpSignInWebLink('file:///etc/passwd'), isNull);
  });

  testWidgets('a hyperlink to another scheme is not offered', (tester) async {
    final opened = await _open(tester);
    opened.processes.single.emit(
      '\x1b]8;;custom:https://example.com\x07Sign in\x1b]8;;\x07\r\n',
    );
    await tester.pump();
    expect(find.textContaining('custom:'), findsNothing);
    opened.processes.single.emit(
      '\x1b]8;;https://example.com/ok\x07Sign in\x1b]8;;\x07\r\n',
    );
    await tester.pump();
    expect(find.text('https://example.com/ok'), findsOneWidget);
    opened.processes.single.exit.complete(1);
    await tester.pump();
  });

  testWidgets('a non-zero exit stays open and can run again', (tester) async {
    final opened = await _open(tester);
    opened.processes.single.exit.complete(3);
    await tester.pump();

    expect(find.text('sign-in exited with status 3'), findsOneWidget);
    expect(opened.result(), isNull);

    await tester.tap(find.widgetWithText(TextButton, 'Run again'));
    await tester.pump();
    expect(opened.processes, hasLength(2));
    expect(opened.processes.first.closed, isTrue);

    await tester.tap(find.byTooltip('Cancel sign-in'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(opened.result(), isFalse);
    expect(opened.processes.last.closed, isTrue);
  });

  testWidgets('a process that cannot start reports it without crashing', (
    tester,
  ) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showAcpSignInTerminal(
                context,
                launch: _launch,
                start: ({required columns, required rows}) =>
                    Future<AcpSignInProcess>.error(StateError('no channel')),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('couldn’t open a terminal on this host'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Run again'), findsOneWidget);
    await tester.tap(find.byTooltip('Cancel sign-in'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(result, isFalse);
  });
}
