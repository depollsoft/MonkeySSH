import 'package:test/test.dart';
import 'package:xterm/xterm.dart';

const _osc = '\x1b]';
const _st = '\x07';

String _mark(String body) => '$_osc$body$_st';

Terminal _terminal({int width = 20, int height = 6}) {
  final terminal = Terminal(maxLines: 100);
  terminal.resize(width, height);
  return terminal;
}

List<SemanticPromptRow> _rowMarks(Terminal terminal) => [
      for (var i = 0; i < terminal.buffer.lines.length; i++)
        terminal.buffer.lines[i].semanticPrompt,
    ];

List<int> _contents(Terminal terminal, int row, int count) => [
      for (var x = 0; x < count; x++)
        terminal.buffer.lines[row].getSemanticContent(x),
    ];

const _o = SemanticContent.output;
const _i = SemanticContent.input;
const _p = SemanticContent.prompt;

void main() {
  group('OSC 133 state', () {
    test('marks prompt, input and output cells and the prompt row', () {
      final terminal = _terminal();
      terminal.write('${_mark('133;A')}\$ ${_mark('133;B')}ls');
      expect(terminal.buffer.lines[0].semanticPrompt, SemanticPromptRow.prompt);
      expect(_contents(terminal, 0, 5), [_p, _p, _i, _i, _o]);
      expect(terminal.buffer.semanticPrompt.content, _i);
      expect(terminal.buffer.cursorIsAtPrompt, isTrue);

      terminal.write('\r\n${_mark('133;C')}out\r\n');
      expect(_rowMarks(terminal).take(3), [
        SemanticPromptRow.prompt,
        SemanticPromptRow.none,
        SemanticPromptRow.none,
      ]);
      expect(_contents(terminal, 1, 3), [_o, _o, _o]);
      expect(terminal.buffer.cursorIsAtPrompt, isFalse);
    });

    test('A starts a fresh line unless the cursor is at a line start', () {
      final terminal = _terminal();
      terminal.write('out${_mark('133;A')}\$ ');
      expect(terminal.buffer.lines[0].toString(), 'out');
      expect(terminal.buffer.lines[1].toString(), r'$ ');
      expect(terminal.buffer.lines[1].semanticPrompt, SemanticPromptRow.prompt);

      terminal.write('\r\n${_mark('133;A')}\$ ');
      expect(terminal.buffer.cursorY, 2);
      expect(terminal.buffer.lines[2].semanticPrompt, SemanticPromptRow.prompt);
      // L alone starts a fresh line too.
      terminal.write('x${_mark('133;L')}');
      expect(terminal.buffer.cursorY, 3);
      expect(terminal.buffer.cursorX, 0);
    });

    test('reads the A options, which a new primary prompt replaces', () {
      final terminal = _terminal();
      final state = terminal.buffer.semanticPrompt;
      terminal.write(
        _mark('133;A;click_events=1;cl=line;special_key=1;redraw=0;aid=42'),
      );
      expect(state.clickEvents, 1);
      expect(state.cursorKeys, PromptCursorKeys.line);
      expect(state.specialKey, isTrue);
      expect(state.redraw, isFalse);
      expect(state.aid, '42');

      // A continuation keeps them and takes what it names.
      terminal.write('\r\n${_mark('133;A;k=s;cl=m')}');
      expect(state.clickEvents, 1);
      expect(state.cursorKeys, PromptCursorKeys.multiple);
      expect(state.aid, '42');
      expect(terminal.buffer.currentLine.semanticPrompt,
          SemanticPromptRow.continuation);

      terminal.write('\r\n${_mark('133;A;cl=w;bogus;click_events=7')}');
      expect(state.clickEvents, 0);
      expect(state.cursorKeys, PromptCursorKeys.smartVertical);
      expect(state.specialKey, isFalse);
      expect(state.redraw, isTrue);
      expect(state.aid, isNull);
      terminal.write(_mark('133;A;cl=v'));
      expect(state.cursorKeys, PromptCursorKeys.conservativeVertical);
    });

    test('rows a newline or wrap reaches inside a prompt continue it', () {
      final terminal = _terminal(width: 6);
      terminal.write('${_mark('133;A')}\$ ${_mark('133;B')}abcdefg\r\nhi');
      expect(_rowMarks(terminal).take(4), [
        SemanticPromptRow.prompt,
        SemanticPromptRow.continuation,
        SemanticPromptRow.continuation,
        SemanticPromptRow.none,
      ]);
      expect(_contents(terminal, 2, 3), [_i, _i, _o]);

      // P names a secondary prompt; I's input ends with its line.
      terminal.write('\r\n${_mark('133;P;k=s')}> ${_mark('133;I')}x\r\ny');
      expect(terminal.buffer.lines[3].semanticPrompt,
          SemanticPromptRow.continuation);
      expect(_contents(terminal, 3, 3), [_p, _p, _i]);
      expect(terminal.buffer.lines[4].semanticPrompt, SemanticPromptRow.none);
      expect(_contents(terminal, 4, 1), [_o]);
    });

    test('C at the start of a prompt row turns it back into output', () {
      // fish: the newline ending the input marks the next row, and its
      // output starts there.
      final terminal = _terminal();
      terminal.write('${_mark('133;A')}> ${_mark('133;B')}ls\r\n');
      expect(terminal.buffer.lines[1].semanticPrompt,
          SemanticPromptRow.continuation);
      terminal.write(_mark('133;C'));
      expect(terminal.buffer.lines[1].semanticPrompt, SemanticPromptRow.none);
      expect(terminal.buffer.lines[0].semanticPrompt, SemanticPromptRow.prompt);
    });

    test('maps the VS Code OSC 633 marks', () {
      final terminal = _terminal();
      terminal.write('out${_mark('633;A')}\$ ${_mark('633;B')}ls');
      // VS Code's A does not start a fresh line.
      expect(terminal.buffer.lines[0].toString(), r'out$ ls');
      expect(terminal.buffer.lines[0].semanticPrompt, SemanticPromptRow.prompt);
      expect(_contents(terminal, 0, 8), [_o, _o, _o, _p, _p, _i, _i, _o]);
      terminal.write('\r\n${_mark('633;F')}> ${_mark('633;G')}x');
      expect(terminal.buffer.lines[1].semanticPrompt,
          SemanticPromptRow.continuation);
      expect(_contents(terminal, 1, 3), [_p, _p, _i]);
      terminal.write('${_mark('633;H')}r${_mark('633;I')}y');
      expect(_contents(terminal, 1, 5), [_p, _p, _i, _p, _i]);
      terminal.write(_mark('633;C'));
      expect(terminal.buffer.semanticPrompt.content, _o);
    });

    test('still reports the OSC to the app', () {
      final seen = <String>[];
      final terminal = _terminal();
      terminal.onPrivateOSC =
          (code, args) => seen.add('$code;${args.join(';')}');
      terminal
          .write(_mark('133;A;cl=line') + _mark('633;C') + _mark('133;D;1'));
      expect(seen, ['133;A;cl=line', '633;C', '133;D;1']);
    });

    test('cell attributes never show the semantic bits', () {
      final terminal = _terminal();
      terminal.write('${_mark('133;A')}\x1b[1m\$${_mark('133;B')}x');
      final cell = CellData.empty();
      terminal.buffer.lines[0].getCellData(0, cell);
      expect(cell.flags, CellAttr.bold);
      terminal.buffer.lines[0].getCellData(1, cell);
      expect(cell.flags, CellAttr.bold);
      expect(terminal.buffer.lines[0].getSemanticContent(1), _i);
    });

    test('marks survive scrolling into the scrollback and a reflow', () {
      final terminal = _terminal(width: 10, height: 3);
      terminal.write('${_mark('133;A')}\$ ${_mark('133;B')}abcdefghijk');
      terminal.write('\r\n${_mark('133;C')}1\r\n2\r\n3\r\n');
      final lines = terminal.buffer.lines;
      expect(lines[0].semanticPrompt, SemanticPromptRow.prompt);
      expect(lines[1].semanticPrompt, SemanticPromptRow.continuation);
      expect(lines[1].isWrapped, isTrue);
      expect(terminal.buffer.scrollBack, greaterThan(0));

      terminal.resize(5, 3);
      expect(lines[0].toString(), r'$ abc');
      expect(lines[0].semanticPrompt, SemanticPromptRow.prompt);
      expect(lines[1].semanticPrompt, SemanticPromptRow.continuation);
      expect(lines[2].semanticPrompt, SemanticPromptRow.continuation);
      expect(lines[3].semanticPrompt, SemanticPromptRow.none);
      expect(lines[3].toString(), '1');
      expect(lines[1].getSemanticContent(0), _i);

      terminal.resize(20, 3);
      expect(lines[0].toString(), r'$ abcdefghijk');
      expect(lines[0].semanticPrompt, SemanticPromptRow.prompt);
      expect(lines[1].semanticPrompt, SemanticPromptRow.none);
    });

    test('RIS clears the state, erased rows lose their marks', () {
      final terminal = _terminal();
      terminal.write('${_mark('133;A;cl=line')}\$ ${_mark('133;B')}ls');
      terminal.write('\x1bc');
      expect(terminal.buffer.semanticPrompt.content, _o);
      expect(terminal.buffer.semanticPrompt.handlesClicks, isFalse);
      expect(terminal.buffer.lines[0].semanticPrompt, SemanticPromptRow.none);
      expect(terminal.buffer.cursorIsAtPrompt, isFalse);
    });

    test('ED 3 ends an open prompt, as a MonkeyMux replay prefix does', () {
      final terminal = _terminal();
      terminal.write('${_mark('133;A')}\$ ${_mark('133;B')}ls');
      terminal.write('\x1b[H\x1b[2J\x1b[3J');
      expect(terminal.buffer.semanticPrompt.content, _o);
      expect(terminal.buffer.cursorIsAtPrompt, isFalse);
      terminal.write('a\r\nb');
      expect(_rowMarks(terminal).take(2), everyElement(SemanticPromptRow.none));
    });
  });

  group('ED 2 at a prompt', () {
    test('moves the screen into the scrollback', () {
      final terminal = _terminal(height: 4);
      terminal.write('${_mark('133;C')}out1\r\nout2\r\n');
      terminal.write('${_mark('133;A')}\$ ${_mark('133;B')}');
      expect(terminal.buffer.scrollBack, 0);
      terminal.write('\x1b[H\x1b[2J');
      expect(terminal.buffer.scrollBack, 3);
      expect(terminal.buffer.lines[0].toString(), 'out1');
      expect(terminal.buffer.lines[2].toString(), r'$ ');
      expect(terminal.buffer.lines[2].semanticPrompt, SemanticPromptRow.prompt);
      for (var row = 0; row < 4; row++) {
        expect(terminal.buffer.lines[3 + row].toString(), '');
        expect(terminal.buffer.lines[3 + row].semanticPrompt,
            SemanticPromptRow.none);
      }
      expect(terminal.buffer.cursorX, 0);
      expect(terminal.buffer.cursorY, 0);
    });

    test('looks past blank rows under the prompt', () {
      final terminal = _terminal(height: 6);
      terminal.write('out\r\n${_mark('133;A')}\$ ${_mark('133;B')}ls');
      // The shell moved home before clearing; blank rows sit below.
      terminal.write('\x1b[H\x1b[2J');
      expect(terminal.buffer.scrollBack, 2);
      expect(terminal.buffer.lines[1].toString(), r'$ ls');
    });

    test('erases in place after command output or without marks', () {
      final terminal = _terminal(height: 4);
      terminal.write('${_mark('133;A')}\$ ${_mark('133;B')}clear\r\n');
      terminal.write('${_mark('133;C')}output\x1b[H\x1b[2J');
      expect(terminal.buffer.scrollBack, 0);

      final plain = _terminal(height: 4);
      plain.write('\$ ls\r\nout\x1b[H\x1b[2J');
      expect(plain.buffer.scrollBack, 0);
      expect(plain.buffer.lines[0].toString(), '');
    });

    test('leaves the alternate screen and ED 3 alone', () {
      final terminal = _terminal(height: 4);
      terminal.write('\x1b[?1049h${_mark('133;A')}\$ \x1b[H\x1b[2J');
      expect(terminal.buffer.height, 4);
      terminal.write('\x1b[?1049l');

      final history = _terminal(height: 4);
      history.write('1\r\n2\r\n3\r\n4\r\n5\r\n');
      history.write('${_mark('133;A')}\$ \x1b[3J');
      expect(history.buffer.scrollBack, 0);
      expect(history.buffer.lines[3].toString(), r'$ ');
    });
  });

  group('prompt click', () {
    Terminal prompt(String marks, String body, {int width = 20}) {
      final terminal = _terminal(width: width);
      terminal.write('${_mark('133;A;$marks')}\$ ${_mark('133;B')}$body');
      return terminal;
    }

    test('cl=line sends arrows along the line, following DECCKM', () {
      final terminal = prompt('cl=line', 'echo hi');
      expect(terminal.promptClickInput(const CellOffset(2, 0)), '\x1b[D' * 7);
      expect(terminal.promptClickInput(const CellOffset(9, 0)), '');
      // Past the end of the input goes to its end.
      expect(terminal.promptClickInput(const CellOffset(15, 0)), '');
      terminal.write('\x1b[5D');
      expect(terminal.promptClickInput(const CellOffset(15, 0)), '\x1b[C' * 5);
      terminal.write('\x1b[?1h');
      expect(terminal.promptClickInput(const CellOffset(8, 0)), '\x1bOC' * 4);
    });

    test('clickPrompt writes the input through onOutput', () {
      final out = <String>[];
      final terminal = prompt('cl=line', 'ab')..onOutput = out.add;
      expect(terminal.clickPrompt(const CellOffset(2, 0)), isTrue);
      expect(out, ['\x1b[D\x1b[D']);
      expect(terminal.clickPrompt(const CellOffset(4, 0)), isFalse);
    });

    test('a wide glyph is one press, from either half', () {
      // "\$ a界b" with the cursor after "b".
      final terminal = prompt('cl=line', 'a界b');
      expect(terminal.promptClickInput(const CellOffset(2, 0)), '\x1b[D' * 3);
      expect(terminal.promptClickInput(const CellOffset(3, 0)), '\x1b[D' * 2);
      expect(terminal.promptClickInput(const CellOffset(4, 0)), '\x1b[D' * 2);
      expect(terminal.promptClickInput(const CellOffset(5, 0)), '\x1b[D');
    });

    test('ignores clicks outside the input', () {
      final terminal = _terminal();
      terminal.write('${_mark('133;C')}output\r\n');
      terminal.write('${_mark('133;A;cl=line')}\$ ${_mark('133;B')}ls');
      // The prompt text, the output above and the rows below.
      expect(terminal.promptClickInput(const CellOffset(0, 1)), isNull);
      expect(terminal.promptClickInput(const CellOffset(2, 0)), isNull);
      expect(terminal.promptClickInput(const CellOffset(2, 3)), isNull);
      expect(terminal.promptClickInput(const CellOffset(2, 1)), '\x1b[D\x1b[D');
    });

    test(
        'needs a prompt that asked for clicks, mouse tracking off, the main '
        'screen, and the cursor at the prompt', () {
      expect(prompt('aid=1', 'ls').promptClickInput(const CellOffset(2, 0)),
          isNull);

      final tracking = prompt('cl=line', 'ls')..write('\x1b[?1000h');
      expect(tracking.promptClickInput(const CellOffset(2, 0)), isNull);

      final running = prompt('cl=line', 'ls')..write('\r\n${_mark('133;C')}');
      expect(running.promptClickInput(const CellOffset(2, 0)), isNull);

      final alt = prompt('cl=line', 'ls')..write('\x1b[?1049h');
      expect(alt.promptClickInput(const CellOffset(2, 0)), isNull);
    });

    test('an empty command line takes clicks after the cursor', () {
      final terminal = prompt('cl=line', '');
      expect(terminal.promptClickInput(const CellOffset(8, 0)), '');
      expect(terminal.promptClickInput(const CellOffset(1, 0)), isNull);
    });

    test('special_key=1 sends the kitty keys fish binds', () {
      final terminal = prompt('cl=line;special_key=1', 'abc');
      expect(
          terminal.promptClickInput(const CellOffset(2, 0)), '\x1b[1;1u' * 3);
      terminal.write('\x1b[3D');
      expect(
          terminal.promptClickInput(const CellOffset(4, 0)), '\x1b[1u\x1b[1u');
    });

    test('arrows are encoded as typed ones, kitty keyboard flags included', () {
      final terminal = prompt('cl=line', 'ab')..write('\x1b[?1h\x1b[>1u');
      final typed = <String>[];
      terminal.onOutput = typed.add;
      terminal.keyInput(TerminalKey.arrowLeft);
      expect(typed.single, isNot('\x1bOD'));
      expect(
          terminal.promptClickInput(const CellOffset(2, 0)), typed.single * 2);
    });

    test('click_events=1 reports a press and release at the screen cell', () {
      final terminal = prompt('click_events=1', 'ls -la');
      expect(terminal.promptClickInput(const CellOffset(4, 0)),
          '\x1b[<0;5;1M\x1b[<0;5;1m');
      // After the input too; the shell decides.
      expect(terminal.promptClickInput(const CellOffset(12, 0)),
          '\x1b[<0;13;1M\x1b[<0;13;1m');
      expect(terminal.promptClickInput(const CellOffset(0, 0)), isNull);
    });

    test('click_events counts rows on screen, not in the buffer', () {
      final terminal = _terminal(height: 3);
      terminal.write('1\r\n2\r\n3\r\n4\r\n');
      terminal.write('${_mark('133;A;click_events=1')}\$ ${_mark('133;B')}ls');
      final row = terminal.buffer.absoluteCursorY;
      expect(terminal.promptClickInput(CellOffset(2, row)),
          '\x1b[<0;3;3M\x1b[<0;3;3m');
    });

    test(
        'click_events=2 counts from the prompt, or a secondary prompt at or '
        'above the click', () {
      final terminal = _terminal(height: 8);
      terminal.write('out\r\n');
      terminal
          .write('${_mark('133;A;click_events=2')}\$ ${_mark('133;B')}a\r\n');
      terminal.write('b\r\n');
      terminal.write('${_mark('133;A;k=s')}> ${_mark('133;B')}c\r\nd');
      // Rows: 1 prompt, 2 input continuing it, 3 secondary prompt, 4 input.
      expect(terminal.promptClickInput(const CellOffset(0, 2)),
          '\x1b[<0;1;2M\x1b[<0;1;2m');
      expect(terminal.promptClickInput(const CellOffset(2, 3)),
          '\x1b[<0;3;1M\x1b[<0;3;1m');
      expect(terminal.promptClickInput(const CellOffset(0, 4)),
          '\x1b[<0;1;2M\x1b[<0;1;2m');
    });

    test('cl=m crosses line breaks with left and right', () {
      final terminal = _terminal(height: 8);
      terminal.write('${_mark('133;A;cl=m')}\$ ${_mark('133;B')}ab\r\ncde');
      // Cursor after "cde"; "a" is 3 + 1 + 2 = 6 presses back.
      expect(terminal.promptClickInput(const CellOffset(2, 0)), '\x1b[D' * 6);
      // Clicking past "ab" lands at its end: 3 + 1.
      expect(terminal.promptClickInput(const CellOffset(9, 0)), '\x1b[D' * 4);
      // cl=line does not leave the cursor's line.
      final line = _terminal(height: 8);
      line.write('${_mark('133;A;cl=line')}\$ ${_mark('133;B')}ab\r\ncde');
      expect(line.promptClickInput(const CellOffset(2, 0)), isNull);
      expect(line.promptClickInput(const CellOffset(1, 1)), '\x1b[D\x1b[D');
    });

    test('a soft-wrapped line is one input line', () {
      final terminal = prompt('cl=line', 'abcdefgh', width: 6);
      // "$ abcd" / "efgh": the cursor is after "h".
      expect(terminal.promptClickInput(const CellOffset(3, 0)), '\x1b[D' * 7);
    });

    test('cl=v moves to the line start, then up or down, then right', () {
      final terminal = _terminal(height: 8);
      terminal.write('${_mark('133;A;cl=v')}\$ ${_mark('133;B')}abcd\r\nxy');
      expect(terminal.promptClickInput(const CellOffset(4, 0)),
          '\x1b[D\x1b[D\x1b[A\x1b[C\x1b[C');
    });

    test('cl=w moves up or down from the column, then along the line', () {
      final terminal = _terminal(height: 8);
      terminal.write('${_mark('133;A;cl=w')}\$ ${_mark('133;B')}ab\r\nwxyz');
      // From column 4 up onto "ab", which clamps to 2; then left to "b".
      expect(terminal.promptClickInput(const CellOffset(3, 0)), '\x1b[A\x1b[D');
      terminal.write('\x1b[3D');
      // From column 1 up to column 1 ("b"), then right to the end.
      expect(
          terminal.promptClickInput(const CellOffset(10, 0)), '\x1b[A\x1b[C');
    });
  });
}
