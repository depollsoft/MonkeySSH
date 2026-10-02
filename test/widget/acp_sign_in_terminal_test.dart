// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_authentication.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/presentation/widgets/acp_sign_in_terminal.dart';

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
