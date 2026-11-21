import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xterm/xterm.dart';

/// The MonkeyMux screen model runs the same cases
/// (remote/monkeymux/grapheme_test.go), so the client and the model it
/// replays from join code points into the same cells, at the same widths,
/// with the cursor in the same place.
const fixturePath =
    '../../remote/monkeymux/testdata/grapheme_cluster_parity.json';

/// The viewport row [y] as the fixture writes it: each cell's text from
/// column 0, `<` for the right half of a wide glyph, an empty string for an
/// empty cell, and no trailing empty cells.
List<String> graphemeRow(Terminal terminal, int y) {
  final buffer = terminal.buffer;
  final line = buffer.lines[buffer.scrollBack + y];
  final cells = <String>[];
  for (var x = 0; x < buffer.viewWidth; x++) {
    cells.add(x > 0 && line.getWidth(x - 1) == 2 ? '<' : line.getGrapheme(x));
  }
  while (cells.isNotEmpty && cells.last.isEmpty) {
    cells.removeLast();
  }
  return cells;
}

void main() {
  final file = File(fixturePath);
  if (!file.existsSync()) {
    test('grapheme cluster parity', () {}, skip: 'fixture unavailable');
    return;
  }
  final cases = jsonDecode(file.readAsStringSync()) as List<dynamic>;
  for (final raw in cases) {
    final testCase = raw as Map<String, dynamic>;
    test(testCase['name'], () {
      var size = (testCase['size'] as List).cast<int>();
      final terminal = Terminal(maxLines: 10000);
      terminal.resize(size[0], size[1]);
      terminal.write(testCase['write'] as String);
      // Then each size in turn, which the model's reflow follows too.
      for (final step in (testCase['resize'] as List?) ?? const []) {
        size = (step as List).cast<int>();
        terminal.resize(size[0], size[1]);
      }

      final rows = testCase['rows'] as List;
      final buffer = terminal.buffer;
      for (var y = 0; y < size[1]; y++) {
        expect(
          graphemeRow(terminal, y),
          y < rows.length ? rows[y] : <String>[],
          reason: 'row $y',
        );
      }
      expect(
        [buffer.cursorY, buffer.cursorX, buffer.isWrapPending],
        testCase['cursor'],
        reason: 'cursor',
      );
      expect(
        [
          for (var y = 0; y < size[1]; y++)
            if (buffer.lines[buffer.scrollBack + y].isWrapped) y,
        ],
        testCase['wrapped'],
        reason: 'wrapped rows',
      );
    });
  }
}
