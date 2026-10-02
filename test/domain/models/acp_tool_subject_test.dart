import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_tool_subject.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';

AcpToolCallUpdate _tool(Map<String, Object?> json) =>
    AcpToolCallUpdate.fromJson(<String, Object?>{'toolCallId': 't', ...json});

void main() {
  test('prefers a command in raw input', () {
    expect(
      acpToolCallSubject(
        _tool({
          'rawInput': {'command': 'npm test', 'file_path': '/a'},
          'locations': [
            {'path': '/b'},
          ],
        }),
      ),
      'npm test',
    );
  });

  test('joins an argv command and marks multi-line input', () {
    expect(
      acpToolCallSubject(
        _tool({
          'rawInput': {
            'command': ['git', 'status'],
          },
        }),
      ),
      'git status',
    );
    expect(
      acpToolCallSubject(
        _tool({
          'rawInput': {'command': 'set -e\n  make  all'},
        }),
      ),
      'set -e …',
    );
  });

  test('falls back to a diff path, then the first location', () {
    expect(
      acpToolCallSubject(
        _tool({
          'content': [
            {'type': 'diff', 'path': '/src/a.dart', 'newText': 'x'},
          ],
        }),
      ),
      '/src/a.dart',
    );
    expect(
      acpToolCallSubject(
        _tool({
          'locations': [
            {'path': '/src/b.dart', 'line': 12},
          ],
        }),
      ),
      '/src/b.dart:12',
    );
  });

  test('bounds long subjects and ignores non-text input', () {
    final long = 'x' * 400;
    final subject = acpToolCallSubject(
      _tool({
        'rawInput': {'command': long},
      }),
    )!;
    expect(subject.length, kAcpToolSubjectMaxCharacters);
    expect(subject, endsWith('…'));
    expect(
      acpToolCallSubject(
        _tool({
          'rawInput': {
            'command': {'nested': true},
          },
        }),
      ),
      isNull,
    );
    expect(acpToolCallSubject(_tool({})), isNull);
  });
}
