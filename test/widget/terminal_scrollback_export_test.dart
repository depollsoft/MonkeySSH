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

  test('only iOS and Android use the share sheet', () {
    // macOS and Windows return from share_plus while the target may still
    // read the file, which the export then deletes.
    for (final platform in TargetPlatform.values) {
      expect(
        terminalScrollbackExportUsesShareSheet(platform, isWeb: false),
        platform == TargetPlatform.iOS || platform == TargetPlatform.android,
        reason: '$platform',
      );
    }
    expect(
      terminalScrollbackExportUsesShareSheet(TargetPlatform.iOS, isWeb: true),
      isFalse,
    );
  });

  test('macOS may open the save dialog the export uses', () {
    // file_picker refuses to show the save panel in a sandboxed app without
    // this entitlement.
    for (final path in [
      'macos/Runner/Release.entitlements',
      'macos/Runner/DebugProfile.entitlements',
    ]) {
      expect(
        File(path).readAsStringSync(),
        contains('com.apple.security.files.user-selected.read-write'),
        reason: path,
      );
    }
  });

  test('cleans up exports left from an earlier run', () async {
    final temp = Directory.systemTemp.createTempSync('scrollback-cleanup-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final old = DateTime.now().subtract(const Duration(hours: 1));
    final stale = Directory('${temp.path}/monkeyssh-scrollback-old')
      ..createSync();
    // Another program's entry in a shared temporary directory.
    final foreign = Directory('${temp.path}/scrollback-other')..createSync();
    File('${stale.path}/terminal-scrollback-1.txt').writeAsStringSync('x');
    final sharePlus = Directory('${temp.path}/share_plus')..createSync();
    final staleCopy = File('${sharePlus.path}/terminal-scrollback-2.txt')
      ..writeAsStringSync('x')
      ..setLastModifiedSync(old);
    final otherShare = File('${sharePlus.path}/photo.jpg')
      ..writeAsStringSync('x')
      ..setLastModifiedSync(old);
    // Everything above is older than this moment; the export below is newer.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final now = DateTime.now();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final fresh = Directory('${temp.path}/monkeyssh-scrollback-new')
      ..createSync();

    // Linux and Windows share their temporary directory: nothing is touched.
    expect(
      await cleanUpTerminalScrollbackExports(
        temporaryDirectory: temp,
        maxAge: Duration.zero,
        now: now,
        platform: TargetPlatform.linux,
      ),
      0,
    );
    expect(stale.existsSync(), isTrue);

    final deleted = await cleanUpTerminalScrollbackExports(
      temporaryDirectory: temp,
      maxAge: Duration.zero,
      now: now,
      platform: TargetPlatform.android,
    );

    expect(deleted, 2);
    expect(stale.existsSync(), isFalse);
    expect(staleCopy.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
    expect(otherShare.existsSync(), isTrue);
    expect(foreign.existsSync(), isTrue);
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
