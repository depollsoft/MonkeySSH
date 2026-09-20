import 'package:test/test.dart';
import 'package:xterm/src/core/mouse/reporter.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('MouseReporter', () {
    test('report() supports normal mode', () {
      final output = MouseReporter.report(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        CellOffset(0, 0),
        MouseReportMode.normal,
      );

      expect(output, equals('\x1B[M !!'));
    });

    test('report() supports utf mode', () {
      final output = MouseReporter.report(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        CellOffset(0, 0),
        MouseReportMode.utf,
      );

      expect(output, equals('\x1B[M !!'));
    });

    test('report() supports sgr mode', () {
      final output = MouseReporter.report(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        CellOffset(0, 0),
        MouseReportMode.sgr,
      );

      expect(output, equals('\x1B[<0;1;1M'));
    });

    group('wheel button codes', () {
      // Wheel buttons are reported as bit 6 (+64) plus the button number in
      // the low two bits. Adding the raw button number on top of 64 instead
      // (64 + 4 = 68) sets the Shift modifier bit, so strict applications read
      // the report as a modified wheel event and refuse to scroll.
      const expectedSgrIds = {
        TerminalMouseButton.wheelUp: 64,
        TerminalMouseButton.wheelDown: 65,
        TerminalMouseButton.wheelLeft: 66,
        TerminalMouseButton.wheelRight: 67,
      };

      test('sgr mode reports 64/65/66/67', () {
        expectedSgrIds.forEach((button, id) {
          expect(
            MouseReporter.report(
              button,
              TerminalMouseButtonState.down,
              CellOffset(0, 0),
              MouseReportMode.sgr,
            ),
            '\x1B[<$id;1;1M',
          );
        });
      });

      test('normal mode shifts the same ids by 32', () {
        expectedSgrIds.forEach((button, id) {
          expect(
            MouseReporter.report(
              button,
              TerminalMouseButtonState.down,
              CellOffset(0, 0),
              MouseReportMode.normal,
            ),
            '\x1B[M${String.fromCharCode(32 + id)}!!',
          );
        });
      });

      test('urxvt mode shifts the same ids by 32', () {
        expectedSgrIds.forEach((button, id) {
          expect(
            MouseReporter.report(
              button,
              TerminalMouseButtonState.down,
              CellOffset(0, 0),
              MouseReportMode.urxvt,
            ),
            '\x1B[${32 + id};1;1M',
          );
        });
      });

      test('the ids carry no modifier bits', () {
        for (final button in expectedSgrIds.keys) {
          // Bits 2 (shift), 3 (meta) and 4 (control) must all be clear.
          expect(button.id & 0x1c, 0, reason: '${button.name} id ${button.id}');
        }
      });
    });

    test('report() supports urxvt mode', () {
      final output = MouseReporter.report(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        CellOffset(0, 0),
        MouseReportMode.urxvt,
      );

      expect(output, equals('\x1B[32;1;1M'));
    });
  });
}
