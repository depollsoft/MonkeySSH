import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/models/terminal_program_status.dart';
import 'package:monkeyssh/domain/models/terminal_progress.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/terminal_notification.dart';

import '../../helpers/mocks.dart';

SshSession _session() => SshSession(
  connectionId: 1,
  hostId: 1,
  client: MockSshClient(),
  config: const SshConnectionConfig(
    hostname: 'example.com',
    port: 22,
    username: 'demo',
  ),
);

const _inlinePngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUB'
    'AScY42YAAAAASUVORK5CYII=';

void main() {
  test('routes OSC 1337 inline images into terminal graphics', () async {
    final session = _session();
    final terminal = session.getOrCreateTerminal();

    session.debugHandlePrivateOsc('1337', const [
      'File=inline=1',
      'width=2',
      'doNotMoveCursor=1:$_inlinePngBase64',
    ]);

    for (
      var attempt = 0;
      attempt < 20 && !terminal.graphics.hasPlacements;
      attempt += 1
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(terminal.graphics.placements, hasLength(1));
    expect(terminal.graphics.placements.single.cols, 2);
  });

  test('routes OSC 9 to a terminal notification request', () async {
    final session = _session();
    final next = session.terminalNotifications.first;
    session.debugHandlePrivateOsc('9', ['Build finished']);
    final request = await next;
    expect(request, const TerminalNotificationRequest(body: 'Build finished'));
  });

  test('routes OSC 777 with a title and body', () async {
    final session = _session();
    final next = session.terminalNotifications.first;
    session.debugHandlePrivateOsc('777', ['notify', 'Deploy', 'Succeeded']);
    final request = await next;
    expect(request.title, 'Deploy');
    expect(request.body, 'Succeeded');
  });

  test('terminal parser routes BEL and fragmented ST OSC 633 sequences', () {
    final session = _session();
    final terminal = session.getOrCreateTerminal();
    void write(String data) => terminal.write(data);

    write('\x1b]633;A\x07');
    expect(session.shellStatus, TerminalShellStatus.prompt);

    write('\x1b]633;P;Cwd=/home/demo/project\x1b');
    expect(session.workingDirectory, isNull);
    write(r'\');
    expect(
      resolveTerminalWorkingDirectoryPath(session.workingDirectory),
      '/home/demo/project',
    );
  });

  test('OSC 7 can clear previously reported working-directory metadata', () {
    final session = _session()
      ..debugHandlePrivateOsc('7', const ['file://host/home/demo']);
    expect(session.workingDirectory, isNotNull);

    session.debugHandlePrivateOsc('7', const ['']);
    expect(session.workingDirectory, isNull);
  });

  test('routes OSC 633 shell state and working-directory properties', () {
    final session = _session();
    var metadataChanges = 0;
    void handleOsc(List<String> args) =>
        session.debugHandlePrivateOsc('633', args);
    session.addMetadataListener(() => metadataChanges += 1);

    handleOsc(const ['A']);
    expect(session.shellStatus, TerminalShellStatus.prompt);
    handleOsc(const ['P', 'Cwd=/home/demo/project']);
    expect(
      resolveTerminalWorkingDirectoryPath(session.workingDirectory),
      '/home/demo/project',
    );
    // Command-line payloads are consumed without retaining user content.
    handleOsc(const ['E', 'secret command']);
    expect(metadataChanges, 2);
    handleOsc(const ['D', '23']);
    expect(session.lastExitCode, 23);
    expect(metadataChanges, 3);
  });

  test('routes OSC 9;9 and iTerm2 remote-host/current-directory metadata', () {
    final session = _session();
    void handleOsc(String code, List<String> args) =>
        session.debugHandlePrivateOsc(code, args);

    handleOsc('9', const ['9', r'C:\Users\demo\repo']);
    expect(
      resolveTerminalWorkingDirectoryPath(session.workingDirectory),
      '/C:/Users/demo/repo',
    );

    handleOsc('1337', const ['RemoteHost=demo@build.example.com']);
    handleOsc('1337', const ['CurrentDir=/srv/repo']);
    expect(session.workingDirectory?.host, 'build.example.com');
    expect(
      resolveTerminalWorkingDirectoryPath(session.workingDirectory),
      '/srv/repo',
    );
  });

  test('applies and resets remote OSC palette overrides per session', () {
    final session = _session()..terminalTheme = TerminalThemes.dracula;
    var metadataChanges = 0;
    void handleOsc(String code, List<String> args) =>
        session.debugHandlePrivateOsc(code, args);
    session.addMetadataListener(() => metadataChanges += 1);

    handleOsc('11', const ['#102030']);
    expect(session.terminalTheme?.background, const Color(0xFF102030));
    handleOsc('4', const ['1', '#abcdef']);
    expect(session.terminalTheme?.red, const Color(0xFFABCDEF));

    handleOsc('111', const []);
    handleOsc('104', const []);
    expect(
      session.terminalTheme?.background,
      TerminalThemes.dracula.background,
    );
    expect(session.terminalTheme?.red, TerminalThemes.dracula.red);
    expect(metadataChanges, 4);
  });

  test('tracks shell and explicit command marks', () {
    final session = _session();
    final terminal = session.getOrCreateTerminal();
    void handleOsc(String code, List<String> args) =>
        session.debugHandlePrivateOsc(code, args);
    terminal.write('prompt\r\n');
    handleOsc('133', const ['C']);
    terminal.write('result\r\n');
    handleOsc('1337', const ['SetMark']);

    expect(session.terminalCommandMarkCount, 2);
    expect(session.terminalCommandMarkTracker.debugMarkRows, [1, 2]);
  });

  test('routes OSC 9;4 to terminal progress metadata', () async {
    final session = _session();
    var metadataChanges = 0;
    session
      ..addMetadataListener(() => metadataChanges += 1)
      ..debugHandlePrivateOsc('9', ['4', '1', '50']);

    expect(
      session.terminalProgress,
      const TerminalProgress(
        state: TerminalProgressState.normal,
        percentage: 50,
      ),
    );
    expect(metadataChanges, 1);

    session.debugHandlePrivateOsc('9', ['4', '0']);

    expect(session.terminalProgress, isNull);
    expect(metadataChanges, 2);
  });

  test('synchronizes and clears progress without duplicate notifications', () {
    final session = _session();
    var metadataChanges = 0;
    const progress = TerminalProgress(
      state: TerminalProgressState.normal,
      percentage: 50,
    );
    session.addMetadataListener(() => metadataChanges += 1);

    expect(session.synchronizeTerminalProgress(progress), isTrue);
    expect(session.terminalProgress, progress);
    expect(metadataChanges, 1);

    expect(session.synchronizeTerminalProgress(progress), isFalse);
    expect(metadataChanges, 1);

    expect(session.clearTerminalProgress(), isTrue);
    expect(session.terminalProgress, isNull);
    expect(metadataChanges, 2);

    expect(session.clearTerminalProgress(), isFalse);
    expect(metadataChanges, 2);
  });

  test('routes OSC 7501 reports to program status', () {
    final session = _session();
    var metadataChanges = 0;
    session
      ..addMetadataListener(() => metadataChanges += 1)
      ..debugHandlePrivateOsc('7501', const ['state=working:app=claude-code']);

    expect(
      session.programStatus,
      const TerminalProgramStatus(
        state: TerminalProgramState.working,
        app: 'claude-code',
      ),
    );
    expect(metadataChanges, 1);

    session.debugHandlePrivateOsc('7501', const [
      'state=working:app=claude-code',
    ]);
    expect(metadataChanges, 1);

    session.debugHandlePrivateOsc('133', const ['A', 'redraw=0']);
    expect(session.programStatus, isNull);
    expect(metadataChanges, 2);
  });

  test('takes multiplexer program status from the window snapshot', () {
    final session = _session()..remoteMuxBackend = RemoteMuxBackend.monkeyMux;
    const status = TerminalProgramStatus(
      state: TerminalProgramState.blocked,
      kind: TerminalProgramBlockedKind.permission,
    );

    session.debugHandlePrivateOsc('7501', const ['state=working']);
    expect(session.programStatus, isNull);

    expect(session.synchronizeProgramStatus(status), isTrue);
    expect(session.synchronizeProgramStatus(status), isFalse);
    expect(session.programStatus, status);

    session.remoteMuxBackend = null;
    expect(session.programStatus, isNull);
  });

  test('attaching a multiplexer drops plain-shell program status', () {
    final session = _session()
      ..debugHandlePrivateOsc('7501', const ['state=done']);
    var metadataChanges = 0;
    session
      ..addMetadataListener(() => metadataChanges += 1)
      ..remoteMuxBackend = RemoteMuxBackend.tmux;

    expect(session.programStatus, isNull);
    expect(metadataChanges, 1);

    session.remoteMuxBackend = null;
    expect(session.programStatus, isNull);
  });

  test('OSC 9;4 progress does not emit a notification', () async {
    final session = _session();
    var emitted = false;
    final sub = session.terminalNotifications.listen((_) => emitted = true);

    session.debugHandlePrivateOsc('9', ['4', '3']);
    await Future<void>.delayed(Duration.zero);

    expect(emitted, isFalse);
    expect(
      session.terminalProgress,
      const TerminalProgress(state: TerminalProgressState.indeterminate),
    );
    await sub.cancel();
  });

  test('assembles a chunked OSC 99 notification', () async {
    final session = _session();
    final next = session.terminalNotifications.first;
    session
      ..debugHandlePrivateOsc('99', ['i=1:d=0', 'Tests'])
      ..debugHandlePrivateOsc('99', ['i=1:p=body', 'All green']);
    final request = await next;
    expect(request.title, 'Tests');
    expect(request.body, 'All green');
    expect(request.identifier, '1');
  });

  test(
    'routes Kitty close actions to the notification lifecycle stream',
    () async {
      final session = _session();
      final next = session.terminalNotifications.first;
      session.debugHandlePrivateOsc('99', const ['i=build:p=close']);
      expect(
        await next,
        const TerminalNotificationRequest.close(identifier: 'build'),
      );
    },
  );

  test('does not emit for non-notification OSC codes', () async {
    final session = _session();
    var emitted = false;
    final sub = session.terminalNotifications.listen((_) => emitted = true);
    // OSC 8 (hyperlink) and OSC 7 (working dir) must not notify.
    session
      ..debugHandlePrivateOsc('8', ['', 'https://example.com'])
      ..debugHandlePrivateOsc('7', ['file://host/home/demo']);
    await Future<void>.delayed(Duration.zero);
    expect(emitted, isFalse);
    await sub.cancel();
  });
}
