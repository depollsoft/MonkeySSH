import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/monkeymux_windows_cleanup.dart';
import 'package:monkeyssh/domain/services/windows_remote_powershell.dart';

void main() {
  late Directory fixture;
  late String root;
  final old = DateTime.now().toUtc().subtract(const Duration(days: 30));
  final digest = 'a' * 64;
  final otherDigest = 'b' * 64;

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('monkeymux-cleanup-');
    // macOS /var is a symlink; production deliberately avoids linked ancestors.
    root = '${await fixture.resolveSymbolicLinks()}/install root’s';
  });
  tearDown(() => fixture.delete(recursive: true));

  Future<File> binary(String relative, {bool recent = false}) async {
    final file = File('$root/$relative/monkeymux.exe');
    await file.parent.create(recursive: true);
    await file.writeAsString('test executable');
    if (!recent) await file.setLastModified(old);
    return file;
  }

  Future<ProcessResult?> runCleanup(
    File current, {
    String before = '',
    String after = '',
  }) async {
    final script = File('${fixture.path}/cleanup.ps1');
    await script.writeAsString(
      '\uFEFF'
      '''
\$ErrorActionPreference = 'Stop'
$before
${buildMonkeyMuxWindowsCleanupScript(installRoot: root, executablePath: current.path, platform: 'windows-amd64')}
$after
Write-Output 'CONNECTION_CAN_CONTINUE'
''',
    );
    try {
      final result =
          await Process.run(Platform.isWindows ? 'powershell.exe' : 'pwsh', [
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            script.path,
          ]).timeout(const Duration(seconds: 20));
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('CONNECTION_CAN_CONTINUE'));
      return result;
    } on ProcessException {
      if (Platform.isWindows) rethrow;
      markTestSkipped('PowerShell required; Windows CI always runs this test.');
      return null;
    }
  }

  test(
    'prunes old builds and legacy versions, retains current and recent use',
    () async {
      final current = await binary('0.2.0/windows-amd64/$digest');
      final oldSameVersion = await binary('0.2.0/windows-amd64/$otherDigest');
      final oldVersion = await binary('0.1.0/windows-amd64/$digest');
      final legacy = await binary('0.0.1/windows-amd64');
      final recentInstall = await binary(
        '0.1.1/windows-amd64/$digest',
        recent: true,
      );
      final recentUse = await binary('0.1.2/windows-amd64/$digest');
      await File('${recentUse.parent.path}/.last-used').writeAsString('');
      final expiredUse = await binary('0.1.3/windows-amd64/$digest');
      final expiredLease = File('${expiredUse.parent.path}/.last-used');
      await expiredLease.writeAsString('');
      await expiredLease.setLastModified(old);
      final otherPlatform = await binary('0.0.2/windows-arm64/$digest');
      final unrecognizedVersion = await binary(
        'my-files/windows-amd64/$digest',
      );
      final malformedVersions = [
        for (final version in ['1x2y3', '12345', '1.2x3', '1x2.3'])
          await binary('$version/windows-amd64/$digest'),
      ];
      final unrecognizedBuild = await binary('0.1.4/windows-amd64/user-files');
      final withExtraFile = await binary('0.1.5/windows-amd64/$digest');
      final extra = File('${withExtraFile.parent.path}/keep.txt');
      await extra.writeAsString('keep');

      final result = await runCleanup(current);
      if (result == null) return;
      expect(result.stdout, contains('MONKEYMUX_CLEANUP:5:0'));
      for (final file in [
        current,
        recentInstall,
        recentUse,
        otherPlatform,
        unrecognizedVersion,
        ...malformedVersions,
        unrecognizedBuild,
        extra,
      ]) {
        expect(file.existsSync(), isTrue, reason: file.path);
      }
      for (final file in [oldSameVersion, oldVersion, legacy, expiredUse]) {
        expect(file.parent.existsSync(), isFalse, reason: file.path);
      }
      expect(Directory('$root/0.1.0').existsSync(), isFalse);
      expect(Directory('$root/0.0.1').existsSync(), isFalse);
      expect(withExtraFile.existsSync(), isFalse);
      final lease = File('${current.parent.path}/.last-used');
      expect(lease.lastModifiedSync().toUtc().isAfter(old), isTrue);
      expect(
        (await runCleanup(current))!.stdout,
        contains('MONKEYMUX_CLEANUP:0:0'),
      );
    },
  );

  test(
    'skips linked directories and files without traversing their targets',
    () async {
      final current = await binary('0.2.0/windows-amd64/$digest');
      final outside = await binary('outside');
      final linkedVersion = '$root/0.1.0';
      final outsideVersion = Directory('${fixture.path}/outside-version');
      final external = File(
        '${outsideVersion.path}/windows-amd64/$digest/monkeymux.exe',
      );
      await external.parent.create(recursive: true);
      await external.writeAsString('keep');
      await external.setLastModified(old);
      if (Platform.isWindows) {
        final result = await Process.run('cmd.exe', [
          '/c',
          'mklink',
          '/J',
          linkedVersion.replaceAll('/', r'\'),
          outsideVersion.path.replaceAll('/', r'\'),
        ]);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      } else {
        await Link(linkedVersion).create(outsideVersion.path);
        final linkedBuild = '$root/0.2.0/windows-amd64/$otherDigest';
        await Link(linkedBuild).create(outside.parent.path);
        final fileLink = File('$root/0.1.1/windows-amd64/monkeymux.exe');
        await fileLink.parent.create(recursive: true);
        await Link(fileLink.path).create(outside.path);
      }
      try {
        final result = await runCleanup(current);
        if (result == null) return;
        expect(result.stdout, contains('MONKEYMUX_CLEANUP:0:0'));
        expect(external.existsSync(), isTrue);
        expect(outside.existsSync(), isTrue);
      } finally {
        // Remove the Windows junction before recursively removing the fixture.
        if (Platform.isWindows) await Directory(linkedVersion).delete();
      }
    },
  );

  test('cleanup failure does not prevent connecting', () async {
    final current = await binary('0.2.0/windows-amd64/$digest');
    await Directory('${current.parent.path}/.last-used').create();
    final previous = await binary('0.1.0/windows-amd64/$digest');
    final result = await runCleanup(current);
    if (result == null) return;
    expect(current.existsSync(), isTrue);
    expect(previous.existsSync(), isTrue);
  });

  test(
    'Windows locked builds survive and are pruned after release',
    () async {
      final current = await binary('0.2.0/windows-amd64/$digest');
      final locked = await binary('0.1.0/windows-amd64/$digest');
      final result = await runCleanup(
        current,
        before:
            '\$lock = [IO.File]::Open(${powerShellSingleQuote(locked.path)}, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)',
        after: r'$lock.Dispose()',
      );
      expect(result!.stdout, contains('MONKEYMUX_CLEANUP:0:1'));
      expect(locked.existsSync(), isTrue);
      expect(
        (await runCleanup(current))!.stdout,
        contains('MONKEYMUX_CLEANUP:1:0'),
      );
      expect(locked.parent.existsSync(), isFalse);
    },
    skip: !Platform.isWindows,
  );

  test(
    'Windows running executable survives until its process exits',
    () async {
      final current = await binary('0.2.0/windows-amd64/$digest');
      final running = await binary('0.1.0/windows-amd64/$digest');
      await File(Platform.environment['ComSpec']!).copy(running.path);
      await running.setLastModified(old);
      final process = await Process.start(running.path, ['/d', '/q']);
      final ready = Completer<void>();
      final output = process.stdout.listen((_) {
        if (!ready.isCompleted) ready.complete();
      });
      final errors = process.stderr.listen((_) {});
      try {
        process.stdin.writeln('echo MONKEYMUX_READY');
        await process.stdin.flush();
        await ready.future.timeout(const Duration(seconds: 10));
        final result = await runCleanup(current);
        expect(result!.stdout, contains('MONKEYMUX_CLEANUP:0:1'));
        expect(running.existsSync(), isTrue);
      } finally {
        process.kill();
        await process.exitCode;
        await process.stdin.close();
        await output.cancel();
        await errors.cancel();
      }
      expect(
        (await runCleanup(current))!.stdout,
        contains('MONKEYMUX_CLEANUP:1:0'),
      );
      expect(running.parent.existsSync(), isFalse);
    },
    skip: !Platform.isWindows,
  );
}
