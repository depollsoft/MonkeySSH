import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xterm/xterm.dart';

/// The MonkeyMux screen model runs the same cases
/// (remote/monkeymux/vtscreen_prompt_test.go), so the two agree on the
/// semantic prompt marks, the content of every cell and what ED 2 at a prompt
/// keeps. A case with a `frame` is a window the client attaches to after its
/// first `replayAfter` steps: the client receives the model's replay (the
/// recorded frame) in their place and must then track the model.
const fixturePath =
    '../../remote/monkeymux/testdata/semantic_prompt_parity.json';

/// One line per buffer line, scrollback first: the row mark (`P`rompt,
/// `C`ontinuation, `S`econdary prompt), `+` for a
/// soft-wrapped row, the text and each cell's content (`o`utput, `i`nput,
/// `p`rompt); then the cursor, its content and the active screen's prompt
/// options.
List<String> dumpSemanticPrompt(Terminal terminal) {
  final buffer = terminal.buffer;
  final out = <String>[];
  for (var y = 0; y < buffer.lines.length; y++) {
    final line = buffer.lines[y];
    final mark = switch (line.semanticPrompt) {
      SemanticPromptRow.none => '-',
      SemanticPromptRow.prompt => 'P',
      SemanticPromptRow.continuation => 'C',
      SemanticPromptRow.secondary => 'S',
    };
    final text = StringBuffer();
    final content = StringBuffer();
    final end = line.getTrimmedLength(buffer.viewWidth);
    for (var x = 0; x < end; x++) {
      if (x > 0 && line.getWidth(x - 1) == 2) continue;
      final codePoint = line.getCodePoint(x);
      text.writeCharCode(codePoint == 0 ? 0x20 : codePoint);
      content.write('oip'[line.getSemanticContent(x)]);
    }
    final wrap = line.isWrapped ? '+' : ' ';
    out.add('$mark$wrap|$text|$content');
  }
  final state = buffer.semanticPrompt;
  out.add(
    'cursor ${buffer.cursorX},${buffer.cursorY} '
    '${'oip'[state.content]}${state.inputEndsAtEol ? ' eol' : ''} '
    'click=${state.clickEvents} cl=${state.cursorKeys?.name ?? '-'} '
    'special=${state.specialKey} redraw=${state.redraw} aid=${state.aid ?? '-'}',
  );
  return out;
}

/// Runs [testCase] on a client terminal and returns it.
Terminal runSemanticParityCase(Map<String, dynamic> testCase) {
  final size = (testCase['size'] as List).cast<int>();
  // As many lines as the app keeps: more than the model's whole scrollback.
  final terminal = Terminal(maxLines: 10000);
  terminal.resize(size[0], size[1]);
  var steps = testCase['steps'] as List;
  final frame = testCase['frame'] as String?;
  if (frame != null) {
    terminal.write(frame);
    steps = steps.sublist(testCase['replayAfter'] as int);
  }
  for (final step in steps) {
    final map = step as Map<String, dynamic>;
    if (map['write'] != null) terminal.write(map['write'] as String);
    if (map['resize'] != null) {
      final resize = (map['resize'] as List).cast<int>();
      terminal.resize(resize[0], resize[1]);
    }
  }
  return terminal;
}

void main() {
  final file = File(fixturePath);
  if (!file.existsSync()) {
    test('semantic prompt parity', () {}, skip: 'fixture unavailable');
    return;
  }
  final cases = jsonDecode(file.readAsStringSync()) as List<dynamic>;
  for (final raw in cases) {
    final testCase = raw as Map<String, dynamic>;
    test(testCase['name'], () {
      expect(
        dumpSemanticPrompt(runSemanticParityCase(testCase)),
        testCase['expect'],
      );
    });
  }
}
