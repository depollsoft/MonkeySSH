import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInputClient;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_input_handler.dart';
import 'package:xterm/xterm.dart';

import '../test/helpers/terminal_input_helpers.dart';

const _deleteDetectionMarker = '\u200B\u200B';

Duration _validationSummaryHoldDuration(int seconds) =>
    Duration(seconds: seconds);

Duration? _holdValidationSummaryDuration() {
  const seconds = int.fromEnvironment('HOLD_VALIDATION_SUMMARY_SECONDS');
  if (seconds <= 0) {
    return null;
  }
  return _validationSummaryHoldDuration(seconds);
}

class _ValidationCase {
  const _ValidationCase({
    required this.id,
    required this.title,
    required this.expectedVisibleText,
    required this.steps,
    this.resolveTextBeforeCursor,
    this.expectedRawOutput,
    this.expectedEditingText,
    this.expectedSelectionOffset,
    this.expectedTerminalCursorOffset,
  });

  final String id;
  final String title;
  final String expectedVisibleText;
  final String? expectedRawOutput;
  final String? expectedEditingText;
  final int? expectedSelectionOffset;
  final int? expectedTerminalCursorOffset;
  final String? Function()? resolveTextBeforeCursor;
  final List<(String, int, int, TextRange?)> steps;
}

class _ValidationResult {
  const _ValidationResult({
    required this.testCase,
    required this.visibleText,
    required this.rawOutput,
    required this.editingText,
    required this.selectionOffset,
    required this.terminalCursorOffset,
  });

  final _ValidationCase testCase;
  final String visibleText;
  final String rawOutput;
  final String editingText;
  final int? selectionOffset;
  final int terminalCursorOffset;

  bool get passed =>
      visibleText == testCase.expectedVisibleText &&
      (testCase.expectedRawOutput == null ||
          rawOutput == testCase.expectedRawOutput) &&
      (testCase.expectedEditingText == null ||
          editingText == testCase.expectedEditingText) &&
      (testCase.expectedSelectionOffset == null ||
          selectionOffset == testCase.expectedSelectionOffset) &&
      (testCase.expectedTerminalCursorOffset == null ||
          terminalCursorOffset == testCase.expectedTerminalCursorOffset);
}

class _ResultScreen extends StatelessWidget {
  const _ResultScreen({required this.result});

  final _ValidationResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColor = result.passed ? Colors.green : Colors.red;
    final rows = <Widget>[
      Text(result.testCase.title, style: theme.textTheme.headlineSmall),
      const SizedBox(height: 16),
      Text(
        result.passed ? 'PASS' : 'FAIL',
        style: theme.textTheme.headlineMedium?.copyWith(color: statusColor),
      ),
      const SizedBox(height: 24),
      _ResultRow(
        label: 'Expected visible',
        value: result.testCase.expectedVisibleText,
      ),
      _ResultRow(label: 'Actual visible', value: result.visibleText),
      _ResultRow(
        label: 'Expected raw',
        value: result.testCase.expectedRawOutput ?? '(not asserted)',
      ),
      _ResultRow(label: 'Actual raw', value: result.rawOutput),
      _ResultRow(
        label: 'Expected editing text',
        value: result.testCase.expectedEditingText ?? '(not asserted)',
      ),
      _ResultRow(label: 'Actual editing text', value: result.editingText),
      _ResultRow(
        label: 'Expected cursor',
        value:
            result.testCase.expectedSelectionOffset?.toString() ??
            '(not asserted)',
      ),
      _ResultRow(
        label: 'Actual cursor',
        value: result.selectionOffset?.toString() ?? 'null',
      ),
      _ResultRow(
        label: 'Expected terminal cursor',
        value:
            result.testCase.expectedTerminalCursorOffset?.toString() ??
            '(not asserted)',
      ),
      _ResultRow(
        label: 'Actual terminal cursor',
        value: result.terminalCursorOffset.toString(),
      ),
    ];

