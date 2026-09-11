import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';
import 'package:xterm/xterm.dart';

@GenerateNiceMocks([MockSpec<EscapeHandler>()])
import 'parser_test.mocks.dart';

void main() {
  group('EscapeParser', () {
    test('can parse window manipulation', () {
      final parser = EscapeParser(MockEscapeHandler());
      parser.write('\x1b[8;24;80t');
      verify(parser.handler.resize(80, 24));
    });

    test('can parse private host window manipulation', () {
      final parser = EscapeParser(MockEscapeHandler());
      parser.write('\x1b[?8;24;80t');
      verify(parser.handler.resizeFromHost(80, 24));
    });

    group('SGR extended color', () {
      test('legacy semicolon truecolor foreground', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[38;2;255;128;0m');
        verify(parser.handler.setForegroundColorRgb(255, 128, 0));
      });

      test('legacy semicolon indexed background', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[48;5;160m');
        verify(parser.handler.setBackgroundColor256(160));
      });

      test('colon truecolor foreground with empty color space', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[38:2::255:128:0m');
        verify(parser.handler.setForegroundColorRgb(255, 128, 0));
      });

      test('colon truecolor foreground without color space', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[38:2:255:128:0m');
        verify(parser.handler.setForegroundColorRgb(255, 128, 0));
      });

      test('colon indexed foreground', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[38:5:160m');
        verify(parser.handler.setForegroundColor256(160));
      });

      test('colon truecolor background with explicit color space id', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[48:2:1:10:20:30m');
        verify(parser.handler.setBackgroundColorRgb(10, 20, 30));
      });

      test('colon SGR does not bleed into following attributes', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[1;38:5:208;4m');
        verify(parser.handler.setCursorBold());
        verify(parser.handler.setForegroundColor256(208));
        verify(parser.handler.setCursorUnderline());
      });

      test(
        'missing extended color arguments do not leak into later params',
        () {
          final parser = EscapeParser(MockEscapeHandler());
          expect(() => parser.write('\x1b[38m'), returnsNormally);
          expect(() => parser.write('\x1b[38;5m'), returnsNormally);
          parser.write('\x1b[48;2;255;31m');
          verifyNever(parser.handler.setCursorBlink());
          verifyNever(parser.handler.setBackgroundColorRgb(255, 31, 0));
          verify(parser.handler.setForegroundColor16(NamedColor.red));
        },
      );

      test('unknown extended color mode does not skip following attributes',
          () {
        final parser = EscapeParser(MockEscapeHandler());

        parser.write('\x1b[38;7;3m');

        verifyNever(parser.handler.setCursorInverse());
        verify(parser.handler.setCursorItalic());
      });
    });

    group('SGR underline and overline', () {
      test('empty SGR parameter resets style', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[31;m');
        verify(parser.handler.setForegroundColor16(NamedColor.red));
        verify(parser.handler.resetCursorStyle());
      });

      test('legacy single underline (4)', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[4m');
        verify(parser.handler.setCursorUnderline());
      });

      test('curly underline (4:3)', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[4:3m');
        verify(parser.handler.setCursorUnderlineStyle(UnderlineStyle.curly));
      });

      test('dotted underline (4:4)', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[4:4m');
        verify(parser.handler.setCursorUnderlineStyle(UnderlineStyle.dotted));
      });

      test('underline off via sub-parameter (4:0)', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[4:0m');
        verify(parser.handler.setCursorUnderlineStyle(UnderlineStyle.none));
      });

      test('double underline (21)', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[21m');
        verify(parser.handler.setCursorUnderlineStyle(UnderlineStyle.double));
      });

      test('22 clears both bold and faint', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[22m');
        verify(parser.handler.unsetCursorBold());
        verify(parser.handler.unsetCursorFaint());
      });

      test('overline on and off (53 / 55)', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[53m');
        verify(parser.handler.setCursorOverline());
        parser.write('\x1b[55m');
        verify(parser.handler.unsetCursorOverline());
      });
    });

    group('SGR underline color', () {
      test('indexed underline color (58:5:n)', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[58:5:160m');
        verify(parser.handler.setUnderlineColor256(160));
      });

      test('legacy indexed underline color (58;5;n)', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[58;5;160m');
        verify(parser.handler.setUnderlineColor256(160));
      });

      test('truecolor underline color (58:2::r:g:b)', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[58:2::10:20:30m');
        verify(parser.handler.setUnderlineColorRgb(10, 20, 30));
      });

      test('reset underline color (59)', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[59m');
        verify(parser.handler.resetUnderlineColor());
      });

      test('combined curly underline with color does not bleed', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b[4:3;58:2::255:0:0mX');
        verify(parser.handler.setCursorUnderlineStyle(UnderlineStyle.curly));
        verify(parser.handler.setUnderlineColorRgb(255, 0, 0));
        verify(parser.handler.writeChar(0x58));
      });
    });

    group('robustness', () {
      test('numeric saturation survives chunking and resets per parameter', () {
        for (final digits in ['2147483647', '2147483648', '9' * 300]) {
          final handler = MockEscapeHandler();
          final parser = EscapeParser(handler)..write('\x1b[');
          for (final digit in digits.split('')) {
            parser.write(digit);
          }
          parser.write(';5H\x1b[3C');
          verify(handler.setCursor(4, 0x7ffffffe)).called(1);
          verify(handler.moveCursorX(3)).called(1);
        }
      });

      test('designates G2 and G3 charsets', () {
        final parser = EscapeParser(MockEscapeHandler());
        parser.write('\x1b*0\x1b+B');
        verify(parser.handler.designateCharset(2, '0'.codeUnitAt(0)));
        verify(parser.handler.designateCharset(3, 'B'.codeUnitAt(0)));
      });

      test('caps the number of CSI parameters without hanging', () {
        final parser = EscapeParser(MockEscapeHandler());
        final huge = '\x1b[${List.filled(5000, '1').join(';')}m';
        expect(() => parser.write(huge), returnsNormally);
      });

      test('caps the number of colon sub-parameters', () {
        final parser = EscapeParser(MockEscapeHandler());
        final huge = '\x1b[38:${List.filled(5000, '1').join(':')}m';
        expect(() => parser.write(huge), returnsNormally);
      });
    });

    group('Kitty graphics (APC)', () {
      test('parses args and decodes the base64 payload', () {
        final handler = MockEscapeHandler();
        // 'hi' -> base64 'aGk='
        EscapeParser(handler).write('\x1b_Ga=T,f=100;aGk=\x1b\\');
        final args = verify(
          handler.graphicsCommandStart(captureAny),
        ).captured.single;
        expect(args, {'a': 'T', 'f': '100'});
        final chunk = verify(
          handler.graphicsDataChunk(captureAny),
        ).captured.single;
        expect(chunk, [0x68, 0x69]);
        verify(handler.graphicsCommandEnd());
      });

      test('m=1 marks a non-final chunk (no end yet)', () {
        final handler = MockEscapeHandler();
        EscapeParser(handler).write('\x1b_Ga=t,m=1;aGk=\x1b\\');
        verify(handler.graphicsCommandStart(captureAny));
        verifyNever(handler.graphicsCommandEnd());
      });

      test('command without payload still starts and ends', () {
        final handler = MockEscapeHandler();
        EscapeParser(handler).write('\x1b_Ga=d\x1b\\');
        final args = verify(
          handler.graphicsCommandStart(captureAny),
        ).captured.single;
        expect(args, {'a': 'd'});
        verifyNever(handler.graphicsDataChunk(captureAny));
        verify(handler.graphicsCommandEnd());
      });

      test('unknown APC is consumed without leaking payload as text', () {
        final handler = MockEscapeHandler();
        EscapeParser(handler).write('\x1b_Xsome data\x1b\\hi');
        verifyNever(handler.graphicsCommandStart(captureAny));
        // The trailing "hi" is still written normally.
        verify(handler.writeChar(0x68));
        verify(handler.writeChar(0x69));
      });

      test('a command split across writes is dispatched once', () {
        final handler = MockEscapeHandler();
        EscapeParser(handler)
          ..write('\x1b_Ga=T;aG')
          ..write('k=\x1b\\');
        verify(handler.graphicsCommandStart(captureAny)).called(1);
        verify(handler.graphicsCommandEnd()).called(1);
      });
    });

    group('ESC re-enters the escape state', () {
      // ECMA-48/VT500: an ESC aborts whatever sequence is being collected and
      // starts a new one. Swallowing it instead lets a duplicated or stray ESC
      // turn the sequence that follows into visible garbage, e.g. `ESC ESC ] 8
      // ; id=...` printing the hyperlink introducer as literal text.
      test('duplicated ESC still dispatches the OSC that follows', () {
        final handler = MockEscapeHandler();
        EscapeParser(handler).write(
          '\x1b\x1b]8;id=md-7nao1v;https://example.com/x\x1b\\',
        );
        verify(
          handler.unknownOSC('8', ['id=md-7nao1v', 'https://example.com/x']),
        ).called(1);
        verifyNever(handler.writeChar(0x5d)); // ']'
      });

      test('duplicated ESC still dispatches the CSI that follows', () {
        final handler = MockEscapeHandler();
        EscapeParser(handler).write('\x1b\x1b[38;5;214m');
        verify(handler.setForegroundColor256(214)).called(1);
        verifyNever(handler.writeChar(0x5b)); // '['
      });

      test('ESC ends a truncated CSI instead of being absorbed by it', () {
        final handler = MockEscapeHandler();
        EscapeParser(handler).write('\x1b[38;5\x1b]0;title\x07');
        verify(handler.setTitle('title')).called(1);
      });

      test('ESC ends a truncated OSC instead of swallowing the next escape',
          () {
        final handler = MockEscapeHandler();
        EscapeParser(handler).write('\x1b]0;trunc\x1b]2;title\x07');
        verify(handler.setTitle('title')).called(1);
        verifyNever(handler.setTitle('trunc'));
      });

      test('a truncated OSC does not dispatch its partial parameters', () {
        final handler = MockEscapeHandler();
        EscapeParser(handler).write('\x1b]8;id=x;https://cut\x1b[38;5;214m');
        verifyNever(handler.unknownOSC(any, any));
        verify(handler.setForegroundColor256(214)).called(1);
      });

      test('ESC ends a truncated APC instead of swallowing the next escape',
          () {
        final handler = MockEscapeHandler();
        EscapeParser(handler).write('\x1b_Ga=T;aGk\x1b]2;title\x07');
        verify(handler.setTitle('title')).called(1);
        verifyNever(handler.graphicsCommandStart(captureAny));
      });

      test('ESC ends a truncated DCS instead of swallowing the next escape',
          () {
        final handler = MockEscapeHandler();
        EscapeParser(handler).write('\x1bP+q544\x1b]2;title\x07');
        verify(handler.setTitle('title')).called(1);
        verifyNever(handler.sendTermcapReport(any));
      });

      test('ESC is not taken as a charset designation name', () {
        final handler = MockEscapeHandler();
        EscapeParser(handler).write('\x1b(\x1b]2;title\x07');
        verify(handler.setTitle('title')).called(1);
        verifyNever(handler.designateCharset(any, any));
      });

      test('an aborted APC cancels an open m=1 graphics transmission', () {
        // Without the cancel, `_graphicsActive` stays set and Terminal swallows
        // the next image's args as a continuation of the broken transmission.
        final handler = MockEscapeHandler();
        final parser = EscapeParser(handler)
          ..write('\x1b_Ga=T,f=100,m=1;AAAA\x1b\\')
          ..write('\x1b_Gm=0;BBBB\x1b[0m');
        verify(handler.graphicsCommandAbort()).called(1);
        verifyNever(handler.graphicsCommandEnd());

        parser.write('\x1b_Ga=T,f=100;CCCC\x1b\\');
        verify(handler.graphicsCommandEnd()).called(1);
      });

      test('a trailing lone ESC is still buffered across writes', () {
        final handler = MockEscapeHandler();
        EscapeParser(handler)
          ..write('\x1b\x1b')
          ..write(']2;title\x07');
        verify(handler.setTitle('title')).called(1);
      });
    });
  });
}
