// ignore_for_file: public_member_api_docs

import 'dart:async';

// These packages are supplied by Flutter and flutter_test respectively.
// ignore: depend_on_referenced_packages
import 'package:characters/characters.dart';
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/auto_connect_command.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart'
    show applyTerminalInputDelta;
import 'package:monkeyssh/presentation/widgets/keyboard_toolbar.dart';
import 'package:monkeyssh/presentation/widgets/terminal_ime_engine.dart';
import 'package:xterm/xterm.dart';

import '../../helpers/terminal_input_helpers.dart'
    show terminalTextFromEvents, terminalStateFromEvents;

const _deleteDetectionMarker = '\u200B\u200B';
const _terminalShiftEnterNewlineInput = '\n';

typedef _LoggedEditingState = ({
  String text,
  int selectionBase,
  int selectionExtent,
  int composingBase,
  int composingExtent,
});

typedef _MatrixScenario = ({
  String name,
  List<TextEditingValue> sequence,
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
        terminalEchoes: null,
      ),
      (
        name: 'gpt-derived ${_insertAfterMiddleScenario(seed).name}',
        sequence: _insertAfterMiddleScenario(seed).sequence,
        terminalEchoes: null,
      ),
      (
        name: 'gpt-derived ${_replaceMiddleScenario(seed).name}',
        sequence: _replaceMiddleScenario(seed).sequence,
        terminalEchoes: null,
      ),
      (
        name: 'gpt-derived ${_backspaceWithinMiddleScenario(seed).name}',
        sequence: _backspaceWithinMiddleScenario(seed).sequence,
        terminalEchoes: null,
      ),
      (
        name: 'gpt-derived ${_deleteMiddleSelectionScenario(seed).name}',
        sequence: _deleteMiddleSelectionScenario(seed).sequence,
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
      name: 'flutter EditableText preserves composing range when a collapsed caret moves within it',
      sequence: const [
        baseValue,
        TextEditingValue(
          text: 'foo composing bar',
          selection: TextSelection.collapsed(offset: 5),
          composing: TextRange(start: 4, end: 12),
        ),
      ],
      terminalEchoes: null,
    ),
    (
      name: 'flutter EditableText clears composing range when a collapsed caret moves before it',
      sequence: const [
        baseValue,
        TextEditingValue(
          text: 'foo composing bar',
          selection: TextSelection.collapsed(offset: 2),
        ),
      ],
      terminalEchoes: null,
    ),
    (
      name: 'flutter EditableText clears composing range when a collapsed caret moves after it',
      sequence: const [
        baseValue,
        TextEditingValue(
          text: 'foo composing bar',
          selection: TextSelection.collapsed(offset: 14),
        ),
      ],
      terminalEchoes: null,
    ),
    (
      name: 'flutter EditableText clears composing range when a selection moves before it',
      sequence: const [
        baseValue,
        TextEditingValue(
          text: 'foo composing bar',
          selection: TextSelection(baseOffset: 1, extentOffset: 2),
        ),
      ],
      terminalEchoes: null,
    ),
    (
      name: 'flutter EditableText preserves composing range when a selection stays within it',
      sequence: const [
        baseValue,
        TextEditingValue(
          text: 'foo composing bar',
          selection: TextSelection(baseOffset: 5, extentOffset: 7),
          composing: TextRange(start: 4, end: 12),
        ),
      ],
      terminalEchoes: null,
    ),
    (
      name: 'flutter EditableText clears composing range when a selection moves after it',
      sequence: const [
        baseValue,
        TextEditingValue(
          text: 'foo composing bar',
          selection: TextSelection(baseOffset: 13, extentOffset: 15),
        ),
      ],
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
  _ImeDriver driver,
  _ImeHarness harness,
  _ResetTrigger trigger, {
  required String initialText,
}) async {
  switch (trigger) {
    case _ResetTrigger.trailingBackspace:
      final shortenedText = _dropLastGrapheme(initialText);
      driver.updateEditingValue(
        _editingValue(shortenedText, selectionOffset: shortenedText.length),
      );
      await driver.flush();
      break;
    case _ResetTrigger.newlineAction:
      driver.engine.performAction(TextInputAction.newline);
      await driver.flush();
      break;
    case _ResetTrigger.newlineText:
      final textWithNewline = '$initialText\n';
      driver.updateEditingValue(
        _editingValue(textWithNewline, selectionOffset: textWithNewline.length),
      );
      await driver.flush();
      break;
    case _ResetTrigger.controllerClear:
      harness.controller.clearImeBuffer();
      await driver.flush();
      break;
    case _ResetTrigger.markerLoss:
      driver.updateEditingValue(
        const TextEditingValue(
          text: '\u200B',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      await driver.flush();
      break;
  }
}

Future<void> _expectResetContinuationScenario(
  _ImeDriver driver,
  _ResetScenario scenario,
) async {
  const initialText = 'alpha';
  const followUpText = ' beta';
  final harness = await _createImeHarness(
    driver,
    resolveTextBeforeCursor: () => scenario.resolveTextBeforeCursor,
  );

  driver.updateEditingValue(
    _editingValue(initialText, selectionOffset: initialText.length),
  );
  await driver.flush();

  harness.terminalOutput.clear();
  driver.log.clear();

  await _applyResetTrigger(
    driver,
    harness,
    scenario.trigger,
    initialText: initialText,
  );

  harness.terminalOutput.clear();
  driver.log.clear();

  driver.updateEditingValue(
    _editingValue(followUpText, selectionOffset: followUpText.length),
  );
  await driver.flush();

  expect(
    terminalTextFromEvents(harness.terminalOutput),
    scenario.shouldTrim ? 'beta' : ' beta',
  );

  await _disposeImeHarness(driver, harness);
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
  Terminal(onOutput: output.add)
      .keyInput(key, shift: shift, alt: alt, ctrl: ctrl);
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
  _batchTests();
  _dictationTests();
  _unicodeTests();

  group('TerminalTextInputHandler', () {
    test(
      'disables autocorrect while preserving keyboard suggestions',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final harness = await _createImeHarness(driver);
        final configuration = driver.engine
            .buildTextInputConfiguration()
            .toJson();
        final inputType = configuration['inputType']! as Map<dynamic, dynamic>;

        expect(inputType['name'], 'TextInputType.text');
        expect(configuration['autocorrect'], isFalse);
        expect(configuration['enableSuggestions'], isTrue);
        expect(configuration['enableIMEPersonalizedLearning'], isTrue);

        await _disposeImeHarness(driver, harness);
      },
    );

    test('uses a password-friendly IME configuration for secrets', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(driver, sensitiveInput: true);
      final configuration = driver.engine
          .buildTextInputConfiguration()
          .toJson();
      final inputType = configuration['inputType']! as Map<dynamic, dynamic>;

      expect(inputType['name'], 'TextInputType.text');
      expect(configuration['obscureText'], isTrue);
      expect(configuration['autocorrect'], isFalse);
      expect(configuration['enableSuggestions'], isFalse);
      expect(configuration['enableIMEPersonalizedLearning'], isFalse);

      await _disposeImeHarness(driver, harness);
    });

    test('preserves swipe typing context across short pauses', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);

      await driver.attach(terminal: terminal);

      await driver.flush();

      driver.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bhello ',
          selection: TextSelection.collapsed(offset: 8),
        ),
      );
      await driver.flush();

      await driver.flush(const Duration(milliseconds: 400));

      driver.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bhello world ',
          selection: TextSelection.collapsed(offset: 14),
        ),
      );
      await driver.flush();

      expect(terminalOutput.join(), 'hello world ');
    });

    test('drops a spurious leading newline before first swipe text', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(driver);
      final terminalOutput = harness.terminalOutput;

      await _commitSwipeText(driver, '$_deleteDetectionMarker\nhello');

      expect(terminalOutput.join(), 'hello');

      await _disposeImeHarness(driver, harness);
    });

    test('drops a leading space before first swipe text', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(driver);
      final terminalOutput = harness.terminalOutput;

      await _commitSwipeText(driver, '$_deleteDetectionMarker hello');

      expect(terminalOutput.join(), 'hello');

      await _disposeImeHarness(driver, harness);
    });

    test('drops a leading swipe space after a committed newline', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(driver);
      final terminalOutput = harness.terminalOutput;

      driver.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Becho hi\n',
          selection: TextSelection.collapsed(offset: 10),
        ),
      );
      await driver.flush();

      await _commitSwipeText(driver, '$_deleteDetectionMarker next');

      expect(
        terminalOutput.join(),
        'echo hi${_terminalKeyOutput(TerminalKey.enter)}next',
      );

      await _disposeImeHarness(driver, harness);
    });

    test('preserves the swipe separator after an input reset when text already exists', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(
        driver,
        resolveTextBeforeCursor: () => 'echo ready',
      );
      final terminalOutput = harness.terminalOutput;

      await _commitSwipeText(driver, '$_deleteDetectionMarker world');

      expect(terminalTextFromEvents(terminalOutput), ' world');

      await _disposeImeHarness(driver, harness);
    });

    test('trims a swipe separator after an input reset when the current line is only a prompt marker', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      await _swipeSeparatorAfterPromptReset(driver);
    });

    test('trims a duplicate swipe separator after an input reset when text already ends with whitespace', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(
        driver,
        resolveTextBeforeCursor: () => 'echo ready ',
      );
      final terminalOutput = harness.terminalOutput;

      await _commitSwipeText(driver, '$_deleteDetectionMarker world');

      expect(terminalTextFromEvents(terminalOutput), 'world');

      await _disposeImeHarness(driver, harness);
    });

    test('preserves leading spaces for first non-swipe commit', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(driver);
      final terminalOutput = harness.terminalOutput;

      driver.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200B  hello',
          selection: TextSelection.collapsed(offset: 9),
        ),
      );
      await driver.flush();

      expect(terminalOutput.join(), '  hello');

      await _disposeImeHarness(driver, harness);
    });

    test('drops a swipe newline followed by a stray leading space', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(driver);
      final terminalOutput = harness.terminalOutput;

      await _commitSwipeText(driver, '$_deleteDetectionMarker\n hello');

      expect(terminalOutput.join(), 'hello');

      await _disposeImeHarness(driver, harness);
    });

    test('preserves later swipe spaces after trimming first input', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(driver);
      final terminalOutput = harness.terminalOutput;

      await _commitSwipeText(driver, '$_deleteDetectionMarker hello ');

      driver.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bhello world ',
          selection: TextSelection.collapsed(offset: 14),
        ),
      );
      await driver.flush();

      expect(terminalOutput.join(), 'hello world ');

      await _disposeImeHarness(driver, harness);
    });

    test(
      'preserves a separator after typed input is fully backspaced away',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final harness = await _createImeHarness(
          driver,
          resolveTextBeforeCursor: () => 'echo ready',
        );
        final terminalOutput = harness.terminalOutput;

        driver.updateEditingValue(
          _editingValue('tmp', selectionOffset: 'tmp'.length),
        );
        await driver.flush();

        driver.updateEditingValue(_editingValue('', selectionOffset: 0));
        await driver.flush();

        await _commitSwipeText(driver, '$_deleteDetectionMarker hello');

        expect(
          terminalStateFromEvents(
            terminalOutput,
            initialText: 'echo ready',
            initialCursorOffset: 'echo ready'.length,
          ),
          (text: 'echo ready hello', cursorOffset: 'echo ready hello'.length),
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'trims a leading swipe space after swipe input is fully backspaced away',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final harness = await _createImeHarness(driver);
        final terminalOutput = harness.terminalOutput;

        await _commitSwipeText(driver, '$_deleteDetectionMarker hello');

        driver.updateEditingValue(_editingValue('', selectionOffset: 0));
        await driver.flush();

        terminalOutput.clear();

        await _commitSwipeText(driver, '$_deleteDetectionMarker world');

        expect(terminalTextFromEvents(terminalOutput), 'world');

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'trims a leading suggestion space after input is fully backspaced away',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final harness = await _createImeHarness(driver);
        final terminalOutput = harness.terminalOutput;

        await _commitSwipeText(driver, '$_deleteDetectionMarker hello');

        driver.updateEditingValue(_editingValue('', selectionOffset: 0));
        await driver.flush();

        terminalOutput.clear();

        driver.updateEditingValue(
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                ' world',
            selection: TextSelection.collapsed(offset: 8),
          ),
        );
        await driver.flush();

        expect(terminalTextFromEvents(terminalOutput), 'world');

        await _disposeImeHarness(driver, harness);
      },
    );

    test('resyncs delete-detection marker after backspacing past it', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(driver);
      final terminalOutput = harness.terminalOutput;

      driver.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bok',
          selection: TextSelection.collapsed(offset: 4),
        ),
      );
      await driver.flush();

      driver.updateEditingValue(
        const TextEditingValue(
          text: '\u200B',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      await driver.flush();

      driver.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bre',
          selection: TextSelection.collapsed(offset: 4),
        ),
      );
      await driver.flush();

      expect(terminalOutput.join(), 'ok\x7f\x7fre');
      expect(terminalStateFromEvents(terminalOutput), (
        text: 're',
        cursorOffset: 2,
      ));

      await _disposeImeHarness(driver, harness);
    });

    test('forwards a terminal backspace when delete detection loses the marker with no buffered text', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(driver);
      final terminalOutput = harness.terminalOutput;

      driver.updateEditingValue(
        const TextEditingValue(
          text: '\u200B',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      await driver.flush();

      expect(terminalOutput.join(), _terminalKeyOutput(TerminalKey.backspace));
      expect(
        driver.engine.editingValue,
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(offset: 2),
        ),
      );

      await _disposeImeHarness(driver, harness);
    });

    test('clears all buffered text when the IME loses the marker', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(driver);
      final terminalOutput = harness.terminalOutput;

      driver.updateEditingValue(
        _editingValue('hello', selectionOffset: 'hello'.length),
      );
      await driver.flush();

      terminalOutput.clear();

      driver.updateEditingValue(
        const TextEditingValue(selection: TextSelection.collapsed(offset: 0)),
      );
      await driver.flush();

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
        driver.engine.editingValue,
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(offset: 2),
        ),
      );

      await _disposeImeHarness(driver, harness);
    });

    test('keeps IME replacement selections intact', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(driver);
      final terminalOutput = harness.terminalOutput;

      driver.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bteh ',
          selection: TextSelection.collapsed(offset: 6),
        ),
      );
      await driver.flush();

      expect(terminalTextFromEvents(terminalOutput), 'teh ');

      driver.log.clear();

      driver.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bthe ',
          selection: TextSelection(baseOffset: 2, extentOffset: 5),
        ),
      );
      await driver.flush();

      expect(terminalTextFromEvents(terminalOutput), 'the ');
      expect(
        driver.log.where((call) => call.method == 'TextInput.setEditingState'),
        isEmpty,
      );

      driver.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bthe ',
          selection: TextSelection.collapsed(offset: 6),
        ),
      );
      await driver.flush();

      expect(terminalTextFromEvents(terminalOutput), 'the ');
      expect(
        driver.log.where((call) => call.method == 'TextInput.setEditingState'),
        isEmpty,
      );

      await _disposeImeHarness(driver, harness);
    });

    test('keeps the tracked cursor aligned after a hardware left arrow before IME insertion', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(driver);
      final terminalOutput = harness.terminalOutput;

      driver.updateEditingValue(
        _editingValue('hello', selectionOffset: 'hello'.length),
      );
      await driver.flush();

      await driver.hardwareKey(TerminalKey.arrowLeft);
      await driver.flush();
      await driver.flush();

      terminalOutput.clear();

      driver.updateEditingValue(
        _editingValue('hello', selectionOffset: 'hell'.length),
      );
      await driver.flush();

      driver.updateEditingValue(
        _editingValue('hellXo', selectionOffset: 'hellX'.length),
      );
      await driver.flush();

      expect(terminalOutput.join(), 'X');
      expect(
        terminalStateFromEvents(
          terminalOutput,
          initialText: 'hello',
          initialCursorOffset: 'hell'.length,
        ),
        (text: 'hellXo', cursorOffset: 'hellX'.length),
      );

      await _disposeImeHarness(driver, harness);
    });

    test(
      'moves the terminal cursor when the IME caret moves without text changes',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final harness = await _createImeHarness(
          driver,
          initialEditingValue: _editingValue(
            'echo teh world',
            selectionOffset: 'echo teh world'.length,
          ),
        );
        final terminalOutput = harness.terminalOutput..clear();

        driver.updateEditingValue(
          _editingValue('echo teh world', selectionOffset: 'echo teh '.length),
        );
        await driver.flush();

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

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'resyncs the IME state when the caret moves within existing text',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final harness = await _createImeHarness(
          driver,
          initialEditingValue: _editingValue(
            'echo teh world',
            selectionOffset: 'echo teh world'.length,
          ),
        );
        harness.terminalOutput.clear();
        driver.log.clear();

        driver.updateEditingValue(
          _editingValue('echo teh world', selectionOffset: 'echo '.length),
        );
        await driver.flush();

        expect(
          driver.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          hasLength(1),
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test('resyncs the IME state when a replacement selection collapses to a different caret position', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(
        driver,
        initialEditingValue: _editingValue(
          'echo teh world',
          selectionOffset: 'echo teh world'.length,
        ),
      );
      final terminalOutput = harness.terminalOutput;

      driver.updateEditingValue(
        const TextEditingValue(
          text: '${_deleteDetectionMarker}echo the world',
          selection: TextSelection(baseOffset: 7, extentOffset: 10),
        ),
      );
      await driver.flush();

      terminalOutput.clear();
      driver.log.clear();

      driver.updateEditingValue(
        _editingValue('echo the world', selectionOffset: 'echo '.length),
      );
      await driver.flush();

      expect(
        terminalOutput.join(),
        List.filled(3, _terminalKeyOutput(TerminalKey.arrowLeft)).join(),
      );
      expect(
        driver.log.where((call) => call.method == 'TextInput.setEditingState'),
        hasLength(1),
      );

      await _disposeImeHarness(driver, harness);
    });

    for (final testCase in [
      (
        name: 'keeps the cursor aligned when a replacement is followed by a later move and backspace elsewhere',
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
        name: 'keeps the cursor aligned when a replacement is followed by a later replacement elsewhere',
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
        name: 'keeps the cursor aligned when replacement selection is followed by immediate backspace',
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
        name: 'keeps the cursor aligned when a replacement selection includes a trailing space before backspace',
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
        name: 'keeps the cursor aligned when deleting and then reinserting a replacement separator',
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
        name: 'keeps the cursor aligned when whitespace-cluster replacement collapses two spaces before backspace',
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
        name: 'keeps the cursor aligned across repeated non-collapsed replacements before backspace',
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
        name: 'keeps the cursor aligned across repeated-word non-collapsed replacements before backspace',
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
        name: 'keeps the cursor aligned when editing inside a triple-space cluster after an internal move',
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
        name: 'keeps the cursor aligned after replacing a repeated word and then backspacing a later repeated match',
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
        name: 'inserts at the beginning of the line without rewriting the existing text',
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
        name: 'inserts an identical character at a moved caret without rewriting the unchanged suffix',
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
        name: 'moves and inserts around an emoji using grapheme-aware cursor offsets',
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
        name: 'deletes an identical character at a moved caret without rewriting the unchanged suffix',
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
        name: 'keeps the cursor aligned when inserting and then backspacing at a space boundary',
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
        name: 'keeps the cursor aligned when inserting and then backspacing between repeated spaces',
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
        name: 'replaces punctuation at a moved caret without rewriting the trailing word',
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
        name: 'keeps the cursor aligned when replacing punctuation and double-space clusters before backspace',
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
        name: 'replaces the middle repeated word without touching the trailing match',
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
        name: 'keeps the cursor aligned after replacing a repeated word and then backspacing',
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
        name: 'keeps the cursor aligned when a repeated-word replacement commits from composition before backspace',
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
        name: 'keeps the cursor aligned when composition moves away before collapsing and a later backspace follows',
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
        name: 'keeps the cursor aligned when an autocorrected word is punctuated and then backspaced',
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
        name: 'keeps the cursor aligned across repeated backspaces after an autocorrected repeated token',
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
      (
        name: 'rewrites a short trailing tail when an autocorrect-on-space edits the word before it',
        initialEditingValue: _editingValue(
          'teh ',
          selectionOffset: 'teh '.length,
        ),
        initialState: (text: 'teh ', cursorOffset: 'teh '.length),
        steps: [_editingValue('the ', selectionOffset: 'the '.length)],
        expected: (text: 'the ', cursorOffset: 'the '.length),
        expectedOutput:
            '${List.filled(3, _terminalKeyOutput(TerminalKey.backspace)).join()}'
            'he ',
      ),
      (
        name: 'keeps using arrow keys when the unchanged trailing tail is longer than the rewrite limit',
        initialEditingValue: _editingValue(
          'i am going home ',
          selectionOffset: 'i am going home '.length,
        ),
        initialState: (
          text: 'i am going home ',
          cursorOffset: 'i am going home '.length,
        ),
        steps: [
          _editingValue(
            'I am going home ',
            selectionOffset: 'I am going home '.length,
          ),
        ],
        expected: (
          text: 'I am going home ',
          cursorOffset: 'I am going home '.length,
        ),
        expectedOutput:
            '${List.filled(15, _terminalKeyOutput(TerminalKey.arrowLeft)).join()}'
            '${_terminalKeyOutput(TerminalKey.backspace)}'
            'I'
            '${List.filled(15, _terminalKeyOutput(TerminalKey.arrowRight)).join()}',
      ),
    ]) {
      test(testCase.name, () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final harness = await _createImeHarness(
          driver,
          initialEditingValue: testCase.initialEditingValue,
        );
        final terminalOutput = harness.terminalOutput..clear();
        for (final value in testCase.steps) {
          driver.updateEditingValue(value);
          await driver.flush();
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
        await _disposeImeHarness(driver, harness);
      });
    }

    test('keeps using arrow keys when the unchanged trailing tail is control input', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(
        driver,
        initialEditingValue: _editingValue(
          'teh\t',
          selectionOffset: 'teh\t'.length,
        ),
      );
      final terminalOutput = harness.terminalOutput..clear();

      // Retyping the tab would rerun shell completion, so the edit before
      // it must still navigate around the tail instead of resending it.
      driver.updateEditingValue(
        _editingValue('the\t', selectionOffset: 'the\t'.length),
      );
      await driver.flush();

      final output = terminalOutput.join();
      expect(output, contains(_terminalKeyOutput(TerminalKey.arrowLeft)));
      expect(
        _terminalKeyOutput(TerminalKey.backspace).allMatches(output).length,
        2,
      );
      expect(output, isNot(contains('he\t')));

      await _disposeImeHarness(driver, harness);
    });

    test('does not review the retyped context of a framed double-space period as inserted text', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      driver.platform = TargetPlatform.iOS;

      var reviewCount = 0;
      final harness = await _createImeHarness(
        driver,
        onReviewInsertedText: (_) async {
          reviewCount++;
          return true;
        },
        initialTerminalOutput: '\x1b[?2004h',
        initialEditingValue: _editingValue(
          r'echo $(date) hi ',
          selectionOffset: r'echo $(date) hi '.length,
        ),
      );
      final terminalOutput = harness.terminalOutput..clear();
      // Seeding the buffer is itself a multi-grapheme insertion into a
      // command containing a substitution, so it is reviewed once.
      final reviewCountAfterSeed = reviewCount;

      driver.updateEditingValue(
        _editingValue(
          r'echo $(date) hi. ',
          selectionOffset: r'echo $(date) hi. '.length,
        ),
      );
      await driver.flush();

      expect(reviewCount, reviewCountAfterSeed);
      expect(terminalOutput, ['\x7f', '\x7f', '\x1b[200~i. \x1b[201~']);

      await _disposeImeHarness(driver, harness);
    });

    test('rewrites the trailing space instead of arrowing around it for a double-space period', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      driver.platform = TargetPlatform.iOS;

      final harness = await _createImeHarness(
        driver,
        initialEditingValue: _editingValue(
          'hello ',
          selectionOffset: 'hello '.length,
        ),
      );
      final terminalOutput = harness.terminalOutput..clear();

      // Gboard and iOS turn the second space into ". " while the caret stays
      // at the end of the buffer, then the user keeps typing.
      for (final value in [
        _editingValue('hello. ', selectionOffset: 'hello. '.length),
        _editingValue('hello. w', selectionOffset: 'hello. w'.length),
      ]) {
        driver.updateEditingValue(value);
        await driver.flush();
      }

      expect(
        terminalOutput.join(),
        '${_terminalKeyOutput(TerminalKey.backspace)}. w',
      );
      expect(
        terminalOutput.join(),
        isNot(contains(_terminalKeyOutput(TerminalKey.arrowLeft))),
      );
      expect(
        terminalStateFromEvents(
          terminalOutput,
          initialText: 'hello ',
          initialCursorOffset: 'hello '.length,
        ),
        (text: 'hello. w', cursorOffset: 'hello. w'.length),
      );

      await _disposeImeHarness(driver, harness);
    });

    test('preserves replacement text after a later word delete drops part of the marker', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(
        driver,
        initialEditingValue: const TextEditingValue(
          text: '\u200B\u200Bteh world ',
          selection: TextSelection.collapsed(offset: 12),
        ),
      );
      final terminalOutput = harness.terminalOutput;

      driver.log.clear();

      driver.updateEditingValue(
        const TextEditingValue(
          text: '\u200Bteh ',
          selection: TextSelection.collapsed(offset: 5),
        ),
      );
      await driver.flush();

      driver.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bthe ',
          selection: TextSelection(baseOffset: 2, extentOffset: 5),
        ),
      );
      await driver.flush();

      driver.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bthe ',
          selection: TextSelection.collapsed(offset: 6),
        ),
      );
      await driver.flush();

      expect(terminalTextFromEvents(terminalOutput), 'the ');

      await _disposeImeHarness(driver, harness);
    });

    test('keeps the cursor aligned when replacing across an emoji boundary and trailing space', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      const initialText = 'go 👩🏽‍💻 now';
      const selectionStart = _deleteDetectionMarker.length + 'go '.length;
      const selectionEnd = _deleteDetectionMarker.length + 'go 👩🏽‍💻 '.length;

      final harness = await _createImeHarness(driver);

      driver.updateEditingValue(
        _editingValue(initialText, selectionOffset: initialText.length),
      );
      await driver.flush();

      harness.terminalOutput.clear();

      driver.updateEditingValue(
        const TextEditingValue(
          text: '$_deleteDetectionMarker$initialText',
          selection: TextSelection(
            baseOffset: selectionStart,
            extentOffset: selectionEnd,
          ),
        ),
      );
      await driver.flush();

      driver.updateEditingValue(
        _editingValue('go later now', selectionOffset: 'go later'.length),
      );
      await driver.flush();

      driver.updateEditingValue(
        _editingValue('go late now', selectionOffset: 'go late'.length),
      );
      await driver.flush();

      expect(
        terminalStateFromEvents(
          harness.terminalOutput,
          initialText: initialText,
          initialCursorOffset: initialText.characters.length,
        ),
        (text: 'go late now', cursorOffset: 'go late'.length),
      );

      await _disposeImeHarness(driver, harness);
    });

    test('keeps the cursor aligned when replacing the first word and trailing space at the buffer start', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      const initialText = 'teh world';
      const selectionEnd = _deleteDetectionMarker.length + 'teh '.length;

      final harness = await _createImeHarness(driver);

      driver.updateEditingValue(
        _editingValue(initialText, selectionOffset: initialText.length),
      );
      await driver.flush();

      harness.terminalOutput.clear();

      driver.updateEditingValue(
        const TextEditingValue(
          text: '$_deleteDetectionMarker$initialText',
          selection: TextSelection(
            baseOffset: _deleteDetectionMarker.length,
            extentOffset: selectionEnd,
          ),
        ),
      );
      await driver.flush();

      driver.updateEditingValue(
        _editingValue('the world', selectionOffset: 'the'.length),
      );
      await driver.flush();

      driver.updateEditingValue(
        _editingValue('th world', selectionOffset: 'th'.length),
      );
      await driver.flush();

      expect(
        terminalStateFromEvents(
          harness.terminalOutput,
          initialText: initialText,
          initialCursorOffset: initialText.length,
        ),
        (text: 'th world', cursorOffset: 'th'.length),
      );

      await _disposeImeHarness(driver, harness);
    });

    test('keeps the cursor aligned when replacing the last word and leading space at the buffer end', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      const initialText = 'hello teh';
      const selectionStart = _deleteDetectionMarker.length + 'hello'.length;
      const selectionEnd = _deleteDetectionMarker.length + initialText.length;

      final harness = await _createImeHarness(driver);

      driver.updateEditingValue(
        _editingValue(initialText, selectionOffset: initialText.length),
      );
      await driver.flush();

      harness.terminalOutput.clear();

      driver.updateEditingValue(
        const TextEditingValue(
          text: '$_deleteDetectionMarker$initialText',
          selection: TextSelection(
            baseOffset: selectionStart,
            extentOffset: selectionEnd,
          ),
        ),
      );
      await driver.flush();

      driver.updateEditingValue(
        _editingValue('hello the', selectionOffset: 'hello the'.length),
      );
      await driver.flush();

      driver.updateEditingValue(
        _editingValue('hello th', selectionOffset: 'hello th'.length),
      );
      await driver.flush();

      expect(
        terminalStateFromEvents(
          harness.terminalOutput,
          initialText: initialText,
          initialCursorOffset: initialText.length,
        ),
        (text: 'hello th', cursorOffset: 'hello th'.length),
      );

      await _disposeImeHarness(driver, harness);
    });

    test('soft-keyboard newline text sends terminal Enter', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(
        driver,
        initialEditingValue: _editingValue(
          'echo',
          selectionOffset: 'echo'.length,
        ),
      );
      final terminalOutput = harness.terminalOutput..clear();

      driver.updateEditingValue(
        _editingValue('echo\n', selectionOffset: 'echo\n'.length),
      );
      await driver.flush();

      expect(terminalOutput.join(), _terminalKeyOutput(TerminalKey.enter));
      expect(
        driver.engine.editingValue,
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(
            offset: _deleteDetectionMarker.length,
          ),
        ),
      );

      await _disposeImeHarness(driver, harness);
    });

    test('suppresses the first follow-up newline action after a committed newline update', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(
        driver,
        initialEditingValue: _editingValue(
          'echo\n',
          selectionOffset: 'echo\n'.length,
        ),
      );
      final terminalOutput = harness.terminalOutput..clear();

      final client = driver.engine;
      Future<void> performNewlineAction() async {
        client.performAction(TextInputAction.newline);
        await driver.flush();
      }

      await performNewlineAction();

      expect(terminalOutput, isEmpty);

      await performNewlineAction();

      expect(terminalOutput.join(), _terminalKeyOutput(TerminalKey.enter));

      await _disposeImeHarness(driver, harness);
    });

    test('newline actions consume one-shot toolbar modifiers', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      var shiftActive = true;
      final harness = await _createImeHarness(
        driver,
        resolveTerminalKeyModifiers: () =>
            (ctrl: false, alt: false, shift: shiftActive),
        consumeTerminalKeyModifiers: () => shiftActive = false,
      );

      driver.engine.performAction(TextInputAction.newline);
      await driver.flush();
      driver.engine.performAction(TextInputAction.newline);
      await driver.flush();

      expect(
        harness.terminalOutput.join(),
        _terminalShiftEnterNewlineInput + _terminalKeyOutput(TerminalKey.enter),
      );

      await _disposeImeHarness(driver, harness);
    });

    test(
      'Android IME replacement after HID Backspace does not delete twice',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        driver.platform = TargetPlatform.android;
        final controller = _ImeController(driver);
        _ImeHarness? harness;

        try {
          harness = await _createImeHarness(
            driver,
            initialTerminalOutput: '\x1b[>1u',
            controller: controller,
          );
          final terminalOutput = harness.terminalOutput;

          driver.updateEditingValue(_editingValue('CC', selectionOffset: 2));
          await driver.flush();
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
          await driver.flush();

          driver.updateEditingValue(_editingValue('D', selectionOffset: 1));
          await driver.flush();

          expect(terminalOutput, <String>['\x7f', '\x7f', 'D']);
        } finally {
          if (harness != null) {
            await _disposeImeHarness(driver, harness);
          }
          controller.dispose();
        }
      },
    );

    test(
      'Android IME append after omitted Backspace drops stale buffer text',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        driver.platform = TargetPlatform.android;
        final controller = _ImeController(driver);
        _ImeHarness? harness;

        try {
          harness = await _createImeHarness(
            driver,
            initialTerminalOutput: '\x1b[>1u',
            controller: controller,
          );
          final terminalOutput = harness.terminalOutput;

          driver.updateEditingValue(_editingValue('A', selectionOffset: 1));
          await driver.flush();
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
          driver.updateEditingValue(_editingValue('AB', selectionOffset: 2));
          await driver.flush();

          expect(terminalOutput, <String>['\x7f', 'B']);
          expect(
            driver.engine.editingValue,
            _editingValue('B', selectionOffset: 1),
          );
        } finally {
          if (harness != null) {
            await _disposeImeHarness(driver, harness);
          }
          controller.dispose();
        }
      },
    );

    test(
      'rejected replacement preserves an applied Android IME Backspace',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        driver.platform = TargetPlatform.android;
        final controller = _ImeController(driver);
        _ImeHarness? harness;

        try {
          harness = await _createImeHarness(
            driver,
            initialTerminalOutput: '\x1b[>1u',
            onReviewInsertedText: (_) async => false,
            controller: controller,
          );
          final terminalOutput = harness.terminalOutput;

          driver.updateEditingValue(_editingValue('AB', selectionOffset: 2));
          await driver.flush();
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
          driver.updateEditingValue(_editingValue('x\ny', selectionOffset: 3));
          await driver.flush();

          expect(terminalOutput, <String>['\x7f']);
          expect(
            driver.engine.editingValue,
            _editingValue('A', selectionOffset: 1),
          );

          driver.updateEditingValue(_editingValue('AC', selectionOffset: 2));
          await driver.flush();

          expect(terminalOutput, <String>['\x7f', 'C']);
        } finally {
          if (harness != null) {
            await _disposeImeHarness(driver, harness);
          }
          controller.dispose();
        }
      },
    );

    test('notifies when soft-keyboard input is sent to the terminal', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final terminal = Terminal();
      var callbackCount = 0;

      await driver.attach(
        terminal: terminal,
        onUserInput: () => callbackCount++,
      );

      await driver.flush();

      driver.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bhello',
          selection: TextSelection.collapsed(offset: 7),
        ),
      );
      await driver.flush();

      expect(callbackCount, 1);
    });

    test(
      'ignores a stale newline edit when the IME action arrives first',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        var reviewCount = 0;

        final harness = await _createImeHarness(
          driver,
          onReviewInsertedText: (_) async {
            reviewCount++;
            return true;
          },
        );

        driver.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho hi',
            selection: TextSelection.collapsed(offset: 9),
          ),
        );
        await driver.flush();

        harness.terminalOutput.clear();

        driver.engine.performAction(TextInputAction.newline);
        await driver.flush();

        driver.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho hi\n',
            selection: TextSelection.collapsed(offset: 10),
          ),
        );
        await driver.flush();

        expect(harness.terminalOutput.join(), '\r');
        expect(reviewCount, 0);
        expect(
          driver.engine.editingValue,
          const TextEditingValue(
            text: '\u200B\u200B',
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'accepts new text after swallowing an action-first newline commit',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        var reviewCount = 0;

        final harness = await _createImeHarness(
          driver,
          onReviewInsertedText: (_) async {
            reviewCount++;
            return true;
          },
        );

        driver.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho hi',
            selection: TextSelection.collapsed(offset: 9),
          ),
        );
        await driver.flush();

        harness.terminalOutput.clear();

        driver.engine.performAction(TextInputAction.newline);
        await driver.flush();

        driver.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho hi\nn',
            selection: TextSelection.collapsed(offset: 11),
          ),
        );
        await driver.flush();

        expect(harness.terminalOutput.join(), '\rn');
        expect(reviewCount, 0);
        expect(
          driver.engine.editingValue,
          const TextEditingValue(
            text: '\u200B\u200Bn',
            selection: TextSelection.collapsed(offset: 3),
          ),
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'commits active IME composition before an action-first newline',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final harness = await _createImeHarness(driver);
        const committedPrefix = 'git reset --';
        const command = '${committedPrefix}hard';

        driver.updateEditingValue(
          _editingValue(
            committedPrefix,
            selectionOffset: committedPrefix.length,
          ),
        );
        await driver.flush();

        driver.updateEditingValue(
          _editingValue(
            command,
            selectionOffset: command.length,
            composing: const TextRange(
              start: committedPrefix.length,
              end: command.length,
            ),
          ),
        );
        await driver.flush();

        expect(harness.terminalOutput.join(), committedPrefix);

        driver.engine.performAction(TextInputAction.newline);
        await driver.flush();

        driver.updateEditingValue(
          _editingValue('$command\n', selectionOffset: command.length + 1),
        );
        await driver.flush();

        expect(
          harness.terminalOutput.join(),
          '$command${_terminalKeyOutput(TerminalKey.enter)}',
        );
        expect(
          driver.engine.editingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(
              offset: _deleteDetectionMarker.length,
            ),
          ),
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'preserves action modifiers while committing active IME composition',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        var shiftActive = true;
        var consumeCount = 0;
        final harness = await _createImeHarness(
          driver,
          resolveTerminalKeyModifiers: () =>
              (ctrl: false, alt: false, shift: shiftActive),
          consumeTerminalKeyModifiers: () {
            consumeCount++;
            shiftActive = false;
          },
        );
        const committedPrefix = 'echo ';
        const command = '${committedPrefix}hi';

        driver.updateEditingValue(
          _editingValue(
            committedPrefix,
            selectionOffset: committedPrefix.length,
          ),
        );
        await driver.flush();

        driver.updateEditingValue(
          _editingValue(
            command,
            selectionOffset: command.length,
            composing: const TextRange(
              start: committedPrefix.length,
              end: command.length,
            ),
          ),
        );
        await driver.flush();

        driver.engine.performAction(TextInputAction.newline);
        await driver.flush();

        expect(
          harness.terminalOutput.join(),
          '$command$_terminalShiftEnterNewlineInput',
        );
        expect(consumeCount, 1);
        expect(shiftActive, isFalse);

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'does not submit when reviewed IME composition is rejected on Enter',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final decision = Completer<bool>();
        var reviewCount = 0;
        final harness = await _createImeHarness(
          driver,
          onReviewInsertedText: (_) {
            reviewCount++;
            return decision.future;
          },
        );
        const command = r'echo $(id)';

        driver.updateEditingValue(
          _editingValue(
            command,
            selectionOffset: command.length,
            composing: const TextRange(start: 0, end: command.length),
          ),
        );
        await driver.flush();

        driver.engine.performAction(TextInputAction.newline);
        await driver.flush();

        driver.updateEditingValue(
          _editingValue('$command\n', selectionOffset: command.length + 1),
        );
        await driver.flush();

        expect(reviewCount, 1);
        expect(harness.terminalOutput, isEmpty);

        decision.complete(false);
        await driver.flush();
        await driver.flush();

        expect(reviewCount, 1);
        expect(harness.terminalOutput, isEmpty);
        expect(
          driver.engine.editingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(
              offset: _deleteDetectionMarker.length,
            ),
          ),
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'preserves reviewed Enter while coalescing the IME newline follow-up',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final decision = Completer<bool>();
        var reviewCount = 0;
        var shiftActive = true;
        var consumeCount = 0;
        final harness = await _createImeHarness(
          driver,
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

        driver.updateEditingValue(
          _editingValue(
            command,
            selectionOffset: command.length,
            composing: const TextRange(start: 0, end: command.length),
          ),
        );
        await driver.flush();

        driver.engine.performAction(TextInputAction.newline);
        await driver.flush();

        driver.updateEditingValue(
          _editingValue('$command\n', selectionOffset: command.length + 1),
        );
        await driver.flush();

        expect(reviewCount, 1);
        expect(harness.terminalOutput, isEmpty);

        decision.complete(true);
        await driver.flush();
        await driver.flush();

        expect(reviewCount, 1);
        expect(
          harness.terminalOutput.join(),
          '$command$_terminalShiftEnterNewlineInput',
        );
        expect(consumeCount, 1);
        expect(shiftActive, isFalse);

        await _disposeImeHarness(driver, harness);
      },
    );

    test('defers edit-first Enter until command review approves', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final decision = Completer<bool>();
      var reviewCount = 0;
      final harness = await _createImeHarness(
        driver,
        onReviewInsertedText: (_) {
          reviewCount++;
          return decision.future;
        },
      );
      const command = r'echo $(id)';

      driver.updateEditingValue(
        _editingValue(command, selectionOffset: command.length),
      );
      await driver.flush();

      driver.engine.performAction(TextInputAction.newline);
      await driver.flush();

      driver.updateEditingValue(
        _editingValue('$command\n', selectionOffset: command.length + 1),
      );
      await driver.flush();

      expect(reviewCount, 1);
      expect(harness.terminalOutput, isEmpty);

      decision.complete(true);
      await driver.flush();
      await driver.flush();

      expect(reviewCount, 1);
      expect(
        harness.terminalOutput.join(),
        '$command${_terminalKeyOutput(TerminalKey.enter)}',
      );

      await _disposeImeHarness(driver, harness);
    });

    test(
      'does not submit edit-first Enter when command review rejects',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final decision = Completer<bool>();
        var reviewCount = 0;
        final harness = await _createImeHarness(
          driver,
          onReviewInsertedText: (_) {
            reviewCount++;
            return decision.future;
          },
        );
        const command = r'echo $(id)';

        driver.updateEditingValue(
          _editingValue(command, selectionOffset: command.length),
        );
        await driver.flush();

        driver.engine.performAction(TextInputAction.newline);
        await driver.flush();

        driver.updateEditingValue(
          _editingValue('$command\n', selectionOffset: command.length + 1),
        );
        await driver.flush();

        decision.complete(false);
        await driver.flush();
        await driver.flush();

        expect(reviewCount, 1);
        expect(harness.terminalOutput, isEmpty);

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'stale review does not clear a newer composing Enter action',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final decisions = <Completer<bool>>[];
        var shiftActive = true;
        var consumeCount = 0;
        final harness = await _createImeHarness(
          driver,
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

        driver.updateEditingValue(
          _editingValue(staleCommand, selectionOffset: staleCommand.length),
        );
        await driver.flush();
        expect(decisions, hasLength(1));

        driver.updateEditingValue(
          _editingValue(
            currentCommand,
            selectionOffset: currentCommand.length,
            composing: const TextRange(start: 0, end: currentCommand.length),
          ),
        );
        await driver.flush();

        driver.engine.performAction(TextInputAction.newline);
        await driver.flush();

        decisions.first.complete(true);
        await driver.flush();
        await driver.flush();
        expect(decisions, hasLength(2));

        driver.updateEditingValue(
          _editingValue(
            '$currentCommand\n',
            selectionOffset: currentCommand.length + 1,
          ),
        );
        await driver.flush();

        decisions.last.complete(true);
        await driver.flush();
        await driver.flush();

        expect(
          harness.terminalOutput.join(),
          '$currentCommand$_terminalShiftEnterNewlineInput',
        );
        expect(consumeCount, 1);
        expect(shiftActive, isFalse);

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'reviewed newline uses captured modifiers without suppressing next Enter',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final decision = Completer<bool>();
        var shiftActive = true;
        var consumeCount = 0;
        final harness = await _createImeHarness(
          driver,
          onReviewInsertedText: (_) => decision.future,
          resolveTerminalKeyModifiers: () =>
              (ctrl: false, alt: false, shift: shiftActive),
          consumeTerminalKeyModifiers: () {
            consumeCount++;
            shiftActive = false;
          },
        );
        const command = r'echo $(id)';

        driver.updateEditingValue(
          _editingValue('$command\n', selectionOffset: command.length + 1),
        );
        await driver.flush();

        driver.engine.performAction(TextInputAction.newline);
        await driver.flush();

        decision.complete(true);
        await driver.flush();
        await driver.flush();

        expect(
          harness.terminalOutput.join(),
          '$command$_terminalShiftEnterNewlineInput',
        );
        expect(consumeCount, 1);

        driver.engine.performAction(TextInputAction.newline);
        await driver.flush();

        expect(
          harness.terminalOutput.join(),
          '$command$_terminalShiftEnterNewlineInput'
          '${_terminalKeyOutput(TerminalKey.enter)}',
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test('rejection preserves text typed after the pending newline', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final decision = Completer<bool>();
      final harness = await _createImeHarness(
        driver,
        onReviewInsertedText: (_) => decision.future,
      );
      const command = r'echo $(id)';
      const followUpText = 'next';

      driver.updateEditingValue(
        _editingValue(
          command,
          selectionOffset: command.length,
          composing: const TextRange(start: 0, end: command.length),
        ),
      );
      await driver.flush();

      driver.engine.performAction(TextInputAction.newline);
      await driver.flush();

      driver.updateEditingValue(
        _editingValue(
          '$command\n$followUpText',
          selectionOffset: command.length + 1 + followUpText.length,
          composing: const TextRange(
            start: command.length + 1,
            end: command.length + 1 + followUpText.length,
          ),
        ),
      );
      await driver.flush();

      decision.complete(false);
      await driver.flush();
      await driver.flush();

      expect(harness.terminalOutput, isEmpty);

      driver.updateEditingValue(
        _editingValue(followUpText, selectionOffset: followUpText.length),
      );
      await driver.flush();

      expect(harness.terminalOutput.join(), followUpText);
      expect(
        driver.engine.editingValue,
        const TextEditingValue(
          text: '$_deleteDetectionMarker$followUpText',
          selection: TextSelection.collapsed(
            offset: _deleteDetectionMarker.length + followUpText.length,
          ),
        ),
      );

      await _disposeImeHarness(driver, harness);
    });

    test(
      'canonicalizes a previous stale Enter prefix before replaying follow-up',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final decision = Completer<bool>();
        var reviewCount = 0;
        final harness = await _createImeHarness(
          driver,
          onReviewInsertedText: (_) {
            reviewCount++;
            return decision.future;
          },
        );
        const previousCommand = 'echo ready';
        const currentCommand = r'echo $(id)';
        const stalePrefix = '$previousCommand\n';

        driver.updateEditingValue(
          _editingValue(
            previousCommand,
            selectionOffset: previousCommand.length,
          ),
        );
        await driver.flush();
        driver.engine.performAction(TextInputAction.newline);
        await driver.flush();

        driver.updateEditingValue(
          _editingValue(
            '$stalePrefix$currentCommand',
            selectionOffset: stalePrefix.length + currentCommand.length,
            composing: const TextRange(
              start: stalePrefix.length,
              end: stalePrefix.length + currentCommand.length,
            ),
          ),
        );
        await driver.flush();

        driver.engine.performAction(TextInputAction.newline);
        await driver.flush();

        driver.updateEditingValue(
          _editingValue(
            '$stalePrefix$currentCommand\n',
            selectionOffset: stalePrefix.length + currentCommand.length + 1,
          ),
        );
        await driver.flush();

        expect(reviewCount, 1);
        decision.complete(true);
        await driver.flush();
        await driver.flush();

        expect(
          harness.terminalOutput.join(),
          '$previousCommand${_terminalKeyOutput(TerminalKey.enter)}'
          '$currentCommand${_terminalKeyOutput(TerminalKey.enter)}',
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test('locked Alt preserves composed input and deferred Enter', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final toolbarController = KeyboardToolbarController()..lockAlt();
      addTearDown(toolbarController.dispose);
      final harness = await _createImeHarness(
        driver,
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

      driver.updateEditingValue(
        _editingValue(
          'x',
          selectionOffset: 1,
          composing: const TextRange(start: 0, end: 1),
        ),
      );
      await driver.flush();

      driver.engine.performAction(TextInputAction.newline);
      await driver.flush();

      expect(
        harness.terminalOutput.join(),
        // Alt applies to the composed character; Enter+Alt is meta-sends-escape.
        '\x1bx\x1b\r',
      );
      expect(toolbarController.isAltActive, isTrue);

      await _disposeImeHarness(driver, harness);
    });

    test('edit-first approval preserves next-line suffix input', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final decision = Completer<bool>();
      var reviewCount = 0;
      final harness = await _createImeHarness(
        driver,
        onReviewInsertedText: (_) {
          reviewCount++;
          return decision.future;
        },
      );
      const command = r'echo $(id)';
      const followUpText = 'next';

      driver.updateEditingValue(
        _editingValue('$command\n', selectionOffset: command.length + 1),
      );
      await driver.flush();

      driver.engine.performAction(TextInputAction.newline);
      await driver.flush();

      driver.updateEditingValue(
        _editingValue(
          '$command\n$followUpText',
          selectionOffset: command.length + 1 + followUpText.length,
          composing: const TextRange(
            start: command.length + 1,
            end: command.length + 1 + followUpText.length,
          ),
        ),
      );
      await driver.flush();

      expect(reviewCount, 1);
      decision.complete(true);
      await driver.flush();
      await driver.flush();

      expect(
        harness.terminalOutput.join(),
        '$command${_terminalKeyOutput(TerminalKey.enter)}',
      );

      driver.updateEditingValue(
        _editingValue(followUpText, selectionOffset: followUpText.length),
      );
      await driver.flush();

      expect(
        harness.terminalOutput.join(),
        '$command${_terminalKeyOutput(TerminalKey.enter)}$followUpText',
      );
      expect(
        driver.engine.editingValue,
        const TextEditingValue(
          text: '$_deleteDetectionMarker$followUpText',
          selection: TextSelection.collapsed(
            offset: _deleteDetectionMarker.length + followUpText.length,
          ),
        ),
      );

      await _disposeImeHarness(driver, harness);
    });

    test(
      'exact stale composing text does not block later Enter actions',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final harness = await _createImeHarness(driver);
        const command = 'echo ready';

        driver.updateEditingValue(
          _editingValue(command, selectionOffset: command.length),
        );
        await driver.flush();
        driver.engine.performAction(TextInputAction.newline);
        await driver.flush();

        driver.updateEditingValue(
          _editingValue(
            command,
            selectionOffset: command.length,
            composing: const TextRange(start: 0, end: command.length),
          ),
        );
        await driver.flush();

        driver.engine.performAction(TextInputAction.newline);
        await driver.flush();
        driver.engine.performAction(TextInputAction.newline);
        await driver.flush();

        expect(
          harness.terminalOutput.join(),
          '$command${_terminalKeyOutput(TerminalKey.enter)}'
          '${_terminalKeyOutput(TerminalKey.enter)}'
          '${_terminalKeyOutput(TerminalKey.enter)}',
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'captures composing next-line input while command review is pending',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final decision = Completer<bool>();
        var reviewCount = 0;
        final harness = await _createImeHarness(
          driver,
          onReviewInsertedText: (_) {
            reviewCount++;
            return decision.future;
          },
        );
        const command = r'echo $(id)';
        const followUpText = 'next';

        driver.updateEditingValue(
          _editingValue(
            command,
            selectionOffset: command.length,
            composing: const TextRange(start: 0, end: command.length),
          ),
        );
        await driver.flush();
        driver.engine.performAction(TextInputAction.newline);
        await driver.flush();

        driver.updateEditingValue(
          _editingValue(
            '$command\n$followUpText',
            selectionOffset: command.length + 1 + followUpText.length,
            composing: const TextRange(
              start: command.length + 1,
              end: command.length + 1 + followUpText.length,
            ),
          ),
        );
        await driver.flush();

        driver.log.clear();
        decision.complete(true);
        await driver.flush();
        await driver.flush();

        expect(reviewCount, 1);
        expect(
          harness.terminalOutput.join(),
          '$command${_terminalKeyOutput(TerminalKey.enter)}',
        );

        driver.updateEditingValue(
          _editingValue(followUpText, selectionOffset: followUpText.length),
        );
        await driver.flush();

        expect(
          harness.terminalOutput.join(),
          '$command${_terminalKeyOutput(TerminalKey.enter)}$followUpText',
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'multiline composition still sends the final deferred Enter',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final decision = Completer<bool>();
        var shiftActive = true;
        final harness = await _createImeHarness(
          driver,
          onReviewInsertedText: (_) => decision.future,
          resolveTerminalKeyModifiers: () =>
              (ctrl: false, alt: false, shift: shiftActive),
          consumeTerminalKeyModifiers: () => shiftActive = false,
        );
        const command = 'printf one\nprintf two';

        driver.updateEditingValue(
          _editingValue(
            command,
            selectionOffset: command.length,
            composing: const TextRange(start: 0, end: command.length),
          ),
        );
        await driver.flush();
        driver.engine.performAction(TextInputAction.newline);
        await driver.flush();

        decision.complete(true);
        await driver.flush();
        await driver.flush();

        expect(
          harness.terminalOutput.join(),
          'printf one${_terminalKeyOutput(TerminalKey.enter)}'
          'printf two$_terminalShiftEnterNewlineInput',
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'trailing composed newline does not consume the deferred Enter',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        var shiftActive = true;
        final harness = await _createImeHarness(
          driver,
          resolveTerminalKeyModifiers: () =>
              (ctrl: false, alt: false, shift: shiftActive),
          consumeTerminalKeyModifiers: () => shiftActive = false,
        );
        const command = 'printf one\n';

        driver.updateEditingValue(
          _editingValue(
            command,
            selectionOffset: command.length,
            composing: const TextRange(start: 0, end: command.length),
          ),
        );
        await driver.flush();
        driver.engine.performAction(TextInputAction.newline);
        await driver.flush();

        expect(
          harness.terminalOutput.join(),
          'printf one${_terminalKeyOutput(TerminalKey.enter)}'
          '$_terminalShiftEnterNewlineInput',
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'trailing-newline composition replays only next-line suffix input',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final decision = Completer<bool>();
        final harness = await _createImeHarness(
          driver,
          onReviewInsertedText: (_) => decision.future,
        );
        const command = 'printf `one`\n';
        const followUpText = 'next';

        driver.updateEditingValue(
          _editingValue(
            command,
            selectionOffset: command.length,
            composing: const TextRange(start: 0, end: command.length),
          ),
        );
        await driver.flush();
        driver.engine.performAction(TextInputAction.newline);
        await driver.flush();

        driver.updateEditingValue(
          _editingValue(
            '$command$followUpText',
            selectionOffset: command.length + followUpText.length,
            composing: const TextRange(
              start: command.length,
              end: command.length + followUpText.length,
            ),
          ),
        );
        await driver.flush();

        decision.complete(true);
        await driver.flush();
        await driver.flush();

        expect(
          harness.terminalOutput.join(),
          'printf `one`${_terminalKeyOutput(TerminalKey.enter)}'
          '${_terminalKeyOutput(TerminalKey.enter)}',
        );
        expect(
          _setEditingStateStates(driver.log, stripTerminalMarker: true).last,
          const (
            text: followUpText,
            selectionBase: followUpText.length,
            selectionExtent: followUpText.length,
            composingBase: 0,
            composingExtent: followUpText.length,
          ),
        );

        driver.updateEditingValue(
          _editingValue(followUpText, selectionOffset: followUpText.length),
        );
        await driver.flush();

        expect(
          harness.terminalOutput.join(),
          'printf `one`${_terminalKeyOutput(TerminalKey.enter)}'
          '${_terminalKeyOutput(TerminalKey.enter)}$followUpText',
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test('reviews high-risk multi-character IME insertion', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final decision = Completer<bool>();
      final reviews = <TerminalCommandReview>[];
      final harness = await _createImeHarness(
        driver,
        onReviewInsertedText: (review) {
          reviews.add(review);
          return decision.future;
        },
      );
      final terminalOutput = harness.terminalOutput;

      driver.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Becho \$(id)',
          selection: TextSelection.collapsed(offset: 12),
        ),
      );
      await driver.flush();

      expect(reviews, hasLength(1));
      expect(reviews.single.command, r'echo $(id)');
      expect(
        reviews.single.reasons,
        contains(TerminalCommandReviewReason.commandSubstitution),
      );
      expect(terminalOutput, isEmpty);
      expect(driver.effects, [('review', r'echo $(id)')]);

      decision.complete(true);
      await driver.flush();
      await driver.flush();

      expect(terminalStateFromEvents(terminalOutput), (
        text: r'echo $(id)',
        cursorOffset: r'echo $(id)'.length,
      ));

      expect(driver.effects, [
        ('review', r'echo $(id)'),
        'user input',
        ('output', r'echo $(id)'),
      ]);
      await _disposeImeHarness(driver, harness);
    });

    test(
      'does not review quoted shell-like IME text as suspicious paste',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final reviews = <TerminalCommandReview>[];
        const benignCommand = 'printf "%s" "fish & chips | <html>"';
        final harness = await _createImeHarness(
          driver,
          onReviewInsertedText: (review) async {
            reviews.add(review);
            return true;
          },
        );
        final terminalOutput = harness.terminalOutput;

        driver.updateEditingValue(
          const TextEditingValue(
            text: '$_deleteDetectionMarker$benignCommand',
            selection: TextSelection.collapsed(
              offset: _deleteDetectionMarker.length + benignCommand.length,
            ),
          ),
        );
        await driver.flush();
        await driver.flush();

        expect(reviews, isEmpty);
        expect(terminalOutput.join(), benignCommand);

        await _disposeImeHarness(driver, harness);
      },
    );

    test('does not review a short swipe-composed word', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final reviews = <TerminalCommandReview>[];
      final harness = await _createImeHarness(
        driver,
        onReviewInsertedText: (review) async {
          reviews.add(review);
          return true;
        },
      );
      final terminalOutput = harness.terminalOutput;

      driver.updateEditingValue(
        const TextEditingValue(
          text: '${_deleteDetectionMarker}copilot',
          selection: TextSelection.collapsed(offset: 9),
          composing: TextRange(start: 2, end: 9),
        ),
      );
      await driver.flush();

      expect(reviews, isEmpty);
      expect(terminalOutput, isEmpty);

      driver.updateEditingValue(
        const TextEditingValue(
          text: '${_deleteDetectionMarker}copilot ',
          selection: TextSelection.collapsed(offset: 10),
        ),
      );
      await driver.flush();

      expect(reviews, isEmpty);
      expect(terminalOutput.join(), 'copilot ');

      await _disposeImeHarness(driver, harness);
    });

    test('reviews paste-like keyboard payloads', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final reviews = <TerminalCommandReview>[];
      final insertedText = List.filled(
        terminalKeyboardPasteLikeInsertionThreshold + 1,
        'a',
      ).join();
      final harness = await _createImeHarness(
        driver,
        onReviewInsertedText: (review) async {
          reviews.add(review);
          return false;
        },
      );
      final terminalOutput = harness.terminalOutput;

      driver.updateEditingValue(
        TextEditingValue(
          text: '$_deleteDetectionMarker$insertedText',
          selection: TextSelection.collapsed(
            offset: _deleteDetectionMarker.length + insertedText.length,
          ),
        ),
      );
      await driver.flush();
      await driver.flush();

      expect(reviews, hasLength(1));
      expect(
        reviews.single.reasons,
        contains(TerminalCommandReviewReason.largeKeyboardInsertion),
      );
      expect(terminalOutput, isEmpty);
      expect(
        driver.engine.editingValue,
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(offset: 2),
        ),
      );

      await _disposeImeHarness(driver, harness);
    });

    test(
      'reviews a high-risk committed IME payload after composition ends',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final decision = Completer<bool>();
        final reviews = <TerminalCommandReview>[];
        final harness = await _createImeHarness(
          driver,
          onReviewInsertedText: (review) {
            reviews.add(review);
            return decision.future;
          },
        );
        final terminalOutput = harness.terminalOutput;

        driver.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho \$(id)',
            selection: TextSelection.collapsed(offset: 12),
            composing: TextRange(start: 2, end: 12),
          ),
        );
        await driver.flush();

        expect(reviews, isEmpty);
        expect(terminalOutput, isEmpty);

        driver.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho \$(id)',
            selection: TextSelection.collapsed(offset: 12),
          ),
        );
        await driver.flush();

        expect(reviews, hasLength(1));
        expect(reviews.single.command, r'echo $(id)');
        expect(terminalOutput, isEmpty);

        decision.complete(true);
        await driver.flush();
        await driver.flush();

        expect(terminalStateFromEvents(terminalOutput), (
          text: r'echo $(id)',
          cursorOffset: r'echo $(id)'.length,
        ));

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'does not review harmless IME text with standalone ampersand',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final reviews = <TerminalCommandReview>[];
        final harness = await _createImeHarness(
          driver,
          onReviewInsertedText: (review) async {
            reviews.add(review);
            return true;
          },
        );
        final terminalOutput = harness.terminalOutput;

        driver.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho ready & echo done',
            selection: TextSelection.collapsed(offset: 24),
          ),
        );
        await driver.flush();

        expect(reviews, isEmpty);
        expect(terminalOutput.join(), 'echo ready & echo done');

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'reviews a high-risk committed IME payload while keeping its selection',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final decision = Completer<bool>();
        final reviews = <TerminalCommandReview>[];
        final harness = await _createImeHarness(
          driver,
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

        driver.log.clear();
        driver.updateEditingValue(
          const TextEditingValue(
            text: suspiciousText,
            selection: suspiciousSelection,
          ),
        );
        await driver.flush();

        expect(reviews, hasLength(1));
        expect(reviews.single.command, suspiciousUserText);
        expect(
          reviews.single.reasons,
          contains(TerminalCommandReviewReason.commandSubstitution),
        );
        expect(terminalOutput, isEmpty);
        expect(
          driver.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          isEmpty,
        );

        decision.complete(true);
        await driver.flush();
        await driver.flush();

        expect(terminalTextFromEvents(terminalOutput), suspiciousUserText);

        final client = driver.engine;
        expect(
          client.editingValue,
          const TextEditingValue(
            text: suspiciousText,
            selection: suspiciousSelection,
          ),
        );
        expect(
          driver.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          isEmpty,
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test('rejects high-risk IME insertion until the user approves', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(
        driver,
        onReviewInsertedText: (_) async => false,
      );
      final terminalOutput = harness.terminalOutput;

      driver.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Becho \$(id)',
          selection: TextSelection.collapsed(offset: 12),
        ),
      );
      await driver.flush();
      await driver.flush();

      final client = driver.engine;
      expect(terminalOutput, isEmpty);
      expect(client.editingValue.text, _deleteDetectionMarker);

      await _disposeImeHarness(driver, harness);
    });

    test(
      'reviews high-risk IME insertions against the full terminal line context',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final reviews = <TerminalCommandReview>[];
        final harness = await _createImeHarness(
          driver,
          onReviewInsertedText: (review) async {
            reviews.add(review);
            return false;
          },
        );
        final terminalOutput = harness.terminalOutput;

        const existingCommand = r'echo $(';
        for (var index = 1; index <= existingCommand.length; index++) {
          final currentCommand = existingCommand.substring(0, index);
          driver.updateEditingValue(
            TextEditingValue(
              text: '$_deleteDetectionMarker$currentCommand',
              selection: TextSelection.collapsed(
                offset: _deleteDetectionMarker.length + currentCommand.length,
              ),
            ),
          );
          await driver.flush();
        }

        reviews.clear();

        const combinedCommand = '${existingCommand}id)';
        driver.updateEditingValue(
          const TextEditingValue(
            text: '$_deleteDetectionMarker$combinedCommand',
            selection: TextSelection.collapsed(
              offset: _deleteDetectionMarker.length + combinedCommand.length,
            ),
          ),
        );
        await driver.flush();
        await driver.flush();

        expect(terminalTextFromEvents(terminalOutput), existingCommand);
        expect(reviews, hasLength(1));
        expect(reviews.single.command, combinedCommand);
        expect(
          reviews.single.reasons,
          contains(TerminalCommandReviewReason.commandSubstitution),
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'ignores stale review approvals when a newer editing value arrives',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final decision = Completer<bool>();
        final reviews = <TerminalCommandReview>[];
        final harness = await _createImeHarness(
          driver,
          onReviewInsertedText: (review) {
            reviews.add(review);
            return decision.future;
          },
        );
        final terminalOutput = harness.terminalOutput;

        driver.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho \$(id)',
            selection: TextSelection.collapsed(offset: 12),
          ),
        );
        await driver.flush();

        expect(reviews, hasLength(1));
        expect(terminalOutput, isEmpty);

        driver.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Bls',
            selection: TextSelection.collapsed(offset: 4),
          ),
        );
        await driver.flush();

        expect(reviews, hasLength(1));
        expect(terminalOutput, isEmpty);

        decision.complete(true);
        await driver.flush();
        await driver.flush();

        expect(terminalOutput.join(), 'ls');

        final client = driver.engine;
        expect(client.editingValue.text, '${_deleteDetectionMarker}ls');

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'ignores stale review approvals after an external IME buffer clear',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final decision = Completer<bool>();
        final reviews = <TerminalCommandReview>[];
        final harness = await _createImeHarness(
          driver,
          onReviewInsertedText: (review) {
            reviews.add(review);
            return decision.future;
          },
        );
        final terminalOutput = harness.terminalOutput;
        final controller = harness.controller;

        driver.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho \$(id)',
            selection: TextSelection.collapsed(offset: 12),
          ),
        );
        await driver.flush();

        expect(reviews, hasLength(1));
        expect(terminalOutput, isEmpty);

        controller.clearImeBuffer();
        await driver.flush();

        final client = driver.engine;
        expect(client.editingValue.text, _deleteDetectionMarker);

        decision.complete(true);
        await driver.flush();
        await driver.flush();

        expect(terminalOutput, isEmpty);
        expect(client.editingValue.text, _deleteDetectionMarker);

        await _disposeImeHarness(driver, harness);
      },
    );

    test('trims a swipe-leading space even when a composing update is overwritten in the review queue', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final decision = Completer<bool>();
      final harness = await _createImeHarness(
        driver,
        onReviewInsertedText: (_) => decision.future,
      );
      final terminalOutput = harness.terminalOutput;

      driver.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Becho \$(id)',
          selection: TextSelection.collapsed(offset: 12),
        ),
      );
      await driver.flush();

      expect(terminalOutput, isEmpty);

      driver.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200B hello',
          selection: TextSelection.collapsed(offset: 8),
          composing: TextRange(start: 2, end: 8),
        ),
      );
      await driver.flush();

      driver.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200B hello',
          selection: TextSelection.collapsed(offset: 8),
        ),
      );
      await driver.flush();

      decision.complete(true);
      await driver.flush();
      await driver.flush();

      expect(terminalTextFromEvents(terminalOutput), 'hello');
      expect(terminalStateFromEvents(terminalOutput), (
        text: 'hello',
        cursorOffset: 'hello'.length,
      ));

      await _disposeImeHarness(driver, harness);
    });

    test('reviews high-risk IME insertions after input resets', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);
      final reviews = <TerminalCommandReview>[];
      var readOnly = false;

      await driver.attach(
        terminal: terminal,
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
      );
      const existingCommand = r'echo $(';
      for (var index = 1; index <= existingCommand.length; index++) {
        final currentCommand = existingCommand.substring(0, index);
        driver.updateEditingValue(
          TextEditingValue(
            text: '$_deleteDetectionMarker$currentCommand',
            selection: TextSelection.collapsed(
              offset: _deleteDetectionMarker.length + currentCommand.length,
            ),
          ),
        );
        await driver.flush();
      }

      readOnly = true;
      driver.engine.options = TerminalImeOptions(
        platform: driver.platform,
        deleteDetection: true,
        readOnly: readOnly,
      );
      driver.engine.reset(TerminalImeResetReason.connection);
      await driver.flush();

      readOnly = false;
      driver.engine.options = TerminalImeOptions(
        platform: driver.platform,
        deleteDetection: true,
        readOnly: readOnly,
      );
      driver.engine.reset(TerminalImeResetReason.connection);
      await driver.flush();

      reviews.clear();

      driver.updateEditingValue(
        const TextEditingValue(
          text: '$_deleteDetectionMarker id)',
          selection: TextSelection.collapsed(offset: 6),
        ),
      );
      await driver.flush();
      await driver.flush();

      expect(reviews, hasLength(1));
      expect(reviews.single.command, r'echo $( id)');
      expect(
        reviews.single.reasons,
        contains(TerminalCommandReviewReason.commandSubstitution),
      );
      expect(terminalTextFromEvents(terminalOutput), existingCommand);
    });
  });

  group('TerminalTextInputHandler compared with TextField', () {
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
        terminalEchoes: 1,
      ),
      (
        name: 'matches earlier-word replacement after partially deleting newer text',
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
        terminalEchoes: null,
      ),
      ..._buildFlutterReplacedParityScenarios(),
      ..._buildFlutterDeltaParityScenarios(),
      ..._buildFlutterComposingParityScenarios(),
      ..._buildGeneratedComparisonScenarios(),
      ..._buildGptComparisonScenarios(),
    ];

    for (final scenario in matrixScenarios) {
      test(scenario.name, () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        await _expectRecordedTextFieldSequence(
          driver,
          sequence: scenario.sequence,
          expectedTerminalEchoCount: scenario.terminalEchoes,
        );
      });
    }

    final opusResetScenarios = _buildOpusResetScenarios();

    for (final scenario in opusResetScenarios) {
      test(scenario.name, () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        await _expectResetContinuationScenario(driver, scenario);
      });
    }

    test('clears the IME buffer after trailing backspace', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(driver);
      driver.log.clear();

      // Type "hello".
      driver.updateEditingValue(_editingValue('hello', selectionOffset: 5));
      await driver.flush();

      driver.log.clear();

      // Backspace to "hell".
      driver.updateEditingValue(_editingValue('hell', selectionOffset: 4));
      await driver.flush();

      // The terminal should show "hell".
      expect(terminalTextFromEvents(harness.terminalOutput), 'hell');

      // The IME buffer should be cleared after the backspace.
      expect(
        driver.log
            .where((call) => call.method == 'TextInput.setEditingState')
            .length,
        1,
      );

      // The editing state is reset to the marker only so suggestions start
      // fresh from the next typed character.
      final client = driver.engine;
      expect(
        client.editingValue,
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(offset: 2),
        ),
      );

      await _disposeImeHarness(driver, harness);
    });

    test(
      'defers iOS trailing backspace buffer clears so native repeat stays fast',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        driver.platform = TargetPlatform.iOS;

        final harness = await _createImeHarness(driver);

        driver.updateEditingValue(_editingValue('hello', selectionOffset: 5));
        await driver.flush();
        driver.log.clear();

        driver.updateEditingValue(_editingValue('hell', selectionOffset: 4));
        await driver.flush();

        expect(terminalTextFromEvents(harness.terminalOutput), 'hell');
        expect(
          driver.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          isEmpty,
        );
        expect(
          driver.engine.editingValue,
          _editingValue('hell', selectionOffset: 4),
        );

        driver.updateEditingValue(_editingValue('hel', selectionOffset: 3));
        await driver.flush();

        expect(terminalTextFromEvents(harness.terminalOutput), 'hel');
        expect(
          driver.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          isEmpty,
        );

        await driver.flush(terminalIosBackspaceRepeatSettleDelay);

        expect(
          driver.engine.editingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
        expect(
          driver.log
              .where((call) => call.method == 'TextInput.setEditingState')
              .length,
          1,
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'keeps the iOS backspace buffer through slow native repeat gaps',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        driver.platform = TargetPlatform.iOS;

        final harness = await _createImeHarness(driver);

        driver.updateEditingValue(_editingValue('hello', selectionOffset: 5));
        await driver.flush();
        harness.terminalOutput.clear();
        driver.log.clear();

        driver.updateEditingValue(_editingValue('hell', selectionOffset: 4));
        await driver.flush();

        await driver.flush(const Duration(milliseconds: 600));

        expect(
          driver.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          isEmpty,
        );
        expect(
          driver.engine.editingValue,
          _editingValue('hell', selectionOffset: 4),
        );

        driver.updateEditingValue(_editingValue('hel', selectionOffset: 3));
        await driver.flush();

        expect(
          terminalStateFromEvents(
            harness.terminalOutput,
            initialText: 'hello',
            initialCursorOffset: 5,
          ),
          (text: 'hel', cursorOffset: 3),
        );
        expect(
          driver.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          isEmpty,
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'strips leaked iOS backspace runways before a composed slash command',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        driver.platform = TargetPlatform.iOS;

        final harness = await _createImeHarness(driver);

        driver.updateEditingValue(_editingValue('x', selectionOffset: 1));
        await driver.flush();
        driver.updateEditingValue(_editingValue('', selectionOffset: 0));
        await driver.flush();

        expect(
          driver.engine.editingValue,
          _iosBackspaceRunwayValue(terminalIosBackspaceRepeatRunwayLength),
        );

        harness.terminalOutput.clear();

        driver.updateEditingValue(
          _iosBackspaceRunwayComposingValue(
            terminalIosBackspaceRepeatRunwayLength,
            suffix: '/help',
          ),
        );
        await driver.flush();

        expect(harness.terminalOutput, isEmpty);

        driver.updateEditingValue(
          _iosBackspaceRunwayValue(
            terminalIosBackspaceRepeatRunwayLength,
            suffix: '/help',
          ),
        );
        await driver.flush();

        expect(harness.terminalOutput, ['/help']);
        expect(
          driver.engine.editingValue,
          _editingValue('/help', selectionOffset: '/help'.length),
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test('strips duplicated iOS backspace runways before typed text', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      driver.platform = TargetPlatform.iOS;

      final harness = await _createImeHarness(driver);

      driver.updateEditingValue(_editingValue('x', selectionOffset: 1));
      await driver.flush();
      driver.updateEditingValue(_editingValue('', selectionOffset: 0));
      await driver.flush();

      expect(
        driver.engine.editingValue,
        _iosBackspaceRunwayValue(terminalIosBackspaceRepeatRunwayLength),
      );

      harness.terminalOutput.clear();

      driver.updateEditingValue(
        _iosBackspaceRunwayValue(
          terminalIosBackspaceRepeatRunwayLength * 2,
          suffix: 'ls ',
        ),
      );
      await driver.flush();

      expect(harness.terminalOutput, ['ls ']);
      expect(
        driver.engine.editingValue,
        _editingValue('ls ', selectionOffset: 'ls '.length),
      );

      await _disposeImeHarness(driver, harness);
    });

    test(
      'strips stale iOS backspace runways after the platform drops state',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        driver.platform = TargetPlatform.iOS;

        final harness = await _createImeHarness(driver);

        driver.updateEditingValue(_editingValue('x', selectionOffset: 1));
        await driver.flush();
        driver.updateEditingValue(_editingValue('', selectionOffset: 0));
        await driver.flush();

        expect(
          driver.engine.editingValue,
          _iosBackspaceRunwayValue(terminalIosBackspaceRepeatRunwayLength),
        );

        driver.updateEditingValue(
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
        await driver.flush();

        harness.terminalOutput.clear();

        driver.updateEditingValue(
          _iosBackspaceRunwayValue(
            terminalIosBackspaceRepeatRunwayLength,
            suffix: 'add ',
          ),
        );
        await driver.flush();

        expect(harness.terminalOutput, ['add ']);
        expect(
          driver.engine.editingValue,
          _editingValue('add ', selectionOffset: 'add '.length),
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'preserves leading zero-width text outside iOS backspace runway state',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        driver.platform = TargetPlatform.android;

        final harness = await _createImeHarness(driver);
        const input = '\u200B/help';

        driver.updateEditingValue(
          _editingValue(input, selectionOffset: input.length),
        );
        await driver.flush();

        expect(harness.terminalOutput, [input]);

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'keeps iOS held backspace fast after visible text is exhausted',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        driver.platform = TargetPlatform.iOS;

        final harness = await _createImeHarness(driver);
        final backspaceOutput = _terminalKeyOutput(TerminalKey.backspace);

        driver.updateEditingValue(_editingValue('ab', selectionOffset: 2));
        await driver.flush();
        harness.terminalOutput.clear();
        driver.log.clear();

        driver.updateEditingValue(_editingValue('a', selectionOffset: 1));
        await driver.flush();
        driver.updateEditingValue(_editingValue('', selectionOffset: 0));
        await driver.flush();

        expect(
          terminalStateFromEvents(
            harness.terminalOutput,
            initialText: 'ab',
            initialCursorOffset: 2,
          ),
          (text: '', cursorOffset: 0),
        );
        expect(
          driver.engine.editingValue,
          _iosBackspaceRunwayValue(terminalIosBackspaceRepeatRunwayLength),
        );

        harness.terminalOutput.clear();
        driver.log.clear();

        driver.updateEditingValue(
          _iosBackspaceRunwayValue(terminalIosBackspaceRepeatRunwayLength - 1),
        );
        await driver.flush();

        expect(harness.terminalOutput, [backspaceOutput]);
        expect(
          driver.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          isEmpty,
        );

        harness.terminalOutput.clear();

        driver.updateEditingValue(
          _iosBackspaceRunwayValue(
            terminalIosBackspaceRepeatRunwayLength - 1,
            suffix: 'x',
          ),
        );
        await driver.flush();

        expect(harness.terminalOutput, ['x']);
        expect(
          driver.engine.editingValue,
          _editingValue('x', selectionOffset: 1),
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test('typing cancels the deferred iOS trailing backspace clear', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      driver.platform = TargetPlatform.iOS;

      final harness = await _createImeHarness(driver);

      driver.updateEditingValue(_editingValue('hello', selectionOffset: 5));
      await driver.flush();
      driver.log.clear();

      driver.updateEditingValue(_editingValue('hell', selectionOffset: 4));
      await driver.flush();
      driver.updateEditingValue(_editingValue('hellp', selectionOffset: 5));
      await driver.flush();
      await driver.flush(terminalIosBackspaceRepeatSettleDelay);

      expect(terminalTextFromEvents(harness.terminalOutput), 'hellp');
      expect(
        driver.engine.editingValue,
        _editingValue('hellp', selectionOffset: 5),
      );
      expect(
        driver.log.where((call) => call.method == 'TextInput.setEditingState'),
        isEmpty,
      );

      await _disposeImeHarness(driver, harness);
    });

    test(
      'typing after trailing backspace inserts from a fresh buffer',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final harness = await _createImeHarness(driver);

        // Type "hello".
        driver.updateEditingValue(_editingValue('hello', selectionOffset: 5));
        await driver.flush();

        // Backspace to "hell".
        driver.updateEditingValue(_editingValue('hell', selectionOffset: 4));
        await driver.flush();

        // Type "o" from the freshly cleared IME buffer.
        driver.updateEditingValue(_editingValue('o', selectionOffset: 1));
        await driver.flush();

        // The terminal should show "hello".
        expect(terminalTextFromEvents(harness.terminalOutput), 'hello');

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'clears the IME buffer after deleting a corrected contraction tail',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final harness = await _createImeHarness(driver);

        driver.updateEditingValue(
          _editingValue("didn't", selectionOffset: "didn't".length),
        );
        await driver.flush();

        driver.log.clear();

        driver.updateEditingValue(
          _editingValue('didn', selectionOffset: 'didn'.length),
        );
        await driver.flush();

        expect(terminalTextFromEvents(harness.terminalOutput), 'didn');

        final client = driver.engine;
        expect(
          client.editingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'trims a leading swipe space after backspace-triggered IME buffer clear',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final harness = await _createImeHarness(driver);

        // Type "hello".
        driver.updateEditingValue(_editingValue('hello', selectionOffset: 5));
        await driver.flush();

        // Backspace to "hell".
        driver.updateEditingValue(_editingValue('hell', selectionOffset: 4));
        await driver.flush();

        // Swipe-type " world" from the cleared IME buffer.
        await _commitSwipeText(driver, '$_deleteDetectionMarker world');
        await driver.flush();

        // The cleared IME buffer should not keep suggesting continuations from
        // the deleted word. Because the terminal text before the cursor does
        // not end in whitespace, the leading swipe space is trimmed.
        expect(
          terminalStateFromEvents(harness.terminalOutput).text,
          'hellworld',
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test('trims a leading suggestion space after backspace-triggered IME buffer clear', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(driver);

      driver.updateEditingValue(
        _editingValue('didnt', selectionOffset: 'didnt'.length),
      );
      await driver.flush();

      driver.updateEditingValue(
        _editingValue('didn', selectionOffset: 'didn'.length),
      );
      await driver.flush();

      driver.updateEditingValue(
        const TextEditingValue(
          text: '$_deleteDetectionMarker test',
          selection: TextSelection.collapsed(offset: 7),
        ),
      );
      await driver.flush();

      expect(terminalTextFromEvents(harness.terminalOutput), 'didntest');

      await _disposeImeHarness(driver, harness);
    });

    test('preserves the shortened prefix when a delete-reset continuation resumes the same word with the live terminal prefix', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(
        driver,
        resolveTextBeforeCursor: () => 'didn',
      );

      driver.updateEditingValue(
        _editingValue('didnt', selectionOffset: 'didnt'.length),
      );
      await driver.flush();

      driver.updateEditingValue(
        _editingValue('didn', selectionOffset: 'didn'.length),
      );
      await driver.flush();

      driver.updateEditingValue(
        const TextEditingValue(
          text: '$_deleteDetectionMarker test',
          selection: TextSelection.collapsed(offset: 7),
        ),
      );
      await driver.flush();

      expect(terminalTextFromEvents(harness.terminalOutput), 'didntest');

      await _disposeImeHarness(driver, harness);
    });

    test('replaces a shortened first word after backspace without duplicating the prefix', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      await _suggestionReplacingShortenedFirstWord(driver);
    });

    for (final testCase in [
      (
        name: 'preserves a new separator when a trailing-backspace reset is followed by a same-initial unrelated committed word',
        initialEditingValue: _editingValue('shell', selectionOffset: 5),
        shortenedEditingValue: _editingValue('shel', selectionOffset: 4),
        continuation: _editingValue(' story ', selectionOffset: 7),
        initialState: (text: 'shel', cursorOffset: 'shel'.length),
        expected: (text: 'shel story ', cursorOffset: 'shel story '.length),
        expectedEditingValue: null,
      ),
      (
        name: 'preserves the deleted suffix when a trailing-backspace reset resumes the same word and continues into the next word',
        initialEditingValue: _editingValue('things', selectionOffset: 6),
        shortenedEditingValue: _editingValue('thin', selectionOffset: 4),
        continuation: _editingValue(' gs are ', selectionOffset: 8),
        initialState: (text: 'thin', cursorOffset: 'thin'.length),
        expected: (text: 'things are ', cursorOffset: 'things are '.length),
        expectedEditingValue: null,
      ),
      (
        name: 'keeps the shortened prefix when later delete-reset words only share letters with the deleted suggestion',
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
        name: 'drops a stale one-letter delete-reset fragment before the next word',
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
      test(testCase.name, () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final harness = await _createImeHarness(
          driver,
          resolveTextBeforeCursor: () => testCase.initialState.text,
          initialEditingValue: testCase.initialEditingValue,
        );
        final terminalOutput = harness.terminalOutput;
        driver.updateEditingValue(testCase.shortenedEditingValue);
        await driver.flush();
        terminalOutput.clear();
        driver.updateEditingValue(testCase.continuation);
        await driver.flush();
        expect(
          terminalStateFromEvents(
            terminalOutput,
            initialText: testCase.initialState.text,
            initialCursorOffset: testCase.initialState.cursorOffset,
          ),
          testCase.expected,
        );
        if (testCase.expectedEditingValue != null) {
          expect(driver.engine.editingValue, testCase.expectedEditingValue);
        }
        await _disposeImeHarness(driver, harness);
      });
    }

    test('trims a leading IME separator during delete-reset replacement when the live terminal prefix is visible', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      await _imeSeparatorDuringDeleteReset(driver);
    });

    test('preserves a manual separator when replacing a swiped word after backspacing into it', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      await _manualSeparatorAfterSwipeBackspace(driver);
    });

    test('preserves an IME separator when replacing a swiped word after backspacing into it', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      await _imeSeparatorAfterSwipeBackspace(driver);
    });

    test('does not force-resync the IME during replacement after deleting a later word', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      await _replacementAfterDeletingLaterWord(driver);
    });

    test(
      'trims a leading suggestion space after a committed newline',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final harness = await _createImeHarness(driver);

        driver.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho hi\n',
            selection: TextSelection.collapsed(offset: 10),
          ),
        );
        await driver.flush();

        driver.updateEditingValue(
          const TextEditingValue(
            text: '$_deleteDetectionMarker next',
            selection: TextSelection.collapsed(offset: 7),
          ),
        );
        await driver.flush();

        expect(
          terminalTextFromEvents(harness.terminalOutput),
          'echo hi${_terminalKeyOutput(TerminalKey.enter)}next',
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test('resets IME editing state after modifier chord character', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      var modifierActive = false;

      final harness = await _createImeHarness(
        driver,
        hasActiveToolbarModifier: () => modifierActive,
      );

      // Type "ls" normally.
      driver.updateEditingValue(_editingValue('ls', selectionOffset: 2));
      await driver.flush();
      expect(terminalTextFromEvents(harness.terminalOutput), 'ls');

      // Activate Ctrl modifier (simulating toolbar toggle).
      modifierActive = true;

      // Type 'c' with modifier active (would produce Ctrl+C in practice).
      driver.updateEditingValue(_editingValue('lsc', selectionOffset: 3));
      await driver.flush();

      // The IME editing state should be fully reset after the modified
      // character (control codes make the terminal state unpredictable).
      final client = driver.engine;
      expect(
        client.editingValue,
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(offset: 2),
        ),
      );

      await _disposeImeHarness(driver, harness);
    });

    test('applies modifiers before soft-keyboard text is emitted', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      var modifierActive = true;
      final harness = await _createImeHarness(
        driver,
        hasActiveToolbarModifier: () => modifierActive,
        applyTerminalTextInputModifiers: (text) {
          expect(text, 'q');
          modifierActive = false;
          return '\x11';
        },
      );

      driver.updateEditingValue(_editingValue('q', selectionOffset: 1));
      await driver.flush();

      expect(harness.terminalOutput, <String>['\x11']);
      expect(modifierActive, isFalse);
      expect(
        driver.engine.editingValue,
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(offset: 2),
        ),
      );

      await _disposeImeHarness(driver, harness);
    });

    test('modifier chords ignore stale multi-character IME batches', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final toolbarController = KeyboardToolbarController()..toggleCtrl();
      addTearDown(toolbarController.dispose);
      final harness = await _createImeHarness(
        driver,
        hasActiveToolbarModifier: () =>
            toolbarController.isCtrlActive || toolbarController.isAltActive,
        applyTerminalTextInputModifiers:
            toolbarController.applySystemKeyboardModifiers,
      );

      driver.updateEditingValue(
        _editingValue('staleq', selectionOffset: 'staleq'.length),
      );
      await driver.flush();

      expect(harness.terminalOutput, <String>['\x11']);
      expect(toolbarController.isCtrlActive, isFalse);
      expect(
        driver.engine.editingValue,
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(offset: 2),
        ),
      );

      await _disposeImeHarness(driver, harness);
    });

    test(
      'soft-keyboard newline uses Enter key path even with toolbar modifiers',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        var shiftActive = true;
        var textModifierCalls = 0;
        final harness = await _createImeHarness(
          driver,
          hasActiveToolbarModifier: () => true,
          resolveTerminalKeyModifiers: () =>
              (ctrl: false, alt: false, shift: shiftActive),
          consumeTerminalKeyModifiers: () => shiftActive = false,
          applyTerminalTextInputModifiers: (text) {
            textModifierCalls++;
            return text;
          },
        );

        driver.updateEditingValue(_editingValue('\n', selectionOffset: 1));
        await driver.flush();

        // Newline must not go through the single-grapheme text modifier path.
        expect(textModifierCalls, 0);
        expect(harness.terminalOutput, <String>[
          _terminalShiftEnterNewlineInput,
        ]);
        expect(shiftActive, isFalse);

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'controller clears the IME buffer after external terminal actions',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final harness = await _createImeHarness(driver);
        final controller = harness.controller;

        driver.updateEditingValue(_editingValue('hello', selectionOffset: 5));
        await driver.flush();

        controller.clearImeBuffer();
        await driver.flush();

        final client = driver.engine;
        expect(
          client.editingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'resets IME after second character of a two-part chord (tmux Ctrl+b, c)',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        var modifierActive = false;
        var fakeNow = DateTime(2026);
        driver.clock = () => fakeNow;
        addTearDown(() => driver.clock = null);
        final harness = await _createImeHarness(
          driver,
          hasActiveToolbarModifier: () => modifierActive,
        );

        // Step 1: Ctrl+b (modifier active, type 'b').
        modifierActive = true;
        driver.updateEditingValue(_editingValue('b', selectionOffset: 1));
        await driver.flush();

        // Modifier consumed (one-shot).
        modifierActive = false;

        // After Ctrl+b the buffer should be fully reset.
        var client = driver.engine;
        expect(
          client.editingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        // Step 2: 'c' within the chord window (< 500 ms).
        fakeNow = fakeNow.add(const Duration(milliseconds: 100));
        driver.updateEditingValue(_editingValue('c', selectionOffset: 1));
        await driver.flush();

        // The follow-up character should also trigger a full reset.
        client = driver.engine;
        expect(
          client.editingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        // Step 3: Type normally — 'l' should accumulate (no more chord).
        driver.updateEditingValue(_editingValue('l', selectionOffset: 1));
        await driver.flush();

        // Normal typing accumulates in the buffer.
        client = driver.engine;
        expect(
          client.editingValue,
          const TextEditingValue(
            text: '${_deleteDetectionMarker}l',
            selection: TextSelection.collapsed(offset: 3),
          ),
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test('typing copilot after tmux Ctrl+b, c keeps the leading c when space is pressed', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      var modifierActive = false;
      var fakeNow = DateTime(2026);
      driver.clock = () => fakeNow;
      addTearDown(() => driver.clock = null);
      final harness = await _createImeHarness(
        driver,
        resolveTextBeforeCursor: () => '>',
        hasActiveToolbarModifier: () => modifierActive,
      );
      final terminalOutput = harness.terminalOutput;
      final controller = harness.controller;

      modifierActive = true;
      driver.updateEditingValue(_editingValue('b', selectionOffset: 1));
      await driver.flush();
      modifierActive = false;

      fakeNow = fakeNow.add(const Duration(milliseconds: 100));
      driver.updateEditingValue(_editingValue('c', selectionOffset: 1));
      await driver.flush();

      terminalOutput.clear();
      driver.log.clear();
      controller.handleExternalTerminalOutput();
      await driver.flush();

      for (var index = 1; index <= 'copilot'.length; index++) {
        final text = 'copilot'.substring(0, index);
        driver.updateEditingValue(_editingValue(text, selectionOffset: index));
        await driver.flush();
      }

      driver.updateEditingValue(
        _editingValue('c opilot ', selectionOffset: 'c opilot '.length),
      );
      await driver.flush();

      expect(terminalTextFromEvents(terminalOutput), 'copilot ');

      await _disposeImeHarness(driver, harness);
    });

    test(
      'preserves an intentional space inserted inside the first token',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final harness = await _createImeHarness(
          driver,
          resolveTextBeforeCursor: () => '>',
        );
        final terminalOutput = harness.terminalOutput;
        harness.controller.handleExternalTerminalOutput();
        await driver.flush();

        driver.updateEditingValue(
          _editingValue('copilot', selectionOffset: 'copilot'.length),
        );
        await driver.flush();

        terminalOutput.clear();

        driver.updateEditingValue(
          _editingValue('c opilot', selectionOffset: 2),
        );
        await driver.flush();

        expect(
          terminalStateFromEvents(
            terminalOutput,
            initialText: 'copilot',
            initialCursorOffset: 'copilot'.length,
          ),
          (text: 'c opilot', cursorOffset: 2),
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test(
      'preserves leading indentation when a split token is normalized',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        var modifierActive = false;
        var fakeNow = DateTime(2026);
        driver.clock = () => fakeNow;
        addTearDown(() => driver.clock = null);
        final harness = await _createImeHarness(
          driver,
          resolveTextBeforeCursor: () => '>',
          hasActiveToolbarModifier: () => modifierActive,
        );
        final terminalOutput = harness.terminalOutput;
        final controller = harness.controller;

        modifierActive = true;
        driver.updateEditingValue(_editingValue('b', selectionOffset: 1));
        await driver.flush();
        modifierActive = false;

        fakeNow = fakeNow.add(const Duration(milliseconds: 100));
        driver.updateEditingValue(_editingValue('c', selectionOffset: 1));
        await driver.flush();

        terminalOutput.clear();
        controller.handleExternalTerminalOutput();
        await driver.flush();

        driver.updateEditingValue(
          _editingValue('  copilot', selectionOffset: '  copilot'.length),
        );
        await driver.flush();

        terminalOutput.clear();

        driver.updateEditingValue(
          _editingValue('  c opilot ', selectionOffset: '  c opilot '.length),
        );
        await driver.flush();

        expect(
          terminalStateFromEvents(
            terminalOutput,
            initialText: '  copilot',
            initialCursorOffset: '  copilot'.length,
          ),
          (text: '  copilot ', cursorOffset: '  copilot '.length),
        );

        await _disposeImeHarness(driver, harness);
      },
    );

    test('does not reset after modifier chord when follow-up arrives after timeout', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      var modifierActive = false;
      var fakeNow = DateTime(2026);
      driver.clock = () => fakeNow;
      addTearDown(() => driver.clock = null);
      final harness = await _createImeHarness(
        driver,
        hasActiveToolbarModifier: () => modifierActive,
      );

      // Ctrl+C (standalone modifier chord).
      modifierActive = true;
      driver.updateEditingValue(_editingValue('c', selectionOffset: 1));
      await driver.flush();
      modifierActive = false;

      // Buffer is reset after Ctrl+C.
      var client = driver.engine;
      expect(
        client.editingValue,
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(offset: 2),
        ),
      );

      // Advance past the chord window (> 500 ms).
      fakeNow = fakeNow.add(const Duration(milliseconds: 600));

      // Type 'l' — this should accumulate normally because the chord
      // window has expired.
      driver.updateEditingValue(_editingValue('l', selectionOffset: 1));
      await driver.flush();

      client = driver.engine;
      expect(
        client.editingValue,
        const TextEditingValue(
          text: '${_deleteDetectionMarker}l',
          selection: TextSelection.collapsed(offset: 3),
        ),
      );

      await _disposeImeHarness(driver, harness);
    });

    test('regular typing accumulates in IME buffer without reset', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(
        driver,
        hasActiveToolbarModifier: () => false,
      );
      final terminalOutput = harness.terminalOutput;

      // Type "hello" one character at a time.
      for (var i = 1; i <= 5; i++) {
        driver.updateEditingValue(
          _editingValue('hello'.substring(0, i), selectionOffset: i),
        );
        await driver.flush();
      }

      // The terminal should have "hello".
      expect(terminalTextFromEvents(terminalOutput), 'hello');

      // The IME editing state should still have the full accumulated text.
      final client = driver.engine;
      expect(
        client.editingValue,
        const TextEditingValue(
          text: '${_deleteDetectionMarker}hello',
          selection: TextSelection.collapsed(offset: 7),
        ),
      );

      await _disposeImeHarness(driver, harness);
    });
  });
}

