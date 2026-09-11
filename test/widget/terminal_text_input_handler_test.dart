// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/auto_connect_command.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';
import 'package:monkeyssh/presentation/widgets/keyboard_toolbar.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_input_handler.dart';
import 'package:xterm/xterm.dart';

import '../helpers/terminal_input_harness.dart';
import '../helpers/terminal_input_helpers.dart';
import '../helpers/terminal_input_scenarios.dart';

const _deleteDetectionMarker = '\u200B\u200B';
const _terminalShiftEnterNewlineInput = '\n';

typedef _LoggedEditingState = ({
  String text,
  int selectionBase,
  int selectionExtent,
  int composingBase,
  int composingExtent,
});

typedef _ComparisonResult = ({
  _LoggedEditingState finalState,
  List<_LoggedEditingState> echoedStates,
});

typedef _MatrixScenario = ({
  String name,
  List<TextEditingValue> sequence,
  int? textFieldEchoes,
  int? terminalEchoes,
});

typedef _SegmentSeed = ({
  String name,
  String before,
  String middle,
  String after,
});

typedef _ResetSeed = ({
  String name,
  String resolveTextBeforeCursor,
  bool trimsAfterSuggestionReset,
});

typedef _ResetScenario = ({
  String name,
  _ResetTrigger trigger,
  String resolveTextBeforeCursor,
  bool shouldTrim,
});

enum _ResetTrigger {
  trailingBackspace,
  newlineAction,
  newlineText,
  controllerClear,
  markerLoss,
}

TextEditingValue _userValue(
  String text, {
  required int selectionBase,
  int? selectionExtent,
  TextRange composing = TextRange.empty,
}) => TextEditingValue(
  text: text,
  selection: selectionExtent == null
      ? TextSelection.collapsed(offset: selectionBase)
      : TextSelection(baseOffset: selectionBase, extentOffset: selectionExtent),
  composing: composing,
);

String _dropLastGrapheme(String text) {
  final graphemes = text.characters.toList(growable: false);
  if (graphemes.isEmpty) {
    return text;
  }
  return graphemes.sublist(0, graphemes.length - 1).join();
}

_MatrixScenario _insertBeforeMiddleScenario(_SegmentSeed seed) {
  final initial = '${seed.before}${seed.middle}${seed.after}';
  final insertionOffset = seed.before.length;
  final updated = '${seed.before}X${seed.middle}${seed.after}';
  return (
    name: '${seed.name}: inserts before the edited segment',
    sequence: [
      _userValue(initial, selectionBase: initial.length),
      _userValue(initial, selectionBase: insertionOffset),
      _userValue(updated, selectionBase: insertionOffset + 1),
    ],
    textFieldEchoes: null,
    terminalEchoes: null,
  );
}

_MatrixScenario _insertAfterMiddleScenario(_SegmentSeed seed) {
  final initial = '${seed.before}${seed.middle}${seed.after}';
  final insertionOffset = '${seed.before}${seed.middle}'.length;
  final updated = '${seed.before}${seed.middle};${seed.after}';
  return (
    name: '${seed.name}: inserts after the edited segment',
    sequence: [
      _userValue(initial, selectionBase: initial.length),
      _userValue(initial, selectionBase: insertionOffset),
      _userValue(updated, selectionBase: insertionOffset + 1),
    ],
    textFieldEchoes: null,
    terminalEchoes: null,
  );
}

_MatrixScenario _replaceMiddleScenario(_SegmentSeed seed) {
  final initial = '${seed.before}${seed.middle}${seed.after}';
  final selectionBase = seed.before.length;
  final selectionExtent = selectionBase + seed.middle.length;
  final updated = '${seed.before}ZX${seed.after}';
  return (
    name: '${seed.name}: replaces the edited segment',
    sequence: [
      _userValue(initial, selectionBase: initial.length),
      _userValue(
        initial,
        selectionBase: selectionBase,
        selectionExtent: selectionExtent,
      ),
      _userValue(updated, selectionBase: selectionBase + 2),
    ],
    textFieldEchoes: null,
    terminalEchoes: null,
  );
}

_MatrixScenario _backspaceWithinMiddleScenario(_SegmentSeed seed) {
  final initial = '${seed.before}${seed.middle}${seed.after}';
  final shortenedMiddle = _dropLastGrapheme(seed.middle);
  final caretOffset = '${seed.before}${seed.middle}'.length;
  final updated = '${seed.before}$shortenedMiddle${seed.after}';
  return (
    name: '${seed.name}: backspaces within the edited segment',
    sequence: [
      _userValue(initial, selectionBase: initial.length),
      _userValue(initial, selectionBase: caretOffset),
      _userValue(
        updated,
        selectionBase: '${seed.before}$shortenedMiddle'.length,
      ),
    ],
    textFieldEchoes: null,
    terminalEchoes: null,
  );
}

_MatrixScenario _deleteMiddleSelectionScenario(_SegmentSeed seed) {
  final initial = '${seed.before}${seed.middle}${seed.after}';
  final selectionBase = seed.before.length;
  final selectionExtent = selectionBase + seed.middle.length;
  final updated = '${seed.before}${seed.after}';
  return (
    name: '${seed.name}: deletes the edited segment selection',
    sequence: [
      _userValue(initial, selectionBase: initial.length),
      _userValue(
        initial,
        selectionBase: selectionBase,
        selectionExtent: selectionExtent,
      ),
      _userValue(updated, selectionBase: selectionBase),
    ],
    textFieldEchoes: null,
    terminalEchoes: null,
  );
}

List<_MatrixScenario> _buildGeneratedComparisonScenarios() {
  const seeds = <_SegmentSeed>[
    (name: 'plain-word', before: 'he', middle: 'll', after: 'o there'),
    (name: 'space-separated', before: 'foo ', middle: 'ba', after: 'r baz'),
    (name: 'punctuation', before: 'hello, ', middle: 'wo', after: 'rld!'),
    (name: 'repeated-token', before: 'aa', middle: 'aa', after: ' aa'),
    (name: 'emoji-boundary', before: 'go ', middle: '👩🏽‍💻', after: ' now'),
    (name: 'path-fragment', before: '/usr/', middle: 'lo', after: 'cal/bin'),
    (name: 'number-fragment', before: '12', middle: '34', after: '56-78'),
    (name: 'hyphenated', before: 'shell-', middle: 'hi', after: 'story.txt'),
    (name: 'apostrophe', before: 'did', middle: 'n\'t', after: ' panic'),
    (name: 'command-subst', before: 'echo ', middle: r'$(pwd)', after: ' done'),
    (name: 'tab-separated', before: 'foo\t', middle: 'bar', after: '\tbaz'),
    (name: 'snake-case', before: 'snake_', middle: 'ca', after: 'se_value'),
    (name: 'bracketed', before: '[', middle: 'item', after: '] list'),
    (name: 'quoted', before: '"', middle: 'hello', after: '" world'),
    (name: 'pipe-chain', before: 'ls | ', middle: 'gr', after: 'ep ssh'),
    (name: 'git-ref', before: 'feature/', middle: 'ime', after: '-fix'),
    (name: 'ipv6-ish', before: 'fe80::', middle: '1', after: 'ff:fe23'),
    (name: 'env-var', before: r'$HO', middle: 'ME', after: '/bin'),
    (name: 'semicolon', before: 'echo ', middle: 'hi', after: '; pwd'),
    (name: 'mixed-symbols', before: 'x=', middle: '42', after: '; y=7'),
  ];

  return [
    for (final seed in seeds) ...[
      _insertBeforeMiddleScenario(seed),
      _insertAfterMiddleScenario(seed),
      _replaceMiddleScenario(seed),
      _backspaceWithinMiddleScenario(seed),
      _deleteMiddleSelectionScenario(seed),
    ],
  ];
}

List<_MatrixScenario> _buildGptComparisonScenarios() {
  const seeds = <_SegmentSeed>[
    (name: 'leading-indent', before: '  ', middle: 'he', after: 'llo world'),
    (name: 'double-space', before: 'foo  ', middle: 'ba', after: 'r baz'),
    (name: 'cjk-plain', before: '你', middle: '好', after: '世界'),
    (name: 'accented-latin', before: 'na', middle: 'ï', after: 've test'),
    (name: 'quoted-arg', before: 'echo "', middle: 'hi', after: '" now'),
    (name: 'brace-expansion', before: '{a,', middle: 'b', after: ',c}'),
    (name: 'windows-path', before: r'C:\', middle: 'Us', after: r'ers\me'),
    (name: 'env-braces', before: r'${', middle: 'HO', after: 'ME}'),
    (name: 'and-chain', before: 'cmd && ', middle: 'ec', after: 'ho'),
    (name: 'comment-fragment', before: '# ', middle: 'to', after: 'do item'),
    (name: 'ssh-config', before: 'Host ', middle: 'my', after: '-box'),
    (name: 'url-like', before: 'https://', middle: 'ex', after: '.am/path'),
    (name: 'csv-fragment', before: 'a,', middle: 'b', after: ',c,d'),
    (name: 'leading-tab', before: '\t', middle: 'cm', after: 'd --help'),
    (name: 'mid-spaces', before: 'cmd', middle: '  ', after: 'arg'),
    (name: 'spanish-tilde', before: 'mañ', middle: 'an', after: 'a mode'),
    (name: 'pipe-reader', before: 'cat ', middle: 'fi', after: 'le | less'),
    (name: 'env-equals', before: 'KEY=', middle: 'va', after: 'lue'),
    (name: 'paren-spaced', before: '( ', middle: 'ab', after: ' ) tail'),
    (name: 'digits-dots', before: '1.', middle: '2', after: '.3.4'),
  ];

  return [
    for (final seed in seeds) ...[
      (
        name: 'gpt-derived ${_insertBeforeMiddleScenario(seed).name}',
        sequence: _insertBeforeMiddleScenario(seed).sequence,
        textFieldEchoes: null,
        terminalEchoes: null,
      ),
      (
        name: 'gpt-derived ${_insertAfterMiddleScenario(seed).name}',
        sequence: _insertAfterMiddleScenario(seed).sequence,
        textFieldEchoes: null,
        terminalEchoes: null,
      ),
      (
        name: 'gpt-derived ${_replaceMiddleScenario(seed).name}',
        sequence: _replaceMiddleScenario(seed).sequence,
        textFieldEchoes: null,
        terminalEchoes: null,
      ),
      (
        name: 'gpt-derived ${_backspaceWithinMiddleScenario(seed).name}',
        sequence: _backspaceWithinMiddleScenario(seed).sequence,
        textFieldEchoes: null,
        terminalEchoes: null,
      ),
      (
        name: 'gpt-derived ${_deleteMiddleSelectionScenario(seed).name}',
        sequence: _deleteMiddleSelectionScenario(seed).sequence,
        textFieldEchoes: null,
        terminalEchoes: null,
      ),
    ],
  ];
}

List<_MatrixScenario> _buildFlutterReplacedParityScenarios() {
  const testText = 'From a false proposition, anything follows.';
  final cases =
      <
        ({
          String name,
          TextEditingValue initialValue,
          TextRange replacementRange,
          String replacementText,
        })
      >[
        (
          name: 'selection deletion',
          initialValue: const TextEditingValue(
            text: testText,
            selection: TextSelection(baseOffset: 5, extentOffset: 13),
          ),
          replacementRange: const TextSelection(
            baseOffset: 5,
            extentOffset: 13,
          ),
          replacementText: '',
        ),
        (
          name: 'reversed selection deletion',
          initialValue: const TextEditingValue(
            text: testText,
            selection: TextSelection(baseOffset: 13, extentOffset: 5),
          ),
          replacementRange: const TextSelection(
            baseOffset: 13,
            extentOffset: 5,
          ),
          replacementText: '',
        ),
        (
          name: 'insert',
          initialValue: const TextEditingValue(
            text: testText,
            selection: TextSelection.collapsed(offset: 5),
          ),
          replacementRange: const TextSelection.collapsed(offset: 5),
          replacementText: 'AA',
        ),
        (
          name: 'replace before selection',
          initialValue: const TextEditingValue(
            text: testText,
            selection: TextSelection(baseOffset: 13, extentOffset: 5),
          ),
          replacementRange: const TextRange(start: 4, end: 5),
          replacementText: 'AA',
        ),
        (
          name: 'replace after selection',
          initialValue: const TextEditingValue(
            text: testText,
            selection: TextSelection(baseOffset: 13, extentOffset: 5),
          ),
          replacementRange: const TextRange(start: 13, end: 14),
          replacementText: 'AA',
        ),
        (
          name: 'replace inside selection - start boundary',
          initialValue: const TextEditingValue(
            text: testText,
            selection: TextSelection(baseOffset: 13, extentOffset: 5),
          ),
          replacementRange: const TextRange(start: 5, end: 6),
          replacementText: 'AA',
        ),
        (
          name: 'replace inside selection - end boundary',
          initialValue: const TextEditingValue(
            text: testText,
            selection: TextSelection(baseOffset: 13, extentOffset: 5),
          ),
          replacementRange: const TextRange(start: 12, end: 13),
          replacementText: 'AA',
        ),
        (
          name: 'delete after selection',
          initialValue: const TextEditingValue(
            text: testText,
            selection: TextSelection(baseOffset: 13, extentOffset: 5),
          ),
          replacementRange: const TextRange(start: 13, end: 14),
          replacementText: '',
        ),
        (
          name: 'delete inside selection - start boundary',
          initialValue: const TextEditingValue(
            text: testText,
            selection: TextSelection(baseOffset: 13, extentOffset: 5),
          ),
          replacementRange: const TextRange(start: 5, end: 6),
          replacementText: '',
        ),
        (
          name: 'delete inside selection - end boundary',
          initialValue: const TextEditingValue(
            text: testText,
            selection: TextSelection(baseOffset: 13, extentOffset: 5),
          ),
          replacementRange: const TextRange(start: 12, end: 13),
          replacementText: '',
        ),
      ];

  return [
    for (final scenario in cases)
      (
        name: 'flutter TextEditingValue.replaced ${scenario.name}',
        sequence: [
          scenario.initialValue,
          scenario.initialValue.replaced(
            scenario.replacementRange,
            scenario.replacementText,
          ),
        ],
        textFieldEchoes: null,
        terminalEchoes: null,
      ),
  ];
}

List<_MatrixScenario> _buildFlutterDeltaParityScenarios() {
  final cases =
      <({String name, TextEditingValue initialValue, TextEditingDelta delta})>[
        (
          name: 'insertion at a collapsed selection',
          initialValue: TextEditingValue.empty,
          delta: const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: 'let there be text',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 17),
            composing: TextRange.empty,
          ),
        ),
        (
          name: 'insertion at end of composing region',
          initialValue: const TextEditingValue(
            text: 'hello worl',
            selection: TextSelection.collapsed(offset: 10),
          ),
          delta: const TextEditingDeltaInsertion(
            oldText: 'hello worl',
            textInserted: 'd',
            insertionOffset: 10,
            selection: TextSelection.collapsed(offset: 11),
            composing: TextRange(start: 6, end: 11),
          ),
        ),
        (
          name: 'deletion at end of composing region',
          initialValue: const TextEditingValue(
            text: 'hello world',
            selection: TextSelection.collapsed(offset: 11),
          ),
          delta: const TextEditingDeltaDeletion(
            oldText: 'hello world',
            deletedRange: TextRange(start: 10, end: 11),
            selection: TextSelection.collapsed(offset: 10),
            composing: TextRange(start: 6, end: 10),
          ),
        ),
        (
          name: 'replacement with longer text',
          initialValue: const TextEditingValue(
            text: 'hello worfi',
            selection: TextSelection.collapsed(offset: 11),
          ),
          delta: const TextEditingDeltaReplacement(
            oldText: 'hello worfi',
            replacementText: 'working',
            replacedRange: TextRange(start: 6, end: 11),
            selection: TextSelection.collapsed(offset: 13),
            composing: TextRange(start: 6, end: 13),
          ),
        ),
        (
          name: 'replacement with shorter text',
          initialValue: const TextEditingValue(
            text: 'hello world',
            selection: TextSelection.collapsed(offset: 11),
          ),
          delta: const TextEditingDeltaReplacement(
            oldText: 'hello world',
            replacementText: 'h',
            replacedRange: TextRange(start: 6, end: 11),
            selection: TextSelection.collapsed(offset: 7),
            composing: TextRange(start: 6, end: 7),
          ),
        ),
        (
          name: 'replacement with same-length text',
          initialValue: const TextEditingValue(
            text: 'hello world',
            selection: TextSelection.collapsed(offset: 11),
          ),
          delta: const TextEditingDeltaReplacement(
            oldText: 'hello world',
            replacementText: 'words',
            replacedRange: TextRange(start: 6, end: 11),
            selection: TextSelection.collapsed(offset: 11),
            composing: TextRange(start: 6, end: 11),
          ),
        ),
        (
          name: 'non-text selection/composing update',
          initialValue: const TextEditingValue(
            text: 'hello world',
            selection: TextSelection.collapsed(offset: 11),
          ),
          delta: const TextEditingDeltaNonTextUpdate(
            oldText: 'hello world',
            selection: TextSelection.collapsed(offset: 10),
            composing: TextRange(start: 6, end: 11),
          ),
        ),
      ];

  return [
    for (final scenario in cases)
      (
        name: 'flutter TextEditingDelta ${scenario.name}',
        sequence: [
          scenario.initialValue,
          scenario.delta.apply(scenario.initialValue),
        ],
        textFieldEchoes: null,
        terminalEchoes: null,
      ),
  ];
}

List<_MatrixScenario> _buildFlutterComposingParityScenarios() {
  const baseValue = TextEditingValue(
    text: 'foo composing bar',
    selection: TextSelection.collapsed(offset: 4),
    composing: TextRange(start: 4, end: 12),
  );

  return [
    (
      name:
          'flutter EditableText preserves composing range when a collapsed caret moves within it',
      sequence: const [
        baseValue,
        TextEditingValue(
          text: 'foo composing bar',
          selection: TextSelection.collapsed(offset: 5),
          composing: TextRange(start: 4, end: 12),
        ),
      ],
      textFieldEchoes: null,
      terminalEchoes: null,
    ),
    (
      name:
          'flutter EditableText clears composing range when a collapsed caret moves before it',
      sequence: const [
        baseValue,
        TextEditingValue(
          text: 'foo composing bar',
          selection: TextSelection.collapsed(offset: 2),
        ),
      ],
      textFieldEchoes: null,
      terminalEchoes: null,
    ),
    (
      name:
          'flutter EditableText clears composing range when a collapsed caret moves after it',
      sequence: const [
        baseValue,
        TextEditingValue(
          text: 'foo composing bar',
          selection: TextSelection.collapsed(offset: 14),
        ),
      ],
      textFieldEchoes: null,
      terminalEchoes: null,
    ),
    (
      name:
          'flutter EditableText clears composing range when a selection moves before it',
      sequence: const [
        baseValue,
        TextEditingValue(
          text: 'foo composing bar',
          selection: TextSelection(baseOffset: 1, extentOffset: 2),
        ),
      ],
      textFieldEchoes: null,
      terminalEchoes: null,
    ),
    (
      name:
          'flutter EditableText preserves composing range when a selection stays within it',
      sequence: const [
        baseValue,
        TextEditingValue(
          text: 'foo composing bar',
          selection: TextSelection(baseOffset: 5, extentOffset: 7),
          composing: TextRange(start: 4, end: 12),
        ),
      ],
      textFieldEchoes: null,
      terminalEchoes: null,
    ),
    (
      name:
          'flutter EditableText clears composing range when a selection moves after it',
      sequence: const [
        baseValue,
        TextEditingValue(
          text: 'foo composing bar',
          selection: TextSelection(baseOffset: 13, extentOffset: 15),
        ),
      ],
      textFieldEchoes: null,
      terminalEchoes: null,
    ),
  ];
}

List<_ResetScenario> _buildOpusResetScenarios() {
  const seeds = <_ResetSeed>[
    (
      name: 'empty-context',
      resolveTextBeforeCursor: '',
      trimsAfterSuggestionReset: true,
    ),
    (
      name: 'single-space-context',
      resolveTextBeforeCursor: ' ',
      trimsAfterSuggestionReset: true,
    ),
    (
      name: 'tab-context',
      resolveTextBeforeCursor: '\t',
      trimsAfterSuggestionReset: true,
    ),
    (
      name: 'newline-context',
      resolveTextBeforeCursor: '\n',
      trimsAfterSuggestionReset: true,
    ),
    (
      name: 'carriage-context',
      resolveTextBeforeCursor: '\r',
      trimsAfterSuggestionReset: true,
    ),
    (
      name: 'prompt-space-context',
      resolveTextBeforeCursor: r'$ ',
      trimsAfterSuggestionReset: true,
    ),
    (
      name: 'prompt-marker-context',
      resolveTextBeforeCursor: '>',
      trimsAfterSuggestionReset: true,
    ),
    (
      name: 'command-space-context',
      resolveTextBeforeCursor: 'echo ready ',
      trimsAfterSuggestionReset: true,
    ),
    (
      name: 'command-tab-context',
      resolveTextBeforeCursor: 'echo ready\t',
      trimsAfterSuggestionReset: true,
    ),
    (
      name: 'command-newline-context',
      resolveTextBeforeCursor: 'echo ready\n',
      trimsAfterSuggestionReset: true,
    ),
    (
      name: 'double-space-context',
      resolveTextBeforeCursor: 'echo ready  ',
      trimsAfterSuggestionReset: true,
    ),
    (
      name: 'plain-command-context',
      resolveTextBeforeCursor: 'echo',
      trimsAfterSuggestionReset: false,
    ),
    (
      name: 'paren-context',
      resolveTextBeforeCursor: 'echo(',
      trimsAfterSuggestionReset: false,
    ),
    (
      name: 'emoji-context',
      resolveTextBeforeCursor: 'say 😀',
      trimsAfterSuggestionReset: false,
    ),
    (
      name: 'quoted-context',
      resolveTextBeforeCursor: '"quoted',
      trimsAfterSuggestionReset: false,
    ),
    (
      name: 'path-context',
      resolveTextBeforeCursor: '/usr/local',
      trimsAfterSuggestionReset: false,
    ),
    (
      name: 'assignment-context',
      resolveTextBeforeCursor: 'KEY=value',
      trimsAfterSuggestionReset: false,
    ),
    (
      name: 'semicolon-context',
      resolveTextBeforeCursor: 'echo;',
      trimsAfterSuggestionReset: false,
    ),
    (
      name: 'bracket-context',
      resolveTextBeforeCursor: 'list]',
      trimsAfterSuggestionReset: false,
    ),
    (
      name: 'hyphen-context',
      resolveTextBeforeCursor: 'git-status',
      trimsAfterSuggestionReset: false,
    ),
    (
      name: 'ipv6-context',
      resolveTextBeforeCursor: 'fe80::1',
      trimsAfterSuggestionReset: false,
    ),
  ];

  return [
    for (final seed in seeds)
      for (final trigger in _ResetTrigger.values)
        (
          name:
              'opus-derived ${trigger.name} ${trigger == _ResetTrigger.markerLoss || seed.trimsAfterSuggestionReset ? 'trims' : 'preserves'} leading suggestion spacing for ${seed.name}',
          trigger: trigger,
          resolveTextBeforeCursor: seed.resolveTextBeforeCursor,
          shouldTrim:
              trigger == _ResetTrigger.markerLoss ||
              seed.trimsAfterSuggestionReset,
        ),
  ];
}

