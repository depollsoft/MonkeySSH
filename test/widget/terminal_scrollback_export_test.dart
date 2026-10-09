import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/terminal_scrollback_export.dart';
import 'package:share_plus/share_plus.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('names the file after the time, not the host', () {
    expect(
      terminalScrollbackExportFileName(DateTime(2026, 10, 9, 7, 5, 3)),
      'terminal-scrollback-20261009-070503.txt',
    );
  });

  test('only Linux and the web save through a dialog', () {
    for (final platform in TargetPlatform.values) {
      expect(
        terminalScrollbackExportUsesShareSheet(platform, isWeb: false),
        platform != TargetPlatform.linux,
        reason: '$platform',
      );
    }
    expect(
      terminalScrollbackExportUsesShareSheet(TargetPlatform.iOS, isWeb: true),
      isFalse,
    );
  });

  group('exportTerminalScrollback', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('scrollback-export-test-');
    });

    tearDown(() {
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });

    Future<BuildContext> pumpHost(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.expand())),
      );
      return tester.element(find.byType(SizedBox));
    }

    testWidgets('shares the buffer as a text file and then deletes it', (
      tester,
    ) async {
      final terminal = Terminal()
        ..resize(10, 6)
        ..write('first  \r\n0123456789wrapped\r\n\$ ');
      final context = await pumpHost(tester);
      ShareParams? shared;
      String? sharedText;
      String? sharedPath;

      await tester.runAsync(
        () => exportTerminalScrollback(
          context: context,
          terminal: terminal,
          platform: TargetPlatform.iOS,
          now: DateTime(2026, 10, 9, 12),
          temporaryDirectory: () async => temp,
          share: (params) async {
            shared = params;
            sharedPath = params.files!.single.path;
            sharedText = File(sharedPath!).readAsStringSync();
            return const ShareResult('', ShareResultStatus.success);
          },
        ),
      );

      expect(shared, isNotNull);
      expect(
        shared!.files!.single.name,
        'terminal-scrollback-20261009-120000.txt',
      );
      expect(shared!.files!.single.mimeType, 'text/plain');
      expect(sharedText, 'first\n0123456789wrapped\n\$\n');
      expect(File(sharedPath!).existsSync(), isFalse);
      expect(temp.listSync(), isEmpty);
    });

    testWidgets('says so when there is nothing to export', (tester) async {
      final terminal = Terminal()..resize(10, 4);
      final context = await pumpHost(tester);
      var shares = 0;

      await tester.runAsync(
        () => exportTerminalScrollback(
          context: context,
          terminal: terminal,
          platform: TargetPlatform.android,
          temporaryDirectory: () async => temp,
          share: (params) async {
            shares++;
            return const ShareResult('', ShareResultStatus.success);
          },
        ),
      );
      await tester.pump();

      expect(shares, 0);
      expect(find.text('Nothing to export yet'), findsOneWidget);
    });

    testWidgets('reports a share sheet failure and still cleans up', (
      tester,
    ) async {
      final terminal = Terminal()
        ..resize(10, 4)
        ..write('output');
      final context = await pumpHost(tester);

      await tester.runAsync(
        () => exportTerminalScrollback(
          context: context,
          terminal: terminal,
          platform: TargetPlatform.android,
          temporaryDirectory: () async => temp,
          share: (params) async => throw StateError('no share sheet'),
        ),
      );
      await tester.pump();

      expect(
        find.text('Couldn’t open the share sheet. Try again.'),
        findsOneWidget,
      );
      expect(temp.listSync(), isEmpty);
    });

    testWidgets('saves through a dialog on Linux', (tester) async {
      final terminal = Terminal()
        ..resize(10, 4)
        ..write('output');
      final context = await pumpHost(tester);
      String? savedName;
      Uint8List? savedBytes;

      await tester.runAsync(
        () => exportTerminalScrollback(
          context: context,
          terminal: terminal,
          platform: TargetPlatform.linux,
          now: DateTime(2026, 1, 2, 3, 4, 5),
          save: ({required fileName, required bytes}) async {
            savedName = fileName;
            savedBytes = bytes;
            return Uri.file('/tmp/$fileName');
          },
        ),
      );
      await tester.pump();

      expect(savedName, 'terminal-scrollback-20260102-030405.txt');
      expect(String.fromCharCodes(savedBytes!), 'output\n');
      expect(find.text('Scrollback saved'), findsOneWidget);
    });
  });
}
