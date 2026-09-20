import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// RIS (`ESC c`) and DECSTR (`CSI ! p`).
///
/// Both were silently dropped by the parser, so `reset` (which writes RIS then
/// DECSTR) left the screen, the modes and the tab stops exactly as the crashed
/// program had left them.
void main() {
  Terminal newTerminal() => Terminal(inputHandler: null);

  group('RIS (ESC c)', () {
    test('clears the screen, keeps the scrollback, and homes the cursor', () {
      final terminal = newTerminal();
      for (var i = 0; i < 40; i++) {
        terminal.write('line $i\r\n');
      }
      final heightBefore = terminal.buffer.height;
      expect(heightBefore, greaterThan(terminal.viewHeight));
      expect(terminal.buffer.getText(), contains('line 0'));

      terminal.write('\x1bc');

      // xterm keeps its saved lines on RIS, and so does the MonkeyMux screen
      // model; only the visible screen is erased.
      expect(terminal.buffer.height, heightBefore);
      expect(terminal.buffer.getText(), contains('line 0'));
      final visible = [
        for (var row = 0; row < terminal.viewHeight; row++)
          terminal.buffer.lines[terminal.buffer.scrollBack + row].toString(),
      ].join();
      expect(visible.trim(), isEmpty);
      expect(terminal.buffer.cursorX, 0);
      expect(terminal.buffer.cursorY, 0);

      terminal.write('\x1b[3J');
      expect(terminal.buffer.height, terminal.viewHeight);
    });

    test('resets the graphic rendition', () {
      final terminal = newTerminal();
      terminal.write('\x1b[1;4;31m');
      expect(terminal.cursor.isBold, isTrue);

      terminal.write('\x1bc');

      expect(terminal.cursor.isBold, isFalse);
      expect(terminal.cursor.underlineStyle, UnderlineStyle.none);
      expect(terminal.cursor.foreground, 0);
    });

    test('resets the designated character sets and the shift state', () {
      final terminal = newTerminal();
      terminal.write('\x1b(0'); // G0 = DEC special graphics
      terminal.write('q');
      expect(terminal.buffer.getText(), startsWith('─'));

      terminal.write('\x1bc');
      terminal.write('q');

      expect(terminal.buffer.getText(), startsWith('q'));
    });

    test('resets the modes DECSTR owns', () {
      final terminal = newTerminal();
      terminal.write('\x1b[4h'); // IRM
      terminal.write('\x1b[?25l'); // DECTCEM off
      terminal.write('\x1b[?7l'); // DECAWM off
      terminal.write('\x1b[?1h'); // DECCKM
      terminal.write('\x1b[?6h'); // DECOM
      terminal.write('\x1b[?2004h'); // bracketed paste
      terminal.write('\x1b[?1004h'); // focus reporting
      terminal.write('\x1b='); // DECKPAM
      terminal.write('\x1b[20h'); // LNM

      terminal.write('\x1bc');

      expect(terminal.insertMode, isFalse);
      expect(terminal.cursorVisibleMode, isTrue);
      expect(terminal.autoWrapMode, isTrue);
      expect(terminal.cursorKeysMode, isFalse);
      expect(terminal.originMode, isFalse);
      expect(terminal.bracketedPasteMode, isFalse);
      expect(terminal.reportFocusMode, isFalse);
      expect(terminal.appKeypadMode, isFalse);
      expect(terminal.lineFeedMode, isFalse);
    });

    test('resets the modes DECSTR leaves alone', () {
      final terminal = newTerminal();
      terminal.write('\x1b[?1002h'); // mouse tracking
      terminal.write('\x1b[?1006h'); // SGR mouse reports
      terminal.write('\x1b[?1007h'); // alt-buffer mouse scroll
      terminal.write('\x1b[?5h'); // DECSCNM
      terminal.write('\x1b[?12h'); // cursor blink
      terminal.write('\x1b[?2l'); // DECANM -> VT52
      terminal.write('\x1b[?2026h'); // synchronized output
      terminal.write('\x1b[=5u'); // Kitty keyboard flags
      expect(terminal.mouseMode, isNot(MouseMode.none));
      expect(terminal.kittyKeyboardFlags, 5);

      terminal.write('\x1bc');

      expect(terminal.mouseMode, MouseMode.none);
      expect(terminal.mouseReportMode, MouseReportMode.normal);
      expect(terminal.altBufferMouseScrollMode, isFalse);
      expect(terminal.reverseDisplayMode, isFalse);
      expect(terminal.cursorBlinkMode, isFalse);
      expect(terminal.ansiMode, isTrue);
      expect(terminal.synchronizedOutputMode, isFalse);
      expect(terminal.kittyKeyboardFlags, 0);
    });

    test('resets the scroll margins and the tab stops', () {
      final terminal = newTerminal();
      terminal.write('\x1b[2;5r');
      terminal.write('\x1b[3g'); // clear every tab stop
      expect(terminal.buffer.marginTop, 1);
      expect(terminal.buffer.marginBottom, 4);

      terminal.write('\x1bc');

      expect(terminal.buffer.marginTop, 0);
      expect(terminal.buffer.marginBottom, terminal.viewHeight - 1);
      terminal.write('\t');
      expect(terminal.buffer.cursorX, 8);
    });

    test('resets the saved cursor', () {
      final terminal = newTerminal();
      terminal.write('\x1b[5;9H\x1b[1m\x1b7'); // DECSC at row 5, column 9, bold

      terminal.write('\x1bc');
      terminal.write('\x1b8'); // DECRC

      expect(terminal.buffer.cursorX, 0);
      expect(terminal.buffer.cursorY, 0);
      expect(terminal.cursor.isBold, isFalse);
    });

    test('returns to the main screen and empties the alternate one', () {
      final terminal = newTerminal();
      terminal.write('main text');
      terminal.write('\x1b[?1049h');
      terminal.write('alt text');
      expect(terminal.isUsingAltBuffer, isTrue);

      terminal.write('\x1bc');

      expect(terminal.isUsingAltBuffer, isFalse);
      expect(terminal.buffer.getText().trim(), isEmpty);
      expect(terminal.altBuffer.getText().trim(), isEmpty);
      expect(terminal.mainBuffer.getText().trim(), isEmpty);
    });

    test('keeps retained Kitty images a scrollback placeholder may use', () {
      final terminal = newTerminal();
      final pixel = base64.encode(const [0xFF, 0x00, 0x00, 0xFF]);
      terminal.write('\x1b_Ga=t,i=42,f=32,s=1,v=1,q=2;$pixel\x1b\\');
      expect(terminal.heldImageSignatures(), contains(42));

      terminal.write('\x1bc');

      // Same replay-safe rule as a screen clear: the scrollback survives RIS
      // and its placeholder cells may still refer to the image.
      expect(terminal.heldImageSignatures(), contains(42));
    });

    test('leaves an open MonkeyMux synchronized redraw alone', () {
      final terminal = newTerminal();
      terminal.write('\x1b[?9002h');
      expect(terminal.isMonkeyMuxSynchronizedOutputOpen, isTrue);

      terminal.write('\x1bc');

      // The 9002 transaction is transport framing written by the server around
      // a redraw, not application state: the end marker is still coming.
      expect(terminal.isMonkeyMuxSynchronizedOutputOpen, isTrue);
      terminal.write('\x1b[?9002l');
      expect(terminal.isMonkeyMuxSynchronizedOutputOpen, isFalse);
    });

    test('is not confused with the primary device attributes request', () {
      final terminal = newTerminal();
      final output = <String>[];
      terminal.onOutput = output.add;
      terminal.write('hello');

      terminal.write('\x1b[c'); // DA1, not RIS

      expect(output, isNotEmpty);
      expect(terminal.buffer.getText(), contains('hello'));
    });

    test('survives being split across write boundaries', () {
      final terminal = newTerminal();
      terminal.write('mess');
      terminal.write('\x1b');
      terminal.write('c');

      expect(terminal.buffer.getText().trim(), isEmpty);
      expect(terminal.buffer.getText(), isNot(contains('c')));
    });
  });

  group('DECSTR (CSI ! p)', () {
    test('keeps the screen, the cursor and the tab stops', () {
      final terminal = newTerminal();
      terminal.write('hello\r\nworld');
      final x = terminal.buffer.cursorX;
      final y = terminal.buffer.cursorY;

      terminal.write('\x1b[!p');

      expect(terminal.buffer.getText(), contains('hello'));
      expect(terminal.buffer.getText(), contains('world'));
      expect(terminal.buffer.cursorX, x);
      expect(terminal.buffer.cursorY, y);
      terminal.write('\r\t');
      expect(terminal.buffer.cursorX, 8);
    });

    test('does not restore tab stops the program cleared', () {
      final terminal = newTerminal();
      terminal.write('\x1b[3g');

      terminal.write('\x1b[!p');
      terminal.write('\t');

      expect(terminal.buffer.cursorX, terminal.viewWidth - 1);
    });

    test('resets rendition, margins, the saved cursor and its own modes', () {
      final terminal = newTerminal();
      terminal.write('\x1b[10;3H\x1b[1m\x1b7');
      terminal.write('\x1b[4h\x1b[?25l\x1b[?7l\x1b[?1h\x1b[?6h');
      terminal.write('\x1b[?2004h\x1b[?1004h\x1b=\x1b[20h');
      terminal.write('\x1b[2;5r');
      terminal.write('\x1b(0');

      terminal.write('\x1b[!p');

      expect(terminal.cursor.isBold, isFalse);
      expect(terminal.insertMode, isFalse);
      expect(terminal.cursorVisibleMode, isTrue);
      expect(terminal.autoWrapMode, isTrue);
      expect(terminal.cursorKeysMode, isFalse);
      expect(terminal.originMode, isFalse);
      expect(terminal.bracketedPasteMode, isFalse);
      expect(terminal.reportFocusMode, isFalse);
      expect(terminal.appKeypadMode, isFalse);
      expect(terminal.lineFeedMode, isFalse);
      expect(terminal.buffer.marginTop, 0);
      expect(terminal.buffer.marginBottom, terminal.viewHeight - 1);

      terminal.write('q');
      expect(terminal.buffer.getText(), contains('q'));

      terminal.write('\x1b8'); // the saved cursor is back at home
      expect(terminal.buffer.cursorX, 0);
      expect(terminal.buffer.cursorY, 0);
    });

    test('leaves mouse tracking and the Kitty keyboard flags alone', () {
      final terminal = newTerminal();
      terminal.write('\x1b[?1002h\x1b[?1006h\x1b[=5u');

      terminal.write('\x1b[!p');

      // xterm and xterm.js both keep these across a soft reset; dropping them
      // would take mouse input away from a program that merely re-initialises.
      expect(terminal.mouseMode, MouseMode.upDownScrollDrag);
      expect(terminal.mouseReportMode, MouseReportMode.sgr);
      expect(terminal.kittyKeyboardFlags, 5);
    });

    test('does not clear the Kitty images', () {
      final terminal = newTerminal();
      final pixel = base64.encode(const [0xFF, 0x00, 0x00, 0xFF]);
      terminal.write('\x1b_Ga=t,i=42,f=32,s=1,v=1,q=2;$pixel\x1b\\');

      terminal.write('\x1b[!p');

      expect(terminal.heldImageSignatures(), contains(42));
    });

    test('a `p` final without the `!` intermediate is ignored', () {
      final terminal = newTerminal();
      terminal.write('hi\x1b[1m');

      terminal.write('\x1b[p');
      terminal.write('\x1b[?!p');
      terminal.write('\x1b[0"p'); // DECSCL

      expect(terminal.buffer.getText(), contains('hi'));
      expect(terminal.buffer.getText(), isNot(contains('p')));
      expect(terminal.cursor.isBold, isTrue);
    });
  });

  group('the byte stream /usr/bin/reset writes', () {
    test('leaves no literal garbage behind', () {
      final terminal = newTerminal();
      terminal.write('some mess\r\n\x1b[1mBOLD');
      terminal.write('\x1b[4h\x1b[?25l\x1b[2;5r\x1b[3g\x1b[?1002h');

      // Tab initialisation (TBC, then CR + 8 spaces + HTS per stop), then
      // rs1/rs2 (RIS, DECSTR, DECRST, keypad reset), then CR.
      final stream = StringBuffer('\r\x1b[3g');
      for (var i = 0; i < 9; i++) {
        stream.write('        \x1bH');
      }
      stream.write('\r\x1bc\x1b[!p\x1b[?3;4l\x1b[4l\x1b>\r');
      terminal.write(stream.toString());

      expect(terminal.buffer.getText().trim(), isEmpty);
      expect(terminal.buffer.cursorX, 0);
      expect(terminal.buffer.cursorY, 0);
      expect(terminal.cursor.isBold, isFalse);
      expect(terminal.insertMode, isFalse);
      expect(terminal.cursorVisibleMode, isTrue);
      expect(terminal.mouseMode, MouseMode.none);
      expect(terminal.buffer.marginTop, 0);
      expect(terminal.buffer.marginBottom, terminal.viewHeight - 1);
      // RIS restored the default stops; the HTS loop above re-set them anyway.
      terminal.write('\t');
      expect(terminal.buffer.cursorX, 8);
    });
  });
}