Future<void> _applyResetTrigger(
  WidgetTester tester,
  TerminalInputHarness harness,
  _ResetTrigger trigger, {
  required String initialText,
}) async {
  switch (trigger) {
    case _ResetTrigger.trailingBackspace:
      final shortenedText = _dropLastGrapheme(initialText);
      tester.testTextInput.updateEditingValue(
        _editingValue(shortenedText, selectionOffset: shortenedText.length),
      );
      await tester.pump();
      break;
    case _ResetTrigger.newlineAction:
      _terminalTextInputClient(tester).performAction(TextInputAction.newline);
      await tester.pump();
      break;
    case _ResetTrigger.newlineText:
      final textWithNewline = '$initialText\n';
      tester.testTextInput.updateEditingValue(
        _editingValue(textWithNewline, selectionOffset: textWithNewline.length),
      );
      await tester.pump();
      break;
    case _ResetTrigger.controllerClear:
      harness.controller.clearImeBuffer();
      await tester.pump();
      break;
    case _ResetTrigger.markerLoss:
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      await tester.pump();
      break;
  }
}

Future<void> _expectResetContinuationScenario(
  WidgetTester tester,
  _ResetScenario scenario,
) async {
  const initialText = 'alpha';
  const followUpText = ' beta';
  final harness = await pumpTerminalInputHarness(
    tester,
    resolveTextBeforeCursor: () => scenario.resolveTextBeforeCursor,
  );

  tester.testTextInput.updateEditingValue(
    _editingValue(initialText, selectionOffset: initialText.length),
  );
  await tester.pump();

  harness.terminalOutput.clear();
  tester.testTextInput.log.clear();

  await _applyResetTrigger(
    tester,
    harness,
    scenario.trigger,
    initialText: initialText,
  );

  harness.terminalOutput.clear();
  tester.testTextInput.log.clear();

  tester.testTextInput.updateEditingValue(
    _editingValue(followUpText, selectionOffset: followUpText.length),
  );
  await tester.pump();

  expect(
    terminalTextFromEvents(harness.terminalOutput),
    scenario.shouldTrim ? 'beta' : ' beta',
  );

  await disposeTerminalInputHarness(tester, harness);
}

TextEditingValue _editingValue(
  String userText, {
  required int selectionOffset,
  TextRange composing = TextRange.empty,
}) => TextEditingValue(
  text: '$_deleteDetectionMarker$userText',
  selection: TextSelection.collapsed(
    offset: _deleteDetectionMarker.length + selectionOffset,
  ),
  composing: composing == TextRange.empty
      ? TextRange.empty
      : TextRange(
          start: _deleteDetectionMarker.length + composing.start,
          end: _deleteDetectionMarker.length + composing.end,
        ),
);

String _iosBackspaceRunwayPayload(int length) =>
    String.fromCharCodes(List<int>.filled(length, 0x200B));

TextEditingValue _iosBackspaceRunwayValue(int length, {String suffix = ''}) {
  final text =
      '$_deleteDetectionMarker${_iosBackspaceRunwayPayload(length)}'
      '$suffix';
  return TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
  );
}

TextEditingValue _iosBackspaceRunwayComposingValue(
  int length, {
  required String suffix,
}) {
  final runway = _iosBackspaceRunwayPayload(length);
  final text = '$_deleteDetectionMarker$runway$suffix';
  final suffixStart = _deleteDetectionMarker.length + runway.length;
  return TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
    composing: TextRange(start: suffixStart, end: text.length),
  );
}

String _terminalKeyOutput(
  TerminalKey key, {
  bool shift = false,
  bool alt = false,
  bool ctrl = false,
}) {
  final output = <String>[];
  Terminal(
    onOutput: output.add,
  ).keyInput(key, shift: shift, alt: alt, ctrl: ctrl);
  return output.join();
}

int _normalizeOffsetToUserSpace(int offset, int prefixLength, int maxLength) {
  if (offset < 0) {
    return offset;
  }
  final normalized = offset - prefixLength;
  if (normalized < 0) {
    return 0;
  }
  if (normalized > maxLength) {
    return maxLength;
  }
  return normalized;
}

_LoggedEditingState _loggedStateFromTextEditingValue(TextEditingValue value) =>
    (
      text: value.text,
      selectionBase: value.selection.baseOffset,
      selectionExtent: value.selection.extentOffset,
      composingBase: value.composing.start,
      composingExtent: value.composing.end,
    );

TextEditingValue _terminalEditingValueFromUserValue(TextEditingValue value) {
  const prefixLength = _deleteDetectionMarker.length;
  final selection = value.selection.isValid
      ? TextSelection(
          baseOffset: prefixLength + value.selection.baseOffset,
          extentOffset: prefixLength + value.selection.extentOffset,
          affinity: value.selection.affinity,
          isDirectional: value.selection.isDirectional,
        )
      : value.selection;
  final composing = value.composing.isValid && !value.composing.isCollapsed
      ? TextRange(
          start: prefixLength + value.composing.start,
          end: prefixLength + value.composing.end,
        )
      : value.composing;
  return TextEditingValue(
    text: '$_deleteDetectionMarker${value.text}',
    selection: selection,
    composing: composing,
  );
}

_LoggedEditingState _loggedStateFromSetEditingStateCall(
  MethodCall call, {
  bool stripTerminalMarker = false,
}) {
  final arguments = call.arguments as Map<dynamic, dynamic>;
  var text = arguments['text'] as String? ?? '';
  var selectionBase = arguments['selectionBase'] as int? ?? -1;
  var selectionExtent = arguments['selectionExtent'] as int? ?? -1;
  var composingBase = arguments['composingBase'] as int? ?? -1;
  var composingExtent = arguments['composingExtent'] as int? ?? -1;

  if (stripTerminalMarker && text.startsWith(_deleteDetectionMarker)) {
    const prefixLength = _deleteDetectionMarker.length;
    text = text.substring(prefixLength);
    selectionBase = _normalizeOffsetToUserSpace(
      selectionBase,
      prefixLength,
      text.length,
    );
    selectionExtent = _normalizeOffsetToUserSpace(
      selectionExtent,
      prefixLength,
      text.length,
    );
    if (composingBase >= 0) {
      composingBase = _normalizeOffsetToUserSpace(
        composingBase,
        prefixLength,
        text.length,
      );
      composingExtent = _normalizeOffsetToUserSpace(
        composingExtent,
        prefixLength,
        text.length,
      );
    }
  }

  return (
    text: text,
    selectionBase: selectionBase,
    selectionExtent: selectionExtent,
    composingBase: composingBase,
    composingExtent: composingExtent,
  );
}

List<_LoggedEditingState> _setEditingStateStates(
  Iterable<MethodCall> log, {
  bool stripTerminalMarker = false,
}) => log
    .where((call) => call.method == 'TextInput.setEditingState')
    .map(
      (call) => _loggedStateFromSetEditingStateCall(
        call,
        stripTerminalMarker: stripTerminalMarker,
      ),
    )
    .toList(growable: false);

_LoggedEditingState _loggedTerminalClientState(TextEditingValue value) {
  const prefixLength = _deleteDetectionMarker.length;
  final text = value.text.startsWith(_deleteDetectionMarker)
      ? value.text.substring(prefixLength)
      : value.text;
  return (
    text: text,
    selectionBase: _normalizeOffsetToUserSpace(
      value.selection.baseOffset,
      prefixLength,
      text.length,
    ),
    selectionExtent: _normalizeOffsetToUserSpace(
      value.selection.extentOffset,
      prefixLength,
      text.length,
    ),
    composingBase: value.composing.isValid && !value.composing.isCollapsed
        ? _normalizeOffsetToUserSpace(
            value.composing.start,
            prefixLength,
            text.length,
          )
        : -1,
    composingExtent: value.composing.isValid && !value.composing.isCollapsed
        ? _normalizeOffsetToUserSpace(
            value.composing.end,
            prefixLength,
            text.length,
          )
        : -1,
  );
}

Future<_ComparisonResult> _runTextFieldSequence(
  WidgetTester tester,
  List<TextEditingValue> userValues,
) async {
  final controller = TextEditingController();
  final focusNode = FocusNode();

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TextField(controller: controller, focusNode: focusNode),
      ),
    ),
  );

  focusNode.requestFocus();
  await tester.pump();
  tester.testTextInput.log.clear();

  for (final value in userValues) {
    tester.testTextInput.updateEditingValue(value);
    await tester.pump();
  }

  final result = (
    finalState: _loggedStateFromTextEditingValue(controller.value),
    echoedStates: _setEditingStateStates(tester.testTextInput.log),
  );

  await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
  await tester.pump();
  controller.dispose();
  focusNode.dispose();
  return result;
}

Future<_ComparisonResult> _runTerminalSequence(
  WidgetTester tester,
  List<TextEditingValue> userValues,
) async {
  final terminal = Terminal();
  final focusNode = FocusNode();

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TerminalTextInputHandler(
          terminal: terminal,
          focusNode: focusNode,
          deleteDetection: true,
          manageFocus: false,
          child: Focus(focusNode: focusNode, child: const SizedBox.expand()),
        ),
      ),
    ),
  );

  focusNode.requestFocus();
  await tester.pump();
  tester.testTextInput.log.clear();

  for (final value in userValues) {
    tester.testTextInput.updateEditingValue(
      _terminalEditingValueFromUserValue(value),
    );
    await tester.pump();
  }

  final client =
      tester.state(find.byType(TerminalTextInputHandler)) as TextInputClient;
  final result = (
    finalState: _loggedTerminalClientState(client.currentTextEditingValue!),
    echoedStates: _setEditingStateStates(
      tester.testTextInput.log,
      stripTerminalMarker: true,
    ),
  );

  await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
  await tester.pump();
  focusNode.dispose();
  return result;
}

Future<void> _expectTextFieldComparisonScenario(
  WidgetTester tester, {
  required List<TextEditingValue> sequence,
  int? expectedTextFieldEchoCount = 0,
  int? expectedTerminalEchoCount,
}) async {
  final textFieldResult = await _runTextFieldSequence(tester, sequence);
  final terminalResult = await _runTerminalSequence(tester, sequence);

  expect(terminalResult.finalState, textFieldResult.finalState);
  if (expectedTextFieldEchoCount != null) {
    expect(textFieldResult.echoedStates, hasLength(expectedTextFieldEchoCount));
  }
  if (expectedTerminalEchoCount != null) {
    expect(terminalResult.echoedStates, hasLength(expectedTerminalEchoCount));
  }
}

TextInputClient _terminalTextInputClient(WidgetTester tester) =>
    tester.state(find.byType(TerminalTextInputHandler)) as TextInputClient;

Map<dynamic, dynamic> _textInputConfigurationFromCall(MethodCall call) {
  final arguments = call.arguments;
  if (call.method == 'TextInput.setClient') {
    return (arguments as List<dynamic>)[1]! as Map<dynamic, dynamic>;
  }
  return arguments as Map<dynamic, dynamic>;
}

Map<dynamic, dynamic> _latestTextInputSetClientConfiguration(
  WidgetTester tester,
) {
  final call = tester.testTextInput.log.lastWhere(
    (call) => call.method == 'TextInput.setClient',
  );
  return _textInputConfigurationFromCall(call);
}

