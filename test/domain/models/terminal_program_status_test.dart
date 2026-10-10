import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/terminal_program_status.dart';
import 'package:monkeyssh/domain/models/terminal_progress.dart';

String _text(String value) => base64.encode(utf8.encode(value));

TerminalProgramStatus? _single(String body) {
  final records = TerminalProgramStatusRecords()..apply(body);
  return records.summary;
}

void main() {
  group('TerminalProgramStatusRecords', () {
    test('recognises feature detection', () {
      expect(TerminalProgramStatusRecords.isQuery('?'), isTrue);
      expect(TerminalProgramStatusRecords.isQuery('state=idle'), isFalse);
    });

    test('parses the reports Claude Code sends', () {
      expect(
        _single('state=working:app=claude-code'),
        const TerminalProgramStatus(
          state: TerminalProgramState.working,
          app: 'claude-code',
        ),
      );
      expect(
        _single(
          'state=blocked:app=claude-code:kind=permission:msg='
          '${_text('approve Bash: touch probe2.txt')}',
        ),
        const TerminalProgramStatus(
          state: TerminalProgramState.blocked,
          kind: TerminalProgramBlockedKind.permission,
          app: 'claude-code',
          message: 'approve Bash: touch probe2.txt',
        ),
      );
    });

    test('ignores reports the spec says to drop', () {
      for (final body in [
        'app=claude-code',
        'state=sleeping',
        'state=working:id=a//b',
        'state=working:id=a!b',
        'state=working:id=a/b/c/d/e/f/g/h/i',
        'state=working:id=${'s' * 33}',
        'state=working:abcdefghijklmnopq=1',
        'state=working:app=${'a' * 33}',
        'state=done:msg=a===',
        'state=done:msg=aGkh=',
        'state=done:msg=a-_b',
        'state=done:msg=${_text('a\nb')}',
        'state=done:title=${_text('a\u0085b')}',
        'state=done:msg=${base64.encode([0xff])}',
        'state=done:msg=${base64.encode(List.filled(2049, 0x6d))}',
        'state=done:${'x' * 4096}',
      ]) {
        expect(_single(body), isNull, reason: body);
      }
    });

    test('keeps what is valid and drops what is not', () {
      expect(
        _single('garbage:=x:state=idle:Upper=1:future=yes:app=a!b'),
        const TerminalProgramStatus(state: TerminalProgramState.idle),
      );
      expect(
        _single(' state = done : app = brew '),
        const TerminalProgramStatus(
          state: TerminalProgramState.done,
          app: 'brew',
        ),
      );
      expect(
        _single('state=working:state=done'),
        const TerminalProgramStatus(state: TerminalProgramState.done),
      );
      expect(
        _single('state=working:kind=permission:progress=101'),
        const TerminalProgramStatus(state: TerminalProgramState.working),
      );
      expect(
        _single('state=done:progress=50:msg=aGk'),
        const TerminalProgramStatus(
          state: TerminalProgramState.done,
          message: 'hi',
        ),
      );
      expect(
        _single('state=done:msg=${_text('a\u202eb\u2066c')}')?.message,
        'abc',
      );
    });

    test('a report replaces its record completely', () {
      final records = TerminalProgramStatusRecords()
        ..apply('state=working:app=deploy:progress=10:msg=${_text('push')}')
        ..apply('state=working');

      expect(
        records.summary,
        const TerminalProgramStatus(state: TerminalProgramState.working),
      );
    });

    test('children inherit app and clear with their parent', () {
      final records = TerminalProgramStatusRecords()
        ..apply('state=working:app=deploy')
        ..apply('state=working:id=us-east:progress=40')
        ..apply(
          'state=blocked:id=eu-west:kind=permission:msg='
          '${_text('approve prod')}',
        )
        ..apply('state=working:id=eu-west/canary');

      expect(
        records.summary,
        const TerminalProgramStatus(
          state: TerminalProgramState.blocked,
          kind: TerminalProgramBlockedKind.permission,
          app: 'deploy',
          message: 'approve prod',
        ),
      );

      records.apply('state=clear:id=eu-west');
      expect(records.length, 2);
      expect(
        records.summary,
        const TerminalProgramStatus(
          state: TerminalProgramState.working,
          app: 'deploy',
        ),
      );

      records.apply('state=clear');
      expect(records.summary, isNull);
    });

    test('evicts the least recently updated record past the cap', () {
      final records = TerminalProgramStatusRecords();
      for (
        var index = 0;
        index <= TerminalProgramStatusRecords.maxRecords;
        index++
      ) {
        records.apply('state=working:id=task$index');
        if (index == 1) records.apply('state=done:id=task0');
      }

      expect(records.length, TerminalProgramStatusRecords.maxRecords);
      // Clearing task1 removes nothing because it was evicted; task0 was
      // touched after it and survived.
      records.apply('state=clear:id=task1');
      expect(records.length, TerminalProgramStatusRecords.maxRecords);
      records.apply('state=clear:id=task0');
      expect(records.length, TerminalProgramStatusRecords.maxRecords - 1);
    });

    test('a prompt drops running records but keeps done and error', () {
      final records = TerminalProgramStatusRecords()
        ..apply('state=working')
        ..apply('state=blocked:id=a')
        ..apply('state=idle:id=b')
        ..apply('state=done:id=c')
        ..apply('state=error:id=d:msg=${_text('exit 1')}');

      expect(records.dropRunning(), isTrue);
      expect(records.length, 2);
      expect(
        records.summary,
        const TerminalProgramStatus(
          state: TerminalProgramState.error,
          message: 'exit 1',
        ),
      );
      expect(records.dropRunning(), isFalse);
    });
  });

  group('TerminalProgramStatus', () {
    test('parses MonkeyMux snapshots', () {
      expect(
        TerminalProgramStatus.fromJson({
          'state': 'blocked',
          'kind': 'question',
          'progress': 30,
          'app': 'deploy',
          'title': 'eu-west',
          'msg': 'Which region?',
        }),
        const TerminalProgramStatus(
          state: TerminalProgramState.blocked,
          kind: TerminalProgramBlockedKind.question,
          progress: 30,
          app: 'deploy',
          title: 'eu-west',
          message: 'Which region?',
        ),
      );
      expect(TerminalProgramStatus.fromJson({'state': 'paused'}), isNull);
      expect(TerminalProgramStatus.fromJson('working'), isNull);
      expect(
        TerminalProgramStatus.fromJson({
          'state': 'done',
          'kind': 'auth',
          'progress': 20,
        }),
        const TerminalProgramStatus(state: TerminalProgramState.done),
      );
    });

    test('labels each state', () {
      String label(
        TerminalProgramState state, [
        TerminalProgramBlockedKind? kind,
      ]) => TerminalProgramStatus(state: state, kind: kind).label;

      expect(label(TerminalProgramState.idle), 'waiting');
      expect(label(TerminalProgramState.working), 'working');
      expect(
        label(
          TerminalProgramState.blocked,
          TerminalProgramBlockedKind.permission,
        ),
        'approval',
      );
      expect(
        label(
          TerminalProgramState.blocked,
          TerminalProgramBlockedKind.question,
        ),
        'question',
      );
      expect(
        label(TerminalProgramState.blocked, TerminalProgramBlockedKind.auth),
        'sign in',
      );
      expect(label(TerminalProgramState.blocked), 'blocked');
      expect(label(TerminalProgramState.done), 'done');
      expect(label(TerminalProgramState.error), 'error');
    });

    test('projects work onto the progress bar', () {
      expect(
        const TerminalProgramStatus(state: TerminalProgramState.working)
            .terminalProgress,
        const TerminalProgress(state: TerminalProgressState.indeterminate),
      );
      expect(
        const TerminalProgramStatus(
          state: TerminalProgramState.working,
          progress: 40,
        ).terminalProgress,
        const TerminalProgress(
          state: TerminalProgressState.normal,
          percentage: 40,
        ),
      );
      expect(
        const TerminalProgramStatus(
          state: TerminalProgramState.blocked,
          progress: 40,
        ).terminalProgress,
        const TerminalProgress(
          state: TerminalProgressState.pausedOrWarning,
          percentage: 40,
        ),
      );
      for (final state in [
        TerminalProgramState.idle,
        TerminalProgramState.blocked,
        TerminalProgramState.done,
        TerminalProgramState.error,
      ]) {
        expect(
          TerminalProgramStatus(state: state).terminalProgress,
          isNull,
          reason: state.name,
        );
      }
    });

    test('surfaces the message only when it needs attention', () {
      const message = 'approve Bash: rm -rf build';
      expect(
        const TerminalProgramStatus(
          state: TerminalProgramState.blocked,
          message: message,
        ).attentionMessage,
        message,
      );
      expect(
        const TerminalProgramStatus(
          state: TerminalProgramState.working,
          message: message,
        ).attentionMessage,
        isNull,
      );
    });
  });
}
