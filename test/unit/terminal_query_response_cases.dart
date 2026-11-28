import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// Registers tests from terminal_query_response_test.dart.
void registerUnitTerminalQueryResponseTests() {
  group('terminal_query_response', () {
    group('terminal capability query responses', () {
      test('XTVERSION (CSI > q) reports a kitty-family identity', () {
        // CLIs such as the GitHub Copilot CLI gate their richer rendering (e.g.
        // full-width prompt/composer backgrounds) on a recognized XTVERSION name.
        // MonkeySSH implements the kitty graphics + keyboard protocols, so it
        // answers with a kitty identity to unlock that path.
        final responses = <String>[];
        Terminal()
          ..onOutput = responses.add
          ..write('\x1b[>q');

        expect(responses, ['\x1bP>|kitty(0.32.0)\x1b\\']);
      });

      test('XTVERSION reply starts with a name Copilot CLI recognizes', () {
        final responses = <String>[];
        Terminal()
          ..onOutput = responses.add
          ..write('\x1b[>q');

        // DCS `ESC P > | <name> ESC \`; the payload must start with "kitty".
        final reply = responses.single;
        expect(reply.startsWith('\x1bP>|kitty'), isTrue);
        expect(reply.endsWith('\x1b\\'), isTrue);
      });

      test('a bare CSI q (no > prefix) does not emit an XTVERSION reply', () {
        final responses = <String>[];
        // Space-intermediate form (DECSCUSR cursor style) must not be treated as
        // XTVERSION.
        Terminal()
          ..onOutput = responses.add
          ..write('\x1b[ q');

        expect(responses, isEmpty);
      });

      test('primary device attributes report VT220 with ANSI colour', () {
        final responses = <String>[];
        Terminal()
          ..onOutput = responses.add
          ..write('\x1b[c');

        // DA1: VT220 service class (62) advertising ANSI colour (22).
        expect(responses, ['\x1b[?62;22c']);
      });

      test('secondary device attributes report a VT220-class identity', () {
        final responses = <String>[];
        Terminal()
          ..onOutput = responses.add
          ..write('\x1b[>c');

        // DA2: model 1 (VT220), firmware version 0.
        expect(responses, ['\x1b[>1;0;0c']);
      });
    });

    group('XTGETTCAP (DCS + q <hex> ST)', () {
      String hex(String value) => value.codeUnits
          .map((u) => u.toRadixString(16).padLeft(2, '0'))
          .join();

      test('reports the colour count (Co) as 256', () {
        final responses = <String>[];
        Terminal()
          ..onOutput = responses.add
          ..write('\x1bP+q${hex('Co')}\x1b\\');

        expect(responses, ['\x1bP1+r${hex('Co')}=${hex('256')}\x1b\\']);
      });

      test('reports terminfo colors and direct-colour (RGB)', () {
        final responses = <String>[];
        Terminal()
          ..onOutput = responses.add
          ..write('\x1bP+q${hex('colors')}\x1b\\')
          ..write('\x1bP+q${hex('RGB')}\x1b\\');

        expect(responses, [
          '\x1bP1+r${hex('colors')}=${hex('256')}\x1b\\',
          '\x1bP1+r${hex('RGB')}=${hex('8/8/8')}\x1b\\',
        ]);
      });

      test('reports unknown capabilities as invalid (0+r)', () {
        final responses = <String>[];
        // TN (terminal name) is host/TERM-defined and intentionally not answered.
        Terminal()
          ..onOutput = responses.add
          ..write('\x1bP+q${hex('TN')}\x1b\\');

        expect(responses, ['\x1bP0+r${hex('TN')}\x1b\\']);
      });

      test('answers each capability in a multi-cap request', () {
        final responses = <String>[];
        Terminal()
          ..onOutput = responses.add
          ..write('\x1bP+q${hex('Co')};${hex('bogus')}\x1b\\');

        expect(responses, [
          '\x1bP1+r${hex('Co')}=${hex('256')}\x1b\\',
          '\x1bP0+r${hex('bogus')}\x1b\\',
        ]);
      });

      test('an unhandled DCS is consumed without leaking as text', () {
        final responses = <String>[];
        // A Sixel-style DCS (`DCS q ... ST`, neither +q nor $q) must not emit a
        // reply nor render its body.
        final terminal = Terminal()
          ..onOutput = responses.add
          ..write('\x1bPq#0;2;0;0;0\x1b\\');

        expect(responses, isEmpty);
        expect(terminal.buffer.getText().trim(), isEmpty);
      });
    });

    group(r'DECRQSS (DCS $ q <Pt> ST)', () {
      test('reports the scrolling region (DECSTBM) for an 80x24 terminal', () {
        final responses = <String>[];
        Terminal()
          ..onOutput = responses.add
          ..write('\x1bP\$qr\x1b\\');

        // Default margins span the whole screen: rows 1..24.
        expect(responses, ['\x1bP1\$r1;24r\x1b\\']);
      });

      test('reports a custom scrolling region', () {
        final responses = <String>[];
        Terminal()
          ..onOutput = responses.add
          ..write('\x1b[5;20r') // DECSTBM top=5 bottom=20
          ..write('\x1bP\$qr\x1b\\');

        expect(responses, ['\x1bP1\$r5;20r\x1b\\']);
      });

      test('reports the default SGR as a bare reset', () {
        final responses = <String>[];
        Terminal()
          ..onOutput = responses.add
          ..write('\x1bP\$qm\x1b\\');

        expect(responses, ['\x1bP1\$r0m\x1b\\']);
      });

      test('reports the active SGR (bold + named foreground)', () {
        final responses = <String>[];
        Terminal()
          ..onOutput = responses.add
          ..write('\x1b[1;31m') // bold, red foreground
          ..write('\x1bP\$qm\x1b\\');

        expect(responses, ['\x1bP1\$r0;1;31m\x1b\\']);
      });

      test('reports indexed and rgb SGR colours', () {
        final responses = <String>[];
        Terminal()
          ..onOutput = responses.add
          ..write('\x1b[38;5;42;48;2;1;2;3m') // palette fg 42, rgb bg 1/2/3
          ..write('\x1bP\$qm\x1b\\');

        expect(responses, ['\x1bP1\$r0;38;5;42;48;2;1;2;3m\x1b\\']);
      });

      test('reports an untracked control function (DECSCUSR) as invalid', () {
        final responses = <String>[];
        // Cursor shape (` q`) is not tracked by the core terminal, so DECRQSS
        // reports it as not recognized rather than guessing.
        Terminal()
          ..onOutput = responses.add
          ..write('\x1bP\$q q\x1b\\');

        expect(responses, ['\x1bP0\$r\x1b\\']);
      });
    });

    group('window size reports (CSI t)', () {
      test('leaves pixel-size reports (14t/16t) to the app layer', () {
        final responses = <String>[];
        // `CSI 14t` (text area px) and `CSI 16t` (cell px) are answered by the
        // MonkeySSH app layer, which has the real window metrics. The core must
        // stay silent so the program does not receive two replies.
        Terminal()
          ..onOutput = responses.add
          ..resize(80, 24, 800, 480)
          ..write('\x1b[14t')
          ..write('\x1b[16t');

        expect(responses, isEmpty);
      });

      test('answers the character size report (CSI 18 t)', () {
        final responses = <String>[];
        // 18t (size in characters) is core-only; the app layer does not answer it.
        Terminal()
          ..onOutput = responses.add
          ..write('\x1b[18t');

        expect(responses, ['\x1b[8;24;80t']);
      });
    });
  });
}