Future<void> _swipeSeparatorAfterPromptReset(_ImeDriver driver) async {
  final harness = await _createImeHarness(
    driver,
    resolveTextBeforeCursor: () => '>',
  );

  harness.controller.clearImeBuffer();
  await driver.flush();

  await _commitSwipeText(driver, '$_deleteDetectionMarker world');

  expect(terminalTextFromEvents(harness.terminalOutput), 'world');

  await _disposeImeHarness(driver, harness);
}

Future<void> _suggestionReplacingShortenedFirstWord(_ImeDriver driver) async {
  final harness = await _createImeHarness(driver);

  driver.updateEditingValue(
    const TextEditingValue(
      text: '\u200B\u200Bteh ',
      selection: TextSelection.collapsed(offset: 6),
    ),
  );
  await driver.flush();

  harness.terminalOutput.clear();

  driver.updateEditingValue(
    const TextEditingValue(
      text: '\u200B\u200Bte',
      selection: TextSelection.collapsed(offset: 4),
    ),
  );
  await driver.flush();

  driver.updateEditingValue(
    const TextEditingValue(
      text: '\u200B\u200B the ',
      selection: TextSelection.collapsed(offset: 7),
    ),
  );
  await driver.flush();

  expect(
    terminalStateFromEvents(
      harness.terminalOutput,
      initialText: 'teh ',
      initialCursorOffset: 'teh '.length,
    ),
    (text: 'the ', cursorOffset: 'the '.length),
  );

  await _disposeImeHarness(driver, harness);
}

