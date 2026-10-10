import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/screens/sftp_batch_operations.dart';
import 'package:path/path.dart' as path;

void main() {
  group('runSftpBatch', () {
    test('records a result for every item and keeps going', () async {
      final progress = SftpBatchProgress(verb: 'Deleting', total: 3);
      final report = await runSftpBatch<String>(
        items: ['a', 'b', 'c'],
        nameOf: (item) => item,
        progress: progress,
        run: (item, _) async {
          if (item == 'b') {
            // ignore: only_throw_errors, dartssh2 models protocol errors this way.
            throw SftpStatusError(SftpStatusCode.permissionDenied, 'denied');
          }
        },
      );

      expect(report.results.map((r) => r.outcome), [
        SftpBatchOutcome.done,
        SftpBatchOutcome.failed,
        SftpBatchOutcome.done,
      ]);
      expect(report.results[1].detail, 'Permission denied');
      expect(report.firstError, isA<SftpStatusError>());
      expect(
        sftpBatchSummary('Deleted', report),
        'Deleted 2 of 3 files. 1 failed.',
      );
    });

    test('stops after a failure when asked', () async {
      final report = await runSftpBatch<String>(
        items: ['a', 'b', 'c'],
        nameOf: (item) => item,
        progress: SftpBatchProgress(verb: 'Uploading', total: 3),
        stopOnFailure: true,
        stoppedDetail: 'Not uploaded',
        run: (item, _) async {
          if (item == 'a') throw TimeoutException('slow');
        },
      );

      expect(report.results.map((r) => (r.outcome, r.detail)), [
        (SftpBatchOutcome.failed, 'Timed out'),
        (SftpBatchOutcome.skipped, 'Not uploaded'),
        (SftpBatchOutcome.skipped, 'Not uploaded'),
      ]);
    });

    test('cancellation skips the current and remaining items', () async {
      final progress = SftpBatchProgress(verb: 'Downloading', total: 3);
      final report = await runSftpBatch<String>(
        items: ['a', 'b', 'c'],
        nameOf: (item) => item,
        progress: progress,
        run: (item, _) async {
          if (item == 'b') {
            progress
              ..cancel()
              ..throwIfCancelled();
          }
        },
      );

      expect(report.cancelled, isTrue);
      expect(report.firstError, isNull);
      expect(report.results.map((r) => (r.outcome, r.detail)), [
        (SftpBatchOutcome.done, null),
        (SftpBatchOutcome.skipped, 'Cancelled'),
        (SftpBatchOutcome.skipped, 'Cancelled'),
      ]);
      expect(
        sftpBatchSummary('Downloaded', report),
        'Downloaded 1 of 3 files. Cancelled.',
      );
    });

    test('items can be skipped or failed with their own reason', () async {
      final report = await runSftpBatch<String>(
        items: ['a', 'b'],
        nameOf: (item) => item,
        progress: SftpBatchProgress(verb: 'Moving', total: 2),
        run: (item, _) async => throw item == 'a'
            ? const SftpBatchItemSkipped('Already in this folder')
            : const SftpBatchItemFailure(
                'A file with this name is already here',
              ),
      );

      expect(report.results.map((r) => (r.outcome, r.detail)), [
        (SftpBatchOutcome.skipped, 'Already in this folder'),
        (SftpBatchOutcome.failed, 'A file with this name is already here'),
      ]);
      expect(
        sftpBatchSummary('Moved', report),
        'Moved 0 of 2 files. 1 failed, 1 skipped.',
      );
    });

    test('a batch with only skips does not claim failures', () async {
      final report = await runSftpBatch<String>(
        items: ['a', 'b'],
        nameOf: (item) => item,
        progress: SftpBatchProgress(verb: 'Moving', total: 2),
        run: (item, _) async {
          if (item == 'a') {
            throw const SftpBatchItemSkipped('Already in this folder');
          }
        },
      );

      expect(
        sftpBatchSummary('Moved', report),
        'Moved 1 of 2 files. 1 skipped.',
      );
    });
  });

  test('progress counts bytes of the current item', () {
    final progress = SftpBatchProgress(verb: 'Uploading', total: 2)
      ..start(1, 'b', totalBytes: 100)
      ..updateBytes(50);
    expect(progress.fraction, closeTo(0.75, 0.001));

    var cancelled = 0;
    final remove = progress.onCancel(() => cancelled++);
    progress.cancel();
    remove();
    progress.cancel();
    expect(cancelled, 1);
    expect(
      progress.throwIfCancelled,
      throwsA(isA<SftpBatchCancelledException>()),
    );
  });

  testWidgets('results list every file with a text status', (tester) async {
    const report = SftpBatchReport([
      SftpBatchItemResult('a.txt', SftpBatchOutcome.done),
      SftpBatchItemResult(
        'b.txt',
        SftpBatchOutcome.failed,
        detail: 'Permission denied',
      ),
      SftpBatchItemResult(
        'c.txt',
        SftpBatchOutcome.skipped,
        detail: 'Cancelled',
      ),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSftpBatchResults(
              context,
              title: 'Delete results',
              report: report,
            ),
            child: const Text('show'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();

    expect(find.text('Delete results'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Failed: Permission denied'), findsOneWidget);
    expect(find.text('Skipped: Cancelled'), findsOneWidget);
    expect(find.bySemanticsLabel('b.txt, Failed: Permission denied'), findsOne);
  });

  testWidgets('the progress bar cancels and shows the current file', (
    tester,
  ) async {
    final progress = SftpBatchProgress(verb: 'Uploading', total: 3)
      ..start(1, 'second.txt');
    addTearDown(progress.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: SftpBatchProgressBar(progress: progress),
        ),
      ),
    );

    expect(find.text('uploading 2 of 3'), findsOneWidget);
    expect(find.text('second.txt'), findsOneWidget);
    expect(
      tester.getSize(find.widgetWithText(OutlinedButton, 'Cancel')).height,
      greaterThanOrEqualTo(48),
    );
    await tester.tap(find.text('Cancel'));
    await tester.pump();

    expect(progress.cancelRequested, isTrue);
    expect(find.text('cancelling'), findsOneWidget);
    expect(find.text('Cancelling…'), findsOneWidget);
  });

  testWidgets('reduced motion drops the indeterminate bar', (tester) async {
    final progress = SftpBatchProgress(
      verb: 'Extracting',
      total: 1,
      cancellable: false,
      indeterminate: true,
    )..start(0, 'site.zip');
    addTearDown(progress.dispose);
    Widget build({required bool reduceMotion}) => MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: MaterialApp(
        home: Scaffold(
          bottomNavigationBar: SftpBatchProgressBar(progress: progress),
        ),
      ),
    );

    await tester.pumpWidget(build(reduceMotion: false));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('extracting'), findsOneWidget);

    await tester.pumpWidget(build(reduceMotion: true));
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Cancel'), findsNothing);
  });

  group('local export names', () {
    test('POSIX names that Windows reads as paths stay one entry', () {
      expect(safeLocalFileName(r'..\escaped.txt'), '.._escaped.txt');
      expect(safeLocalFileName(r'C:\Windows\x.dll'), 'C__Windows_x.dll');
      expect(safeLocalFileName('a/b'), 'a_b');
      expect(safeLocalFileName('..'), 'file');
      expect(safeLocalFileName('notes. '), 'notes');
      expect(safeLocalFileName('CON.txt'), '_CON.txt');
      expect(safeLocalFileName('COM¹'), '_COM¹');
      expect(safeLocalFileName('lpt³.log'), '_lpt³.log');
      expect(safeLocalFileName('COM10'), 'COM10');
      expect(safeLocalFileName('what?.md'), 'what_.md');
    });

    test('export paths stay inside the chosen Windows folder', () {
      const directory = r'C:\Users\me\Downloads';
      for (final name in [
        r'..\escaped.txt',
        r'..\..\Windows\system.ini',
        r'C:\autoexec.bat',
        r'\\server\share\x',
        'a:b',
      ]) {
        final result = freeLocalExportPath(
          directory,
          name,
          context: path.windows,
          exists: (_) => false,
        );
        expect(
          path.windows.isWithin(directory, result),
          isTrue,
          reason: '$name -> $result',
        );
        expect(path.windows.dirname(result), directory, reason: name);
      }
    });

    test('export paths never reuse a taken name', () {
      final taken = {'/out/README.md', '/out/README (2).md'};
      expect(
        freeLocalExportPath(
          '/out',
          'README.md',
          context: path.posix,
          exists: taken.contains,
        ),
        '/out/README (3).md',
      );
    });
  });

  testWidgets('large text puts the selection actions on two rows', (
    tester,
  ) async {
    Widget build(double scale) => MediaQuery(
      data: MediaQueryData(
        size: const Size(390, 844),
        textScaler: TextScaler.linear(scale),
      ),
      child: MaterialApp(
        home: Scaffold(
          bottomNavigationBar: SftpBatchSelectionBar(
            selectedCount: 2,
            onDone: () {},
            onDownload: () {},
            onMove: () {},
            onDelete: () {},
          ),
        ),
      ),
    );
    double rowOf(String label) => tester.getCenter(find.text(label)).dy;

    await tester.pumpWidget(build(1));
    expect(rowOf('Download'), rowOf('Close'));

    await tester.pumpWidget(build(2));
    expect(rowOf('Download'), rowOf('Move'));
    expect(rowOf('Delete'), greaterThan(rowOf('Download')));
    expect(tester.takeException(), isNull);
  });
}