void main() {
  test('generated emoji scenarios use UTF-16 selection boundaries', () {
    final scenarios = _buildGeneratedComparisonScenarios().where(
      (scenario) => scenario.name.startsWith('emoji-boundary:'),
    );
    expect(
      [
        for (final scenario in scenarios)
          [
            for (final value in scenario.sequence)
              (value.selection.baseOffset, value.selection.extentOffset),
          ],
      ],
      [
        [(14, 14), (3, 3), (4, 4)],
        [(14, 14), (10, 10), (11, 11)],
        [(14, 14), (3, 10), (5, 5)],
        [(14, 14), (10, 10), (3, 3)],
        [(14, 14), (3, 10), (3, 3)],
      ],
    );
  });

  group('terminalTextLooksLikeSensitiveInputPrompt', () {
    test('detects common password-like prompts', () {
      const prompts = [
        'Password:',
        '[sudo] password for depoll:',
        'root@example.com\'s password: ',
        'Enter passphrase for key \'/Users/depoll/.ssh/id_ed25519\':',
        'PIN:',
        'Verification code:',
        'One-time password:',
        'Authentication code:',
      ];

      for (final prompt in prompts) {
        expect(
          terminalTextLooksLikeSensitiveInputPrompt(prompt),
          isTrue,
          reason: prompt,
        );
      }
    });

    test('only checks the prompt-like text before the cursor', () {
      expect(
        terminalTextLooksLikeSensitiveInputPrompt(
          'Last login: Sun May 3\n\x1B[31mPassword:\x1B[0m ',
        ),
        isTrue,
      );
      expect(
        terminalTextLooksLikeSensitiveInputPrompt('Password:\n\$ '),
        isFalse,
      );
    });

    test('ignores non-secret password-related output', () {
      const lines = [
        'Password requirements:',
        'Password policy:',
        'Password incorrect:',
        'Password reset:',
        'passwordless login enabled:',
        'Last login:',
        'Enter a username:',
        null,
      ];

      for (final line in lines) {
        expect(
          terminalTextLooksLikeSensitiveInputPrompt(line),
          isFalse,
          reason: '$line',
        );
      }
    });
  });

  group('TerminalTextInputHandler', () {
    testWidgets('disables autocorrect while preserving keyboard suggestions', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(tester);
      final configuration = _latestTextInputSetClientConfiguration(tester);
      final inputType = configuration['inputType']! as Map<dynamic, dynamic>;

      expect(inputType['name'], 'TextInputType.text');
      expect(configuration['autocorrect'], isFalse);
      expect(configuration['enableSuggestions'], isTrue);
      expect(configuration['enableIMEPersonalizedLearning'], isTrue);

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets('uses a password-friendly IME configuration for secrets', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        sensitiveInput: true,
      );
      final configuration = _latestTextInputSetClientConfiguration(tester);
      final inputType = configuration['inputType']! as Map<dynamic, dynamic>;

      expect(inputType['name'], 'TextInputType.text');
      expect(configuration['obscureText'], isTrue);
      expect(configuration['autocorrect'], isFalse);
      expect(configuration['enableSuggestions'], isFalse);
      expect(configuration['enableIMEPersonalizedLearning'], isFalse);

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets('restarts the active IME connection for sensitive input', (
      tester,
    ) async {
      final terminal = Terminal();
      final focusNode = FocusNode();

      Widget buildHarness({required bool sensitiveInput}) => MaterialApp(
        home: Scaffold(
          body: TerminalTextInputHandler(
            terminal: terminal,
            focusNode: focusNode,
            deleteDetection: true,
            sensitiveInput: sensitiveInput,
            child: const SizedBox.expand(),
          ),
        ),
      );

      await tester.pumpWidget(buildHarness(sensitiveInput: false));
      focusNode.requestFocus();
      await tester.pump();

      tester.testTextInput.log.clear();
      await tester.pumpWidget(buildHarness(sensitiveInput: true));
      await tester.pump();

      final configuration = _latestTextInputSetClientConfiguration(tester);
      final inputType = configuration['inputType']! as Map<dynamic, dynamic>;

      expect(
        tester.testTextInput.log.where(
          (call) => call.method == 'TextInput.clearClient',
        ),
        hasLength(1),
      );
      expect(
        tester.testTextInput.log.where(
          (call) => call.method == 'TextInput.updateConfig',
        ),
        isEmpty,
      );
      expect(inputType['name'], 'TextInputType.text');
      expect(configuration['obscureText'], isTrue);
      expect(configuration['enableSuggestions'], isFalse);

      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();
      focusNode.dispose();
    });

    testWidgets('preserves swipe typing context across short pauses', (
      tester,
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
              manageFocus: false,
              child: Focus(
                focusNode: focusNode,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bhello ',
          selection: TextSelection.collapsed(offset: 8),
        ),
      );
      await tester.pump();

      await tester.pump(const Duration(milliseconds: 400));

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bhello world ',
          selection: TextSelection.collapsed(offset: 14),
        ),
      );
      await tester.pump();

      expect(terminalOutput.join(), 'hello world ');

      focusNode.dispose();
    });

    testWidgets('drops a spurious leading newline before first swipe text', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
      );
      final terminalOutput = harness.terminalOutput;

      await commitSwipeText(tester, '$_deleteDetectionMarker\nhello');

      expect(terminalOutput.join(), 'hello');

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets('drops a leading space before first swipe text', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
      );
      final terminalOutput = harness.terminalOutput;

      await commitSwipeText(tester, '$_deleteDetectionMarker hello');

      expect(terminalOutput.join(), 'hello');

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets('drops a leading swipe space after a committed newline', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
      );
      final terminalOutput = harness.terminalOutput;

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Becho hi\n',
          selection: TextSelection.collapsed(offset: 10),
        ),
      );
      await tester.pump();

      await commitSwipeText(tester, '$_deleteDetectionMarker next');

      expect(
        terminalOutput.join(),
        'echo hi${_terminalKeyOutput(TerminalKey.enter)}next',
      );

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'preserves the swipe separator after an input reset when text already exists',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          resolveTextBeforeCursor: () => 'echo ready',
        );
        final terminalOutput = harness.terminalOutput;

        await commitSwipeText(tester, '$_deleteDetectionMarker world');

        expect(terminalTextFromEvents(terminalOutput), ' world');

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'trims a swipe separator after an input reset when the current line is only a prompt marker',
      (tester) async {
        await swipeSeparatorAfterPromptReset(tester);
      },
    );

    testWidgets(
      'external prompt output does not reconnect the IME client before keyboard input',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          resolveTextBeforeCursor: () => '>',
        );
        final controller = harness.controller;

        tester.testTextInput.log.clear();
        controller.handleExternalTerminalOutput();
        await tester.pump();

        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setClient',
          ),
          isEmpty,
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'external prompt output resets IME context for the next fresh swipe '
      'after keyboard input',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          resolveTextBeforeCursor: () => '>',
        );
        final terminalOutput = harness.terminalOutput;
        final controller = harness.controller;

        tester.testTextInput.updateEditingValue(
          _editingValue('echo ready', selectionOffset: 'echo ready'.length),
        );
        await tester.pump();
        await tester.testTextInput.receiveAction(TextInputAction.newline);
        await tester.pump();

        terminalOutput.clear();
        tester.testTextInput.log.clear();
        controller.handleExternalTerminalOutput();
        await tester.pump();

        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          hasLength(greaterThanOrEqualTo(1)),
        );

        await commitSwipeText(tester, '$_deleteDetectionMarker world');

        expect(terminalTextFromEvents(terminalOutput), 'world');

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'trims a duplicate swipe separator after an input reset when text already ends with whitespace',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          resolveTextBeforeCursor: () => 'echo ready ',
        );
        final terminalOutput = harness.terminalOutput;

        await commitSwipeText(tester, '$_deleteDetectionMarker world');

        expect(terminalTextFromEvents(terminalOutput), 'world');

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets('preserves leading spaces for first non-swipe commit', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
      );
      final terminalOutput = harness.terminalOutput;

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200B  hello',
          selection: TextSelection.collapsed(offset: 9),
        ),
      );
      await tester.pump();

      expect(terminalOutput.join(), '  hello');

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets('drops a swipe newline followed by a stray leading space', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
      );
      final terminalOutput = harness.terminalOutput;

      await commitSwipeText(tester, '$_deleteDetectionMarker\n hello');

      expect(terminalOutput.join(), 'hello');

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets('preserves later swipe spaces after trimming first input', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
      );
      final terminalOutput = harness.terminalOutput;

      await commitSwipeText(tester, '$_deleteDetectionMarker hello ');

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bhello world ',
          selection: TextSelection.collapsed(offset: 14),
        ),
      );
      await tester.pump();

      expect(terminalOutput.join(), 'hello world ');

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'preserves a separator after typed input is fully backspaced away',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          resolveTextBeforeCursor: () => 'echo ready',
        );
        final terminalOutput = harness.terminalOutput;

        tester.testTextInput.updateEditingValue(
          _editingValue('tmp', selectionOffset: 'tmp'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('', selectionOffset: 0),
        );
        await tester.pump();

        await commitSwipeText(tester, '$_deleteDetectionMarker hello');

        expect(
          terminalStateFromEvents(
            terminalOutput,
            initialText: 'echo ready',
            initialCursorOffset: 'echo ready'.length,
          ),
          (text: 'echo ready hello', cursorOffset: 'echo ready hello'.length),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'trims a leading swipe space after swipe input is fully backspaced away',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
        );
        final terminalOutput = harness.terminalOutput;

        await commitSwipeText(tester, '$_deleteDetectionMarker hello');

        tester.testTextInput.updateEditingValue(
          _editingValue('', selectionOffset: 0),
        );
        await tester.pump();

        terminalOutput.clear();

        await commitSwipeText(tester, '$_deleteDetectionMarker world');

        expect(terminalTextFromEvents(terminalOutput), 'world');

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'trims a leading suggestion space after input is fully backspaced away',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
        );
        final terminalOutput = harness.terminalOutput;

        await commitSwipeText(tester, '$_deleteDetectionMarker hello');

        tester.testTextInput.updateEditingValue(
          _editingValue('', selectionOffset: 0),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                ' world',
            selection: TextSelection.collapsed(offset: 8),
          ),
        );
        await tester.pump();

        expect(terminalTextFromEvents(terminalOutput), 'world');

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets('resyncs delete-detection marker after backspacing past it', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
      );
      final terminalOutput = harness.terminalOutput;

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bok',
          selection: TextSelection.collapsed(offset: 4),
        ),
      );
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bre',
          selection: TextSelection.collapsed(offset: 4),
        ),
      );
      await tester.pump();

      expect(terminalOutput.join(), 'ok\x7f\x7fre');
      expect(terminalStateFromEvents(terminalOutput), (
        text: 're',
        cursorOffset: 2,
      ));

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'forwards a terminal backspace when delete detection loses the marker with no buffered text',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
        );
        final terminalOutput = harness.terminalOutput;

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B',
            selection: TextSelection.collapsed(offset: 1),
          ),
        );
        await tester.pump();

        expect(
          terminalOutput.join(),
          _terminalKeyOutput(TerminalKey.backspace),
        );
        expect(
          (tester.state(find.byType(TerminalTextInputHandler))
                  as TextInputClient)
              .currentTextEditingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets('clears all buffered text when the IME loses the marker', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
      );
      final terminalOutput = harness.terminalOutput;

      tester.testTextInput.updateEditingValue(
        _editingValue('hello', selectionOffset: 'hello'.length),
      );
      await tester.pump();

      terminalOutput.clear();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(selection: TextSelection.collapsed(offset: 0)),
      );
      await tester.pump();

      expect(
        terminalOutput.join(),
        List.filled(
          'hello'.length,
          _terminalKeyOutput(TerminalKey.backspace),
        ).join(),
      );
      expect(
        terminalStateFromEvents(
          terminalOutput,
          initialText: 'hello',
          initialCursorOffset: 'hello'.length,
        ),
        (text: '', cursorOffset: 0),
      );
      expect(
        (tester.state(find.byType(TerminalTextInputHandler)) as TextInputClient)
            .currentTextEditingValue,
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(offset: 2),
        ),
      );

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets('keeps IME replacement selections intact', (tester) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
      );
      final terminalOutput = harness.terminalOutput;

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bteh ',
          selection: TextSelection.collapsed(offset: 6),
        ),
      );
      await tester.pump();

      expect(terminalTextFromEvents(terminalOutput), 'teh ');

      tester.testTextInput.log.clear();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bthe ',
          selection: TextSelection(baseOffset: 2, extentOffset: 5),
        ),
      );
      await tester.pump();

      expect(terminalTextFromEvents(terminalOutput), 'the ');
      expect(
        tester.testTextInput.log.where(
          (call) => call.method == 'TextInput.setEditingState',
        ),
        isEmpty,
      );

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bthe ',
          selection: TextSelection.collapsed(offset: 6),
        ),
      );
      await tester.pump();

      expect(terminalTextFromEvents(terminalOutput), 'the ');
      expect(
        tester.testTextInput.log.where(
          (call) => call.method == 'TextInput.setEditingState',
        ),
        isEmpty,
      );

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'keeps the tracked cursor aligned after a hardware left arrow before IME insertion',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
        );
        final terminalOutput = harness.terminalOutput;

        tester.testTextInput.updateEditingValue(
          _editingValue('hello', selectionOffset: 'hello'.length),
        );
        await tester.pump();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('hello', selectionOffset: 'hell'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('hellXo', selectionOffset: 'hellX'.length),
        );
        await tester.pump();

        expect(terminalOutput.join(), 'X');
        expect(
          terminalStateFromEvents(
            terminalOutput,
            initialText: 'hello',
            initialCursorOffset: 'hell'.length,
          ),
          (text: 'hellXo', cursorOffset: 'hellX'.length),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'accelerates iOS hardware backspace repeat and suppresses native repeats',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          final harness = await pumpTerminalInputHarness(tester);
          final backspaceOutput = _terminalKeyOutput(TerminalKey.backspace);
          int backspaceCount() => harness.terminalOutput
              .where((value) => value == backspaceOutput)
              .length;

          await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
          await tester.pump();

          expect(backspaceCount(), 1);

          await tester.sendKeyRepeatEvent(LogicalKeyboardKey.backspace);
          await tester.pump();

          expect(backspaceCount(), 1);

          await tester.pump(terminalIosHardwareKeyRepeatStartDelay);

          expect(backspaceCount(), 2);

          await tester.pump(terminalIosHardwareKeyRepeatInterval);

          expect(backspaceCount(), 3);

          await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
          await tester.pump();
          final countAfterKeyUp = backspaceCount();

          await tester.pump(
            Duration(
              milliseconds:
                  terminalIosHardwareKeyRepeatInterval.inMilliseconds * 3,
            ),
          );

          expect(backspaceCount(), countAfterKeyUp);

          await disposeTerminalInputHarness(tester, harness);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      'moves the terminal cursor when the IME caret moves without text changes',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          initialEditingValue: _editingValue(
            'echo teh world',
            selectionOffset: 'echo teh world'.length,
          ),
        );
        final terminalOutput = harness.terminalOutput..clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo teh world', selectionOffset: 'echo teh '.length),
        );
        await tester.pump();

        expect(
          terminalOutput.join(),
          List.filled(5, _terminalKeyOutput(TerminalKey.arrowLeft)).join(),
        );
        expect(
          terminalStateFromEvents(
            terminalOutput,
            initialText: 'echo teh world',
            initialCursorOffset: 'echo teh world'.length,
          ),
          (text: 'echo teh world', cursorOffset: 'echo teh '.length),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'resyncs the IME state when the caret moves within existing text',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          initialEditingValue: _editingValue(
            'echo teh world',
            selectionOffset: 'echo teh world'.length,
          ),
        );
        harness.terminalOutput.clear();
        tester.testTextInput.log.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo teh world', selectionOffset: 'echo '.length),
        );
        await tester.pump();

        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          hasLength(1),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets('touch-driven caret moves clear the IME buffer', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
        initialEditingValue: _editingValue(
          'echo teh world',
          selectionOffset: 'echo teh world'.length,
        ),
      );
      final terminalOutput = harness.terminalOutput..clear();

      await tester.tap(find.byType(TerminalTextInputHandler));
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        _editingValue('echo teh world', selectionOffset: 'echo teh '.length),
      );
      await tester.pump();

      expect(
        terminalStateFromEvents(
          terminalOutput,
          initialText: 'echo teh world',
          initialCursorOffset: 'echo teh world'.length,
        ),
        (text: 'echo teh world', cursorOffset: 'echo teh '.length),
      );
      expect(
        _terminalTextInputClient(tester).currentTextEditingValue,
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(offset: 2),
        ),
      );

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'typing after a touch-driven caret move inserts from a fresh IME buffer',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          initialEditingValue: _editingValue(
            'echo teh world',
            selectionOffset: 'echo teh world'.length,
          ),
        );
        final terminalOutput = harness.terminalOutput..clear();

        await tester.tap(find.byType(TerminalTextInputHandler));
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo teh world', selectionOffset: 'echo '.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('X', selectionOffset: 1),
        );
        await tester.pump();

        expect(
          terminalStateFromEvents(
            terminalOutput,
            initialText: 'echo teh world',
            initialCursorOffset: 'echo teh world'.length,
          ),
          (text: 'echo Xteh world', cursorOffset: 'echo X'.length),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'resyncs the IME state when a replacement selection collapses to a different caret position',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          initialEditingValue: _editingValue(
            'echo teh world',
            selectionOffset: 'echo teh world'.length,
          ),
        );
        final terminalOutput = harness.terminalOutput;

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}echo the world',
            selection: TextSelection(baseOffset: 7, extentOffset: 10),
          ),
        );
        await tester.pump();

        terminalOutput.clear();
        tester.testTextInput.log.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo the world', selectionOffset: 'echo '.length),
        );
        await tester.pump();

        expect(
          terminalOutput.join(),
          List.filled(3, _terminalKeyOutput(TerminalKey.arrowLeft)).join(),
        );
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          hasLength(1),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'touch-driven caret moves clear the IME buffer after a replacement selection collapses elsewhere',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          initialEditingValue: _editingValue(
            'echo teh world',
            selectionOffset: 'echo teh world'.length,
          ),
        );
        final terminalOutput = harness.terminalOutput;

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}echo the world',
            selection: TextSelection(baseOffset: 7, extentOffset: 10),
          ),
        );
        await tester.pump();

        terminalOutput.clear();

        await tester.tap(find.byType(TerminalTextInputHandler));
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo the world', selectionOffset: 'echo '.length),
        );
        await tester.pump();

        expect(
          terminalStateFromEvents(
            terminalOutput,
            initialText: 'echo the world',
            initialCursorOffset: 'echo the'.length,
          ),
          (text: 'echo the world', cursorOffset: 'echo '.length),
        );
        expect(
          _terminalTextInputClient(tester).currentTextEditingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    for (final testCase in [
      (
        name:
            'keeps the cursor aligned when a replacement is followed by a later move and backspace elsewhere',
        initialEditingValue: _editingValue(
          'echo teh world',
          selectionOffset: 'echo teh world'.length,
        ),
        initialState: (
          text: 'echo teh world',
          cursorOffset: 'echo teh world'.length,
        ),
        steps: [
          _editingValue('echo teh world', selectionOffset: 'echo teh '.length),
          _editingValue('echo the world', selectionOffset: 'echo the '.length),
          _editingValue(
            'echo the world',
            selectionOffset: 'echo the world'.length,
          ),
          _editingValue(
            'echo the worl',
            selectionOffset: 'echo the worl'.length,
          ),
        ],
        expected: (text: 'echo the worl', cursorOffset: 'echo the worl'.length),
        expectedOutput: null,
      ),
      (
        name:
            'keeps the cursor aligned when a replacement is followed by a later replacement elsewhere',
        initialEditingValue: _editingValue(
          'echo teh world',
          selectionOffset: 'echo teh world'.length,
        ),
        initialState: (
          text: 'echo teh world',
          cursorOffset: 'echo teh world'.length,
        ),
        steps: [
          _editingValue('echo teh world', selectionOffset: 'echo teh '.length),
          _editingValue('echo the world', selectionOffset: 'echo the '.length),
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'echo the world',
            selection: TextSelection(baseOffset: 11, extentOffset: 16),
          ),
          _editingValue(
            'echo the earth',
            selectionOffset: 'echo the earth'.length,
          ),
        ],
        expected: (
          text: 'echo the earth',
          cursorOffset: 'echo the earth'.length,
        ),
        expectedOutput: null,
      ),
      (
        name:
            'keeps the cursor aligned when replacement selection is followed by immediate backspace',
        initialEditingValue: _editingValue(
          'echo teh world',
          selectionOffset: 'echo teh world'.length,
        ),
        initialState: (
          text: 'echo teh world',
          cursorOffset: 'echo teh world'.length,
        ),
        steps: [
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'echo teh world',
            selection: TextSelection(baseOffset: 7, extentOffset: 10),
          ),
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'echo the world',
            selection: TextSelection(baseOffset: 7, extentOffset: 10),
          ),
          _editingValue('echo th world', selectionOffset: 'echo th'.length),
        ],
        expected: (text: 'echo th world', cursorOffset: 'echo th'.length),
        expectedOutput: null,
      ),
      (
        name:
            'keeps the cursor aligned when a replacement selection includes a trailing space before backspace',
        initialEditingValue: _editingValue(
          'echo teh world',
          selectionOffset: 'echo teh world'.length,
        ),
        initialState: (
          text: 'echo teh world',
          cursorOffset: 'echo teh world'.length,
        ),
        steps: [
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'echo teh world',
            selection: TextSelection(baseOffset: 7, extentOffset: 11),
          ),
          _editingValue('echo the world', selectionOffset: 'echo the '.length),
          _editingValue('echo theworld', selectionOffset: 'echo the'.length),
        ],
        expected: (text: 'echo theworld', cursorOffset: 'echo the'.length),
        expectedOutput: null,
      ),
      (
        name:
            'keeps the cursor aligned when deleting and then reinserting a replacement separator',
        initialEditingValue: _editingValue(
          'echo teh world',
          selectionOffset: 'echo teh world'.length,
        ),
        initialState: (
          text: 'echo teh world',
          cursorOffset: 'echo teh world'.length,
        ),
        steps: [
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'echo teh world',
            selection: TextSelection(baseOffset: 7, extentOffset: 11),
          ),
          _editingValue('echo the world', selectionOffset: 'echo the '.length),
          _editingValue('echo theworld', selectionOffset: 'echo the'.length),
          _editingValue('echo the world', selectionOffset: 'echo the '.length),
        ],
        expected: (text: 'echo the world', cursorOffset: 'echo the '.length),
        expectedOutput: null,
      ),
      (
        name:
            'keeps the cursor aligned when whitespace-cluster replacement collapses two spaces before backspace',
        initialEditingValue: _editingValue(
          'foo  bar',
          selectionOffset: 'foo  bar'.length,
        ),
        initialState: (text: 'foo  bar', cursorOffset: 'foo  bar'.length),
        steps: [
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'foo  bar',
            selection: TextSelection(baseOffset: 6, extentOffset: 10),
          ),
          _editingValue('foo baz', selectionOffset: 'foo baz'.length),
          _editingValue('foo ba', selectionOffset: 'foo ba'.length),
        ],
        expected: (text: 'foo ba', cursorOffset: 'foo ba'.length),
        expectedOutput: null,
      ),
      (
        name:
            'keeps the cursor aligned across repeated non-collapsed replacements before backspace',
        initialEditingValue: _editingValue(
          'echo teh world',
          selectionOffset: 'echo teh world'.length,
        ),
        initialState: (
          text: 'echo teh world',
          cursorOffset: 'echo teh world'.length,
        ),
        steps: [
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'echo teh world',
            selection: TextSelection(baseOffset: 7, extentOffset: 10),
          ),
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'echo the world',
            selection: TextSelection(baseOffset: 7, extentOffset: 10),
          ),
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'echo then world',
            selection: TextSelection(baseOffset: 7, extentOffset: 11),
          ),
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'echo the world',
            selection: TextSelection(baseOffset: 7, extentOffset: 10),
          ),
          _editingValue('echo th world', selectionOffset: 'echo th'.length),
        ],
        expected: (text: 'echo th world', cursorOffset: 'echo th'.length),
        expectedOutput: null,
      ),
      (
        name:
            'keeps the cursor aligned across repeated-word non-collapsed replacements before backspace',
        initialEditingValue: _editingValue(
          'bar bar bar',
          selectionOffset: 'bar bar bar'.length,
        ),
        initialState: (text: 'bar bar bar', cursorOffset: 'bar bar bar'.length),
        steps: [
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'bar bar bar',
            selection: TextSelection(baseOffset: 6, extentOffset: 9),
          ),
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'bar baz bar',
            selection: TextSelection(baseOffset: 6, extentOffset: 9),
          ),
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'bar bazz bar',
            selection: TextSelection(baseOffset: 6, extentOffset: 10),
          ),
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'bar baz bar',
            selection: TextSelection(baseOffset: 6, extentOffset: 9),
          ),
          _editingValue('bar ba bar', selectionOffset: 'bar ba'.length),
        ],
        expected: (text: 'bar ba bar', cursorOffset: 'bar ba'.length),
        expectedOutput: null,
      ),
      (
        name:
            'keeps the cursor aligned when editing inside a triple-space cluster after an internal move',
        initialEditingValue: _editingValue(
          'foo   bar',
          selectionOffset: 'foo   bar'.length,
        ),
        initialState: (text: 'foo   bar', cursorOffset: 'foo   bar'.length),
        steps: [
          _editingValue('foo   bar', selectionOffset: 5),
          _editingValue('foo  X bar', selectionOffset: 6),
          _editingValue('foo  X bar', selectionOffset: 5),
          _editingValue('foo X bar', selectionOffset: 4),
        ],
        expected: (text: 'foo X bar', cursorOffset: 4),
        expectedOutput: null,
      ),
      (
        name:
            'keeps the cursor aligned after replacing a repeated word and then backspacing a later repeated match',
        initialEditingValue: _editingValue(
          'bar bar bar',
          selectionOffset: 'bar bar bar'.length,
        ),
        initialState: (text: 'bar bar bar', cursorOffset: 'bar bar bar'.length),
        steps: [
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'bar bar bar',
            selection: TextSelection(baseOffset: 6, extentOffset: 9),
          ),
          _editingValue('bar baz bar', selectionOffset: 'bar baz'.length),
          _editingValue('bar baz bar', selectionOffset: 'bar baz bar'.length),
          _editingValue('bar baz ba', selectionOffset: 'bar baz ba'.length),
        ],
        expected: (text: 'bar baz ba', cursorOffset: 'bar baz ba'.length),
        expectedOutput: null,
      ),
      (
        name: 'inserts at a moved caret without rewriting the unchanged suffix',
        initialEditingValue: _editingValue(
          'foo bar',
          selectionOffset: 'foo bar'.length,
        ),
        initialState: (text: 'foo bar', cursorOffset: 'foo bar'.length),
        steps: [
          _editingValue('foo bar', selectionOffset: 'foo '.length),
          _editingValue('foo Xbar', selectionOffset: 'foo X'.length),
        ],
        expected: (text: 'foo Xbar', cursorOffset: 'foo X'.length),
        expectedOutput:
            '${List.filled(3, _terminalKeyOutput(TerminalKey.arrowLeft)).join()}X',
      ),
      (
        name:
            'inserts at the beginning of the line without rewriting the existing text',
        initialEditingValue: _editingValue(
          'hello',
          selectionOffset: 'hello'.length,
        ),
        initialState: (text: 'hello', cursorOffset: 'hello'.length),
        steps: [
          _editingValue('hello', selectionOffset: 0),
          _editingValue('Xhello', selectionOffset: 1),
        ],
        expected: (text: 'Xhello', cursorOffset: 1),
        expectedOutput:
            '${List.filled(5, _terminalKeyOutput(TerminalKey.arrowLeft)).join()}X',
      ),
      (
        name: 'deletes at a moved caret without rewriting the unchanged suffix',
        initialEditingValue: _editingValue(
          'foo Xbar',
          selectionOffset: 'foo Xbar'.length,
        ),
        initialState: (text: 'foo Xbar', cursorOffset: 'foo Xbar'.length),
        steps: [
          _editingValue('foo Xbar', selectionOffset: 'foo X'.length),
          _editingValue('foo bar', selectionOffset: 'foo '.length),
        ],
        expected: (text: 'foo bar', cursorOffset: 'foo '.length),
        expectedOutput:
            List.filled(3, _terminalKeyOutput(TerminalKey.arrowLeft)).join() +
            _terminalKeyOutput(TerminalKey.backspace),
      ),
      (
        name:
            'inserts an identical character at a moved caret without rewriting the unchanged suffix',
        initialEditingValue: _editingValue(
          'aaaa',
          selectionOffset: 'aaaa'.length,
        ),
        initialState: (text: 'aaaa', cursorOffset: 'aaaa'.length),
        steps: [
          _editingValue('aaaa', selectionOffset: 1),
          _editingValue('aaaaa', selectionOffset: 2),
        ],
        expected: (text: 'aaaaa', cursorOffset: 2),
        expectedOutput:
            '${List.filled(3, _terminalKeyOutput(TerminalKey.arrowLeft)).join()}a',
      ),
      (
        name:
            'moves and inserts around an emoji using grapheme-aware cursor offsets',
        initialEditingValue: _editingValue(
          'a🎉b',
          selectionOffset: 'a🎉b'.length,
        ),
        initialState: (text: 'a🎉b', cursorOffset: 3),
        steps: [
          _editingValue('a🎉b', selectionOffset: 1),
          _editingValue('aX🎉b', selectionOffset: 2),
        ],
        expected: (text: 'aX🎉b', cursorOffset: 2),
        expectedOutput:
            '${List.filled(2, _terminalKeyOutput(TerminalKey.arrowLeft)).join()}X',
      ),
      (
        name:
            'deletes an identical character at a moved caret without rewriting the unchanged suffix',
        initialEditingValue: _editingValue(
          'aaaaa',
          selectionOffset: 'aaaaa'.length,
        ),
        initialState: (text: 'aaaaa', cursorOffset: 'aaaaa'.length),
        steps: [
          _editingValue('aaaaa', selectionOffset: 2),
          _editingValue('aaaa', selectionOffset: 1),
        ],
        expected: (text: 'aaaa', cursorOffset: 1),
        expectedOutput:
            '${List.filled(3, _terminalKeyOutput(TerminalKey.arrowLeft)).join()}'
            '${_terminalKeyOutput(TerminalKey.backspace)}',
      ),
      (
        name:
            'keeps the cursor aligned when inserting and then backspacing at a space boundary',
        initialEditingValue: _editingValue(
          'foo bar',
          selectionOffset: 'foo bar'.length,
        ),
        initialState: (text: 'foo bar', cursorOffset: 'foo bar'.length),
        steps: [
          _editingValue('foo bar', selectionOffset: 'foo '.length),
          _editingValue('foo Xbar', selectionOffset: 'foo X'.length),
          _editingValue('foo bar', selectionOffset: 'foo '.length),
        ],
        expected: (text: 'foo bar', cursorOffset: 'foo '.length),
        expectedOutput:
            '${List.filled(3, _terminalKeyOutput(TerminalKey.arrowLeft)).join()}'
            'X${_terminalKeyOutput(TerminalKey.backspace)}',
      ),
      (
        name:
            'keeps the cursor aligned when inserting and then backspacing between repeated spaces',
        initialEditingValue: _editingValue(
          'foo  bar',
          selectionOffset: 'foo  bar'.length,
        ),
        initialState: (text: 'foo  bar', cursorOffset: 'foo  bar'.length),
        steps: [
          _editingValue('foo  bar', selectionOffset: 'foo '.length),
          _editingValue('foo X bar', selectionOffset: 'foo X'.length),
          _editingValue('foo  bar', selectionOffset: 'foo '.length),
        ],
        expected: (text: 'foo  bar', cursorOffset: 'foo '.length),
        expectedOutput:
            '${List.filled(4, _terminalKeyOutput(TerminalKey.arrowLeft)).join()}'
            'X${_terminalKeyOutput(TerminalKey.backspace)}',
      ),
      (
        name:
            'replaces punctuation at a moved caret without rewriting the trailing word',
        initialEditingValue: _editingValue(
          'hello, world',
          selectionOffset: 'hello, world'.length,
        ),
        initialState: (
          text: 'hello, world',
          cursorOffset: 'hello, world'.length,
        ),
        steps: [
          _editingValue('hello, world', selectionOffset: 'hello,'.length),
          _editingValue('hello; world', selectionOffset: 'hello;'.length),
        ],
        expected: (text: 'hello; world', cursorOffset: 'hello;'.length),
        expectedOutput:
            '${List.filled(6, _terminalKeyOutput(TerminalKey.arrowLeft)).join()}'
            '${_terminalKeyOutput(TerminalKey.backspace)};',
      ),
      (
        name:
            'keeps the cursor aligned when replacing punctuation and double-space clusters before backspace',
        initialEditingValue: _editingValue(
          'hello,  world',
          selectionOffset: 'hello,  world'.length,
        ),
        initialState: (
          text: 'hello,  world',
          cursorOffset: 'hello,  world'.length,
        ),
        steps: [
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'hello,  world',
            selection: TextSelection(baseOffset: 7, extentOffset: 10),
          ),
          _editingValue('hello; world', selectionOffset: 'hello; '.length),
          _editingValue('hello;world', selectionOffset: 'hello;'.length),
        ],
        expected: (text: 'hello;world', cursorOffset: 'hello;'.length),
        expectedOutput: null,
      ),
      (
        name:
            'replaces the middle repeated word without touching the trailing match',
        initialEditingValue: _editingValue(
          'go go go',
          selectionOffset: 'go go go'.length,
        ),
        initialState: (text: 'go go go', cursorOffset: 'go go go'.length),
        steps: [
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'go go go',
            selection: TextSelection(baseOffset: 5, extentOffset: 7),
          ),
          _editingValue('go gone go', selectionOffset: 'go gone'.length),
        ],
        expected: (text: 'go gone go', cursorOffset: 'go gone'.length),
        expectedOutput: null,
      ),
      (
        name:
            'keeps the cursor aligned after replacing a repeated word and then backspacing',
        initialEditingValue: _editingValue(
          'go go go',
          selectionOffset: 'go go go'.length,
        ),
        initialState: (text: 'go go go', cursorOffset: 'go go go'.length),
        steps: [
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'go go go',
            selection: TextSelection(baseOffset: 5, extentOffset: 7),
          ),
          _editingValue('go gone go', selectionOffset: 'go gone'.length),
          _editingValue('go gon go', selectionOffset: 'go gon'.length),
        ],
        expected: (text: 'go gon go', cursorOffset: 'go gon'.length),
        expectedOutput:
            '${List.filled(3, _terminalKeyOutput(TerminalKey.arrowLeft)).join()}'
            'ne${_terminalKeyOutput(TerminalKey.backspace)}',
      ),
      (
        name:
            'keeps the cursor aligned when a repeated-word replacement commits from composition before backspace',
        initialEditingValue: _editingValue(
          'go go go',
          selectionOffset: 'go go go'.length,
        ),
        initialState: (text: 'go go go', cursorOffset: 'go go go'.length),
        steps: [
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'go go go',
            selection: TextSelection(baseOffset: 5, extentOffset: 7),
          ),
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'go gone go',
            selection: TextSelection.collapsed(offset: 9),
            composing: TextRange(start: 5, end: 9),
          ),
          _editingValue('go gone go', selectionOffset: 'go gone'.length),
          _editingValue('go gon go', selectionOffset: 'go gon'.length),
        ],
        expected: (text: 'go gon go', cursorOffset: 'go gon'.length),
        expectedOutput: null,
      ),
      (
        name:
            'keeps the cursor aligned when composition moves away before collapsing and a later backspace follows',
        initialEditingValue: _editingValue(
          'echo teh world',
          selectionOffset: 'echo teh world'.length,
        ),
        initialState: (
          text: 'echo teh world',
          cursorOffset: 'echo teh world'.length,
        ),
        steps: [
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'echo the world',
            selection: TextSelection.collapsed(offset: 9),
            composing: TextRange(start: 7, end: 10),
          ),
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'echo the world',
            selection: TextSelection.collapsed(offset: 16),
            composing: TextRange(start: 7, end: 10),
          ),
          _editingValue(
            'echo the world',
            selectionOffset: 'echo the world'.length,
          ),
          _editingValue(
            'echo the worl',
            selectionOffset: 'echo the worl'.length,
          ),
        ],
        expected: (text: 'echo the worl', cursorOffset: 'echo the worl'.length),
        expectedOutput: null,
      ),
      (
        name:
            'keeps the cursor aligned when an autocorrected word is punctuated and then backspaced',
        initialEditingValue: _editingValue(
          'hi teh world',
          selectionOffset: 'hi teh world'.length,
        ),
        initialState: (
          text: 'hi teh world',
          cursorOffset: 'hi teh world'.length,
        ),
        steps: [
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'hi teh world',
            selection: TextSelection(baseOffset: 5, extentOffset: 9),
          ),
          _editingValue('hi the world', selectionOffset: 'hi the'.length),
          _editingValue('hi the. world', selectionOffset: 'hi the.'.length),
          _editingValue('hi the world', selectionOffset: 'hi the'.length),
        ],
        expected: (text: 'hi the world', cursorOffset: 'hi the'.length),
        expectedOutput: null,
      ),
      (
        name:
            'keeps the cursor aligned across repeated backspaces after an autocorrected repeated token',
        initialEditingValue: _editingValue(
          'go teh go',
          selectionOffset: 'go teh go'.length,
        ),
        initialState: (text: 'go teh go', cursorOffset: 'go teh go'.length),
        steps: [
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'go teh go',
            selection: TextSelection(baseOffset: 5, extentOffset: 9),
          ),
          _editingValue('go the go', selectionOffset: 'go the'.length),
          _editingValue('go th go', selectionOffset: 'go th'.length),
          _editingValue('go t go', selectionOffset: 'go t'.length),
        ],
        expected: (text: 'go t go', cursorOffset: 'go t'.length),
        expectedOutput: null,
      ),
    ]) {
      testWidgets(testCase.name, (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          initialEditingValue: testCase.initialEditingValue,
        );
        final terminalOutput = harness.terminalOutput..clear();
        for (final value in testCase.steps) {
          tester.testTextInput.updateEditingValue(value);
          await tester.pump();
        }
        if (testCase.expectedOutput != null) {
          expect(terminalOutput.join(), testCase.expectedOutput);
        }
        expect(
          terminalStateFromEvents(
            terminalOutput,
            initialText: testCase.initialState.text,
            initialCursorOffset: testCase.initialState.cursorOffset,
          ),
          testCase.expected,
        );
        await disposeTerminalInputHarness(tester, harness);
      });
    }

    testWidgets(
      'preserves replacement text after a later word delete drops part of the marker',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          initialEditingValue: const TextEditingValue(
            text: '\u200B\u200Bteh world ',
            selection: TextSelection.collapsed(offset: 12),
          ),
        );
        final terminalOutput = harness.terminalOutput;

        tester.testTextInput.log.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200Bteh ',
            selection: TextSelection.collapsed(offset: 5),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Bthe ',
            selection: TextSelection(baseOffset: 2, extentOffset: 5),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Bthe ',
            selection: TextSelection.collapsed(offset: 6),
          ),
        );
        await tester.pump();

        expect(terminalTextFromEvents(terminalOutput), 'the ');

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'keeps the cursor aligned when replacing across an emoji boundary and trailing space',
      (tester) async {
        const initialText = 'go 👩🏽‍💻 now';
        const selectionStart = _deleteDetectionMarker.length + 'go '.length;
        const selectionEnd =
            _deleteDetectionMarker.length + 'go 👩🏽‍💻 '.length;

        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
        );

        tester.testTextInput.updateEditingValue(
          _editingValue(initialText, selectionOffset: initialText.length),
        );
        await tester.pump();

        harness.terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '$_deleteDetectionMarker$initialText',
            selection: TextSelection(
              baseOffset: selectionStart,
              extentOffset: selectionEnd,
            ),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('go later now', selectionOffset: 'go later'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('go late now', selectionOffset: 'go late'.length),
        );
        await tester.pump();

        expect(
          terminalStateFromEvents(
            harness.terminalOutput,
            initialText: initialText,
            initialCursorOffset: initialText.characters.length,
          ),
          (text: 'go late now', cursorOffset: 'go late'.length),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'keeps the cursor aligned when replacing the first word and trailing space at the buffer start',
      (tester) async {
        const initialText = 'teh world';
        const selectionEnd = _deleteDetectionMarker.length + 'teh '.length;

        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
        );

        tester.testTextInput.updateEditingValue(
          _editingValue(initialText, selectionOffset: initialText.length),
        );
        await tester.pump();

        harness.terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '$_deleteDetectionMarker$initialText',
            selection: TextSelection(
              baseOffset: _deleteDetectionMarker.length,
              extentOffset: selectionEnd,
            ),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('the world', selectionOffset: 'the'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('th world', selectionOffset: 'th'.length),
        );
        await tester.pump();

        expect(
          terminalStateFromEvents(
            harness.terminalOutput,
            initialText: initialText,
            initialCursorOffset: initialText.length,
          ),
          (text: 'th world', cursorOffset: 'th'.length),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'keeps the cursor aligned when replacing the last word and leading space at the buffer end',
      (tester) async {
        const initialText = 'hello teh';
        const selectionStart = _deleteDetectionMarker.length + 'hello'.length;
        const selectionEnd = _deleteDetectionMarker.length + initialText.length;

        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
        );

        tester.testTextInput.updateEditingValue(
          _editingValue(initialText, selectionOffset: initialText.length),
        );
        await tester.pump();

        harness.terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '$_deleteDetectionMarker$initialText',
            selection: TextSelection(
              baseOffset: selectionStart,
              extentOffset: selectionEnd,
            ),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('hello the', selectionOffset: 'hello the'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('hello th', selectionOffset: 'hello th'.length),
        );
        await tester.pump();

        expect(
          terminalStateFromEvents(
            harness.terminalOutput,
            initialText: initialText,
            initialCursorOffset: initialText.length,
          ),
          (text: 'hello th', cursorOffset: 'hello th'.length),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets('soft-keyboard newline text sends terminal Enter', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
        initialEditingValue: _editingValue(
          'echo',
          selectionOffset: 'echo'.length,
        ),
      );
      final terminalOutput = harness.terminalOutput..clear();

      tester.testTextInput.updateEditingValue(
        _editingValue('echo\n', selectionOffset: 'echo\n'.length),
      );
      await tester.pump();

      expect(terminalOutput.join(), _terminalKeyOutput(TerminalKey.enter));
      expect(
        _terminalTextInputClient(tester).currentTextEditingValue,
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(
            offset: _deleteDetectionMarker.length,
          ),
        ),
      );

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'suppresses the first follow-up newline action after a committed newline update',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          initialEditingValue: _editingValue(
            'echo\n',
            selectionOffset: 'echo\n'.length,
          ),
        );
        final terminalOutput = harness.terminalOutput..clear();

        final client =
            tester.state(find.byType(TerminalTextInputHandler))
                as TextInputClient;
        Future<void> performNewlineAction() async {
          client.performAction(TextInputAction.newline);
          await tester.pump();
        }

        await performNewlineAction();

        expect(terminalOutput, isEmpty);

        await performNewlineAction();

        expect(terminalOutput.join(), _terminalKeyOutput(TerminalKey.enter));

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets('newline actions consume one-shot toolbar modifiers', (
      tester,
    ) async {
      var shiftActive = true;
      final harness = await pumpTerminalInputHarness(
        tester,
        resolveTerminalKeyModifiers: () =>
            (ctrl: false, alt: false, shift: shiftActive),
        consumeTerminalKeyModifiers: () => shiftActive = false,
      );

      _terminalTextInputClient(tester).performAction(TextInputAction.newline);
      await tester.pump();
      _terminalTextInputClient(tester).performAction(TextInputAction.newline);
      await tester.pump();

      expect(
        harness.terminalOutput.join(),
        _terminalShiftEnterNewlineInput + _terminalKeyOutput(TerminalKey.enter),
      );

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets('hardware Shift+Enter sends legacy LF newline', (tester) async {
      final harness = await pumpTerminalInputHarness(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      expect(harness.terminalOutput.join(), _terminalShiftEnterNewlineInput);

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets('hardware Alt+Enter sends meta-sends-escape CR', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();

      expect(harness.terminalOutput.join(), '\x1b\r');

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'virtual Enter ignores stale soft-keyboard Shift and submits via IME',
      (tester) async {
        const virtualShiftKey = PhysicalKeyboardKey(
          LogicalKeyboardKey.androidPlane + 59,
        );
        const virtualEnterKey = PhysicalKeyboardKey(
          LogicalKeyboardKey.androidPlane + 66,
        );

        // Production terminal screen uses manageFocus: false and routes keys
        // through the global HardwareKeyboard handler.
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          manageFocus: false,
        );
        expect(tester.testTextInput.isVisible, isTrue);

        // Soft keyboards often leave Shift pressed after capitalization while
        // also emitting a synthetic Enter key event. That used to encode as
        // alternate-enter (newline) in Codex/Cursor instead of submit.
        HardwareKeyboard.instance.handleKeyEvent(
          const KeyDownEvent(
            logicalKey: LogicalKeyboardKey.shiftLeft,
            physicalKey: virtualShiftKey,
            timeStamp: Duration.zero,
          ),
        );
        HardwareKeyboard.instance.handleKeyEvent(
          const KeyDownEvent(
            logicalKey: LogicalKeyboardKey.enter,
            physicalKey: virtualEnterKey,
            timeStamp: Duration.zero,
          ),
        );
        HardwareKeyboard.instance.handleKeyEvent(
          const KeyUpEvent(
            logicalKey: LogicalKeyboardKey.enter,
            physicalKey: virtualEnterKey,
            timeStamp: Duration.zero,
          ),
        );
        await tester.pump();

        expect(harness.terminalOutput, isEmpty);

        _terminalTextInputClient(tester).performAction(TextInputAction.newline);
        await tester.pump();

        expect(
          harness.terminalOutput.join(),
          _terminalKeyOutput(TerminalKey.enter),
        );

        HardwareKeyboard.instance.handleKeyEvent(
          const KeyUpEvent(
            logicalKey: LogicalKeyboardKey.shiftLeft,
            physicalKey: virtualShiftKey,
            timeStamp: Duration.zero,
          ),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'virtual Enter with toolbar Shift still sends LF newline via IME',
      (tester) async {
        const virtualEnterKey = PhysicalKeyboardKey(
          LogicalKeyboardKey.androidPlane + 66,
        );
        var shiftActive = true;

        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          manageFocus: false,
          resolveTerminalKeyModifiers: () =>
              (ctrl: false, alt: false, shift: shiftActive),
          consumeTerminalKeyModifiers: () => shiftActive = false,
        );

        tester.testTextInput.updateEditingValue(
          _editingValue('C', selectionOffset: 1),
        );
        await tester.pump();
        harness.terminalOutput.clear();

        HardwareKeyboard.instance.handleKeyEvent(
          const KeyDownEvent(
            logicalKey: LogicalKeyboardKey.enter,
            physicalKey: virtualEnterKey,
            timeStamp: Duration.zero,
          ),
        );
        HardwareKeyboard.instance.handleKeyEvent(
          const KeyUpEvent(
            logicalKey: LogicalKeyboardKey.enter,
            physicalKey: virtualEnterKey,
            timeStamp: Duration.zero,
          ),
        );
        await tester.pump();

        expect(harness.terminalOutput, isEmpty);

        _terminalTextInputClient(tester).performAction(TextInputAction.newline);
        await tester.pump();

        expect(harness.terminalOutput.join(), _terminalShiftEnterNewlineInput);
        expect(shiftActive, isFalse);

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'toolbar Shift applies to non-virtual Enter on the hardware path',
      (tester) async {
        var shiftActive = true;
        final harness = await pumpTerminalInputHarness(
          tester,
          manageFocus: false,
          resolveTerminalKeyModifiers: () =>
              (ctrl: false, alt: false, shift: shiftActive),
          consumeTerminalKeyModifiers: () => shiftActive = false,
        );

        // Standard HID Enter (not platform-plane / virtual). Soft and external
        // keyboards both use this on some devices; toolbar Shift must still
        // apply because HardwareKeyboard does not mirror toolbar modifiers.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await tester.pump();

        expect(harness.terminalOutput.join(), _terminalShiftEnterNewlineInput);
        expect(shiftActive, isFalse);

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'toolbar Alt applies to non-virtual Enter on the hardware path',
      (tester) async {
        var altActive = true;
        final harness = await pumpTerminalInputHarness(
          tester,
          manageFocus: false,
          resolveTerminalKeyModifiers: () =>
              (ctrl: false, alt: altActive, shift: false),
          consumeTerminalKeyModifiers: () => altActive = false,
        );

        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await tester.pump();

        expect(harness.terminalOutput.join(), '\x1b\r');
        expect(altActive, isFalse);

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets('virtual shifted text bypasses Kitty hardware key encoding', (
      tester,
    ) async {
      const virtualShiftKey = PhysicalKeyboardKey(
        LogicalKeyboardKey.androidPlane + 59,
      );
      const virtualCommaKey = PhysicalKeyboardKey(
        LogicalKeyboardKey.androidPlane + 55,
      );

      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
        initialTerminalOutput: '\x1b[>9u',
      );

      expect(tester.testTextInput.isVisible, isTrue);

      HardwareKeyboard.instance.handleKeyEvent(
        const KeyDownEvent(
          logicalKey: LogicalKeyboardKey.shiftLeft,
          physicalKey: virtualShiftKey,
          timeStamp: Duration.zero,
        ),
      );
      HardwareKeyboard.instance.handleKeyEvent(
        const KeyDownEvent(
          logicalKey: LogicalKeyboardKey.comma,
          physicalKey: virtualCommaKey,
          character: '<',
          timeStamp: Duration.zero,
        ),
      );
      HardwareKeyboard.instance.handleKeyEvent(
        const KeyUpEvent(
          logicalKey: LogicalKeyboardKey.comma,
          physicalKey: virtualCommaKey,
          timeStamp: Duration.zero,
        ),
      );
      HardwareKeyboard.instance.handleKeyEvent(
        const KeyUpEvent(
          logicalKey: LogicalKeyboardKey.shiftLeft,
          physicalKey: virtualShiftKey,
          timeStamp: Duration.zero,
        ),
      );
      await tester.pump();

      expect(harness.terminalOutput, isEmpty);

      tester.testTextInput.updateEditingValue(
        _editingValue('<', selectionOffset: 1),
      );
      await tester.pump();

      expect(harness.terminalOutput, <String>['<']);

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets('Android IME HID controls bypass Kitty hardware key encoding', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);

      TerminalInputHarness? harness;
      try {
        harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          manageFocus: false,
          initialTerminalOutput: '\x1b[>1u',
        );

        expect(tester.testTextInput.isVisible, isTrue);

        tester.testTextInput.updateEditingValue(
          _editingValue('CC', selectionOffset: 2),
        );
        await tester.pump();
        harness.terminalOutput.clear();

        HardwareKeyboard.instance.handleKeyEvent(
          const KeyDownEvent(
            logicalKey: LogicalKeyboardKey.shiftLeft,
            physicalKey: PhysicalKeyboardKey.shiftLeft,
            timeStamp: Duration.zero,
          ),
        );
        HardwareKeyboard.instance.handleKeyEvent(
          const KeyDownEvent(
            logicalKey: LogicalKeyboardKey.backspace,
            physicalKey: PhysicalKeyboardKey.backspace,
            timeStamp: Duration.zero,
          ),
        );
        HardwareKeyboard.instance.handleKeyEvent(
          const KeyRepeatEvent(
            logicalKey: LogicalKeyboardKey.backspace,
            physicalKey: PhysicalKeyboardKey.backspace,
            timeStamp: Duration.zero,
          ),
        );
        HardwareKeyboard.instance.handleKeyEvent(
          const KeyUpEvent(
            logicalKey: LogicalKeyboardKey.backspace,
            physicalKey: PhysicalKeyboardKey.backspace,
            timeStamp: Duration.zero,
          ),
        );
        await tester.pump();

        expect(harness.terminalOutput, <String>['\x7f', '\x7f']);

        tester.testTextInput.updateEditingValue(
          _editingValue('', selectionOffset: 0),
        );
        await tester.pump();

        expect(
          harness.terminalOutput.join(),
          '${_terminalKeyOutput(TerminalKey.backspace)}'
          '${_terminalKeyOutput(TerminalKey.backspace)}',
        );

        HardwareKeyboard.instance.handleKeyEvent(
          const KeyUpEvent(
            logicalKey: LogicalKeyboardKey.shiftLeft,
            physicalKey: PhysicalKeyboardKey.shiftLeft,
            timeStamp: Duration.zero,
          ),
        );
      } finally {
        if (harness != null) {
          await disposeTerminalInputHarness(tester, harness);
        }
        tester.view.resetViewInsets();
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
      'Android external HID Backspace keeps Kitty encoding with visible IME',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        final controller = TerminalTextInputHandlerController();
        TerminalInputHarness? harness;

        try {
          harness = await pumpTerminalInputHarness(
            tester,
            manageFocus: false,
            initialTerminalOutput: '\x1b[>9u',
            controller: controller,
          );
          final terminalOutput = harness.terminalOutput;

          expect(tester.testTextInput.isVisible, isTrue);
          expect(tester.view.viewInsets.bottom, greaterThan(0));

          controller.debugRecordAndroidPhysicalKey(
            TerminalKey.shiftLeft,
            TerminalKeyEventType.press,
          );
          HardwareKeyboard.instance.handleKeyEvent(
            const KeyDownEvent(
              logicalKey: LogicalKeyboardKey.shiftLeft,
              physicalKey: PhysicalKeyboardKey.shiftLeft,
              timeStamp: Duration.zero,
            ),
          );
          controller.debugRecordAndroidPhysicalKey(
            TerminalKey.backspace,
            TerminalKeyEventType.press,
          );
          HardwareKeyboard.instance.handleKeyEvent(
            const KeyDownEvent(
              logicalKey: LogicalKeyboardKey.backspace,
              physicalKey: PhysicalKeyboardKey.backspace,
              timeStamp: Duration.zero,
            ),
          );
          controller.debugRecordAndroidPhysicalKey(
            TerminalKey.backspace,
            TerminalKeyEventType.release,
          );
          HardwareKeyboard.instance.handleKeyEvent(
            const KeyUpEvent(
              logicalKey: LogicalKeyboardKey.backspace,
              physicalKey: PhysicalKeyboardKey.backspace,
              timeStamp: Duration.zero,
            ),
          );
          controller.debugRecordAndroidPhysicalKey(
            TerminalKey.shiftLeft,
            TerminalKeyEventType.release,
          );
          HardwareKeyboard.instance.handleKeyEvent(
            const KeyUpEvent(
              logicalKey: LogicalKeyboardKey.shiftLeft,
              physicalKey: PhysicalKeyboardKey.shiftLeft,
              timeStamp: Duration.zero,
            ),
          );
          await tester.pump();

          expect(terminalOutput.join(), contains('\x1b[127;2u'));
        } finally {
          if (harness != null) {
            await disposeTerminalInputHarness(tester, harness);
          }
          controller.dispose();
          tester.view.resetViewInsets();
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      'physical Backspace consumes a toolbar modifier with visible IME',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        var ctrlActive = true;
        final controller = TerminalTextInputHandlerController();
        TerminalInputHarness? harness;

        try {
          harness = await pumpTerminalInputHarness(
            tester,
            manageFocus: false,
            initialTerminalOutput: '\x1b[>1u',
            resolveTerminalKeyModifiers: () =>
                (ctrl: ctrlActive, alt: false, shift: false),
            consumeTerminalKeyModifiers: () => ctrlActive = false,
            controller: controller,
          );
          final terminalOutput = harness.terminalOutput;

          controller.debugRecordAndroidPhysicalKey(
            TerminalKey.backspace,
            TerminalKeyEventType.press,
          );
          HardwareKeyboard.instance.handleKeyEvent(
            const KeyDownEvent(
              logicalKey: LogicalKeyboardKey.backspace,
              physicalKey: PhysicalKeyboardKey.backspace,
              timeStamp: Duration.zero,
            ),
          );
          controller.debugRecordAndroidPhysicalKey(
            TerminalKey.backspace,
            TerminalKeyEventType.release,
          );
          HardwareKeyboard.instance.handleKeyEvent(
            const KeyUpEvent(
              logicalKey: LogicalKeyboardKey.backspace,
              physicalKey: PhysicalKeyboardKey.backspace,
              timeStamp: Duration.zero,
            ),
          );
          await tester.pump();

          expect(terminalOutput, <String>['\x1b[127;5u']);
          expect(ctrlActive, isFalse);
        } finally {
          if (harness != null) {
            await disposeTerminalInputHarness(tester, harness);
          }
          controller.dispose();
          tester.view.resetViewInsets();
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets('replacing focus node closes an unfocused input connection', (
      tester,
    ) async {
      final terminal = Terminal();
      final firstFocusNode = FocusNode();
      final replacementFocusNode = FocusNode();

      Widget buildHandler(FocusNode focusNode) => MaterialApp(
        home: Scaffold(
          body: TerminalTextInputHandler(
            terminal: terminal,
            focusNode: focusNode,
            deleteDetection: true,
            child: const SizedBox.expand(),
          ),
        ),
      );

      await tester.pumpWidget(buildHandler(firstFocusNode));
      firstFocusNode.requestFocus();
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);

      await tester.pumpWidget(buildHandler(replacementFocusNode));
      await tester.pump();

      expect(replacementFocusNode.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);

      firstFocusNode.dispose();
      replacementFocusNode.dispose();
    });

    testWidgets(
      'Android IME replacement after HID Backspace does not delete twice',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final controller = TerminalTextInputHandlerController();
        TerminalInputHarness? harness;

        try {
          harness = await pumpTerminalInputHarness(
            tester,
            manageFocus: false,
            initialTerminalOutput: '\x1b[>1u',
            controller: controller,
          );
          final terminalOutput = harness.terminalOutput;

          tester.testTextInput.updateEditingValue(
            _editingValue('CC', selectionOffset: 2),
          );
          await tester.pump();
          terminalOutput.clear();

          controller
            ..debugHandleAndroidImeKey(
              TerminalKey.backspace,
              TerminalKeyEventType.press,
            )
            ..debugHandleAndroidImeKey(
              TerminalKey.backspace,
              TerminalKeyEventType.repeat,
            )
            ..debugHandleAndroidImeKey(
              TerminalKey.backspace,
              TerminalKeyEventType.release,
            );
          await tester.pump();

          tester.testTextInput.updateEditingValue(
            _editingValue('D', selectionOffset: 1),
          );
          await tester.pump();

          expect(terminalOutput, <String>['\x7f', '\x7f', 'D']);
        } finally {
          if (harness != null) {
            await disposeTerminalInputHarness(tester, harness);
          }
          controller.dispose();
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      'Android IME append after omitted Backspace drops stale buffer text',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final controller = TerminalTextInputHandlerController();
        TerminalInputHarness? harness;

        try {
          harness = await pumpTerminalInputHarness(
            tester,
            manageFocus: false,
            initialTerminalOutput: '\x1b[>1u',
            controller: controller,
          );
          final terminalOutput = harness.terminalOutput;

          tester.testTextInput.updateEditingValue(
            _editingValue('A', selectionOffset: 1),
          );
          await tester.pump();
          terminalOutput.clear();

          controller
            ..debugHandleAndroidImeKey(
              TerminalKey.backspace,
              TerminalKeyEventType.press,
            )
            ..debugHandleAndroidImeKey(
              TerminalKey.backspace,
              TerminalKeyEventType.release,
            );
          tester.testTextInput.updateEditingValue(
            _editingValue('AB', selectionOffset: 2),
          );
          await tester.pump();

          expect(terminalOutput, <String>['\x7f', 'B']);
          expect(
            _terminalTextInputClient(tester).currentTextEditingValue,
            _editingValue('B', selectionOffset: 1),
          );
        } finally {
          if (harness != null) {
            await disposeTerminalInputHarness(tester, harness);
          }
          controller.dispose();
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      'rejected replacement preserves an applied Android IME Backspace',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final controller = TerminalTextInputHandlerController();
        TerminalInputHarness? harness;

        try {
          harness = await pumpTerminalInputHarness(
            tester,
            manageFocus: false,
            initialTerminalOutput: '\x1b[>1u',
            onReviewInsertedText: (_) async => false,
            controller: controller,
          );
          final terminalOutput = harness.terminalOutput;

          tester.testTextInput.updateEditingValue(
            _editingValue('AB', selectionOffset: 2),
          );
          await tester.pump();
          terminalOutput.clear();

          controller
            ..debugHandleAndroidImeKey(
              TerminalKey.backspace,
              TerminalKeyEventType.press,
            )
            ..debugHandleAndroidImeKey(
              TerminalKey.backspace,
              TerminalKeyEventType.release,
            );
          tester.testTextInput.updateEditingValue(
            _editingValue('x\ny', selectionOffset: 3),
          );
          await tester.pump();

          expect(terminalOutput, <String>['\x7f']);
          expect(
            _terminalTextInputClient(tester).currentTextEditingValue,
            _editingValue('A', selectionOffset: 1),
          );

          tester.testTextInput.updateEditingValue(
            _editingValue('AC', selectionOffset: 2),
          );
          await tester.pump();

          expect(terminalOutput, <String>['\x7f', 'C']);
        } finally {
          if (harness != null) {
            await disposeTerminalInputHarness(tester, harness);
          }
          controller.dispose();
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets('Android composing IME Backspace sends raw DEL immediately', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final controller = TerminalTextInputHandlerController();
      TerminalInputHarness? harness;

      try {
        harness = await pumpTerminalInputHarness(
          tester,
          manageFocus: false,
          initialTerminalOutput: '\x1b[>1u',
          controller: controller,
        );
        final terminalOutput = harness.terminalOutput;

        tester.testTextInput.updateEditingValue(
          _editingValue('CC', selectionOffset: 2),
        );
        await tester.pump();
        tester.testTextInput.updateEditingValue(
          _editingValue(
            'CC',
            selectionOffset: 2,
            composing: const TextRange(start: 0, end: 2),
          ),
        );
        await tester.pump();
        terminalOutput.clear();

        controller.debugHandleAndroidImeKey(
          TerminalKey.backspace,
          TerminalKeyEventType.press,
        );
        await tester.pump();

        expect(terminalOutput, <String>['\x7f']);

        tester.testTextInput.updateEditingValue(
          _editingValue(
            'C',
            selectionOffset: 1,
            composing: const TextRange(start: 0, end: 1),
          ),
        );
        await tester.pump();

        expect(terminalOutput, <String>['\x7f']);

        controller.debugHandleAndroidImeKey(
          TerminalKey.backspace,
          TerminalKeyEventType.release,
        );
      } finally {
        if (harness != null) {
          await disposeTerminalInputHarness(tester, harness);
        }
        controller.dispose();
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('toolbar modifier applies to composing Android IME Backspace', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      var ctrlActive = true;
      final controller = TerminalTextInputHandlerController();
      TerminalInputHarness? harness;

      try {
        harness = await pumpTerminalInputHarness(
          tester,
          manageFocus: false,
          initialTerminalOutput: '\x1b[>1u',
          resolveTerminalKeyModifiers: () =>
              (ctrl: ctrlActive, alt: false, shift: false),
          consumeTerminalKeyModifiers: () => ctrlActive = false,
          controller: controller,
        );
        final terminalOutput = harness.terminalOutput;

        tester.testTextInput.updateEditingValue(
          _editingValue('CC', selectionOffset: 2),
        );
        await tester.pump();
        tester.testTextInput.updateEditingValue(
          _editingValue(
            'CC',
            selectionOffset: 2,
            composing: const TextRange(start: 0, end: 2),
          ),
        );
        await tester.pump();
        terminalOutput.clear();

        controller.debugHandleAndroidImeKey(
          TerminalKey.backspace,
          TerminalKeyEventType.press,
        );
        await tester.pump();

        expect(terminalOutput, <String>['\x1b[127;5u']);
        expect(ctrlActive, isFalse);

        tester.testTextInput.updateEditingValue(
          _editingValue(
            'C',
            selectionOffset: 1,
            composing: const TextRange(start: 0, end: 1),
          ),
        );
        await tester.pump();

        expect(terminalOutput, <String>['\x1b[127;5u']);

        controller.debugHandleAndroidImeKey(
          TerminalKey.backspace,
          TerminalKeyEventType.release,
        );
      } finally {
        if (harness != null) {
          await disposeTerminalInputHarness(tester, harness);
        }
        controller.dispose();
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
      'toolbar modifier keeps Android IME Backspace on hardware path',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        var ctrlActive = true;
        final controller = TerminalTextInputHandlerController();
        TerminalInputHarness? harness;

        try {
          harness = await pumpTerminalInputHarness(
            tester,
            manageFocus: false,
            initialTerminalOutput: '\x1b[>11u',
            resolveTerminalKeyModifiers: () =>
                (ctrl: ctrlActive, alt: false, shift: false),
            consumeTerminalKeyModifiers: () => ctrlActive = false,
            controller: controller,
          );
          final terminalOutput = harness.terminalOutput;

          tester.testTextInput.updateEditingValue(
            _editingValue('CC', selectionOffset: 2),
          );
          await tester.pump();
          terminalOutput.clear();

          controller
            ..debugHandleAndroidImeKey(
              TerminalKey.backspace,
              TerminalKeyEventType.press,
            )
            ..debugHandleAndroidImeKey(
              TerminalKey.backspace,
              TerminalKeyEventType.repeat,
            )
            ..debugHandleAndroidImeKey(
              TerminalKey.backspace,
              TerminalKeyEventType.release,
            );
          await tester.pump();

          expect(terminalOutput, <String>[
            '\x1b[127;5u',
            '\x1b[127;5:2u',
            '\x1b[127;5:3u',
          ]);
          expect(ctrlActive, isFalse);

          tester.testTextInput.updateEditingValue(
            _editingValue('', selectionOffset: 0),
          );
          await tester.pump();

          expect(terminalOutput, <String>[
            '\x1b[127;5u',
            '\x1b[127;5:2u',
            '\x1b[127;5:3u',
          ]);
        } finally {
          if (harness != null) {
            await disposeTerminalInputHarness(tester, harness);
          }
          controller.dispose();
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets('physical shifted text keeps Kitty hardware key encoding', (
      tester,
    ) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add)
        ..write('\x1b[>9u');
      final focusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              deleteDetection: true,
              manageFocus: false,
              child: Focus(
                focusNode: focusNode,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      expect(tester.testTextInput.isVisible, isTrue);

      HardwareKeyboard.instance.handleKeyEvent(
        const KeyDownEvent(
          logicalKey: LogicalKeyboardKey.shiftLeft,
          physicalKey: PhysicalKeyboardKey.shiftLeft,
          timeStamp: Duration.zero,
        ),
      );
      HardwareKeyboard.instance.handleKeyEvent(
        const KeyDownEvent(
          logicalKey: LogicalKeyboardKey.comma,
          physicalKey: PhysicalKeyboardKey.comma,
          character: '<',
          timeStamp: Duration.zero,
        ),
      );
      HardwareKeyboard.instance.handleKeyEvent(
        const KeyUpEvent(
          logicalKey: LogicalKeyboardKey.comma,
          physicalKey: PhysicalKeyboardKey.comma,
          timeStamp: Duration.zero,
        ),
      );
      HardwareKeyboard.instance.handleKeyEvent(
        const KeyUpEvent(
          logicalKey: LogicalKeyboardKey.shiftLeft,
          physicalKey: PhysicalKeyboardKey.shiftLeft,
          timeStamp: Duration.zero,
        ),
      );
      await tester.pump();

      expect(terminalOutput.join(), contains('\x1b[44;2u'));

      focusNode.dispose();
    });

    testWidgets('keeps ctrl combos working while IME composition is active', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
      );

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Ba',
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange(start: 2, end: 3),
        ),
      );
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(harness.terminalOutput.join(), '\u0003');

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets('notifies when soft-keyboard input is sent to the terminal', (
      tester,
    ) async {
      final terminal = Terminal();
      final focusNode = FocusNode();
      var callbackCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              deleteDetection: true,
              onUserInput: () => callbackCount++,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bhello',
          selection: TextSelection.collapsed(offset: 7),
        ),
      );
      await tester.pump();

      expect(callbackCount, 1);

      focusNode.dispose();
    });

    testWidgets(
      'ignores a stale newline edit when the IME action arrives first',
      (tester) async {
        var reviewCount = 0;

        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          onReviewInsertedText: (_) async {
            reviewCount++;
            return true;
          },
        );

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho hi',
            selection: TextSelection.collapsed(offset: 9),
          ),
        );
        await tester.pump();

        harness.terminalOutput.clear();

        _terminalTextInputClient(tester).performAction(TextInputAction.newline);
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho hi\n',
            selection: TextSelection.collapsed(offset: 10),
          ),
        );
        await tester.pump();

        expect(harness.terminalOutput.join(), '\r');
        expect(reviewCount, 0);
        expect(
          _terminalTextInputClient(tester).currentTextEditingValue,
          const TextEditingValue(
            text: '\u200B\u200B',
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'accepts new text after swallowing an action-first newline commit',
      (tester) async {
        var reviewCount = 0;

        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          onReviewInsertedText: (_) async {
            reviewCount++;
            return true;
          },
        );

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho hi',
            selection: TextSelection.collapsed(offset: 9),
          ),
        );
        await tester.pump();

        harness.terminalOutput.clear();

        _terminalTextInputClient(tester).performAction(TextInputAction.newline);
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho hi\nn',
            selection: TextSelection.collapsed(offset: 11),
          ),
        );
        await tester.pump();

        expect(harness.terminalOutput.join(), '\rn');
        expect(reviewCount, 0);
        expect(
          _terminalTextInputClient(tester).currentTextEditingValue,
          const TextEditingValue(
            text: '\u200B\u200Bn',
            selection: TextSelection.collapsed(offset: 3),
          ),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'commits active IME composition before an action-first newline',
      (tester) async {
        final harness = await pumpTerminalInputHarness(tester);
        const committedPrefix = 'git reset --';
        const command = '${committedPrefix}hard';

        tester.testTextInput.updateEditingValue(
          _editingValue(
            committedPrefix,
            selectionOffset: committedPrefix.length,
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            command,
            selectionOffset: command.length,
            composing: const TextRange(
              start: committedPrefix.length,
              end: command.length,
            ),
          ),
        );
        await tester.pump();

        expect(harness.terminalOutput.join(), committedPrefix);

        _terminalTextInputClient(tester).performAction(TextInputAction.newline);
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('$command\n', selectionOffset: command.length + 1),
        );
        await tester.pump();

        expect(
          harness.terminalOutput.join(),
          '$command${_terminalKeyOutput(TerminalKey.enter)}',
        );
        expect(
          _terminalTextInputClient(tester).currentTextEditingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(
              offset: _deleteDetectionMarker.length,
            ),
          ),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'preserves action modifiers while committing active IME composition',
      (tester) async {
        var shiftActive = true;
        var consumeCount = 0;
        final harness = await pumpTerminalInputHarness(
          tester,
          resolveTerminalKeyModifiers: () =>
              (ctrl: false, alt: false, shift: shiftActive),
          consumeTerminalKeyModifiers: () {
            consumeCount++;
            shiftActive = false;
          },
        );
        const committedPrefix = 'echo ';
        const command = '${committedPrefix}hi';

        tester.testTextInput.updateEditingValue(
          _editingValue(
            committedPrefix,
            selectionOffset: committedPrefix.length,
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            command,
            selectionOffset: command.length,
            composing: const TextRange(
              start: committedPrefix.length,
              end: command.length,
            ),
          ),
        );
        await tester.pump();

        _terminalTextInputClient(tester).performAction(TextInputAction.newline);
        await tester.pump();

        expect(
          harness.terminalOutput.join(),
          '$command$_terminalShiftEnterNewlineInput',
        );
        expect(consumeCount, 1);
        expect(shiftActive, isFalse);

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'does not submit when reviewed IME composition is rejected on Enter',
      (tester) async {
        final decision = Completer<bool>();
        var reviewCount = 0;
        final harness = await pumpTerminalInputHarness(
          tester,
          onReviewInsertedText: (_) {
            reviewCount++;
            return decision.future;
          },
        );
        const command = r'echo $(id)';

        tester.testTextInput.updateEditingValue(
          _editingValue(
            command,
            selectionOffset: command.length,
            composing: const TextRange(start: 0, end: command.length),
          ),
        );
        await tester.pump();

        _terminalTextInputClient(tester).performAction(TextInputAction.newline);
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('$command\n', selectionOffset: command.length + 1),
        );
        await tester.pump();

        expect(reviewCount, 1);
        expect(harness.terminalOutput, isEmpty);

        decision.complete(false);
        await tester.pump();
        await tester.pump();

        expect(reviewCount, 1);
        expect(harness.terminalOutput, isEmpty);
        expect(
          _terminalTextInputClient(tester).currentTextEditingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(
              offset: _deleteDetectionMarker.length,
            ),
          ),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'preserves reviewed Enter while coalescing the IME newline follow-up',
      (tester) async {
        final decision = Completer<bool>();
        var reviewCount = 0;
        var shiftActive = true;
        var consumeCount = 0;
        final harness = await pumpTerminalInputHarness(
          tester,
          onReviewInsertedText: (_) {
            reviewCount++;
            return decision.future;
          },
          resolveTerminalKeyModifiers: () =>
              (ctrl: false, alt: false, shift: shiftActive),
          consumeTerminalKeyModifiers: () {
            consumeCount++;
            shiftActive = false;
          },
        );
        const command = r'echo $(id)';

        tester.testTextInput.updateEditingValue(
          _editingValue(
            command,
            selectionOffset: command.length,
            composing: const TextRange(start: 0, end: command.length),
          ),
        );
        await tester.pump();

        _terminalTextInputClient(tester).performAction(TextInputAction.newline);
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('$command\n', selectionOffset: command.length + 1),
        );
        await tester.pump();

        expect(reviewCount, 1);
        expect(harness.terminalOutput, isEmpty);

        decision.complete(true);
        await tester.pump();
        await tester.pump();

        expect(reviewCount, 1);
        expect(
          harness.terminalOutput.join(),
          '$command$_terminalShiftEnterNewlineInput',
        );
        expect(consumeCount, 1);
        expect(shiftActive, isFalse);

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets('defers edit-first Enter until command review approves', (
      tester,
    ) async {
      final decision = Completer<bool>();
      var reviewCount = 0;
      final harness = await pumpTerminalInputHarness(
        tester,
        onReviewInsertedText: (_) {
          reviewCount++;
          return decision.future;
        },
      );
      const command = r'echo $(id)';

      tester.testTextInput.updateEditingValue(
        _editingValue(command, selectionOffset: command.length),
      );
      await tester.pump();

      _terminalTextInputClient(tester).performAction(TextInputAction.newline);
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        _editingValue('$command\n', selectionOffset: command.length + 1),
      );
      await tester.pump();

      expect(reviewCount, 1);
      expect(harness.terminalOutput, isEmpty);

      decision.complete(true);
      await tester.pump();
      await tester.pump();

      expect(reviewCount, 1);
      expect(
        harness.terminalOutput.join(),
        '$command${_terminalKeyOutput(TerminalKey.enter)}',
      );

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'does not submit edit-first Enter when command review rejects',
      (tester) async {
        final decision = Completer<bool>();
        var reviewCount = 0;
        final harness = await pumpTerminalInputHarness(
          tester,
          onReviewInsertedText: (_) {
            reviewCount++;
            return decision.future;
          },
        );
        const command = r'echo $(id)';

        tester.testTextInput.updateEditingValue(
          _editingValue(command, selectionOffset: command.length),
        );
        await tester.pump();

        _terminalTextInputClient(tester).performAction(TextInputAction.newline);
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('$command\n', selectionOffset: command.length + 1),
        );
        await tester.pump();

        decision.complete(false);
        await tester.pump();
        await tester.pump();

        expect(reviewCount, 1);
        expect(harness.terminalOutput, isEmpty);

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets('stale review does not clear a newer composing Enter action', (
      tester,
    ) async {
      final decisions = <Completer<bool>>[];
      var shiftActive = true;
      var consumeCount = 0;
      final harness = await pumpTerminalInputHarness(
        tester,
        onReviewInsertedText: (_) {
          final decision = Completer<bool>();
          decisions.add(decision);
          return decision.future;
        },
        resolveTerminalKeyModifiers: () =>
            (ctrl: false, alt: false, shift: shiftActive),
        consumeTerminalKeyModifiers: () {
          consumeCount++;
          shiftActive = false;
        },
      );
      const staleCommand = r'echo $(id)';
      const currentCommand = r'printf $(pwd)';

      tester.testTextInput.updateEditingValue(
        _editingValue(staleCommand, selectionOffset: staleCommand.length),
      );
      await tester.pump();
      expect(decisions, hasLength(1));

      tester.testTextInput.updateEditingValue(
        _editingValue(
          currentCommand,
          selectionOffset: currentCommand.length,
          composing: const TextRange(start: 0, end: currentCommand.length),
        ),
      );
      await tester.pump();

      _terminalTextInputClient(tester).performAction(TextInputAction.newline);
      await tester.pump();

      decisions.first.complete(true);
      await tester.pump();
      await tester.pump();
      expect(decisions, hasLength(2));

      tester.testTextInput.updateEditingValue(
        _editingValue(
          '$currentCommand\n',
          selectionOffset: currentCommand.length + 1,
        ),
      );
      await tester.pump();

      decisions.last.complete(true);
      await tester.pump();
      await tester.pump();

      expect(
        harness.terminalOutput.join(),
        '$currentCommand$_terminalShiftEnterNewlineInput',
      );
      expect(consumeCount, 1);
      expect(shiftActive, isFalse);

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'reviewed newline uses captured modifiers without suppressing next Enter',
      (tester) async {
        final decision = Completer<bool>();
        var shiftActive = true;
        var consumeCount = 0;
        final harness = await pumpTerminalInputHarness(
          tester,
          onReviewInsertedText: (_) => decision.future,
          resolveTerminalKeyModifiers: () =>
              (ctrl: false, alt: false, shift: shiftActive),
          consumeTerminalKeyModifiers: () {
            consumeCount++;
            shiftActive = false;
          },
        );
        const command = r'echo $(id)';

        tester.testTextInput.updateEditingValue(
          _editingValue('$command\n', selectionOffset: command.length + 1),
        );
        await tester.pump();

        _terminalTextInputClient(tester).performAction(TextInputAction.newline);
        await tester.pump();

        decision.complete(true);
        await tester.pump();
        await tester.pump();

        expect(
          harness.terminalOutput.join(),
          '$command$_terminalShiftEnterNewlineInput',
        );
        expect(consumeCount, 1);

        _terminalTextInputClient(tester).performAction(TextInputAction.newline);
        await tester.pump();

        expect(
          harness.terminalOutput.join(),
          '$command$_terminalShiftEnterNewlineInput'
          '${_terminalKeyOutput(TerminalKey.enter)}',
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets('rejection preserves text typed after the pending newline', (
      tester,
    ) async {
      final decision = Completer<bool>();
      final harness = await pumpTerminalInputHarness(
        tester,
        onReviewInsertedText: (_) => decision.future,
      );
      const command = r'echo $(id)';
      const followUpText = 'next';

      tester.testTextInput.updateEditingValue(
        _editingValue(
          command,
          selectionOffset: command.length,
          composing: const TextRange(start: 0, end: command.length),
        ),
      );
      await tester.pump();

      _terminalTextInputClient(tester).performAction(TextInputAction.newline);
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        _editingValue(
          '$command\n$followUpText',
          selectionOffset: command.length + 1 + followUpText.length,
          composing: const TextRange(
            start: command.length + 1,
            end: command.length + 1 + followUpText.length,
          ),
        ),
      );
      await tester.pump();

      decision.complete(false);
      await tester.pump();
      await tester.pump();

      expect(harness.terminalOutput, isEmpty);

      tester.testTextInput.updateEditingValue(
        _editingValue(followUpText, selectionOffset: followUpText.length),
      );
      await tester.pump();

      expect(harness.terminalOutput.join(), followUpText);
      expect(
        _terminalTextInputClient(tester).currentTextEditingValue,
        const TextEditingValue(
          text: '$_deleteDetectionMarker$followUpText',
          selection: TextSelection.collapsed(
            offset: _deleteDetectionMarker.length + followUpText.length,
          ),
        ),
      );

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'canonicalizes a previous stale Enter prefix before replaying follow-up',
      (tester) async {
        final decision = Completer<bool>();
        var reviewCount = 0;
        final harness = await pumpTerminalInputHarness(
          tester,
          onReviewInsertedText: (_) {
            reviewCount++;
            return decision.future;
          },
        );
        const previousCommand = 'echo ready';
        const currentCommand = r'echo $(id)';
        const stalePrefix = '$previousCommand\n';

        tester.testTextInput.updateEditingValue(
          _editingValue(
            previousCommand,
            selectionOffset: previousCommand.length,
          ),
        );
        await tester.pump();
        _terminalTextInputClient(tester).performAction(TextInputAction.newline);
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            '$stalePrefix$currentCommand',
            selectionOffset: stalePrefix.length + currentCommand.length,
            composing: const TextRange(
              start: stalePrefix.length,
              end: stalePrefix.length + currentCommand.length,
            ),
          ),
        );
        await tester.pump();

        _terminalTextInputClient(tester).performAction(TextInputAction.newline);
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            '$stalePrefix$currentCommand\n',
            selectionOffset: stalePrefix.length + currentCommand.length + 1,
          ),
        );
        await tester.pump();

        expect(reviewCount, 1);
        decision.complete(true);
        await tester.pump();
        await tester.pump();

        expect(
          harness.terminalOutput.join(),
          '$previousCommand${_terminalKeyOutput(TerminalKey.enter)}'
          '$currentCommand${_terminalKeyOutput(TerminalKey.enter)}',
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets('locked Alt preserves composed input and deferred Enter', (
      tester,
    ) async {
      final toolbarController = KeyboardToolbarController()..lockAlt();
      addTearDown(toolbarController.dispose);
      final harness = await pumpTerminalInputHarness(
        tester,
        resolveTerminalKeyModifiers: () => (
          ctrl: toolbarController.isCtrlActive,
          alt: toolbarController.isAltActive,
          shift: toolbarController.isShiftActive,
        ),
        consumeTerminalKeyModifiers: toolbarController.consumeOneShot,
        applyTerminalTextInputModifiers:
            toolbarController.applySystemKeyboardModifiers,
        hasActiveToolbarModifier: () =>
            toolbarController.isCtrlActive || toolbarController.isAltActive,
      );

      tester.testTextInput.updateEditingValue(
        _editingValue(
          'x',
          selectionOffset: 1,
          composing: const TextRange(start: 0, end: 1),
        ),
      );
      await tester.pump();

      _terminalTextInputClient(tester).performAction(TextInputAction.newline);
      await tester.pump();

      expect(
        harness.terminalOutput.join(),
        // Alt applies to the composed character; Enter+Alt is meta-sends-escape.
        '\x1bx\x1b\r',
      );
      expect(toolbarController.isAltActive, isTrue);

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets('edit-first approval preserves next-line suffix input', (
      tester,
    ) async {
      final decision = Completer<bool>();
      var reviewCount = 0;
      final harness = await pumpTerminalInputHarness(
        tester,
        onReviewInsertedText: (_) {
          reviewCount++;
          return decision.future;
        },
      );
      const command = r'echo $(id)';
      const followUpText = 'next';

      tester.testTextInput.updateEditingValue(
        _editingValue('$command\n', selectionOffset: command.length + 1),
      );
      await tester.pump();

      _terminalTextInputClient(tester).performAction(TextInputAction.newline);
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        _editingValue(
          '$command\n$followUpText',
          selectionOffset: command.length + 1 + followUpText.length,
          composing: const TextRange(
            start: command.length + 1,
            end: command.length + 1 + followUpText.length,
          ),
        ),
      );
      await tester.pump();

      expect(reviewCount, 1);
      decision.complete(true);
      await tester.pump();
      await tester.pump();

      expect(
        harness.terminalOutput.join(),
        '$command${_terminalKeyOutput(TerminalKey.enter)}',
      );

      tester.testTextInput.updateEditingValue(
        _editingValue(followUpText, selectionOffset: followUpText.length),
      );
      await tester.pump();

      expect(
        harness.terminalOutput.join(),
        '$command${_terminalKeyOutput(TerminalKey.enter)}$followUpText',
      );
      expect(
        _terminalTextInputClient(tester).currentTextEditingValue,
        const TextEditingValue(
          text: '$_deleteDetectionMarker$followUpText',
          selection: TextSelection.collapsed(
            offset: _deleteDetectionMarker.length + followUpText.length,
          ),
        ),
      );

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'exact stale composing text does not block later Enter actions',
      (tester) async {
        final harness = await pumpTerminalInputHarness(tester);
        const command = 'echo ready';

        tester.testTextInput.updateEditingValue(
          _editingValue(command, selectionOffset: command.length),
        );
        await tester.pump();
        _terminalTextInputClient(tester).performAction(TextInputAction.newline);
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            command,
            selectionOffset: command.length,
            composing: const TextRange(start: 0, end: command.length),
          ),
        );
        await tester.pump();

        _terminalTextInputClient(tester).performAction(TextInputAction.newline);
        await tester.pump();
        _terminalTextInputClient(tester).performAction(TextInputAction.newline);
        await tester.pump();

        expect(
          harness.terminalOutput.join(),
          '$command${_terminalKeyOutput(TerminalKey.enter)}'
          '${_terminalKeyOutput(TerminalKey.enter)}'
          '${_terminalKeyOutput(TerminalKey.enter)}',
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'captures composing next-line input while command review is pending',
      (tester) async {
        final decision = Completer<bool>();
        var reviewCount = 0;
        final harness = await pumpTerminalInputHarness(
          tester,
          onReviewInsertedText: (_) {
            reviewCount++;
            return decision.future;
          },
        );
        const command = r'echo $(id)';
        const followUpText = 'next';

        tester.testTextInput.updateEditingValue(
          _editingValue(
            command,
            selectionOffset: command.length,
            composing: const TextRange(start: 0, end: command.length),
          ),
        );
        await tester.pump();
        _terminalTextInputClient(tester).performAction(TextInputAction.newline);
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            '$command\n$followUpText',
            selectionOffset: command.length + 1 + followUpText.length,
            composing: const TextRange(
              start: command.length + 1,
              end: command.length + 1 + followUpText.length,
            ),
          ),
        );
        await tester.pump();

        tester.testTextInput.log.clear();
        decision.complete(true);
        await tester.pump();
        await tester.pump();

        expect(reviewCount, 1);
        expect(
          harness.terminalOutput.join(),
          '$command${_terminalKeyOutput(TerminalKey.enter)}',
        );

        tester.testTextInput.updateEditingValue(
          _editingValue(followUpText, selectionOffset: followUpText.length),
        );
        await tester.pump();

        expect(
          harness.terminalOutput.join(),
          '$command${_terminalKeyOutput(TerminalKey.enter)}$followUpText',
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets('multiline composition still sends the final deferred Enter', (
      tester,
    ) async {
      final decision = Completer<bool>();
      var shiftActive = true;
      final harness = await pumpTerminalInputHarness(
        tester,
        onReviewInsertedText: (_) => decision.future,
        resolveTerminalKeyModifiers: () =>
            (ctrl: false, alt: false, shift: shiftActive),
        consumeTerminalKeyModifiers: () => shiftActive = false,
      );
      const command = 'printf one\nprintf two';

      tester.testTextInput.updateEditingValue(
        _editingValue(
          command,
          selectionOffset: command.length,
          composing: const TextRange(start: 0, end: command.length),
        ),
      );
      await tester.pump();
      _terminalTextInputClient(tester).performAction(TextInputAction.newline);
      await tester.pump();

      decision.complete(true);
      await tester.pump();
      await tester.pump();

      expect(
        harness.terminalOutput.join(),
        'printf one${_terminalKeyOutput(TerminalKey.enter)}'
        'printf two$_terminalShiftEnterNewlineInput',
      );

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'trailing composed newline does not consume the deferred Enter',
      (tester) async {
        var shiftActive = true;
        final harness = await pumpTerminalInputHarness(
          tester,
          resolveTerminalKeyModifiers: () =>
              (ctrl: false, alt: false, shift: shiftActive),
          consumeTerminalKeyModifiers: () => shiftActive = false,
        );
        const command = 'printf one\n';

        tester.testTextInput.updateEditingValue(
          _editingValue(
            command,
            selectionOffset: command.length,
            composing: const TextRange(start: 0, end: command.length),
          ),
        );
        await tester.pump();
        _terminalTextInputClient(tester).performAction(TextInputAction.newline);
        await tester.pump();

        expect(
          harness.terminalOutput.join(),
          'printf one${_terminalKeyOutput(TerminalKey.enter)}'
          '$_terminalShiftEnterNewlineInput',
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'trailing-newline composition replays only next-line suffix input',
      (tester) async {
        final decision = Completer<bool>();
        final harness = await pumpTerminalInputHarness(
          tester,
          onReviewInsertedText: (_) => decision.future,
        );
        const command = 'printf one\n';
        const followUpText = 'next';

        tester.testTextInput.updateEditingValue(
          _editingValue(
            command,
            selectionOffset: command.length,
            composing: const TextRange(start: 0, end: command.length),
          ),
        );
        await tester.pump();
        _terminalTextInputClient(tester).performAction(TextInputAction.newline);
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            '$command$followUpText',
            selectionOffset: command.length + followUpText.length,
            composing: const TextRange(
              start: command.length,
              end: command.length + followUpText.length,
            ),
          ),
        );
        await tester.pump();

        decision.complete(true);
        await tester.pump();
        await tester.pump();

        expect(
          harness.terminalOutput.join(),
          'printf one${_terminalKeyOutput(TerminalKey.enter)}'
          '${_terminalKeyOutput(TerminalKey.enter)}',
        );
        expect(
          _setEditingStateStates(
            tester.testTextInput.log,
            stripTerminalMarker: true,
          ).last,
          const (
            text: followUpText,
            selectionBase: followUpText.length,
            selectionExtent: followUpText.length,
            composingBase: 0,
            composingExtent: followUpText.length,
          ),
        );

        tester.testTextInput.updateEditingValue(
          _editingValue(followUpText, selectionOffset: followUpText.length),
        );
        await tester.pump();

        expect(
          harness.terminalOutput.join(),
          'printf one${_terminalKeyOutput(TerminalKey.enter)}'
          '${_terminalKeyOutput(TerminalKey.enter)}$followUpText',
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets('opens the keyboard after a touch tap', (tester) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
      );

      expect(harness.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      tester.testTextInput.hide();
      await tester.pump();

      expect(tester.testTextInput.isVisible, isFalse);

      final target =
          tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
          const Offset(40, 40);
      await tester.tapAt(target);
      await tester.pump();

      expect(harness.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'opens the keyboard after a touch tap when focus keyboard is disabled',
      (tester) async {
        final terminal = Terminal();
        final focusNode = FocusNode();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                deleteDetection: true,
                showKeyboardOnFocus: false,
                child: const SizedBox.expand(key: ValueKey('terminal-child')),
              ),
            ),
          ),
        );

        await tester.pump();

        expect(focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isFalse);

        final target =
            tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
            const Offset(40, 40);
        await tester.tapAt(target);
        await tester.pump();

        expect(focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);

        focusNode.dispose();
      },
    );

    testWidgets(
      'does not reopen the keyboard when the platform closes it while focused',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
        );

        expect(harness.focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);

        tester.testTextInput.log.clear();
        (tester.state(find.byType(TerminalTextInputHandler)) as TextInputClient)
            .connectionClosed();
        await tester.pump();

        expect(harness.focusNode.hasFocus, isTrue);
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.show',
          ),
          isEmpty,
        );
        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets('does not open the keyboard after a touch long press', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
      );

      expect(harness.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      tester.testTextInput.hide();
      await tester.pump();

      expect(tester.testTextInput.isVisible, isFalse);

      final target =
          tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
          const Offset(40, 40);
      final gesture = await tester.createGesture();
      await gesture.down(target, timeStamp: const Duration(seconds: 1));
      await tester.pump(terminalKeyboardTapLongPressTimeout);
      await gesture.up(
        timeStamp:
            const Duration(seconds: 1) + terminalKeyboardTapLongPressTimeout,
      );
      await tester.pump();

      expect(harness.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'keeps the keyboard visible when touch becomes selection intent',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
        );

        expect(harness.focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);

        final target =
            tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
            const Offset(40, 40);
        final gesture = await tester.createGesture();
        await gesture.down(target, timeStamp: const Duration(seconds: 1));
        await tester.pump(terminalKeyboardTapLongPressTimeout);

        expect(harness.focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);

        await gesture.up(
          timeStamp:
              const Duration(seconds: 1) + terminalKeyboardTapLongPressTimeout,
        );
        await tester.pump();

        expect(tester.testTextInput.isVisible, isTrue);

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'keeps the keyboard visible when a held touch starts scrolling',
      (tester) async {
        final harness = await pumpTerminalInputHarness(tester);

        expect(harness.focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);

        final target =
            tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
            const Offset(40, 40);
        final gesture = await tester.createGesture();
        await gesture.down(target, timeStamp: const Duration(seconds: 1));
        await tester.pump();
        await gesture.moveBy(
          const Offset(0, 80),
          timeStamp: const Duration(milliseconds: 1100),
        );
        await tester.pump(terminalKeyboardTapLongPressTimeout);

        expect(tester.testTextInput.isVisible, isTrue);

        await gesture.up(
          timeStamp:
              const Duration(seconds: 1) + terminalKeyboardTapLongPressTimeout,
        );
        await tester.pump();

        expect(tester.testTextInput.isVisible, isTrue);

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets('keeps the keyboard visible during held multitouch', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(tester);

      expect(harness.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      final target =
          tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
          const Offset(40, 40);
      final firstGesture = await tester.createGesture();
      final secondGesture = await tester.createGesture();
      await firstGesture.down(target, timeStamp: const Duration(seconds: 1));
      await tester.pump();
      await secondGesture.down(
        target + const Offset(60, 0),
        timeStamp: const Duration(milliseconds: 1010),
      );
      await tester.pump(terminalKeyboardTapLongPressTimeout);

      expect(tester.testTextInput.isVisible, isTrue);

      await secondGesture.up(timeStamp: const Duration(milliseconds: 1510));
      await firstGesture.up(timeStamp: const Duration(milliseconds: 1520));
      await tester.pump();

      expect(tester.testTextInput.isVisible, isTrue);

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets('does not open the keyboard after a touch drag', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
      );

      expect(harness.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      tester.testTextInput.hide();
      await tester.pump();

      expect(tester.testTextInput.isVisible, isFalse);

      final gesture = await tester.startGesture(
        tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
            const Offset(40, 40),
      );
      await tester.pump();
      await gesture.moveBy(const Offset(0, 80));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(harness.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets('does not open the keyboard after a touch tap when read only', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
        readOnly: true,
      );

      expect(harness.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);

      final target =
          tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
          const Offset(40, 40);
      await tester.tapAt(target);
      await tester.pump();

      expect(harness.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'does not open the keyboard after a touch tap when tapToShowKeyboard '
      'is false',
      (tester) async {
        final terminal = Terminal();
        final focusNode = FocusNode();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                deleteDetection: true,
                tapToShowKeyboard: false,
                child: const SizedBox.expand(key: ValueKey('terminal-child')),
              ),
            ),
          ),
        );

        // The handler uses autofocus: true, which triggers _onFocusChange.
        // With tapToShowKeyboard off, the connection is attached but not shown.
        await tester.pump();

        expect(focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isFalse);

        final target =
            tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
            const Offset(40, 40);
        await tester.tapAt(target);
        await tester.pump();

        expect(tester.testTextInput.isVisible, isFalse);

        focusNode.dispose();
      },
    );

    testWidgets('does not reopen the keyboard on focus restoration when '
        'tapToShowKeyboard is false', (tester) async {
      final terminal = Terminal();
      final focusNode = FocusNode();
      final outerFocusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Focus(
                  focusNode: outerFocusNode,
                  child: const SizedBox(
                    width: 50,
                    height: 50,
                    key: ValueKey('other'),
                  ),
                ),
                Expanded(
                  child: TerminalTextInputHandler(
                    terminal: terminal,
                    focusNode: focusNode,
                    deleteDetection: true,
                    tapToShowKeyboard: false,
                    child: const SizedBox.expand(
                      key: ValueKey('terminal-child'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      await tester.pump();
      expect(focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);

      // Move focus away from the terminal.
      outerFocusNode.requestFocus();
      await tester.pump();
      expect(focusNode.hasFocus, isFalse);

      // Restore focus to the terminal (simulates popup menu close or
      // programmatic focus restore).  Keyboard must stay hidden.
      focusNode.requestFocus();
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);

      focusNode.dispose();
      outerFocusNode.dispose();
    });

    testWidgets(
      'requestKeyboard still shows keyboard when tapToShowKeyboard is false',
      (tester) async {
        final terminal = Terminal();
        final focusNode = FocusNode();
        final controller = TerminalTextInputHandlerController();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                controller: controller,
                deleteDetection: true,
                tapToShowKeyboard: false,
                child: const SizedBox.expand(key: ValueKey('terminal-child')),
              ),
            ),
          ),
        );

        await tester.pump();
        expect(focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isFalse);

        // Explicit requestKeyboard (the toolbar button path) must always work.
        controller.requestKeyboard();
        await tester.pump();

        expect(tester.testTextInput.isVisible, isTrue);

        focusNode.dispose();
      },
    );

    testWidgets('routes hardware keys when the child owns focus', (
      tester,
    ) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);
      final focusNode = FocusNode();
      final otherFocusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Focus(
                  focusNode: otherFocusNode,
                  child: const SizedBox(
                    width: 50,
                    height: 50,
                    key: ValueKey('other-focus-target'),
                  ),
                ),
                Expanded(
                  child: TerminalTextInputHandler(
                    terminal: terminal,
                    focusNode: focusNode,
                    deleteDetection: true,
                    manageFocus: false,
                    child: Focus(
                      focusNode: focusNode,
                      child: const SizedBox.expand(
                        key: ValueKey('terminal-focus-owner'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();

      expect(terminalOutput.join(), _terminalKeyOutput(TerminalKey.arrowLeft));

      terminalOutput.clear();
      otherFocusNode.requestFocus();
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();

      expect(terminalOutput, isEmpty);

      focusNode.dispose();
      otherFocusNode.dispose();
    });

    testWidgets('routes hardware paste shortcuts through the paste callback', (
      tester,
    ) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);
      final focusNode = FocusNode();
      var pasteCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              deleteDetection: true,
              onPasteText: () => pasteCount++,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(pasteCount, 1);
      expect(terminalOutput, isEmpty);

      focusNode.dispose();
    });

    testWidgets('consumes composing hardware keys when the child owns focus', (
      tester,
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
              manageFocus: false,
              child: Focus(
                focusNode: focusNode,
                child: const SizedBox.expand(
                  key: ValueKey('terminal-focus-owner'),
                ),
              ),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        _editingValue(
          'hello',
          selectionOffset: 'hello'.length,
          composing: const TextRange(start: 0, end: 5),
        ),
      );
      await tester.pump();

      final handledKeyDown = await tester.sendKeyDownEvent(
        LogicalKeyboardKey.arrowLeft,
      );
      final handledKeyUp = await tester.sendKeyUpEvent(
        LogicalKeyboardKey.arrowLeft,
      );
      await tester.pump();

      expect(terminalOutput, isEmpty);
      expect(handledKeyDown, isTrue);
      expect(handledKeyUp, isTrue);

      focusNode.dispose();
    });

    testWidgets('does not open the keyboard after a suppressed touch tap', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(tester);

      expect(harness.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      tester.testTextInput.hide();
      await tester.pump();

      expect(tester.testTextInput.isVisible, isFalse);

      harness.controller.suppressNextTouchKeyboardRequest();
      final target =
          tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
          const Offset(40, 40);
      await tester.tapAt(target);
      await tester.pump();

      expect(harness.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);

      await tester.tapAt(target);
      await tester.pump();

      expect(tester.testTextInput.isVisible, isTrue);

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'does not open the keyboard after a multitouch gesture when the last finger stays still',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
        );

        expect(harness.focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);

        tester.testTextInput.hide();
        await tester.pump();

        expect(tester.testTextInput.isVisible, isFalse);

        final origin =
            tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
            const Offset(40, 40);
        final firstGesture = await tester.createGesture(pointer: 1);
        await firstGesture.down(origin);
        await tester.pump();

        final secondGesture = await tester.createGesture(pointer: 2);
        await secondGesture.down(origin + const Offset(20, 0));
        await tester.pump();
        await secondGesture.moveBy(const Offset(0, 80));
        await tester.pump();
        await secondGesture.up();
        await tester.pump();
        await firstGesture.up();
        await tester.pump();

        expect(harness.focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isFalse);

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets('reviews high-risk multi-character IME insertion', (
      tester,
    ) async {
      final decision = Completer<bool>();
      final reviews = <TerminalCommandReview>[];
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
        onReviewInsertedText: (review) {
          reviews.add(review);
          return decision.future;
        },
      );
      final terminalOutput = harness.terminalOutput;

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Becho \$(id)',
          selection: TextSelection.collapsed(offset: 12),
        ),
      );
      await tester.pump();

      expect(reviews, hasLength(1));
      expect(reviews.single.command, r'echo $(id)');
      expect(
        reviews.single.reasons,
        contains(TerminalCommandReviewReason.commandSubstitution),
      );
      expect(terminalOutput, isEmpty);

      decision.complete(true);
      await tester.pump();
      await tester.pump();

      expect(terminalStateFromEvents(terminalOutput), (
        text: r'echo $(id)',
        cursorOffset: r'echo $(id)'.length,
      ));

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'does not review quoted shell-like IME text as suspicious paste',
      (tester) async {
        final reviews = <TerminalCommandReview>[];
        const benignCommand = 'printf "%s" "fish & chips | <html>"';
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          onReviewInsertedText: (review) async {
            reviews.add(review);
            return true;
          },
        );
        final terminalOutput = harness.terminalOutput;

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '$_deleteDetectionMarker$benignCommand',
            selection: TextSelection.collapsed(
              offset: _deleteDetectionMarker.length + benignCommand.length,
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(reviews, isEmpty);
        expect(terminalOutput.join(), benignCommand);

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets('does not review a short swipe-composed word', (tester) async {
      final reviews = <TerminalCommandReview>[];
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
        onReviewInsertedText: (review) async {
          reviews.add(review);
          return true;
        },
      );
      final terminalOutput = harness.terminalOutput;

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '${_deleteDetectionMarker}copilot',
          selection: TextSelection.collapsed(offset: 9),
          composing: TextRange(start: 2, end: 9),
        ),
      );
      await tester.pump();

      expect(reviews, isEmpty);
      expect(terminalOutput, isEmpty);

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '${_deleteDetectionMarker}copilot ',
          selection: TextSelection.collapsed(offset: 10),
        ),
      );
      await tester.pump();

      expect(reviews, isEmpty);
      expect(terminalOutput.join(), 'copilot ');

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets('reviews paste-like keyboard payloads', (tester) async {
      final reviews = <TerminalCommandReview>[];
      final insertedText = List.filled(
        terminalKeyboardPasteLikeInsertionThreshold + 1,
        'a',
      ).join();
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
        onReviewInsertedText: (review) async {
          reviews.add(review);
          return false;
        },
      );
      final terminalOutput = harness.terminalOutput;

      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: '$_deleteDetectionMarker$insertedText',
          selection: TextSelection.collapsed(
            offset: _deleteDetectionMarker.length + insertedText.length,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(reviews, hasLength(1));
      expect(
        reviews.single.reasons,
        contains(TerminalCommandReviewReason.largeKeyboardInsertion),
      );
      expect(terminalOutput, isEmpty);
      expect(
        _terminalTextInputClient(tester).currentTextEditingValue,
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(offset: 2),
        ),
      );

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'reviews a high-risk committed IME payload after composition ends',
      (tester) async {
        final decision = Completer<bool>();
        final reviews = <TerminalCommandReview>[];
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          onReviewInsertedText: (review) {
            reviews.add(review);
            return decision.future;
          },
        );
        final terminalOutput = harness.terminalOutput;

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho \$(id)',
            selection: TextSelection.collapsed(offset: 12),
            composing: TextRange(start: 2, end: 12),
          ),
        );
        await tester.pump();

        expect(reviews, isEmpty);
        expect(terminalOutput, isEmpty);

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho \$(id)',
            selection: TextSelection.collapsed(offset: 12),
          ),
        );
        await tester.pump();

        expect(reviews, hasLength(1));
        expect(reviews.single.command, r'echo $(id)');
        expect(terminalOutput, isEmpty);

        decision.complete(true);
        await tester.pump();
        await tester.pump();

        expect(terminalStateFromEvents(terminalOutput), (
          text: r'echo $(id)',
          cursorOffset: r'echo $(id)'.length,
        ));

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets('does not review harmless IME text with standalone ampersand', (
      tester,
    ) async {
      final reviews = <TerminalCommandReview>[];
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
        onReviewInsertedText: (review) async {
          reviews.add(review);
          return true;
        },
      );
      final terminalOutput = harness.terminalOutput;

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Becho ready & echo done',
          selection: TextSelection.collapsed(offset: 24),
        ),
      );
      await tester.pump();

      expect(reviews, isEmpty);
      expect(terminalOutput.join(), 'echo ready & echo done');

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'reviews a high-risk committed IME payload while keeping its selection',
      (tester) async {
        final decision = Completer<bool>();
        final reviews = <TerminalCommandReview>[];
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          onReviewInsertedText: (review) {
            reviews.add(review);
            return decision.future;
          },
        );
        final terminalOutput = harness.terminalOutput;

        const suspiciousUserText = r'echo $(id)';
        const suspiciousText = '\u200B\u200Becho \$(id)';
        const suspiciousSelection = TextSelection(
          baseOffset: _deleteDetectionMarker.length,
          extentOffset: suspiciousText.length,
        );

        tester.testTextInput.log.clear();
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: suspiciousText,
            selection: suspiciousSelection,
          ),
        );
        await tester.pump();

        expect(reviews, hasLength(1));
        expect(reviews.single.command, suspiciousUserText);
        expect(
          reviews.single.reasons,
          contains(TerminalCommandReviewReason.commandSubstitution),
        );
        expect(terminalOutput, isEmpty);
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          isEmpty,
        );

        decision.complete(true);
        await tester.pump();
        await tester.pump();

        expect(terminalTextFromEvents(terminalOutput), suspiciousUserText);

        final client =
            tester.state(find.byType(TerminalTextInputHandler))
                as TextInputClient;
        expect(
          client.currentTextEditingValue,
          const TextEditingValue(
            text: suspiciousText,
            selection: suspiciousSelection,
          ),
        );
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          isEmpty,
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets('rejects high-risk IME insertion until the user approves', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
        onReviewInsertedText: (_) async => false,
      );
      final terminalOutput = harness.terminalOutput;

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Becho \$(id)',
          selection: TextSelection.collapsed(offset: 12),
        ),
      );
      await tester.pump();
      await tester.pump();

      final client =
          tester.state(find.byType(TerminalTextInputHandler))
              as TextInputClient;
      expect(terminalOutput, isEmpty);
      expect(client.currentTextEditingValue?.text, _deleteDetectionMarker);

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'reviews high-risk IME insertions against the full terminal line context',
      (tester) async {
        final reviews = <TerminalCommandReview>[];
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          onReviewInsertedText: (review) async {
            reviews.add(review);
            return false;
          },
        );
        final terminalOutput = harness.terminalOutput;

        const existingCommand = r'echo $(';
        for (var index = 1; index <= existingCommand.length; index++) {
          final currentCommand = existingCommand.substring(0, index);
          tester.testTextInput.updateEditingValue(
            TextEditingValue(
              text: '$_deleteDetectionMarker$currentCommand',
              selection: TextSelection.collapsed(
                offset: _deleteDetectionMarker.length + currentCommand.length,
              ),
            ),
          );
          await tester.pump();
        }

        reviews.clear();

        const combinedCommand = '${existingCommand}id)';
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '$_deleteDetectionMarker$combinedCommand',
            selection: TextSelection.collapsed(
              offset: _deleteDetectionMarker.length + combinedCommand.length,
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(terminalTextFromEvents(terminalOutput), existingCommand);
        expect(reviews, hasLength(1));
        expect(reviews.single.command, combinedCommand);
        expect(
          reviews.single.reasons,
          contains(TerminalCommandReviewReason.commandSubstitution),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'ignores stale review approvals when a newer editing value arrives',
      (tester) async {
        final decision = Completer<bool>();
        final reviews = <TerminalCommandReview>[];
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          onReviewInsertedText: (review) {
            reviews.add(review);
            return decision.future;
          },
        );
        final terminalOutput = harness.terminalOutput;

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho \$(id)',
            selection: TextSelection.collapsed(offset: 12),
          ),
        );
        await tester.pump();

        expect(reviews, hasLength(1));
        expect(terminalOutput, isEmpty);

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Bls',
            selection: TextSelection.collapsed(offset: 4),
          ),
        );
        await tester.pump();

        expect(reviews, hasLength(1));
        expect(terminalOutput, isEmpty);

        decision.complete(true);
        await tester.pump();
        await tester.pump();

        expect(terminalOutput.join(), 'ls');

        final client =
            tester.state(find.byType(TerminalTextInputHandler))
                as TextInputClient;
        expect(
          client.currentTextEditingValue?.text,
          '${_deleteDetectionMarker}ls',
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'ignores stale review approvals after an external IME buffer clear',
      (tester) async {
        final decision = Completer<bool>();
        final reviews = <TerminalCommandReview>[];
        final harness = await pumpTerminalInputHarness(
          tester,
          onReviewInsertedText: (review) {
            reviews.add(review);
            return decision.future;
          },
        );
        final terminalOutput = harness.terminalOutput;
        final controller = harness.controller;

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho \$(id)',
            selection: TextSelection.collapsed(offset: 12),
          ),
        );
        await tester.pump();

        expect(reviews, hasLength(1));
        expect(terminalOutput, isEmpty);

        controller.clearImeBuffer();
        await tester.pump();

        final client = _terminalTextInputClient(tester);
        expect(client.currentTextEditingValue?.text, _deleteDetectionMarker);

        decision.complete(true);
        await tester.pump();
        await tester.pump();

        expect(terminalOutput, isEmpty);
        expect(client.currentTextEditingValue?.text, _deleteDetectionMarker);

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'trims a swipe-leading space even when a composing update is overwritten in the review queue',
      (tester) async {
        final decision = Completer<bool>();
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          onReviewInsertedText: (_) => decision.future,
        );
        final terminalOutput = harness.terminalOutput;

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho \$(id)',
            selection: TextSelection.collapsed(offset: 12),
          ),
        );
        await tester.pump();

        expect(terminalOutput, isEmpty);

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200B hello',
            selection: TextSelection.collapsed(offset: 8),
            composing: TextRange(start: 2, end: 8),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200B hello',
            selection: TextSelection.collapsed(offset: 8),
          ),
        );
        await tester.pump();

        decision.complete(true);
        await tester.pump();
        await tester.pump();

        expect(terminalTextFromEvents(terminalOutput), 'hello');
        expect(terminalStateFromEvents(terminalOutput), (
          text: 'hello',
          cursorOffset: 'hello'.length,
        ));

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets('reviews high-risk IME insertions after input resets', (
      tester,
    ) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);
      final focusNode = FocusNode();
      final reviews = <TerminalCommandReview>[];
      var readOnly = false;

      Widget buildHandler() => MaterialApp(
        home: Scaffold(
          body: TerminalTextInputHandler(
            terminal: terminal,
            focusNode: focusNode,
            deleteDetection: true,
            readOnly: readOnly,
            buildReviewTextForInsertedText: (delta, currentText) =>
                applyTerminalInputDelta(
                  currentText: terminalTextFromEvents(terminalOutput),
                  cursorOffset: terminalTextFromEvents(terminalOutput).length,
                  deletedCount: delta.deletedCount,
                  appendedText: delta.appendedText,
                ),
            onReviewInsertedText: (review) async {
              reviews.add(review);
              return false;
            },
            child: const SizedBox.expand(),
          ),
        ),
      );

      await tester.pumpWidget(buildHandler());

      focusNode.requestFocus();
      await tester.pump();

      const existingCommand = r'echo $(';
      for (var index = 1; index <= existingCommand.length; index++) {
        final currentCommand = existingCommand.substring(0, index);
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: '$_deleteDetectionMarker$currentCommand',
            selection: TextSelection.collapsed(
              offset: _deleteDetectionMarker.length + currentCommand.length,
            ),
          ),
        );
        await tester.pump();
      }

      readOnly = true;
      await tester.pumpWidget(buildHandler());
      await tester.pump();

      readOnly = false;
      await tester.pumpWidget(buildHandler());
      await tester.pump();

      reviews.clear();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '$_deleteDetectionMarker id)',
          selection: TextSelection.collapsed(offset: 6),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(reviews, hasLength(1));
      expect(reviews.single.command, r'echo $( id)');
      expect(
        reviews.single.reasons,
        contains(TerminalCommandReviewReason.commandSubstitution),
      );
      expect(terminalTextFromEvents(terminalOutput), existingCommand);

      focusNode.dispose();
    });
  });

  group('shouldRequestKeyboardForTerminalPointerUp', () {
    test('requests the keyboard for a tap-like first touch pointer', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 1,
          hadMultipleTouchPointers: false,
          movedBeyondTapSlop: false,
          readOnly: false,
        ),
        isTrue,
      );
    });

    test('suppresses the keyboard after touch movement beyond tap slop', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 1,
          hadMultipleTouchPointers: false,
          movedBeyondTapSlop: true,
          readOnly: false,
        ),
        isFalse,
      );
    });

    test('suppresses the keyboard for additional touch pointers', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 2,
          hadMultipleTouchPointers: true,
          movedBeyondTapSlop: false,
          readOnly: false,
        ),
        isFalse,
      );
    });

    test('suppresses the keyboard after a multitouch gesture sequence', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 1,
          hadMultipleTouchPointers: true,
          movedBeyondTapSlop: false,
          readOnly: false,
        ),
        isFalse,
      );
    });

    test('still requests the keyboard for non-touch pointers', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.mouse,
          activeTouchPointers: 0,
          hadMultipleTouchPointers: false,
          movedBeyondTapSlop: false,
          readOnly: false,
        ),
        isTrue,
      );
    });

    test('never requests the keyboard when input is read only', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 1,
          hadMultipleTouchPointers: false,
          movedBeyondTapSlop: false,
          readOnly: true,
        ),
        isFalse,
      );
    });

    test('requests the keyboard just before touch reaches long press', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 1,
          hadMultipleTouchPointers: false,
          movedBeyondTapSlop: false,
          readOnly: false,
          touchPressDuration:
              terminalKeyboardTapLongPressTimeout -
              const Duration(microseconds: 1),
        ),
        isTrue,
      );
    });

    test('suppresses the keyboard when touch duration reaches long press', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 1,
          hadMultipleTouchPointers: false,
          movedBeyondTapSlop: false,
          readOnly: false,
          touchPressDuration: terminalKeyboardTapLongPressTimeout,
        ),
        isFalse,
      );
    });
  });

  group('TerminalTextInputHandler compared with TextField', () {
    testWidgets(
      'matches TextField user state for collapsed caret moves while issuing one terminal resync',
      (tester) async {
        final sequence = <TextEditingValue>[
          const TextEditingValue(
            text: 'echo teh world',
            selection: TextSelection.collapsed(offset: 14),
          ),
          const TextEditingValue(
            text: 'echo teh world',
            selection: TextSelection.collapsed(offset: 5),
          ),
        ];

        final textFieldResult = await _runTextFieldSequence(tester, sequence);
        final terminalResult = await _runTerminalSequence(tester, sequence);

        expect(terminalResult.finalState, textFieldResult.finalState);
        expect(textFieldResult.echoedStates, isEmpty);
        expect(terminalResult.echoedStates, [textFieldResult.finalState]);
      },
    );

    testWidgets(
      'matches TextField user state when a replacement selection collapses elsewhere',
      (tester) async {
        final sequence = <TextEditingValue>[
          const TextEditingValue(
            text: 'echo teh world',
            selection: TextSelection.collapsed(offset: 14),
          ),
          const TextEditingValue(
            text: 'echo the world',
            selection: TextSelection(baseOffset: 5, extentOffset: 8),
          ),
          const TextEditingValue(
            text: 'echo the world',
            selection: TextSelection.collapsed(offset: 5),
          ),
        ];

        final textFieldResult = await _runTextFieldSequence(tester, sequence);
        final terminalResult = await _runTerminalSequence(tester, sequence);

        expect(terminalResult.finalState, textFieldResult.finalState);
        expect(textFieldResult.echoedStates, isEmpty);
        expect(terminalResult.echoedStates, [textFieldResult.finalState]);
      },
    );

    testWidgets(
      'matches TextField user state after deleting newer text, replacing earlier text, and moving again',
      (tester) async {
        final sequence = <TextEditingValue>[
          const TextEditingValue(
            text: 'teh world ',
            selection: TextSelection.collapsed(offset: 10),
          ),
          const TextEditingValue(
            text: 'teh ',
            selection: TextSelection.collapsed(offset: 4),
          ),
          const TextEditingValue(
            text: 'the ',
            selection: TextSelection(baseOffset: 0, extentOffset: 3),
          ),
          const TextEditingValue(
            text: 'the ',
            selection: TextSelection.collapsed(offset: 1),
          ),
        ];

        final textFieldResult = await _runTextFieldSequence(tester, sequence);
        final terminalResult = await _runTerminalSequence(tester, sequence);

        expect(terminalResult.finalState, textFieldResult.finalState);
        expect(textFieldResult.echoedStates, isEmpty);
        // The deletion-triggered buffer reset in step 2 first echoes the
        // cleared IME state, then the later collapsed-caret move resyncs the
        // current user state.
        expect(terminalResult.echoedStates, [
          (
            text: '',
            selectionBase: 0,
            selectionExtent: 0,
            composingBase: -1,
            composingExtent: -1,
          ),
          textFieldResult.finalState,
        ]);
      },
    );

    testWidgets(
      'matches TextField replacement finalization without an extra terminal resync',
      (tester) async {
        final sequence = <TextEditingValue>[
          const TextEditingValue(
            text: 'teh ',
            selection: TextSelection.collapsed(offset: 4),
          ),
          const TextEditingValue(
            text: 'the ',
            selection: TextSelection(baseOffset: 0, extentOffset: 3),
          ),
          const TextEditingValue(
            text: 'the ',
            selection: TextSelection.collapsed(offset: 4),
          ),
        ];

        final textFieldResult = await _runTextFieldSequence(tester, sequence);
        final terminalResult = await _runTerminalSequence(tester, sequence);

        expect(terminalResult.finalState, textFieldResult.finalState);
        expect(textFieldResult.echoedStates, isEmpty);
        expect(terminalResult.echoedStates, isEmpty);
      },
    );

    final matrixScenarios = <_MatrixScenario>[
      (
        name: 'matches insertion at a moved caret',
        sequence: const [
          TextEditingValue(
            text: 'foo bar',
            selection: TextSelection.collapsed(offset: 7),
          ),
          TextEditingValue(
            text: 'foo bar',
            selection: TextSelection.collapsed(offset: 4),
          ),
          TextEditingValue(
            text: 'foo Xbar',
            selection: TextSelection.collapsed(offset: 5),
          ),
        ],
        textFieldEchoes: 0,
        terminalEchoes: 1,
      ),
      (
        name: 'matches beginning-of-line insertion',
        sequence: const [
          TextEditingValue(
            text: 'hello',
            selection: TextSelection.collapsed(offset: 5),
          ),
          TextEditingValue(
            text: 'hello',
            selection: TextSelection.collapsed(offset: 0),
          ),
          TextEditingValue(
            text: 'Xhello',
            selection: TextSelection.collapsed(offset: 1),
          ),
        ],
        textFieldEchoes: 0,
        terminalEchoes: 1,
      ),
      (
        name: 'matches identical-character insertion at a moved caret',
        sequence: const [
          TextEditingValue(
            text: 'aaaa',
            selection: TextSelection.collapsed(offset: 4),
          ),
          TextEditingValue(
            text: 'aaaa',
            selection: TextSelection.collapsed(offset: 1),
          ),
          TextEditingValue(
            text: 'aaaaa',
            selection: TextSelection.collapsed(offset: 2),
          ),
        ],
        textFieldEchoes: 0,
        terminalEchoes: 1,
      ),
      (
        name: 'matches punctuation replacement at a moved caret',
        sequence: const [
          TextEditingValue(
            text: 'hello, world',
            selection: TextSelection.collapsed(offset: 12),
          ),
          TextEditingValue(
            text: 'hello, world',
            selection: TextSelection.collapsed(offset: 6),
          ),
          TextEditingValue(
            text: 'hello; world',
            selection: TextSelection.collapsed(offset: 6),
          ),
        ],
        textFieldEchoes: 0,
        terminalEchoes: 1,
      ),
      (
        name: 'matches emoji insertion after a caret move',
        sequence: const [
          TextEditingValue(
            text: 'a🎉b',
            selection: TextSelection.collapsed(offset: 4),
          ),
          TextEditingValue(
            text: 'a🎉b',
            selection: TextSelection.collapsed(offset: 1),
          ),
          TextEditingValue(
            text: 'aX🎉b',
            selection: TextSelection.collapsed(offset: 2),
          ),
        ],
        textFieldEchoes: 0,
        terminalEchoes: 1,
      ),
      (
        name: 'matches earlier-word replacement after deleting newer text',
        sequence: const [
          TextEditingValue(
            text: 'teh world ',
            selection: TextSelection.collapsed(offset: 10),
          ),
          TextEditingValue(
            text: 'teh ',
            selection: TextSelection.collapsed(offset: 4),
          ),
          TextEditingValue(
            text: 'the ',
            selection: TextSelection(baseOffset: 0, extentOffset: 3),
          ),
          TextEditingValue(
            text: 'the ',
            selection: TextSelection.collapsed(offset: 4),
          ),
        ],
        textFieldEchoes: 0,
        terminalEchoes: 1,
      ),
      (
        name:
            'matches earlier-word replacement after partially deleting newer text',
        sequence: const [
          TextEditingValue(
            text: 'teh world ',
            selection: TextSelection.collapsed(offset: 10),
          ),
          TextEditingValue(
            text: 'teh wo',
            selection: TextSelection.collapsed(offset: 6),
          ),
          TextEditingValue(
            text: 'the wo',
            selection: TextSelection(baseOffset: 0, extentOffset: 3),
          ),
          TextEditingValue(
            text: 'the wo',
            selection: TextSelection.collapsed(offset: 6),
          ),
        ],
        textFieldEchoes: null,
        terminalEchoes: null,
      ),
      ..._buildFlutterReplacedParityScenarios(),
      ..._buildFlutterDeltaParityScenarios(),
      ..._buildFlutterComposingParityScenarios(),
      ..._buildGeneratedComparisonScenarios(),
      ..._buildGptComparisonScenarios(),
    ];

    for (final scenario in matrixScenarios) {
      testWidgets(scenario.name, (tester) async {
        await _expectTextFieldComparisonScenario(
          tester,
          sequence: scenario.sequence,
          expectedTextFieldEchoCount: scenario.textFieldEchoes,
          expectedTerminalEchoCount: scenario.terminalEchoes,
        );
      });
    }

    final opusResetScenarios = _buildOpusResetScenarios();

    for (final scenario in opusResetScenarios) {
      testWidgets(scenario.name, (tester) async {
        await _expectResetContinuationScenario(tester, scenario);
      });
    }

    testWidgets('clears the IME buffer after trailing backspace', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
      );
      tester.testTextInput.log.clear();

      // Type "hello".
      tester.testTextInput.updateEditingValue(
        _editingValue('hello', selectionOffset: 5),
      );
      await tester.pump();

      tester.testTextInput.log.clear();

      // Backspace to "hell".
      tester.testTextInput.updateEditingValue(
        _editingValue('hell', selectionOffset: 4),
      );
      await tester.pump();

      // The terminal should show "hell".
      expect(terminalTextFromEvents(harness.terminalOutput), 'hell');

      // The IME buffer should be cleared after the backspace.
      expect(
        tester.testTextInput.log
            .where((call) => call.method == 'TextInput.setEditingState')
            .length,
        1,
      );

      // The editing state is reset to the marker only so suggestions start
      // fresh from the next typed character.
      final client = _terminalTextInputClient(tester);
      expect(
        client.currentTextEditingValue,
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(offset: 2),
        ),
      );

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'defers iOS trailing backspace buffer clears so native repeat stays fast',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          final harness = await pumpTerminalInputHarness(tester);

          tester.testTextInput.updateEditingValue(
            _editingValue('hello', selectionOffset: 5),
          );
          await tester.pump();
          tester.testTextInput.log.clear();

          tester.testTextInput.updateEditingValue(
            _editingValue('hell', selectionOffset: 4),
          );
          await tester.pump();

          expect(terminalTextFromEvents(harness.terminalOutput), 'hell');
          expect(
            tester.testTextInput.log.where(
              (call) => call.method == 'TextInput.setEditingState',
            ),
            isEmpty,
          );
          expect(
            _terminalTextInputClient(tester).currentTextEditingValue,
            _editingValue('hell', selectionOffset: 4),
          );

          tester.testTextInput.updateEditingValue(
            _editingValue('hel', selectionOffset: 3),
          );
          await tester.pump();

          expect(terminalTextFromEvents(harness.terminalOutput), 'hel');
          expect(
            tester.testTextInput.log.where(
              (call) => call.method == 'TextInput.setEditingState',
            ),
            isEmpty,
          );

          await tester.pump(terminalIosBackspaceRepeatSettleDelay);

          expect(
            _terminalTextInputClient(tester).currentTextEditingValue,
            const TextEditingValue(
              text: _deleteDetectionMarker,
              selection: TextSelection.collapsed(offset: 2),
            ),
          );
          expect(
            tester.testTextInput.log
                .where((call) => call.method == 'TextInput.setEditingState')
                .length,
            1,
          );

          await disposeTerminalInputHarness(tester, harness);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      'keeps the iOS backspace buffer through slow native repeat gaps',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          final harness = await pumpTerminalInputHarness(tester);

          tester.testTextInput.updateEditingValue(
            _editingValue('hello', selectionOffset: 5),
          );
          await tester.pump();
          harness.terminalOutput.clear();
          tester.testTextInput.log.clear();

          tester.testTextInput.updateEditingValue(
            _editingValue('hell', selectionOffset: 4),
          );
          await tester.pump();

          await tester.pump(const Duration(milliseconds: 600));

          expect(
            tester.testTextInput.log.where(
              (call) => call.method == 'TextInput.setEditingState',
            ),
            isEmpty,
          );
          expect(
            _terminalTextInputClient(tester).currentTextEditingValue,
            _editingValue('hell', selectionOffset: 4),
          );

          tester.testTextInput.updateEditingValue(
            _editingValue('hel', selectionOffset: 3),
          );
          await tester.pump();

          expect(
            terminalStateFromEvents(
              harness.terminalOutput,
              initialText: 'hello',
              initialCursorOffset: 5,
            ),
            (text: 'hel', cursorOffset: 3),
          );
          expect(
            tester.testTextInput.log.where(
              (call) => call.method == 'TextInput.setEditingState',
            ),
            isEmpty,
          );

          await disposeTerminalInputHarness(tester, harness);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      'strips leaked iOS backspace runways before a composed slash command',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          final harness = await pumpTerminalInputHarness(tester);

          tester.testTextInput.updateEditingValue(
            _editingValue('x', selectionOffset: 1),
          );
          await tester.pump();
          tester.testTextInput.updateEditingValue(
            _editingValue('', selectionOffset: 0),
          );
          await tester.pump();

          expect(
            _terminalTextInputClient(tester).currentTextEditingValue,
            _iosBackspaceRunwayValue(terminalIosBackspaceRepeatRunwayLength),
          );

          harness.terminalOutput.clear();

          tester.testTextInput.updateEditingValue(
            _iosBackspaceRunwayComposingValue(
              terminalIosBackspaceRepeatRunwayLength,
              suffix: '/help',
            ),
          );
          await tester.pump();

          expect(harness.terminalOutput, isEmpty);

          tester.testTextInput.updateEditingValue(
            _iosBackspaceRunwayValue(
              terminalIosBackspaceRepeatRunwayLength,
              suffix: '/help',
            ),
          );
          await tester.pump();

          expect(harness.terminalOutput, ['/help']);
          expect(
            _terminalTextInputClient(tester).currentTextEditingValue,
            _editingValue('/help', selectionOffset: '/help'.length),
          );

          await disposeTerminalInputHarness(tester, harness);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets('strips duplicated iOS backspace runways before typed text', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final harness = await pumpTerminalInputHarness(tester);

        tester.testTextInput.updateEditingValue(
          _editingValue('x', selectionOffset: 1),
        );
        await tester.pump();
        tester.testTextInput.updateEditingValue(
          _editingValue('', selectionOffset: 0),
        );
        await tester.pump();

        expect(
          _terminalTextInputClient(tester).currentTextEditingValue,
          _iosBackspaceRunwayValue(terminalIosBackspaceRepeatRunwayLength),
        );

        harness.terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _iosBackspaceRunwayValue(
            terminalIosBackspaceRepeatRunwayLength * 2,
            suffix: 'ls ',
          ),
        );
        await tester.pump();

        expect(harness.terminalOutput, ['ls ']);
        expect(
          _terminalTextInputClient(tester).currentTextEditingValue,
          _editingValue('ls ', selectionOffset: 'ls '.length),
        );

        await disposeTerminalInputHarness(tester, harness);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
      'strips stale iOS backspace runways after the platform drops state',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          final harness = await pumpTerminalInputHarness(tester);

          tester.testTextInput.updateEditingValue(
            _editingValue('x', selectionOffset: 1),
          );
          await tester.pump();
          tester.testTextInput.updateEditingValue(
            _editingValue('', selectionOffset: 0),
          );
          await tester.pump();

          expect(
            _terminalTextInputClient(tester).currentTextEditingValue,
            _iosBackspaceRunwayValue(terminalIosBackspaceRepeatRunwayLength),
          );

          tester.testTextInput.updateEditingValue(
            const TextEditingValue(
              text: _deleteDetectionMarker,
              selection: TextSelection.collapsed(offset: 2),
            ),
          );
          await tester.pump();

          harness.terminalOutput.clear();

          tester.testTextInput.updateEditingValue(
            _iosBackspaceRunwayValue(
              terminalIosBackspaceRepeatRunwayLength,
              suffix: 'add ',
            ),
          );
          await tester.pump();

          expect(harness.terminalOutput, ['add ']);
          expect(
            _terminalTextInputClient(tester).currentTextEditingValue,
            _editingValue('add ', selectionOffset: 'add '.length),
          );

          await disposeTerminalInputHarness(tester, harness);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      'preserves leading zero-width text outside iOS backspace runway state',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          final harness = await pumpTerminalInputHarness(tester);
          const input = '\u200B/help';

          tester.testTextInput.updateEditingValue(
            _editingValue(input, selectionOffset: input.length),
          );
          await tester.pump();

          expect(harness.terminalOutput, [input]);

          await disposeTerminalInputHarness(tester, harness);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      'keeps iOS held backspace fast after visible text is exhausted',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          final harness = await pumpTerminalInputHarness(tester);
          final backspaceOutput = _terminalKeyOutput(TerminalKey.backspace);

          tester.testTextInput.updateEditingValue(
            _editingValue('ab', selectionOffset: 2),
          );
          await tester.pump();
          harness.terminalOutput.clear();
          tester.testTextInput.log.clear();

          tester.testTextInput.updateEditingValue(
            _editingValue('a', selectionOffset: 1),
          );
          await tester.pump();
          tester.testTextInput.updateEditingValue(
            _editingValue('', selectionOffset: 0),
          );
          await tester.pump();

          expect(
            terminalStateFromEvents(
              harness.terminalOutput,
              initialText: 'ab',
              initialCursorOffset: 2,
            ),
            (text: '', cursorOffset: 0),
          );
          expect(
            _terminalTextInputClient(tester).currentTextEditingValue,
            _iosBackspaceRunwayValue(terminalIosBackspaceRepeatRunwayLength),
          );

          harness.terminalOutput.clear();
          tester.testTextInput.log.clear();

          tester.testTextInput.updateEditingValue(
            _iosBackspaceRunwayValue(
              terminalIosBackspaceRepeatRunwayLength - 1,
            ),
          );
          await tester.pump();

          expect(harness.terminalOutput, [backspaceOutput]);
          expect(
            tester.testTextInput.log.where(
              (call) => call.method == 'TextInput.setEditingState',
            ),
            isEmpty,
          );

          harness.terminalOutput.clear();

          tester.testTextInput.updateEditingValue(
            _iosBackspaceRunwayValue(
              terminalIosBackspaceRepeatRunwayLength - 1,
              suffix: 'x',
            ),
          );
          await tester.pump();

          expect(harness.terminalOutput, ['x']);
          expect(
            _terminalTextInputClient(tester).currentTextEditingValue,
            _editingValue('x', selectionOffset: 1),
          );

          await disposeTerminalInputHarness(tester, harness);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets('typing cancels the deferred iOS trailing backspace clear', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final harness = await pumpTerminalInputHarness(tester);

        tester.testTextInput.updateEditingValue(
          _editingValue('hello', selectionOffset: 5),
        );
        await tester.pump();
        tester.testTextInput.log.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('hell', selectionOffset: 4),
        );
        await tester.pump();
        tester.testTextInput.updateEditingValue(
          _editingValue('hellp', selectionOffset: 5),
        );
        await tester.pump();
        await tester.pump(terminalIosBackspaceRepeatSettleDelay);

        expect(terminalTextFromEvents(harness.terminalOutput), 'hellp');
        expect(
          _terminalTextInputClient(tester).currentTextEditingValue,
          _editingValue('hellp', selectionOffset: 5),
        );
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          isEmpty,
        );

        await disposeTerminalInputHarness(tester, harness);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('typing after trailing backspace inserts from a fresh buffer', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
      );

      // Type "hello".
      tester.testTextInput.updateEditingValue(
        _editingValue('hello', selectionOffset: 5),
      );
      await tester.pump();

      // Backspace to "hell".
      tester.testTextInput.updateEditingValue(
        _editingValue('hell', selectionOffset: 4),
      );
      await tester.pump();

      // Type "o" from the freshly cleared IME buffer.
      tester.testTextInput.updateEditingValue(
        _editingValue('o', selectionOffset: 1),
      );
      await tester.pump();

      // The terminal should show "hello".
      expect(terminalTextFromEvents(harness.terminalOutput), 'hello');

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'clears the IME buffer after deleting a corrected contraction tail',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
        );

        tester.testTextInput.updateEditingValue(
          _editingValue("didn't", selectionOffset: "didn't".length),
        );
        await tester.pump();

        tester.testTextInput.log.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('didn', selectionOffset: 'didn'.length),
        );
        await tester.pump();

        expect(terminalTextFromEvents(harness.terminalOutput), 'didn');

        final client = _terminalTextInputClient(tester);
        expect(
          client.currentTextEditingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'trims a leading swipe space after backspace-triggered IME buffer clear',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
        );

        // Type "hello".
        tester.testTextInput.updateEditingValue(
          _editingValue('hello', selectionOffset: 5),
        );
        await tester.pump();

        // Backspace to "hell".
        tester.testTextInput.updateEditingValue(
          _editingValue('hell', selectionOffset: 4),
        );
        await tester.pump();

        // Swipe-type " world" from the cleared IME buffer.
        await commitSwipeText(tester, '$_deleteDetectionMarker world');
        await tester.pump();

        // The cleared IME buffer should not keep suggesting continuations from
        // the deleted word. Because the terminal text before the cursor does
        // not end in whitespace, the leading swipe space is trimmed.
        expect(
          terminalStateFromEvents(harness.terminalOutput).text,
          'hellworld',
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'trims a leading suggestion space after backspace-triggered IME buffer clear',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
        );

        tester.testTextInput.updateEditingValue(
          _editingValue('didnt', selectionOffset: 'didnt'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('didn', selectionOffset: 'didn'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '$_deleteDetectionMarker test',
            selection: TextSelection.collapsed(offset: 7),
          ),
        );
        await tester.pump();

        expect(terminalTextFromEvents(harness.terminalOutput), 'didntest');

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'preserves the shortened prefix when a delete-reset continuation resumes the same word with the live terminal prefix',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          resolveTextBeforeCursor: () => 'didn',
        );

        tester.testTextInput.updateEditingValue(
          _editingValue('didnt', selectionOffset: 'didnt'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('didn', selectionOffset: 'didn'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '$_deleteDetectionMarker test',
            selection: TextSelection.collapsed(offset: 7),
          ),
        );
        await tester.pump();

        expect(terminalTextFromEvents(harness.terminalOutput), 'didntest');

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'replaces a shortened first word after backspace without duplicating the prefix',
      (tester) async {
        await suggestionReplacingShortenedFirstWord(tester);
      },
    );

    for (final testCase in [
      (
        name:
            'preserves a new separator when a trailing-backspace reset is followed by a same-initial unrelated committed word',
        initialEditingValue: _editingValue('shell', selectionOffset: 5),
        shortenedEditingValue: _editingValue('shel', selectionOffset: 4),
        continuation: _editingValue(' story ', selectionOffset: 7),
        initialState: (text: 'shel', cursorOffset: 'shel'.length),
        expected: (text: 'shel story ', cursorOffset: 'shel story '.length),
        expectedEditingValue: null,
      ),
      (
        name:
            'preserves the deleted suffix when a trailing-backspace reset resumes the same word and continues into the next word',
        initialEditingValue: _editingValue('things', selectionOffset: 6),
        shortenedEditingValue: _editingValue('thin', selectionOffset: 4),
        continuation: _editingValue(' gs are ', selectionOffset: 8),
        initialState: (text: 'thin', cursorOffset: 'thin'.length),
        expected: (text: 'things are ', cursorOffset: 'things are '.length),
        expectedEditingValue: null,
      ),
      (
        name:
            'keeps the shortened prefix when later delete-reset words only share letters with the deleted suggestion',
        initialEditingValue: _editingValue(
          'what do we thinking',
          selectionOffset: 'what do we thinking'.length,
        ),
        shortenedEditingValue: _editingValue(
          'what do we t',
          selectionOffset: 'what do we t'.length,
        ),
        continuation: _editingValue(
          ' whatever considering ',
          selectionOffset: ' whatever considering '.length,
        ),
        initialState: (
          text: 'what do we t',
          cursorOffset: 'what do we t'.length,
        ),
        expected: (
          text: 'what do we t whatever considering ',
          cursorOffset: 'what do we t whatever considering '.length,
        ),
        expectedEditingValue: null,
      ),
      (
        name:
            'drops a stale one-letter delete-reset fragment before the next word',
        initialEditingValue: _editingValue(
          'what do we thinking',
          selectionOffset: 'what do we thinking'.length,
        ),
        shortenedEditingValue: _editingValue(
          'what do we t',
          selectionOffset: 'what do we t'.length,
        ),
        continuation: _editingValue(
          's whatever ',
          selectionOffset: 's whatever '.length,
        ),
        initialState: (
          text: 'what do we t',
          cursorOffset: 'what do we t'.length,
        ),
        expected: (
          text: 'what do we t whatever ',
          cursorOffset: 'what do we t whatever '.length,
        ),
        expectedEditingValue: const TextEditingValue(
          text: '$_deleteDetectionMarker whatever ',
          selection: TextSelection.collapsed(offset: 12),
        ),
      ),
    ]) {
      testWidgets(testCase.name, (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          resolveTextBeforeCursor: () => testCase.initialState.text,
          initialEditingValue: testCase.initialEditingValue,
        );
        final terminalOutput = harness.terminalOutput;
        tester.testTextInput.updateEditingValue(testCase.shortenedEditingValue);
        await tester.pump();
        terminalOutput.clear();
        tester.testTextInput.updateEditingValue(testCase.continuation);
        await tester.pump();
        expect(
          terminalStateFromEvents(
            terminalOutput,
            initialText: testCase.initialState.text,
            initialCursorOffset: testCase.initialState.cursorOffset,
          ),
          testCase.expected,
        );
        if (testCase.expectedEditingValue != null) {
          expect(
            _terminalTextInputClient(tester).currentTextEditingValue,
            testCase.expectedEditingValue,
          );
        }
        await disposeTerminalInputHarness(tester, harness);
      });
    }

    testWidgets(
      'trims a leading IME separator during delete-reset replacement when the live terminal prefix is visible',
      (tester) async {
        await imeSeparatorDuringDeleteReset(tester);
      },
    );

    testWidgets(
      'preserves a manual separator when replacing a swiped word after backspacing into it',
      (tester) async {
        await manualSeparatorAfterSwipeBackspace(tester);
      },
    );

    testWidgets(
      'preserves an IME separator when replacing a swiped word after backspacing into it',
      (tester) async {
        await imeSeparatorAfterSwipeBackspace(tester);
      },
    );

    testWidgets(
      'does not force-resync the IME during replacement after deleting a later word',
      (tester) async {
        await replacementAfterDeletingLaterWord(tester);
      },
    );

    testWidgets('trims a leading suggestion space after a committed newline', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
      );

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Becho hi\n',
          selection: TextSelection.collapsed(offset: 10),
        ),
      );
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '$_deleteDetectionMarker next',
          selection: TextSelection.collapsed(offset: 7),
        ),
      );
      await tester.pump();

      expect(
        terminalTextFromEvents(harness.terminalOutput),
        'echo hi${_terminalKeyOutput(TerminalKey.enter)}next',
      );

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets('resets IME editing state after modifier chord character', (
      tester,
    ) async {
      var modifierActive = false;

      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
        hasActiveToolbarModifier: () => modifierActive,
      );

      // Type "ls" normally.
      tester.testTextInput.updateEditingValue(
        _editingValue('ls', selectionOffset: 2),
      );
      await tester.pump();
      expect(terminalTextFromEvents(harness.terminalOutput), 'ls');

      // Activate Ctrl modifier (simulating toolbar toggle).
      modifierActive = true;

      // Type 'c' with modifier active (would produce Ctrl+C in practice).
      tester.testTextInput.updateEditingValue(
        _editingValue('lsc', selectionOffset: 3),
      );
      await tester.pump();

      // The IME editing state should be fully reset after the modified
      // character (control codes make the terminal state unpredictable).
      final client = _terminalTextInputClient(tester);
      expect(
        client.currentTextEditingValue,
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(offset: 2),
        ),
      );

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets('applies modifiers before soft-keyboard text is emitted', (
      tester,
    ) async {
      var modifierActive = true;
      final harness = await pumpTerminalInputHarness(
        tester,
        hasActiveToolbarModifier: () => modifierActive,
        applyTerminalTextInputModifiers: (text) {
          expect(text, 'q');
          modifierActive = false;
          return '\x11';
        },
      );

      tester.testTextInput.updateEditingValue(
        _editingValue('q', selectionOffset: 1),
      );
      await tester.pump();

      expect(harness.terminalOutput, <String>['\x11']);
      expect(modifierActive, isFalse);
      expect(
        _terminalTextInputClient(tester).currentTextEditingValue,
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(offset: 2),
        ),
      );

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets('modifier chords ignore stale multi-character IME batches', (
      tester,
    ) async {
      final toolbarController = KeyboardToolbarController()..toggleCtrl();
      addTearDown(toolbarController.dispose);
      final harness = await pumpTerminalInputHarness(
        tester,
        hasActiveToolbarModifier: () =>
            toolbarController.isCtrlActive || toolbarController.isAltActive,
        applyTerminalTextInputModifiers:
            toolbarController.applySystemKeyboardModifiers,
      );

      tester.testTextInput.updateEditingValue(
        _editingValue('staleq', selectionOffset: 'staleq'.length),
      );
      await tester.pump();

      expect(harness.terminalOutput, <String>['\x11']);
      expect(toolbarController.isCtrlActive, isFalse);
      expect(
        _terminalTextInputClient(tester).currentTextEditingValue,
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(offset: 2),
        ),
      );

      await disposeTerminalInputHarness(tester, harness);
    });

    testWidgets(
      'soft-keyboard newline uses Enter key path even with toolbar modifiers',
      (tester) async {
        var shiftActive = true;
        var textModifierCalls = 0;
        final harness = await pumpTerminalInputHarness(
          tester,
          hasActiveToolbarModifier: () => true,
          resolveTerminalKeyModifiers: () =>
              (ctrl: false, alt: false, shift: shiftActive),
          consumeTerminalKeyModifiers: () => shiftActive = false,
          applyTerminalTextInputModifiers: (text) {
            textModifierCalls++;
            return text;
          },
        );

        tester.testTextInput.updateEditingValue(
          _editingValue('\n', selectionOffset: 1),
        );
        await tester.pump();

        // Newline must not go through the single-grapheme text modifier path.
        expect(textModifierCalls, 0);
        expect(harness.terminalOutput, <String>[
          _terminalShiftEnterNewlineInput,
        ]);
        expect(shiftActive, isFalse);

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'controller clears the IME buffer after external terminal actions',
      (tester) async {
        final harness = await pumpTerminalInputHarness(tester);
        final controller = harness.controller;

        tester.testTextInput.updateEditingValue(
          _editingValue('hello', selectionOffset: 5),
        );
        await tester.pump();

        controller.clearImeBuffer();
        await tester.pump();

        final client = _terminalTextInputClient(tester);
        expect(
          client.currentTextEditingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'resets IME after second character of a two-part chord (tmux Ctrl+b, c)',
      (tester) async {
        var modifierActive = false;
        var fakeNow = DateTime(2026);
        debugSetModifierChordClock(() => fakeNow);
        addTearDown(() => debugSetModifierChordClock(null));
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          hasActiveToolbarModifier: () => modifierActive,
        );

        // Step 1: Ctrl+b (modifier active, type 'b').
        modifierActive = true;
        tester.testTextInput.updateEditingValue(
          _editingValue('b', selectionOffset: 1),
        );
        await tester.pump();

        // Modifier consumed (one-shot).
        modifierActive = false;

        // After Ctrl+b the buffer should be fully reset.
        var client = _terminalTextInputClient(tester);
        expect(
          client.currentTextEditingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        // Step 2: 'c' within the chord window (< 500 ms).
        fakeNow = fakeNow.add(const Duration(milliseconds: 100));
        tester.testTextInput.updateEditingValue(
          _editingValue('c', selectionOffset: 1),
        );
        await tester.pump();

        // The follow-up character should also trigger a full reset.
        client = _terminalTextInputClient(tester);
        expect(
          client.currentTextEditingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        // Step 3: Type normally — 'l' should accumulate (no more chord).
        tester.testTextInput.updateEditingValue(
          _editingValue('l', selectionOffset: 1),
        );
        await tester.pump();

        // Normal typing accumulates in the buffer.
        client = _terminalTextInputClient(tester);
        expect(
          client.currentTextEditingValue,
          const TextEditingValue(
            text: '${_deleteDetectionMarker}l',
            selection: TextSelection.collapsed(offset: 3),
          ),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'typing copilot after tmux Ctrl+b, c keeps the leading c when space is pressed',
      (tester) async {
        var modifierActive = false;
        var fakeNow = DateTime(2026);
        debugSetModifierChordClock(() => fakeNow);
        addTearDown(() => debugSetModifierChordClock(null));
        final harness = await pumpTerminalInputHarness(
          tester,
          resolveTextBeforeCursor: () => '>',
          hasActiveToolbarModifier: () => modifierActive,
        );
        final terminalOutput = harness.terminalOutput;
        final controller = harness.controller;

        modifierActive = true;
        tester.testTextInput.updateEditingValue(
          _editingValue('b', selectionOffset: 1),
        );
        await tester.pump();
        modifierActive = false;

        fakeNow = fakeNow.add(const Duration(milliseconds: 100));
        tester.testTextInput.updateEditingValue(
          _editingValue('c', selectionOffset: 1),
        );
        await tester.pump();

        terminalOutput.clear();
        tester.testTextInput.log.clear();
        controller.handleExternalTerminalOutput();
        await tester.pump();

        for (var index = 1; index <= 'copilot'.length; index++) {
          final text = 'copilot'.substring(0, index);
          tester.testTextInput.updateEditingValue(
            _editingValue(text, selectionOffset: index),
          );
          await tester.pump();
        }

        tester.testTextInput.updateEditingValue(
          _editingValue('c opilot ', selectionOffset: 'c opilot '.length),
        );
        await tester.pump();

        expect(terminalTextFromEvents(terminalOutput), 'copilot ');

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'preserves an intentional space inserted inside the first token',
      (tester) async {
        final harness = await pumpTerminalInputHarness(
          tester,
          resolveTextBeforeCursor: () => '>',
        );
        final terminalOutput = harness.terminalOutput;
        harness.controller.handleExternalTerminalOutput();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('copilot', selectionOffset: 'copilot'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('c opilot', selectionOffset: 2),
        );
        await tester.pump();

        expect(
          terminalStateFromEvents(
            terminalOutput,
            initialText: 'copilot',
            initialCursorOffset: 'copilot'.length,
          ),
          (text: 'c opilot', cursorOffset: 2),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'preserves leading indentation when a split token is normalized',
      (tester) async {
        var modifierActive = false;
        var fakeNow = DateTime(2026);
        debugSetModifierChordClock(() => fakeNow);
        addTearDown(() => debugSetModifierChordClock(null));
        final harness = await pumpTerminalInputHarness(
          tester,
          resolveTextBeforeCursor: () => '>',
          hasActiveToolbarModifier: () => modifierActive,
        );
        final terminalOutput = harness.terminalOutput;
        final controller = harness.controller;

        modifierActive = true;
        tester.testTextInput.updateEditingValue(
          _editingValue('b', selectionOffset: 1),
        );
        await tester.pump();
        modifierActive = false;

        fakeNow = fakeNow.add(const Duration(milliseconds: 100));
        tester.testTextInput.updateEditingValue(
          _editingValue('c', selectionOffset: 1),
        );
        await tester.pump();

        terminalOutput.clear();
        controller.handleExternalTerminalOutput();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('  copilot', selectionOffset: '  copilot'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('  c opilot ', selectionOffset: '  c opilot '.length),
        );
        await tester.pump();

        expect(
          terminalStateFromEvents(
            terminalOutput,
            initialText: '  copilot',
            initialCursorOffset: '  copilot'.length,
          ),
          (text: '  copilot ', cursorOffset: '  copilot '.length),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets(
      'does not reset after modifier chord when follow-up arrives after timeout',
      (tester) async {
        var modifierActive = false;
        var fakeNow = DateTime(2026);
        debugSetModifierChordClock(() => fakeNow);
        addTearDown(() => debugSetModifierChordClock(null));
        final harness = await pumpTerminalInputHarness(
          tester,
          attachController: false,
          hasActiveToolbarModifier: () => modifierActive,
        );

        // Ctrl+C (standalone modifier chord).
        modifierActive = true;
        tester.testTextInput.updateEditingValue(
          _editingValue('c', selectionOffset: 1),
        );
        await tester.pump();
        modifierActive = false;

        // Buffer is reset after Ctrl+C.
        var client = _terminalTextInputClient(tester);
        expect(
          client.currentTextEditingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        // Advance past the chord window (> 500 ms).
        fakeNow = fakeNow.add(const Duration(milliseconds: 600));

        // Type 'l' — this should accumulate normally because the chord
        // window has expired.
        tester.testTextInput.updateEditingValue(
          _editingValue('l', selectionOffset: 1),
        );
        await tester.pump();

        client = _terminalTextInputClient(tester);
        expect(
          client.currentTextEditingValue,
          const TextEditingValue(
            text: '${_deleteDetectionMarker}l',
            selection: TextSelection.collapsed(offset: 3),
          ),
        );

        await disposeTerminalInputHarness(tester, harness);
      },
    );

    testWidgets('regular typing accumulates in IME buffer without reset', (
      tester,
    ) async {
      final harness = await pumpTerminalInputHarness(
        tester,
        attachController: false,
        hasActiveToolbarModifier: () => false,
      );
      final terminalOutput = harness.terminalOutput;

      // Type "hello" one character at a time.
      for (var i = 1; i <= 5; i++) {
        tester.testTextInput.updateEditingValue(
          _editingValue('hello'.substring(0, i), selectionOffset: i),
        );
        await tester.pump();
      }

      // The terminal should have "hello".
      expect(terminalTextFromEvents(terminalOutput), 'hello');

      // The IME editing state should still have the full accumulated text.
      final client = _terminalTextInputClient(tester);
      expect(
        client.currentTextEditingValue,
        const TextEditingValue(
          text: '${_deleteDetectionMarker}hello',
          selection: TextSelection.collapsed(offset: 7),
        ),
      );

      await disposeTerminalInputHarness(tester, harness);
    });
  });
}