Future<void> _imeSeparatorDuringDeleteReset(_ImeDriver driver) async {
  final harness = await _createImeHarness(
    driver,
    resolveTextBeforeCursor: () => 'te',
  );

  driver.updateEditingValue(
    const TextEditingValue(
      text: '\u200B\u200Bteh ',
      selection: TextSelection.collapsed(offset: 6),
    ),
  );
  await driver.flush();

  harness.terminalOutput.clear();

  driver.updateEditingValue(
    const TextEditingValue(
      text: '\u200B\u200Bte',
      selection: TextSelection.collapsed(offset: 4),
    ),
  );
  await driver.flush();

  driver.updateEditingValue(
    const TextEditingValue(
      text: '\u200B\u200B the ',
      selection: TextSelection.collapsed(offset: 7),
    ),
  );
  await driver.flush();

  expect(
    terminalStateFromEvents(
      harness.terminalOutput,
      initialText: 'teh ',
      initialCursorOffset: 'teh '.length,
    ),
    (text: 'the ', cursorOffset: 'the '.length),
  );

  await _disposeImeHarness(driver, harness);
}

Future<void> _manualSeparatorAfterSwipeBackspace(_ImeDriver driver) async {
  final harness = await _createImeHarness(driver);

  await _commitSwipeText(driver, '$_deleteDetectionMarker teh');

  driver.updateEditingValue(
    const TextEditingValue(
      text: '${_deleteDetectionMarker}teh ',
      selection: TextSelection.collapsed(offset: 6),
    ),
  );
  await driver.flush();

  harness.terminalOutput.clear();

  driver.updateEditingValue(
    const TextEditingValue(
      text: '${_deleteDetectionMarker}te',
      selection: TextSelection.collapsed(offset: 4),
    ),
  );
  await driver.flush();

  driver.updateEditingValue(
    const TextEditingValue(
      text: '${_deleteDetectionMarker}the ',
      selection: TextSelection.collapsed(offset: 6),
    ),
  );
  await driver.flush();

  expect(
    terminalStateFromEvents(
      harness.terminalOutput,
      initialText: 'teh ',
      initialCursorOffset: 'teh '.length,
    ),
    (text: 'the ', cursorOffset: 'the '.length),
  );

  await _disposeImeHarness(driver, harness);
}