    return MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              child: DefaultTextStyle(
                style:
                    theme.textTheme.bodyLarge ?? const TextStyle(fontSize: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: rows,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        SelectableText(value),
      ],
    ),
  );
}

Future<_ValidationResult> _runCase(
  WidgetTester tester,
  _ValidationCase testCase,
) async {
  final terminalOutput = <String>[];
  final terminal = Terminal(onOutput: terminalOutput.add);
  final focusNode = FocusNode();

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TerminalTextInputHandler(
          terminal: terminal,
          focusNode: focusNode,
          deleteDetection: true,
          resolveTextBeforeCursor: testCase.resolveTextBeforeCursor,
          child: const SizedBox.expand(),
        ),
      ),
    ),
  );

  focusNode.requestFocus();
  await tester.pump();
  for (final (text, selectionBase, selectionExtent, composing)
      in testCase.steps) {
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection(
          baseOffset: selectionBase,
          extentOffset: selectionExtent,
        ),
        composing: composing ?? TextRange.empty,
      ),
    );
    await tester.pump();
  }

  final client =
      tester.state(find.byType(TerminalTextInputHandler)) as TextInputClient;
  final editingValue = client.currentTextEditingValue;
  final terminalState = terminalStateFromEvents(terminalOutput);
  final result = _ValidationResult(
    testCase: testCase,
    visibleText: terminalState.text,
    rawOutput: terminalOutput.join(),
    editingText: editingValue?.text ?? '',
    selectionOffset: editingValue?.selection.extentOffset,
    terminalCursorOffset: terminalState.cursorOffset,
  );

  await tester.pumpWidget(_ResultScreen(result: result));
  await tester.pumpAndSettle();

  focusNode.dispose();
  return result;
}

class _SummaryScreen extends StatelessWidget {
  const _SummaryScreen({required this.results});

  final List<_ValidationResult> results;

