// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/terminal_capability_hint.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('buildTerminalCapabilityHintReports', () {
    test('encodes the terminal replies MonkeyMux can cache', () {
      const emitter = EscapeEmitter();
      final hint = buildTerminalCapabilityHintReports();
      final entries = hint.split(terminalCapabilityHintRecordSeparator);
      final reports = <String, String>{
        for (final entry in entries)
          entry.split(terminalCapabilityHintFieldSeparator).first: entry
              .split(terminalCapabilityHintFieldSeparator)
              .skip(1)
              .join(terminalCapabilityHintFieldSeparator),
      };

      expect(reports, {
        terminalCapabilityHintPrimaryDeviceAttributesKey: emitter
            .primaryDeviceAttributes(),
        terminalCapabilityHintSecondaryDeviceAttributesKey: emitter
            .secondaryDeviceAttributes(),
        terminalCapabilityHintTertiaryDeviceAttributesKey: emitter
            .tertiaryDeviceAttributes(),
        terminalCapabilityHintTerminalVersionKey: emitter.terminalVersion(),
        terminalCapabilityHintDeviceStatusKey: emitter.operatingStatus(),
        terminalCapabilityHintKittyClipboardKey: '\x1b[?5522;2\$y',
      });
    });

    test('keeps every reply free of the wire separators', () {
      final hint = buildTerminalCapabilityHintReports();

      expect(
        hint.split(terminalCapabilityHintRecordSeparator),
        everyElement(
          predicate<String>(
            (entry) =>
                entry.split(terminalCapabilityHintFieldSeparator).length == 2,
            'has exactly one field separator',
          ),
        ),
      );
    });
  });

  group('encodeTerminalCapabilityHintReports', () {
    test('joins entries with the record and field separators', () {
      expect(
        encodeTerminalCapabilityHintReports({'a': '1', 'b': '2'}),
        'a\x1f1\x1eb\x1f2',
      );
    });

    test('drops empty keys and replies', () {
      expect(
        encodeTerminalCapabilityHintReports({'': '1', 'b': '', 'c': '3'}),
        'c\x1f3',
      );
    });
  });
}