Future<void> _imeSeparatorAfterSwipeBackspace(_ImeDriver driver) async {
  final harness = await _createImeHarness(driver);

  await _commitSwipeText(driver, '${_deleteDetectionMarker}teh ');

  harness.terminalOutput.clear();

  driver.updateEditingValue(
    const TextEditingValue(
      text: '${_deleteDetectionMarker}te',
      selection: TextSelection.collapsed(offset: 4),
    ),
  );
  await driver.flush();

  driver.updateEditingValue(
    const TextEditingValue(
      text: '${_deleteDetectionMarker}the ',
      selection: TextSelection.collapsed(offset: 6),
    ),
  );
  await driver.flush();

  expect(
    terminalStateFromEvents(
      harness.terminalOutput,
      initialText: 'teh ',
      initialCursorOffset: 'teh '.length,
    ),
    (text: 'the ', cursorOffset: 'the '.length),
  );

  await _disposeImeHarness(driver, harness);
}

Future<void> _replacementAfterDeletingLaterWord(_ImeDriver driver) async {
  final harness = await _createImeHarness(driver);

  driver.updateEditingValue(
    const TextEditingValue(
      text: '\u200B\u200Bteh world ',
      selection: TextSelection.collapsed(offset: 12),
    ),
  );
  await driver.flush();

  driver.updateEditingValue(
    const TextEditingValue(
      text: '\u200B\u200Bteh ',
      selection: TextSelection.collapsed(offset: 6),
    ),
  );
  await driver.flush();

  driver.log.clear();

  driver.engine.updateEditingValue(
    const TextEditingValue(
      text: '\u200B\u200Bthe ',
      selection: TextSelection(baseOffset: -1, extentOffset: 0),
    ),
  );
  await driver.flush();

  driver.updateEditingValue(
    const TextEditingValue(
      text: '\u200B\u200Bthe ',
      selection: TextSelection.collapsed(offset: 6),
    ),
  );
  await driver.flush();

  expect(terminalTextFromEvents(harness.terminalOutput), 'the ');
  expect(
    driver.log.where((call) => call.method == 'TextInput.setEditingState'),
    isEmpty,
  );

  await _disposeImeHarness(driver, harness);
}