  @override
  Widget build(BuildContext context) {
    final failureCount = results.where((result) => !result.passed).length;
    return MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Terminal text input validation summary',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    failureCount == 0
                        ? 'All cases passed'
                        : '$failureCount failing case(s)',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      color: failureCount == 0 ? Colors.green : Colors.red,
                    ),
                  ),
                  const SizedBox(height: 24),
                  for (final result in results)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${result.passed ? 'PASS' : 'FAIL'} ${result.testCase.id}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(result.testCase.title),
                          Text(
                            'Expected raw: ${result.testCase.expectedRawOutput ?? '(n/a)'}',
                          ),
                          Text('Actual raw: ${result.rawOutput}'),
                          Text(
                            'Expected visible: ${result.testCase.expectedVisibleText}',
                          ),
                          Text('Actual visible: ${result.visibleText}'),
                          Text(
                            'Expected terminal cursor: '
                            '${result.testCase.expectedTerminalCursorOffset?.toString() ?? '(n/a)'}',
                          ),
                          Text(
                            'Actual terminal cursor: ${result.terminalCursorOffset}',
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const cases = <_ValidationCase>[
    _ValidationCase(
      id: '01-first-swipe-word',
      title: 'First swipe word has no leading whitespace artifact',
      expectedVisibleText: 'hello',
      expectedRawOutput: 'hello',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'hello',
      expectedSelectionOffset: 7,
      steps: [
        (
          '$_deleteDetectionMarker\nhello',
          '$_deleteDetectionMarker\nhello'.length,
          '$_deleteDetectionMarker\nhello'.length,
          TextRange(
            start: _deleteDetectionMarker.length,
            end: '$_deleteDetectionMarker\nhello'.length,
          ),
        ),
        (
          '$_deleteDetectionMarker\nhello',
          '$_deleteDetectionMarker\nhello'.length,
          '$_deleteDetectionMarker\nhello'.length,
          null,
        ),
      ],
    ),
    _ValidationCase(
      id: '02-resume-swipe-separator',
      title: 'Swipe resume preserves separator after input reset',
      expectedVisibleText: ' world',
      expectedRawOutput: ' world',
      expectedEditingText:
          '$_deleteDetectionMarker'
          ' world',
      expectedSelectionOffset: 8,
      resolveTextBeforeCursor: _resolveTerminalTextWithoutTrailingSpace,
      steps: [
        (
          '$_deleteDetectionMarker world',
          '$_deleteDetectionMarker world'.length,
          '$_deleteDetectionMarker world'.length,
          TextRange(
            start: _deleteDetectionMarker.length,
            end: '$_deleteDetectionMarker world'.length,
          ),
        ),
        (
          '$_deleteDetectionMarker world',
          '$_deleteDetectionMarker world'.length,
          '$_deleteDetectionMarker world'.length,
          null,
        ),
      ],
    ),
    _ValidationCase(
      id: '03-no-duplicate-separator',
      title: 'Swipe resume does not duplicate separator after trailing space',
      expectedVisibleText: 'world',
      expectedRawOutput: 'world',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'world',
      expectedSelectionOffset: 7,
      resolveTextBeforeCursor: _resolveTerminalTextWithTrailingSpace,
      steps: [
        (
          '$_deleteDetectionMarker world',
          '$_deleteDetectionMarker world'.length,
          '$_deleteDetectionMarker world'.length,
          TextRange(
            start: _deleteDetectionMarker.length,
            end: '$_deleteDetectionMarker world'.length,
          ),
        ),
        (
          '$_deleteDetectionMarker world',
          '$_deleteDetectionMarker world'.length,
          '$_deleteDetectionMarker world'.length,
          null,
        ),
      ],
    ),
    _ValidationCase(
      id: '04-replacement-after-delete',
      title: 'Replacement after deleting a later swiped word stays intact',
      expectedVisibleText: 'the ',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'the ',
      expectedSelectionOffset: 6,
      expectedTerminalCursorOffset: 'the '.length,
      steps: [
        ('${_deleteDetectionMarker}teh world ', 12, 12, null),
        ('${_deleteDetectionMarker}teh ', 6, 6, null),
        ('${_deleteDetectionMarker}the ', 2, 5, null),
        ('${_deleteDetectionMarker}the ', 6, 6, null),
      ],
    ),
    _ValidationCase(
      id: '05-single-emoji-backspace',
      title: 'Deleting one emoji should emit one backspace',
      expectedVisibleText: '',
      expectedRawOutput: '👍\x7f',
      expectedEditingText: _deleteDetectionMarker,
      expectedSelectionOffset: 2,
      steps: [
        ('$_deleteDetectionMarker👍', 4, 4, null),
        (_deleteDetectionMarker, 2, 2, null),
      ],
    ),
    _ValidationCase(
      id: '06-combining-grapheme-backspace',
      title:
          'Deleting one combining-character grapheme should emit one backspace',
      expectedVisibleText: '',
      expectedRawOutput: 'e\u0301\x7f',
      expectedEditingText: _deleteDetectionMarker,
      expectedSelectionOffset: 2,
      steps: [
        ('${_deleteDetectionMarker}e\u0301', 4, 4, null),
        (_deleteDetectionMarker, 2, 2, null),
      ],
    ),
    _ValidationCase(
      id: '07-cursor-move-only',
      title: 'Collapsed IME caret moves also move the terminal cursor',
      expectedVisibleText: 'echo teh world',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'echo teh world',
      expectedSelectionOffset: 11,
      expectedTerminalCursorOffset: 'echo teh '.length,
      steps: [
        ('${_deleteDetectionMarker}echo teh world', 16, 16, null),
        ('${_deleteDetectionMarker}echo teh world', 11, 11, null),
      ],
    ),
    _ValidationCase(
      id: '08-midline-replace-backspace',
      title:
          'Mid-line replace then backspace keeps the terminal cursor aligned',
      expectedVisibleText: 'echo th world',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'echo th world',
      expectedSelectionOffset: 9,
      expectedTerminalCursorOffset: 'echo th'.length,
      steps: [
        ('${_deleteDetectionMarker}echo teh world', 16, 16, null),
        ('${_deleteDetectionMarker}echo teh world', 11, 11, null),
        ('${_deleteDetectionMarker}echo the world', 11, 11, null),
        ('${_deleteDetectionMarker}echo th world', 9, 9, null),
      ],
    ),
    _ValidationCase(
      id: '09-space-boundary-insert',
      title:
          'Inserting at a moved space boundary does not overwrite the next word',
      expectedVisibleText: 'foo Xbar',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'foo Xbar',
      expectedSelectionOffset: 7,
      expectedTerminalCursorOffset: 'foo X'.length,
      steps: [
        ('${_deleteDetectionMarker}foo bar', 9, 9, null),
        ('${_deleteDetectionMarker}foo bar', 6, 6, null),
        ('${_deleteDetectionMarker}foo Xbar', 7, 7, null),
      ],
    ),
    _ValidationCase(
      id: '10-punctuation-boundary-replace',
      title: 'Replacing punctuation mid-line keeps the trailing word intact',
      expectedVisibleText: 'hello; world',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'hello; world',
      expectedSelectionOffset: 8,
      expectedTerminalCursorOffset: 'hello;'.length,
      steps: [
        ('${_deleteDetectionMarker}hello, world', 14, 14, null),
        ('${_deleteDetectionMarker}hello, world', 8, 8, null),
        ('${_deleteDetectionMarker}hello; world', 8, 8, null),
      ],
    ),
    _ValidationCase(
      id: '11-repeated-word-replace',
      title:
          'Replacing the middle repeated word leaves the trailing match untouched',
      expectedVisibleText: 'go gone go',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'go gone go',
      expectedSelectionOffset: 9,
      expectedTerminalCursorOffset: 'go gone'.length,
      steps: [
        ('${_deleteDetectionMarker}go go go', 10, 10, null),
        ('${_deleteDetectionMarker}go go go', 5, 7, null),
        ('${_deleteDetectionMarker}go gone go', 9, 9, null),
      ],
    ),
    _ValidationCase(
      id: '12-space-boundary-insert-backspace',
      title:
          'Insert then backspace at a moved space boundary restores the original spacing',
      expectedVisibleText: 'foo bar',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'foo bar',
      expectedSelectionOffset: 6,
      expectedTerminalCursorOffset: 'foo '.length,
      steps: [
        ('${_deleteDetectionMarker}foo bar', 9, 9, null),
        ('${_deleteDetectionMarker}foo bar', 6, 6, null),
        ('${_deleteDetectionMarker}foo Xbar', 7, 7, null),
        ('${_deleteDetectionMarker}foo bar', 6, 6, null),
      ],
    ),
    _ValidationCase(
      id: '13-double-space-insert-backspace',
      title:
          'Insert then backspace between repeated spaces does not drift the cursor',
      expectedVisibleText: 'foo  bar',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'foo  bar',
      expectedSelectionOffset: 6,
      expectedTerminalCursorOffset: 'foo '.length,
      steps: [
        ('${_deleteDetectionMarker}foo  bar', 10, 10, null),
        ('${_deleteDetectionMarker}foo  bar', 6, 6, null),
        ('${_deleteDetectionMarker}foo X bar', 7, 7, null),
        ('${_deleteDetectionMarker}foo  bar', 6, 6, null),
      ],
    ),
    _ValidationCase(
      id: '14-repeated-word-replace-backspace',
      title:
          'Replacing a repeated middle word still leaves backspace targeting that word',
      expectedVisibleText: 'go gon go',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'go gon go',
      expectedSelectionOffset: 8,
      expectedTerminalCursorOffset: 'go gon'.length,
      steps: [
        ('${_deleteDetectionMarker}go go go', 10, 10, null),
        ('${_deleteDetectionMarker}go go go', 5, 7, null),
        ('${_deleteDetectionMarker}go gone go', 9, 9, null),
        ('${_deleteDetectionMarker}go gon go', 8, 8, null),
      ],
    ),
    _ValidationCase(
      id: '15-marker-loss-clear',
      title:
          'Losing the delete-detection marker clears all buffered text instead of one character',
      expectedVisibleText: '',
      expectedRawOutput: 'hello\x7f\x7f\x7f\x7f\x7f',
      expectedEditingText: _deleteDetectionMarker,
      expectedSelectionOffset: 2,
      expectedTerminalCursorOffset: 0,
      steps: [('${_deleteDetectionMarker}hello', 7, 7, null), ('', 0, 0, null)],
    ),
    _ValidationCase(
      id: '16-replacement-selection-backspace',
      title:
          'Replacement selection followed by immediate backspace keeps the cursor on the replaced word',
      expectedVisibleText: 'echo th world',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'echo th world',
      expectedSelectionOffset: 9,
      expectedTerminalCursorOffset: 'echo th'.length,
      steps: [
        ('${_deleteDetectionMarker}echo teh world', 16, 16, null),
        ('${_deleteDetectionMarker}echo teh world', 7, 10, null),
        ('${_deleteDetectionMarker}echo the world', 7, 10, null),
        ('${_deleteDetectionMarker}echo th world', 9, 9, null),
      ],
    ),
    _ValidationCase(
      id: '17-identical-char-insert',
      title:
          'Inserting an identical character at a moved caret stays anchored to that caret',
      expectedVisibleText: 'aaaaa',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'aaaaa',
      expectedSelectionOffset: 4,
      expectedTerminalCursorOffset: 2,
      steps: [
        ('${_deleteDetectionMarker}aaaa', 6, 6, null),
        ('${_deleteDetectionMarker}aaaa', 3, 3, null),
        ('${_deleteDetectionMarker}aaaaa', 4, 4, null),
      ],
    ),
    _ValidationCase(
      id: '18-identical-char-delete',
      title:
          'Deleting an identical character at a moved caret backspaces at that caret',
      expectedVisibleText: 'aaaa',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'aaaa',
      expectedSelectionOffset: 3,
      expectedTerminalCursorOffset: 1,
      steps: [
        ('${_deleteDetectionMarker}aaaaa', 7, 7, null),
        ('${_deleteDetectionMarker}aaaaa', 4, 4, null),
        ('${_deleteDetectionMarker}aaaa', 3, 3, null),
      ],
    ),
    _ValidationCase(
      id: '19-repeated-selection-replace-backspace',
      title:
          'Repeated non-collapsed replacement updates still leave backspace on the intended word',
      expectedVisibleText: 'echo th world',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'echo th world',
      expectedSelectionOffset: 9,
      expectedTerminalCursorOffset: 'echo th'.length,
      steps: [
        ('${_deleteDetectionMarker}echo teh world', 16, 16, null),
        ('${_deleteDetectionMarker}echo teh world', 7, 10, null),
        ('${_deleteDetectionMarker}echo the world', 7, 10, null),
        ('${_deleteDetectionMarker}echo then world', 7, 11, null),
        ('${_deleteDetectionMarker}echo the world', 7, 10, null),
        ('${_deleteDetectionMarker}echo th world', 9, 9, null),
      ],
    ),
    _ValidationCase(
      id: '20-replace-move-later-backspace',
      title:
          'Replacing one word then backspacing later elsewhere keeps the later caret anchored',
      expectedVisibleText: 'echo the worl',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'echo the worl',
      expectedSelectionOffset: 15,
      expectedTerminalCursorOffset: 'echo the worl'.length,
      steps: [
        ('${_deleteDetectionMarker}echo teh world', 16, 16, null),
        ('${_deleteDetectionMarker}echo teh world', 11, 11, null),
        ('${_deleteDetectionMarker}echo the world', 11, 11, null),
        ('${_deleteDetectionMarker}echo the world', 16, 16, null),
        ('${_deleteDetectionMarker}echo the worl', 15, 15, null),
      ],
    ),
    _ValidationCase(
      id: '21-replacement-separator-reinsert',
      title:
          'Deleting and reinserting the replacement separator restores the intended spacing without drift',
      expectedVisibleText: 'echo the world',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'echo the world',
      expectedSelectionOffset: 11,
      expectedTerminalCursorOffset: 'echo the '.length,
      steps: [
        ('${_deleteDetectionMarker}echo teh world', 16, 16, null),
        ('${_deleteDetectionMarker}echo teh world', 7, 11, null),
        ('${_deleteDetectionMarker}echo the world', 11, 11, null),
        ('${_deleteDetectionMarker}echo theworld', 10, 10, null),
        ('${_deleteDetectionMarker}echo the world', 11, 11, null),
      ],
    ),
    _ValidationCase(
      id: '22-replace-elsewhere',
      title:
          'Replacing one word and then replacing a later word keeps both edits anchored',
      expectedVisibleText: 'echo the earth',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'echo the earth',
      expectedSelectionOffset: 16,
      expectedTerminalCursorOffset: 'echo the earth'.length,
      steps: [
        ('${_deleteDetectionMarker}echo teh world', 16, 16, null),
        ('${_deleteDetectionMarker}echo teh world', 11, 11, null),
        ('${_deleteDetectionMarker}echo the world', 11, 11, null),
        ('${_deleteDetectionMarker}echo the world', 11, 16, null),
        ('${_deleteDetectionMarker}echo the earth', 16, 16, null),
      ],
    ),
    _ValidationCase(
      id: '23-shorter-prefix-replacement',
      title:
          'Backspacing to a shorter prefix before choosing a replacement keeps the replacement text ordered correctly',
      expectedVisibleText: 'I stink',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'I stink',
      expectedSelectionOffset: 9,
      expectedTerminalCursorOffset: 'I stink'.length,
      steps: [
        ('${_deleteDetectionMarker}I still have', 14, 14, null),
        ('${_deleteDetectionMarker}I sti', 7, 7, null),
        ('${_deleteDetectionMarker}I stink', 4, 9, null),
        ('${_deleteDetectionMarker}I stink', 9, 9, null),
      ],
    ),
  ];

  testWidgets('runs the terminal text input validation matrix', (tester) async {
    final results = <_ValidationResult>[];
    for (final testCase in cases) {
      results.add(await _runCase(tester, testCase));
    }

    await tester.pumpWidget(_SummaryScreen(results: results));
    await tester.pumpAndSettle();
    final holdValidationSummaryDuration = _holdValidationSummaryDuration();
    if (holdValidationSummaryDuration != null) {
      await Future.delayed(holdValidationSummaryDuration);
    }

    final failures = results.where((result) => !result.passed).toList();
    expect(
      failures,
      isEmpty,
      reason: failures
          .map(
            (result) =>
                '${result.testCase.id}: expected raw '
                '${result.testCase.expectedRawOutput ?? '(n/a)'}, '
                'actual raw ${result.rawOutput}, expected visible '
                '${result.testCase.expectedVisibleText}, actual visible '
                '${result.visibleText}, expected terminal cursor '
                '${result.testCase.expectedTerminalCursorOffset?.toString() ?? '(n/a)'}, '
                'actual terminal cursor ${result.terminalCursorOffset}',
          )
          .join('\n'),
    );
  });
}

String _resolveTerminalTextWithoutTrailingSpace() => 'echo ready';

String _resolveTerminalTextWithTrailingSpace() => 'echo ready ';
