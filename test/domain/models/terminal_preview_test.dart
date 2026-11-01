import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/terminal_preview.dart';
import 'package:xterm/xterm.dart';

void main() {
  BufferLine cellsOf(String text) {
    final terminal = Terminal()
      ..resize(8, 1)
      ..write(text);
    final line = terminal.buffer.lines[0];
    return BufferLine(line.length)..copyFrom(line, 0, 0, line.length);
  }

  test('preview lines differ when a grapheme cluster does', () {
    // Same text field and the same first code point in every cell: only the
    // mark joined to the "e" differs, which the card must still repaint.
    final acute = TerminalPreviewLine(text: 'e', cells: cellsOf('é'));
    final grave = TerminalPreviewLine(text: 'e', cells: cellsOf('è'));
    expect(acute, isNot(grave));
    expect(acute, TerminalPreviewLine(text: 'e', cells: cellsOf('é')));
    expect(
      acute.hashCode,
      TerminalPreviewLine(text: 'e', cells: cellsOf('é')).hashCode,
    );
  });
}