Future<void> _commitSwipeText(_ImeDriver driver, String text) async {
  final selection = TextSelection.collapsed(offset: text.length);
  driver.updateEditingValue(
    TextEditingValue(
      text: text,
      selection: selection,
      composing: TextRange(
        start: _deleteDetectionMarker.length,
        end: text.length,
      ),
    ),
  );
  await driver.flush();

  driver.updateEditingValue(TextEditingValue(text: text, selection: selection));
  await driver.flush();
}

const _batchMarker = '\u200B\u200B';

TextEditingValue _batchEditingValue(String text, {bool composing = false}) =>
    TextEditingValue(
      text: '$_batchMarker$text',
      selection: TextSelection.collapsed(
        offset: _batchMarker.length + text.length,
      ),
      composing: composing
          ? TextRange(
              start: _batchMarker.length,
              end: _batchMarker.length + text.length,
            )
          : TextRange.empty,
    );

void _batchTests() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final kitty in [false, true]) {
      test('double-space stays exact in Pi paste mode on $platform, '
          'Kitty: $kitty', () async {
        final driver = _ImeDriver(platform: platform);
        addTearDown(driver.dispose);
        final harness = await _createImeHarness(
          driver,
          initialTerminalOutput: '\x1b[?2004h${kitty ? '\x1b[>1u' : ''}',
          initialEditingValue: _batchEditingValue('hello '),
        );
        harness.terminalOutput.clear();

        driver.updateEditingValue(_batchEditingValue('hello. '));
        await driver.flush();
        driver.updateEditingValue(_batchEditingValue('hello. w'));
        await driver.flush();
        driver.engine.performAction(TextInputAction.newline);
        await driver.flush();

        // Pi prepends a space to a paste starting with '.' after a word.
        // Retype the known 'o' with the correction to avoid path heuristics,
        // while retaining paste boundaries and a separate Return for Codex.
        expect(harness.terminalOutput, [
          '\x7f',
          '\x7f',
          '\x1b[200~o. \x1b[201~',
          '\x1b[200~w\x1b[201~',
          '\r',
        ]);
        await _disposeImeHarness(driver, harness);
      });
    }
  }

  for (final prefix in ['.', '/', '~']) {
    for (final preceding in ['o', '_', '1', ' ', '👩🏽‍💻', '']) {
      test(
        'path-like IME suffix $prefix after "$preceding" stays literal',
        () async {
          final driver = _ImeDriver(platform: TargetPlatform.iOS);
          addTearDown(driver.dispose);
          final harness = await _createImeHarness(
            driver,
            initialTerminalOutput: '\x1b[?2004h',
            initialEditingValue: _batchEditingValue(preceding),
          );
          harness.terminalOutput.clear();

          driver.updateEditingValue(_batchEditingValue('$preceding$prefix '));
          await driver.flush();

          final retype = ['o', '_', '1'].contains(preceding);
          expect(harness.terminalOutput, [
            if (retype) '\x7f',
            '\x1b[200~${retype ? preceding : ''}$prefix \x1b[201~',
          ]);
          await _disposeImeHarness(driver, harness);
        },
      );
    }
  }

  test('does not retype context from before Enter on the next line', () async {
    final driver = _ImeDriver(platform: TargetPlatform.iOS);
    addTearDown(driver.dispose);
    final harness = await _createImeHarness(
      driver,
      initialTerminalOutput: '\x1b[?2004h',
      initialEditingValue: _batchEditingValue('hello'),
    );
    harness.terminalOutput.clear();

    driver.updateEditingValue(_batchEditingValue('hello.\n. '));
    await driver.flush();

    expect(harness.terminalOutput, ['\x7f', '\x1b[200~o.\r. \x1b[201~']);
    await _disposeImeHarness(driver, harness);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test(
      'keeps dictated paragraphs inside one bracketed paste on $platform',
      () async {
        final driver = _ImeDriver(platform: platform);
        addTearDown(driver.dispose);
        final harness = await _createImeHarness(
          driver,
          initialTerminalOutput: '\x1b[?2004h',
        );
        const phrase = 'Para one.\n\nPara two.';

        driver.updateEditingValue(
          _batchEditingValue('Para one.', composing: true),
        );
        await driver.flush();
        driver.updateEditingValue(_batchEditingValue(phrase, composing: true));
        await driver.flush();
        expect(harness.terminalOutput, isEmpty);

        driver.updateEditingValue(_batchEditingValue(phrase));
        await driver.flush();
        expect(harness.terminalOutput, [
          '\x1b[200~Para one.\r\rPara two.\x1b[201~',
        ]);

        // The IME may repeat its final result after the buffer is repaired.
        driver.updateEditingValue(_batchEditingValue(phrase));
        await driver.flush();
        expect(harness.terminalOutput, [
          '\x1b[200~Para one.\r\rPara two.\x1b[201~',
        ]);

        driver.engine.performAction(TextInputAction.newline);
        await driver.flush();
        expect(harness.terminalOutput, [
          '\x1b[200~Para one.\r\rPara two.\x1b[201~',
          '\r',
        ]);
        await _disposeImeHarness(driver, harness);
      },
    );
  }

  for (final bracketed in [false, true]) {
    test('does not review long multi-paragraph dictation the IME previewed, '
        'bracketed: $bracketed', () async {
      final driver = _ImeDriver(platform: TargetPlatform.iOS);
      addTearDown(driver.dispose);
      final reviews = <TerminalCommandReview>[];
      final harness = await _createImeHarness(
        driver,
        initialTerminalOutput: bracketed ? '\x1b[?2004h' : null,
        onReviewInsertedText: (review) async {
          reviews.add(review);
          return false;
        },
      );
      final paragraph = List.filled(
        terminalKeyboardPasteLikeInsertionThreshold,
        'a',
      ).join();
      final phrase = '$paragraph\n\nsecond paragraph';

      driver.updateEditingValue(_batchEditingValue(paragraph, composing: true));
      await driver.flush();
      driver.updateEditingValue(_batchEditingValue(phrase, composing: true));
      await driver.flush();
      driver.updateEditingValue(_batchEditingValue('$phrase.'));
      await driver.flush();
      await driver.flush();

      expect(reviews, isEmpty);
      expect(
        harness.terminalOutput,
        bracketed
            ? ['\x1b[200~$paragraph\r\rsecond paragraph.\x1b[201~']
            : [paragraph, '\r', '\r', 'second paragraph.'],
      );
      await _disposeImeHarness(driver, harness);
    });
  }

  test('still reviews a long commit the IME never previewed', () async {
    final driver = _ImeDriver(platform: TargetPlatform.iOS);
    addTearDown(driver.dispose);
    final reviews = <TerminalCommandReview>[];
    final harness = await _createImeHarness(
      driver,
      initialTerminalOutput: '\x1b[?2004h',
      onReviewInsertedText: (review) async {
        reviews.add(review);
        return false;
      },
    );
    final pasted = List.filled(
      terminalKeyboardPasteLikeInsertionThreshold + 1,
      'a',
    ).join();

    driver.updateEditingValue(_batchEditingValue('hi', composing: true));
    await driver.flush();
    driver.updateEditingValue(_batchEditingValue('hi$pasted'));
    await driver.flush();
    await driver.flush();

    expect(reviews, hasLength(1));
    expect(
      reviews.single.reasons,
      contains(TerminalCommandReviewReason.largeKeyboardInsertion),
    );
    expect(harness.terminalOutput, isEmpty);
    await _disposeImeHarness(driver, harness);
  });

  test(
    'keeps embedded newlines on the key path while Shift is active',
    () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      var shift = true;
      final harness = await _createImeHarness(
        driver,
        initialTerminalOutput: '\x1b[?2004h\x1b[>1u',
        resolveTerminalKeyModifiers: () =>
            (ctrl: false, alt: false, shift: shift),
        consumeTerminalKeyModifiers: () => shift = false,
      );

      driver.updateEditingValue(_batchEditingValue('one\ntwo'));
      await driver.flush();

      expect(harness.terminalOutput, [
        '\x1b[200~one\x1b[201~',
        '\x1b[13;2u',
        '\x1b[200~two\x1b[201~',
      ]);
      expect(shift, isFalse);
      await _disposeImeHarness(driver, harness);
    },
  );

  test('sends a final Return hidden behind trailing whitespace', () async {
    final driver = _ImeDriver(platform: TargetPlatform.iOS);
    addTearDown(driver.dispose);
    final harness = await _createImeHarness(
      driver,
      initialTerminalOutput: '\x1b[?2004h',
    );

    driver.updateEditingValue(_batchEditingValue('one\ntwo\n '));
    await driver.flush();

    expect(harness.terminalOutput, ['\x1b[200~one\rtwo\x1b[201~', '\r', ' ']);
    await _disposeImeHarness(driver, harness);
  });

  test('keeps trailing spaces inside a paragraph block', () async {
    final driver = _ImeDriver(platform: TargetPlatform.iOS);
    addTearDown(driver.dispose);
    final harness = await _createImeHarness(
      driver,
      initialTerminalOutput: '\x1b[?2004h',
    );

    driver.updateEditingValue(_batchEditingValue('one\ntwo '));
    await driver.flush();

    expect(harness.terminalOutput, ['\x1b[200~one\rtwo \x1b[201~']);
    await _disposeImeHarness(driver, harness);
  });

  test('sends a leading Return on an empty line as Return', () async {
    final driver = _ImeDriver(platform: TargetPlatform.iOS);
    addTearDown(driver.dispose);
    final harness = await _createImeHarness(
      driver,
      initialTerminalOutput: '\x1b[?2004h',
    );

    driver.updateEditingValue(_batchEditingValue('\n  text'));
    await driver.flush();

    expect(harness.terminalOutput, ['\r', '\x1b[200~  text\x1b[201~']);
    await _disposeImeHarness(driver, harness);
  });

  test('recognises previewed dictation after an iOS backspace runway', () async {
    final driver = _ImeDriver(platform: TargetPlatform.iOS);
    addTearDown(driver.dispose);
    final reviews = <TerminalCommandReview>[];
    final harness = await _createImeHarness(
      driver,
      onReviewInsertedText: (review) async {
        reviews.add(review);
        return false;
      },
    );
    driver.updateEditingValue(_dictationDictationValue('${_dictationMarker}x'));
    await driver.flush();
    driver.updateEditingValue(_dictationDictationValue(_dictationMarker));
    await driver.flush();
    final backspaceBuffer = driver.engine.editingValue.text;
    expect(
      backspaceBuffer.length,
      _dictationMarker.length + terminalIosBackspaceRepeatRunwayLength,
    );
    harness.terminalOutput.clear();

    final phrase =
        '${List.filled(terminalKeyboardPasteLikeInsertionThreshold, 'a').join()}'
        '\n\nsecond paragraph';
    driver.updateEditingValue(
      _dictationDictationValue('$backspaceBuffer$phrase', composing: true),
    );
    await driver.flush();
    driver.updateEditingValue(
      _dictationDictationValue('$backspaceBuffer$phrase.'),
    );
    await driver.flush();
    await driver.flush();

    expect(reviews, isEmpty);
    expect(
      terminalTextFromEvents(harness.terminalOutput),
      '${phrase.replaceAll('\n', '\r')}.',
    );
    await _disposeImeHarness(driver, harness);
  });

  test(
    'keeps only trailing newlines as Return after a paragraph block',
    () async {
      final driver = _ImeDriver(platform: TargetPlatform.iOS);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(
        driver,
        initialTerminalOutput: '\x1b[?2004h',
      );

      driver.updateEditingValue(_batchEditingValue('Para one.\nPara two.\n'));
      await driver.flush();

      expect(harness.terminalOutput, [
        '\x1b[200~Para one.\rPara two.\x1b[201~',
        '\r',
      ]);
      driver.engine.performAction(TextInputAction.newline);
      await driver.flush();
      expect(harness.terminalOutput, [
        '\x1b[200~Para one.\rPara two.\x1b[201~',
        '\r',
      ]);
      await _disposeImeHarness(driver, harness);
    },
  );

  test('pastes a paragraph appended to an earlier dictation commit', () async {
    final driver = _ImeDriver(platform: TargetPlatform.iOS);
    addTearDown(driver.dispose);
    final harness = await _createImeHarness(
      driver,
      initialTerminalOutput: '\x1b[?2004h',
      initialEditingValue: _batchEditingValue('Para one.'),
    );
    harness.terminalOutput.clear();

    driver.updateEditingValue(_batchEditingValue('Para one.\n\nPara two.'));
    await driver.flush();

    expect(harness.terminalOutput, ['\x1b[200~\r\rPara two.\x1b[201~']);
    await _disposeImeHarness(driver, harness);
  });

  test(
    'sends dictated paragraphs line by line without bracketed paste',
    () async {
      final driver = _ImeDriver(platform: TargetPlatform.iOS);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(driver);

      driver.updateEditingValue(_batchEditingValue('Para one.\n\nPara two.'));
      await driver.flush();

      expect(harness.terminalOutput, ['Para one.', '\r', '\r', 'Para two.']);
      await _disposeImeHarness(driver, harness);
    },
  );

  test('keeps modified paragraphs off the bracketed paste path', () async {
    final driver = _ImeDriver(platform: TargetPlatform.android);
    addTearDown(driver.dispose);
    final harness = await _createImeHarness(
      driver,
      initialTerminalOutput: '\x1b[?2004h',
      applyTerminalTextInputModifiers: (text) => '\x1b$text',
    );

    driver.updateEditingValue(_batchEditingValue('one\ntwo'));
    await driver.flush();

    expect(harness.terminalOutput, ['\x1bone', '\r', '\x1btwo']);
    await _disposeImeHarness(driver, harness);
  });

  for (final enter in ['\n', '\r', '\r\n']) {
    test('frames IME batch before Return ${enter.codeUnits}', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(
        driver,
        initialTerminalOutput: '\x1b[?2004h',
      );

      driver.updateEditingValue(_batchEditingValue('hello$enter'));
      await driver.flush();
      driver.engine.performAction(TextInputAction.newline);
      await driver.flush();

      expect(harness.terminalOutput, ['\x1b[200~hello\x1b[201~', '\r']);
      await _disposeImeHarness(driver, harness);
    });
  }

  for (final text in ['hello', 'y', '你好', '👩🏽‍💻']) {
    for (final composing in [false, true]) {
      test('frames $text before Return, composing: $composing', () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final harness = await _createImeHarness(
          driver,
          initialTerminalOutput: '\x1b[?2004h',
        );
        driver.updateEditingValue(
          _batchEditingValue(
            composing ? text : '$text\n',
            composing: composing,
          ),
        );
        await driver.flush();
        if (composing) {
          expect(harness.terminalOutput, isEmpty);
          driver.engine.performAction(TextInputAction.newline);
          await driver.flush();
        }

        expect(harness.terminalOutput, ['\x1b[200~$text\x1b[201~', '\r']);
        await _disposeImeHarness(driver, harness);
      });
    }
  }

  test('frames a batch committed before a later Return action', () async {
    final driver = _ImeDriver(platform: TargetPlatform.android);
    addTearDown(driver.dispose);
    final harness = await _createImeHarness(
      driver,
      initialTerminalOutput: '\x1b[?2004h',
    );
    driver.updateEditingValue(_batchEditingValue('hello'));
    await driver.flush();
    expect(harness.terminalOutput, ['\x1b[200~hello\x1b[201~']);

    driver.engine.performAction(TextInputAction.newline);
    await driver.flush();
    expect(harness.terminalOutput, ['\x1b[200~hello\x1b[201~', '\r']);
    await _disposeImeHarness(driver, harness);
  });

  for (final suffix in ['?', '!', '.', 'x', ' ']) {
    for (final actionOnly in [false, true]) {
      test('frames separately committed $suffix after swipe before Return, '
          'action only: $actionOnly', () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final harness = await _createImeHarness(
          driver,
          initialTerminalOutput: '\x1b[?2004h',
        );
        driver.updateEditingValue(_batchEditingValue('hello', composing: true));
        await driver.flush();
        expect(harness.terminalOutput, isEmpty);
        driver.updateEditingValue(_batchEditingValue('hello'));
        await driver.flush();
        driver.updateEditingValue(_batchEditingValue('hello$suffix'));
        await driver.flush();
        if (!actionOnly) {
          driver.updateEditingValue(_batchEditingValue('hello$suffix\n'));
          await driver.flush();
        }
        driver.engine.performAction(TextInputAction.newline);
        await driver.flush();

        expect(harness.terminalOutput, [
          '\x1b[200~hello\x1b[201~',
          if (suffix == '.') '\x7f',
          '\x1b[200~${suffix == '.' ? 'o' : ''}$suffix\x1b[201~',
          '\r',
        ]);
        await _disposeImeHarness(driver, harness);
      });
    }
  }

  for (final reset in ['Return', 'toolbar key', 'connection']) {
    test('restores standalone shortcuts after $reset resets a batch', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(
        driver,
        initialTerminalOutput: '\x1b[?2004h',
      );
      driver.updateEditingValue(_batchEditingValue('hello'));
      await driver.flush();
      switch (reset) {
        case 'Return':
          driver.engine.performAction(TextInputAction.newline);
        case 'toolbar key':
          harness.controller.clearImeBuffer();
        case 'connection':
          driver.engine.reset(TerminalImeResetReason.connection);
          await driver.flush();
      }
      await driver.flush();
      harness.terminalOutput.clear();
      driver.updateEditingValue(_batchEditingValue('?'));
      await driver.flush();

      expect(harness.terminalOutput, ['?']);
      await _disposeImeHarness(driver, harness);
    });
  }

  for (final input in [
    (key: LogicalKeyboardKey.enter, modifier: null, output: '\r'),
    (
      key: LogicalKeyboardKey.enter,
      modifier: LogicalKeyboardKey.shiftLeft,
      output: '\n',
    ),
    (
      key: LogicalKeyboardKey.enter,
      modifier: LogicalKeyboardKey.altLeft,
      output: '\x1b\r',
    ),
    (
      key: LogicalKeyboardKey.keyC,
      modifier: LogicalKeyboardKey.controlLeft,
      output: '\x03',
    ),
    (key: LogicalKeyboardKey.escape, modifier: null, output: '\x1b'),
  ]) {
    test(
      'restores standalone input after hardware ${input.modifier?.keyLabel ?? ''}'
      ' ${input.key.keyLabel}',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final harness = await _createImeHarness(
          driver,
          initialTerminalOutput: '\x1b[?2004h',
        );
        driver.updateEditingValue(_batchEditingValue('hello'));
        await driver.flush();
        final modifier = input.modifier;
        await driver.hardwareKey(
          input.key == LogicalKeyboardKey.enter
              ? TerminalKey.enter
              : input.key == LogicalKeyboardKey.escape
              ? TerminalKey.escape
              : TerminalKey.keyC,
          shift: modifier == LogicalKeyboardKey.shiftLeft,
          alt: modifier == LogicalKeyboardKey.altLeft,
          ctrl: modifier == LogicalKeyboardKey.controlLeft,
        );
        await driver.flush();
        // Hardware keys do not replace the platform's editing buffer.
        driver.updateEditingValue(_batchEditingValue('hello?'));
        await driver.flush();

        expect(harness.terminalOutput, [
          '\x1b[200~hello\x1b[201~',
          input.output,
          '?',
        ]);
        await _disposeImeHarness(driver, harness);
      },
    );
  }

  for (final modifier in [
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.metaLeft,
  ]) {
    test('ends framing on ${modifier.keyLabel}+V', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      var pasteCount = 0;
      final harness = await _createImeHarness(
        driver,
        initialTerminalOutput: '\x1b[?2004h',
        onPasteText: () => pasteCount++,
      );
      driver.updateEditingValue(_batchEditingValue('hello'));
      await driver.flush();

      driver.engine.endFraming();
      await driver.onPasteText!();

      driver.updateEditingValue(_batchEditingValue('hello?'));
      await driver.flush();

      expect(pasteCount, 1);
      expect(harness.terminalOutput, ['\x1b[200~hello\x1b[201~', '?']);
      await _disposeImeHarness(driver, harness);
    });
  }

  for (final repeat in [false, true]) {
    test('ends framing on raw Android Backspace, repeat: $repeat', () async {
      final driver = _ImeDriver(platform: TargetPlatform.android);
      addTearDown(driver.dispose);
      final harness = await _createImeHarness(
        driver,
        initialTerminalOutput: '\x1b[?2004h',
      );
      driver.updateEditingValue(_batchEditingValue('hello'));
      await driver.flush();
      harness.controller.debugHandleAndroidImeKey(
        TerminalKey.backspace,
        TerminalKeyEventType.press,
      );
      if (repeat) {
        harness.controller.debugHandleAndroidImeKey(
          TerminalKey.backspace,
          TerminalKeyEventType.repeat,
        );
      }
      harness.controller.debugHandleAndroidImeKey(
        TerminalKey.backspace,
        TerminalKeyEventType.release,
      );
      // Some IMEs never send the editing-value deletion after raw Backspace.
      driver.updateEditingValue(_batchEditingValue('hello?'));
      await driver.flush();

      expect(harness.terminalOutput, [
        '\x1b[200~hello\x1b[201~',
        '\x7f',
        if (repeat) '\x7f',
        '?',
      ]);
      await _disposeImeHarness(driver, harness);
    });
  }

  for (final composing in [false, true]) {
    test(
      'ends framing before deferred iOS deletion reset, composing: $composing',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.iOS);
        addTearDown(driver.dispose);
        final harness = await _createImeHarness(
          driver,
          initialTerminalOutput: '\x1b[?2004h',
        );
        driver.updateEditingValue(_batchEditingValue('hello'));
        await driver.flush();
        driver.updateEditingValue(
          _batchEditingValue('hell', composing: composing),
        );
        await driver.flush();
        driver.updateEditingValue(_batchEditingValue('hell?'));
        await driver.flush();

        expect(harness.terminalOutput, [
          '\x1b[200~hello\x1b[201~',
          '\x7f',
          '?',
        ]);
        await _disposeImeHarness(driver, harness);
      },
    );
  }

  test('preserves control characters in IME input', () async {
    final driver = _ImeDriver(platform: TargetPlatform.android);
    addTearDown(driver.dispose);
    final harness = await _createImeHarness(
      driver,
      initialTerminalOutput: '\x1b[?2004h',
    );
    driver.updateEditingValue(_batchEditingValue('a\tb'));
    await driver.flush();

    expect(harness.terminalOutput, ['a\tb']);
    await _disposeImeHarness(driver, harness);
  });

  test('keeps ordinary typing and unsupported batch input unchanged', () async {
    final driver = _ImeDriver(platform: TargetPlatform.android);
    addTearDown(driver.dispose);
    final harness = await _createImeHarness(
      driver,
      initialTerminalOutput: '\x1b[?2004h',
    );
    driver.updateEditingValue(_batchEditingValue('h'));
    await driver.flush();
    harness.terminal.write('\x1b[?2004l');
    driver.updateEditingValue(_batchEditingValue('hello\n'));
    await driver.flush();

    expect(harness.terminalOutput, ['h', 'ello', '\r']);
    await _disposeImeHarness(driver, harness);
  });

  test('keeps modified text out of bracketed paste', () async {
    final driver = _ImeDriver(platform: TargetPlatform.android);
    addTearDown(driver.dispose);
    var alt = false;
    final harness = await _createImeHarness(
      driver,
      initialTerminalOutput: '\x1b[?2004h',
      applyTerminalTextInputModifiers: (text) => alt ? '\x1b$text' : text,
    );
    driver.updateEditingValue(_batchEditingValue('hello'));
    await driver.flush();
    alt = true;
    driver.updateEditingValue(_batchEditingValue('hello. '));
    await driver.flush();

    expect(harness.terminalOutput, ['\x1b[200~hello\x1b[201~', '\x1b. ']);
    await _disposeImeHarness(driver, harness);
  });

  test('stops framing when the application disables bracketed paste', () async {
    final driver = _ImeDriver(platform: TargetPlatform.android);
    addTearDown(driver.dispose);
    final harness = await _createImeHarness(
      driver,
      initialTerminalOutput: '\x1b[?2004h',
    );
    driver.updateEditingValue(_batchEditingValue('hello'));
    await driver.flush();
    harness.terminal.write('\x1b[?2004l');
    driver.updateEditingValue(_batchEditingValue('hello?'));
    await driver.flush();
    driver.updateEditingValue(_batchEditingValue('hello?\n'));
    await driver.flush();

    expect(harness.terminalOutput, ['\x1b[200~hello\x1b[201~', '?', '\r']);
    await _disposeImeHarness(driver, harness);
  });

  test('keeps Shift Return separate from a committed batch', () async {
    final driver = _ImeDriver(platform: TargetPlatform.android);
    addTearDown(driver.dispose);
    var shift = true;
    final harness = await _createImeHarness(
      driver,
      initialTerminalOutput: '\x1b[?2004h\x1b[>1u',
      resolveTerminalKeyModifiers: () =>
          (ctrl: false, alt: false, shift: shift),
      consumeTerminalKeyModifiers: () => shift = false,
    );
    driver.updateEditingValue(_batchEditingValue('hello'));
    await driver.flush();
    driver.updateEditingValue(_batchEditingValue('hello?'));
    await driver.flush();
    driver.updateEditingValue(_batchEditingValue('hello?\n'));
    await driver.flush();

    expect(harness.terminalOutput, [
      '\x1b[200~hello\x1b[201~',
      '\x1b[200~?\x1b[201~',
      '\x1b[13;2u',
    ]);
    expect(shift, isFalse);
    await _disposeImeHarness(driver, harness);
  });
}

