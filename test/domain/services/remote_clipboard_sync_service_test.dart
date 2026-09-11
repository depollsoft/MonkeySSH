import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/remote_clipboard_sync_service.dart';

void main() {
  group('RemoteClipboardSyncService', () {
    for (final text in ['', 'line\n', 'line\n\n', 'quote\' and snowman ☃\n']) {
      test('read command preserves ${jsonEncode(text)}', () async {
        final command =
            r'pbpaste() { printf %s "$CLIPBOARD_TEXT"; };'
            '\n${RemoteClipboardSyncService.buildReadCommand()}';
        final result = await Process.run(
          '/bin/sh',
          ['-c', command],
          environment: {'CLIPBOARD_TEXT': text},
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(
          RemoteClipboardSyncService.parseReadOutput(
            result.stdout as String,
          ).text,
          text,
        );
      }, skip: Platform.isWindows);

      test('write command preserves ${jsonEncode(text)}', () async {
        final command =
            'pbcopy() { cat; };\n'
            '${RemoteClipboardSyncService.buildWriteCommand(text)}';
        final result = await Process.run('/bin/sh', ['-c', command]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(result.stdout, text);
      }, skip: Platform.isWindows);
    }

    test('canSyncText rejects oversized content', () {
      final text = 'a' * (1024 * 1024 + 1);
      expect(RemoteClipboardSyncService.canSyncText(text), isFalse);
    });

    test('buildReadCommand probes common clipboard utilities', () {
      final command = RemoteClipboardSyncService.buildReadCommand();
      expect(command, contains('pbpaste'));
      expect(command, contains('wl-paste'));
      expect(command, contains('xclip'));
      expect(command, contains('xsel'));
    });

    test('buildWriteCommand probes common clipboard utilities', () {
      final command = RemoteClipboardSyncService.buildWriteCommand('hello');
      expect(command, contains('pbcopy'));
      expect(command, contains('wl-copy'));
      expect(command, contains('xclip -selection clipboard'));
      expect(command, contains('xsel --clipboard --input'));
    });

    test('parseReadOutput decodes clipboard payload', () {
      final result = RemoteClipboardSyncService.parseReadOutput('aGVsbG8=');
      expect(result.supported, isTrue);
      expect(result.text, 'hello');
    });

    test('parseReadOutput detects unsupported clipboard', () {
      final result = RemoteClipboardSyncService.parseReadOutput(
        RemoteClipboardSyncService.unsupportedMarker,
      );
      expect(result.supported, isFalse);
      expect(result.text, isEmpty);
    });

    test('parseReadOutput treats invalid payload as unsupported', () {
      final result = RemoteClipboardSyncService.parseReadOutput('not-base64');
      expect(result.supported, isFalse);
      expect(result.text, isEmpty);
    });
  });
}