const _dictationMarker = '\u200B\u200B';

TextEditingValue _dictationDictationValue(
  String text, {
  bool composing = false,
}) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: text.length),
  composing: composing
      ? TextRange(start: 0, end: text.length)
      : TextRange.empty,
);

void _dictationTests() {
  for (final prefix in ['', '\u200B', _dictationMarker]) {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      test(
        "${'commits dictation with ${prefix.length} delete markers exactly once'} (${platform.name})",
        () async {
          final driver = _ImeDriver(platform: platform);
          addTearDown(driver.dispose);
          final harness = await _createImeHarness(driver);
          const phrase = 'Please explain this code.';

          for (final partial in ['Please', 'Please explain', phrase]) {
            driver.updateEditingValue(
              _dictationDictationValue('$prefix$partial', composing: true),
            );
            await driver.flush();
            expect(harness.terminalOutput, isEmpty);
          }

          driver.updateEditingValue(_dictationDictationValue('$prefix$phrase'));
          await driver.flush();
          expect(harness.terminalOutput.join(), phrase);

          final client = driver.engine;
          expect(
            client.editingValue,
            _dictationDictationValue('$_dictationMarker$phrase'),
          );

          // An IME may acknowledge the repaired buffer or repeat its final result.
          driver.updateEditingValue(_dictationDictationValue('$prefix$phrase'));
          await driver.flush();
          driver.updateEditingValue(
            _dictationDictationValue('$_dictationMarker$phrase'),
          );
          await driver.flush();
          expect(harness.terminalOutput.join(), phrase);

          await _disposeImeHarness(driver, harness);
        },
      );
    }
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test(
      "${'replaces dictated text when the IME replaces the whole buffer'} (${platform.name})",
      () async {
        final driver = _ImeDriver(platform: platform);
        addTearDown(driver.dispose);
        final harness = await _createImeHarness(driver);
        for (final phrase in [
          'Explain the coat.',
          'Explain the code.',
          'Explain the code. 🐒',
        ]) {
          driver.updateEditingValue(_dictationDictationValue(phrase));
          await driver.flush();
          expect(terminalStateFromEvents(harness.terminalOutput), (
            text: phrase,
            cursorOffset: phrase.characters.length,
          ));
        }

        await _disposeImeHarness(driver, harness);
      },
    );
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test(
      "${'Enter commits dictation that replaced the delete markers'} (${platform.name})",
      () async {
        final driver = _ImeDriver(platform: platform);
        addTearDown(driver.dispose);
        final harness = await _createImeHarness(driver);
        const phrase = 'Explain this code';
        driver.updateEditingValue(
          _dictationDictationValue(phrase, composing: true),
        );
        await driver.flush();

        await driver.receiveAction(TextInputAction.newline);
        await driver.flush();
        expect(harness.terminalOutput.join(), '$phrase\r');

        await _disposeImeHarness(driver, harness);
      },
    );
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test(
      "${'reviews a marker-free dictation commit before sending it'} (${platform.name})",
      () async {
        final driver = _ImeDriver(platform: platform);
        addTearDown(driver.dispose);
        var reviewCount = 0;
        const command = r'echo $(id)';
        final harness = await _createImeHarness(
          driver,
          onReviewInsertedText: (review) async {
            reviewCount++;
            expect(review.command, command);
            return false;
          },
        );
        driver.updateEditingValue(_dictationDictationValue(command));
        await driver.flush();

        expect(reviewCount, 1);
        expect(harness.terminalOutput, isEmpty);
        await _disposeImeHarness(driver, harness);
      },
    );
  }

  for (final preservesBackspaceBuffer in [false, true]) {
    test(
      'iOS dictation ${preservesBackspaceBuffer ? 'preserves' : 'replaces'} the backspace buffer',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.iOS);
        addTearDown(driver.dispose);
        final harness = await _createImeHarness(driver);
        driver.updateEditingValue(
          _dictationDictationValue('${_dictationMarker}x'),
        );
        await driver.flush();
        driver.updateEditingValue(_dictationDictationValue(_dictationMarker));
        await driver.flush();

        final client = driver.engine;
        final backspaceBuffer = client.editingValue.text;
        expect(
          backspaceBuffer.length,
          _dictationMarker.length + terminalIosBackspaceRepeatRunwayLength,
        );
        harness.terminalOutput.clear();

        const phrase = 'Explain this code.';
        final prefix = preservesBackspaceBuffer ? backspaceBuffer : '';
        driver.updateEditingValue(
          _dictationDictationValue('$prefix$phrase', composing: true),
        );
        await driver.flush();
        expect(harness.terminalOutput, isEmpty);

        driver.updateEditingValue(_dictationDictationValue('$prefix$phrase'));
        await driver.flush();
        expect(harness.terminalOutput.join(), phrase);
        expect(
          client.editingValue,
          _dictationDictationValue('$_dictationMarker$phrase'),
        );

        // Backspace must delete the final dictated character, with no hidden
        // buffer characters forwarded to the remote terminal.
        final shortened = phrase.substring(0, phrase.length - 1);
        driver.updateEditingValue(
          _dictationDictationValue('$_dictationMarker$shortened'),
        );
        await driver.flush();
        expect(terminalTextFromEvents(harness.terminalOutput), shortened);

        await _disposeImeHarness(driver, harness);
      },
    );
  }
}

const _unicodeDeleteDetectionMarker = '\u200B\u200B';

void _unicodeTests() {
  group('TerminalTextInputHandler unicode behavior', () {
    for (final testCase in [
      (
        name: 'deletes a single emoji with one backspace',
        initialEditingValue: const TextEditingValue(
          text: '$_unicodeDeleteDetectionMarker👍',
          selection: TextSelection.collapsed(offset: 4),
        ),
        expectedOutput: '👍\x7f',
      ),
      (
        name:
            'deletes a single combining-character grapheme with one backspace',
        initialEditingValue: const TextEditingValue(
          text:
              '$_unicodeDeleteDetectionMarker'
              'e\u0301',
          selection: TextSelection.collapsed(offset: 4),
        ),
        expectedOutput: 'e\u0301\x7f',
      ),
    ]) {
      test(testCase.name, () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final harness = await _createImeHarness(
          driver,
          initialEditingValue: testCase.initialEditingValue,
        );
        driver.updateEditingValue(
          const TextEditingValue(
            text: _unicodeDeleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
        await driver.flush();
        expect(harness.terminalOutput.join(), testCase.expectedOutput);
        await _disposeImeHarness(driver, harness);
      });
    }

    test(
      'does not review a single emoji insertion as suspicious paste',
      () async {
        final driver = _ImeDriver(platform: TargetPlatform.android);
        addTearDown(driver.dispose);
        final terminalOutput = <String>[];
        final terminal = Terminal(onOutput: terminalOutput.add);
        final reviews = <TerminalCommandReview>[];

        await driver.attach(
          terminal: terminal,
          onReviewInsertedText: (review) async {
            reviews.add(review);
            return true;
          },
        );

        await driver.flush();

        driver.engine.updateEditingValue(
          const TextEditingValue(
            text: '$_unicodeDeleteDetectionMarker👍',
            selection: TextSelection.collapsed(offset: 4),
          ),
        );
        await driver.flush();
        await driver.flush();

        expect(reviews, isEmpty);
        expect(terminalOutput.join(), '👍');
      },
    );
  });
}

/// Drives the editing boundary without a binding, widget tree or input channel.
class _ImeDriver {
  _ImeDriver({required this.platform});
  TargetPlatform platform;
  final FakeAsync _timers = FakeAsync();
  final List<TerminalImeEngine> _engines = [];
  final log = <MethodCall>[];
  final effects = <Object>[];
  late TerminalImeEngine engine;
  DateTime Function()? clock;
  FutureOr<void> Function()? onPasteText;

  Future<void> attach({
    required Terminal terminal,
    bool deleteDetection = true,
    bool readOnly = false,
    bool sensitiveInput = false,
    Brightness keyboardAppearance = Brightness.dark,
    VoidCallback? onUserInput,
    TerminalTextInputReviewCallback? onReviewInsertedText,
    TerminalTextInputReviewTextBuilder? buildReviewTextForInsertedText,
    TerminalTextBeforeCursorResolver? resolveTextBeforeCursor,
    TerminalKeyModifierResolver? resolveTerminalKeyModifiers,
    VoidCallback? consumeTerminalKeyModifiers,
    TerminalTextInputModifierApplier? applyTerminalTextInputModifiers,
    ValueGetter<bool>? hasActiveToolbarModifier,
  }) async {
    engine = TerminalImeEngine(
      terminal: terminal,
      options: TerminalImeOptions(
        platform: platform,
        deleteDetection: deleteDetection,
        readOnly: readOnly,
        sensitiveInput: sensitiveInput,
        keyboardAppearance: keyboardAppearance,
      ),
      now: () => clock?.call() ?? DateTime(2026).add(_timers.elapsed),
      schedule: (duration, callback) =>
          _timers.run((_) => Timer(duration, callback)),
      effects: TerminalImeEffects(
        onUserInput: () {
          effects.add('user input');
          onUserInput?.call();
        },
        onReviewInsertedText: onReviewInsertedText == null
            ? null
            : (review) {
                effects.add(('review', review.command));
                return onReviewInsertedText(review);
              },
        buildReviewTextForInsertedText: buildReviewTextForInsertedText,
        resolveTextBeforeCursor: resolveTextBeforeCursor,
        resolveTerminalKeyModifiers: resolveTerminalKeyModifiers,
        consumeTerminalKeyModifiers: consumeTerminalKeyModifiers,
        applyTerminalTextInputModifiers: applyTerminalTextInputModifiers,
        hasActiveToolbarModifier: hasActiveToolbarModifier,
        onEditingState: (value) {
          effects.add(('editing state', value));
          log.add(MethodCall('TextInput.setEditingState', value.toJSON()));
        },
      ),
    );
    _engines.add(engine);
    engine.reset(TerminalImeResetReason.connection);
    log.add(
      MethodCall('TextInput.setEditingState', engine.editingValue.toJSON()),
    );
  }

  void updateEditingValue(TextEditingValue value) =>
      engine.updateEditingValue(value);
  Future<void> receiveAction(TextInputAction action) async =>
      engine.performAction(action);

  // Yield to the event loop so all runnable review/queue continuations finish.
  // An unresolved review remains pending, just as with a widget pump.
  Future<void> flush([Duration duration = Duration.zero]) async {
    _timers.elapse(duration);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> hardwareKey(
    TerminalKey key, {
    bool ctrl = false,
    bool alt = false,
    bool shift = false,
  }) async {
    engine.sendHardwareTerminalKey(
      key,
      ctrl: ctrl,
      alt: alt,
      shift: shift,
      meta: false,
      hasShortcutModifier: ctrl || alt,
    );
    await flush();
  }

  void dispose() {
    for (final engine in _engines) {
      engine.dispose();
    }
  }
}

class _ImeController {
  _ImeController(this.driver);
  final _ImeDriver driver;
  void clearImeBuffer() => driver.engine.clearImeBufferForFreshInput();
  void resetImeCompletions() => driver.engine.resetImeCompletions();
  void handleExternalTerminalOutput() =>
      driver.engine.handleExternalTerminalOutput();
  void debugHandleAndroidImeKey(TerminalKey key, TerminalKeyEventType type) {
    expect(key, TerminalKey.backspace);
    driver.engine.handleAndroidImeBackspace(
      type,
      toolbarModifiers: driver.engine.effects.resolveTerminalKeyModifiers
          ?.call(),
    );
  }

  void dispose() {}
}

typedef _ImeHarness = ({
  Terminal terminal,
  List<String> terminalOutput,
  _ImeController controller,
});

Future<_ImeHarness> _createImeHarness(
  _ImeDriver driver, {
  TextEditingValue? initialEditingValue,
  String? initialTerminalOutput,
  bool readOnly = false,
  bool deleteDetection = true,
  bool sensitiveInput = false,
  FutureOr<void> Function()? onPasteText,
  TerminalTextInputReviewCallback? onReviewInsertedText,
  TerminalTextBeforeCursorResolver? resolveTextBeforeCursor,
  TerminalKeyModifierResolver? resolveTerminalKeyModifiers,
  VoidCallback? consumeTerminalKeyModifiers,
  TerminalTextInputModifierApplier? applyTerminalTextInputModifiers,
  ValueGetter<bool>? hasActiveToolbarModifier,
  _ImeController? controller,
}) async {
  final terminalOutput = <String>[];
  final terminal = Terminal(
    onOutput: (text) {
      driver.effects.add(('output', text));
      terminalOutput.add(text);
    },
  );
  if (initialTerminalOutput != null) terminal.write(initialTerminalOutput);
  driver.onPasteText = onPasteText;
  await driver.attach(
    terminal: terminal,
    readOnly: readOnly,
    deleteDetection: deleteDetection,
    sensitiveInput: sensitiveInput,
    onReviewInsertedText: onReviewInsertedText,
    resolveTextBeforeCursor: resolveTextBeforeCursor,
    resolveTerminalKeyModifiers: resolveTerminalKeyModifiers,
    consumeTerminalKeyModifiers: consumeTerminalKeyModifiers,
    applyTerminalTextInputModifiers: applyTerminalTextInputModifiers,
    hasActiveToolbarModifier: hasActiveToolbarModifier,
  );
  if (initialEditingValue != null) {
    driver.updateEditingValue(initialEditingValue);
    await driver.flush();
  }
  return (
    terminal: terminal,
    terminalOutput: terminalOutput,
    controller: controller ?? _ImeController(driver),
  );
}

Future<void> _disposeImeHarness(_ImeDriver driver, _ImeHarness harness) async {
  driver.engine.dispose();
  await driver.flush();
}

Future<void> _expectRecordedTextFieldSequence(
  _ImeDriver driver, {
  required List<TextEditingValue> sequence,
  int? expectedTerminalEchoCount,
}) async {
  await _createImeHarness(driver);
  driver.log.clear();
  for (final value in sequence) {
    driver.updateEditingValue(_terminalEditingValueFromUserValue(value));
    await driver.flush();
  }
  // TextField accepts these platform values unchanged. Four widget tests keep
  // the live TextField contract; the generated matrix uses its explicit value.
  expect(
    _loggedTerminalClientState(driver.engine.editingValue),
    _loggedStateFromTextEditingValue(sequence.last),
  );
  if (expectedTerminalEchoCount != null) {
    expect(
      _setEditingStateStates(driver.log, stripTerminalMarker: true),
      hasLength(expectedTerminalEchoCount),
    );
  }
}
