/// Runs Thomas Dickey's esctest2 conformance suite against [Terminal], as
/// Ghostty 1.4 runs it against its own core.
///
/// esctest2 is GPL-2.0, so it isn't vendored. Fetch the pinned commit and
/// point ESCTEST_DIR at it; without ESCTEST_DIR this test is skipped:
///
///     test/esctest/fetch_esctest.sh ~/esctest2
///     ESCTEST_DIR=~/esctest2 flutter test test/esctest
///
/// Each esctest test gets its own esctest process, which esctest_bridge.py
/// runs on a pty, and a fresh [Terminal] in its own isolate. One test's
/// leftovers can't change the next one's result, and a hang costs only that
/// test its timeout. The results must match expected_failures.txt exactly: a
/// failure not listed there fails this test, and so does a listed test that
/// passes, so the list only shrinks. ESCTEST_UPDATE=1 rewrites the list to
/// match instead.
///
/// Also read: ESCTEST_INCLUDE (a regular expression; only the tests whose
/// names match run, and the list is checked only for those), ESCTEST_JOBS
/// (tests run at once) and ESCTEST_OUT (where each test's esctest log goes,
/// build/esctest by default).
@Timeout(Duration(minutes: 20))
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// The size esctest resets the terminal to before every test.
const _rows = 25;
const _cols = 80;

/// The checksum xterm computes with `checksumExtension: 23`, which esctest
/// expects with `--xterm-checksum` 334 or later.
const _checksumExtension = ChecksumExtension.positive |
    ChecksumExtension.noAttributes |
    ChecksumExtension.noTrim |
    ChecksumExtension.fullCodePoint;

/// How long esctest waits for each byte of a reply before failing the test.
/// A reply this terminal never sends costs a failing test this much once.
const _replyTimeout = '1';

/// How long one test may run before it counts as hung.
const _testTimeout = Duration(seconds: 60);

/// What esctest is told about the terminal, as Ghostty tells it: answer like
/// xterm patch 411, the closest real terminal.
const _esctestArguments = [
  '--expected-terminal=xterm',
  '--xterm-checksum=411',
  '--xterm-reverse-wrap=411',
  '--timeout=$_replyTimeout',
  '--no-print-logs',
];

const _harnessDir = 'test/esctest';
const _expectedFailuresPath = '$_harnessDir/expected_failures.txt';

void main() {
  final esctestDirVariable = Platform.environment['ESCTEST_DIR'] ?? '';
  final esctestDir = esctestDirVariable.isEmpty
      ? ''
      : Directory(esctestDirVariable).absolute.path;

  test(
    'esctest2 results match expected_failures.txt',
    () async {
      await _checkPinnedCommit(esctestDir);
      final include = RegExp(Platform.environment['ESCTEST_INCLUDE'] ?? '');
      final names = (await _listTests(esctestDir)).where(include.hasMatch);
      final logDir = Directory(
        Platform.environment['ESCTEST_OUT'] ?? 'build/esctest',
      );
      if (logDir.existsSync()) logDir.deleteSync(recursive: true);
      logDir.createSync(recursive: true);

      final outcomes = await _runAll(
        names.toList(),
        jobs: int.tryParse(Platform.environment['ESCTEST_JOBS'] ?? '') ??
            math.min(Platform.numberOfProcessors, 4),
        run: (name) => _runTest(esctestDir, name, logDir),
      );

      final expectedFile = File(_expectedFailuresPath);
      final expected = _ExpectedFailures.parse(expectedFile.readAsStringSync())
          .names
          .where(include.hasMatch)
          .toSet();
      final failing = {
        for (final outcome in outcomes)
          if (outcome.status.isFailure) outcome.name,
      };
      final newFailures = outcomes
          .where((o) => o.status.isFailure && !expected.contains(o.name))
          .toList();
      final nowPassing = expected.difference(failing).toList()..sort();

      final summary = _summarize(outcomes, newFailures, nowPassing);
      File('${logDir.path}/summary.txt').writeAsStringSync(summary);
      // ignore: avoid_print
      print(summary);

      if (Platform.environment['ESCTEST_UPDATE'] == '1') {
        expectedFile.writeAsStringSync(
          _ExpectedFailures.parse(expectedFile.readAsStringSync()).update(
            remove: nowPassing.toSet(),
            add: [for (final outcome in newFailures) outcome.name],
          ),
        );
        return;
      }

      expect(
        newFailures.map((o) => o.name),
        isEmpty,
        reason: 'These esctest tests fail but are not in '
            '$_expectedFailuresPath. Fix them, or add them to the list if '
            'the failure is understood. Logs: ${logDir.path}',
      );
      expect(
        nowPassing,
        isEmpty,
        reason: 'These esctest tests are listed in $_expectedFailuresPath '
            'but no longer fail. Remove them from the list.',
      );
    },
    skip: esctestDir.isEmpty
        ? 'ESCTEST_DIR is not set. Run test/esctest/fetch_esctest.sh DIR and '
            'set ESCTEST_DIR=DIR to run the esctest2 conformance suite.'
        : false,
  );
}

/// Fails unless [esctestDir] holds the commit fetch_esctest.sh pins, which is
/// the one expected_failures.txt was made with.
Future<void> _checkPinnedCommit(String esctestDir) async {
  final script = File('$_harnessDir/fetch_esctest.sh').readAsStringSync();
  final pinned = RegExp(r'^ESCTEST2_COMMIT=([0-9a-f]{40})$', multiLine: true)
      .firstMatch(script)!
      .group(1);
  final head =
      await Process.run('git', ['-C', esctestDir, 'rev-parse', 'HEAD']);
  expect(
    (head.stdout as String).trim(),
    pinned,
    reason: '$esctestDir must be the esctest2 commit fetch_esctest.sh pins. '
        'Run test/esctest/fetch_esctest.sh $esctestDir.',
  );
}

Future<List<String>> _listTests(String esctestDir) async {
  final result = await Process.run(
    'python3',
    ['$_harnessDir/esctest_bridge.py', 'list', esctestDir],
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return const LineSplitter().convert(result.stdout as String);
}

/// Runs [run] for every name, [jobs] at a time, and returns the outcomes in
/// the order of [names].
Future<List<_Outcome>> _runAll(
  List<String> names, {
  required int jobs,
  required Future<_Outcome> Function(String name) run,
}) async {
  final queue = Queue.of(names);
  final outcomes = <String, _Outcome>{};
  Future<void> worker() async {
    while (queue.isNotEmpty) {
      final name = queue.removeFirst();
      outcomes[name] = await run(name);
    }
  }

  await Future.wait([for (var i = 0; i < math.max(jobs, 1); i++) worker()]);
  return [for (final name in names) outcomes[name]!];
}

/// Runs one esctest test against a fresh terminal and reads its result from
/// esctest's log.
Future<_Outcome> _runTest(
    String esctestDir, String name, Directory logDir) async {
  // esctest runs in its own directory.
  final log = File('${logDir.absolute.path}/$name.log');
  final fromTerminal = ReceivePort();
  final isolate = await Isolate.spawn(
    _terminalIsolate,
    fromTerminal.sendPort,
    debugName: 'esctest $name',
  );

  final toTerminal = Completer<SendPort>();
  final terminalErrors = <String>[];
  Process? process;
  var stdinOpen = true;
  void send(List<int> frame) {
    if (stdinOpen) process?.stdin.add(frame);
  }

  fromTerminal.listen((message) {
    switch (message) {
      case final SendPort port:
        toTerminal.complete(port);
      case final Uint8List reply:
        send(_dataFrame(reply));
      case _Resize(:final rows, :final cols):
        send(_resizeFrame(rows, cols));
      case final String error:
        terminalErrors.add(error);
    }
  });
  final terminal = await toTerminal.future;

  process = await Process.start('python3', [
    '$_harnessDir/esctest_bridge.py',
    'run',
    esctestDir,
    '$_rows',
    '$_cols',
    ..._esctestArguments,
    '--logfile=${log.path}',
    '--include=^${RegExp.escape(name)}\$',
  ]);
  // The bridge exits once esctest does, and replies still in flight then
  // have nowhere to go.
  process.stdin.done.ignore();
  process.stdout.listen(
    (chunk) => terminal.send(
      chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
    ),
  );
  final stderr = process.stderr.transform(utf8.decoder).join();

  var hung = false;
  final exitCode = await process.exitCode.timeout(
    _testTimeout,
    onTimeout: () {
      hung = true;
      process!.kill();
      return process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          process!.kill(ProcessSignal.sigkill);
          return process.exitCode;
        },
      );
    },
  );
  stdinOpen = false;
  await process.stdin.close().catchError((_) {});
  isolate.kill(priority: Isolate.immediate);
  fromTerminal.close();

  final text = log.existsSync() ? log.readAsStringSync() : '';
  final _Status status;
  if (hung) {
    status = _Status.hung;
  } else if (terminalErrors.isNotEmpty) {
    status = _Status.terminalError;
  } else if (text.contains('*** TEST $name FAILED')) {
    status = _Status.failed;
  } else if (RegExp(r'^Passed\.$', multiLine: true).hasMatch(text)) {
    status = _Status.passed;
  } else if (text.contains('\nFails as expected: ')) {
    status = _Status.knownXtermBug;
  } else if (text.contains('\nSkipped because terminal lacks')) {
    status = _Status.skipped;
  } else {
    status = _Status.error;
  }
  if (terminalErrors.isNotEmpty || status == _Status.error || hung) {
    log.writeAsStringSync(
      '\n--- harness ---\nbridge exit code: $exitCode\n'
      '${hung ? 'timed out after $_testTimeout\n' : ''}'
      '${await stderr}${terminalErrors.join('\n')}',
      mode: FileMode.append,
    );
  }
  return _Outcome(name, status, log.path);
}

/// Hosts the terminal under test. Bytes from esctest arrive as [Uint8List]s;
/// the terminal's replies go back as [Uint8List]s and its resizes as
/// [_Resize]s. An exception from the terminal is sent back as a [String].
void _terminalIsolate(SendPort toHarness) {
  final fromHarness = ReceivePort();
  toHarness.send(fromHarness.sendPort);

  final terminal = Terminal(maxLines: 1000)
    ..rectangularAreaChecksumEnabled = true
    ..defaultChecksumExtension = _checksumExtension;
  terminal.resize(_cols, _rows);
  terminal.onOutput = (data) => toHarness.send(
        Uint8List.fromList(utf8.encode(_oneBasedCursorReports(data))),
      );
  terminal.onResize =
      (cols, rows, _, __) => toHarness.send(_Resize(rows: rows, cols: cols));

  // The app decodes shell output the same way (ssh_session_runtime.dart).
  final input = const Utf8Decoder(allowMalformed: true)
      .startChunkedConversion(_TerminalSink(terminal));
  fromHarness.listen((message) {
    try {
      input.add(message as Uint8List);
    } catch (error, stack) {
      toHarness.send('terminal threw: $error\n$stack');
    }
  });
}

/// The app sends this terminal's replies through
/// `normalizeTerminalOutputForRemoteShell` (lib/domain/services/
/// ssh_service.dart), which turns the zero-based cursor position reports the
/// terminal emits into the one-based ones a program expects. Do the same, so
/// esctest sees what a program on the other end of an SSH session sees.
String _oneBasedCursorReports(String data) => data.replaceAllMapped(
      RegExp(r'\x1b\[([0-9]+);([0-9]+)R'),
      (match) => '\x1b[${int.parse(match[1]!) + 1};'
          '${int.parse(match[2]!) + 1}R',
    );

class _TerminalSink implements Sink<String> {
  _TerminalSink(this.terminal);

  final Terminal terminal;

  @override
  void add(String data) => terminal.write(data);

  @override
  void close() {}
}

class _Resize {
  const _Resize({required this.rows, required this.cols});

  final int rows;
  final int cols;
}

/// The frames esctest_bridge.py reads from its stdin.
List<int> _dataFrame(Uint8List bytes) => (BytesBuilder(copy: false)
      ..addByte(0x44) // D
      ..add((ByteData(4)..setUint32(0, bytes.length)).buffer.asUint8List())
      ..add(bytes))
    .takeBytes();

List<int> _resizeFrame(int rows, int cols) => (ByteData(5)
      ..setUint8(0, 0x52) // R
      ..setUint16(1, rows)
      ..setUint16(3, cols))
    .buffer
    .asUint8List();

enum _Status {
  passed('passed'),

  /// The test is marked as a known xterm bug, and fails here too.
  knownXtermBug('failed as xterm does'),

  /// The test needs a higher VT level than esctest was told to test.
  skipped('skipped'),
  failed('FAILED', isFailure: true),
  hung('HUNG', isFailure: true),
  terminalError('TERMINAL THREW', isFailure: true),

  /// esctest finished without saying how the test went.
  error('NO RESULT', isFailure: true);

  const _Status(this.label, {this.isFailure = false});

  final String label;
  final bool isFailure;
}

class _Outcome {
  const _Outcome(this.name, this.status, this.logPath);

  final String name;
  final _Status status;
  final String logPath;
}

String _summarize(
  List<_Outcome> outcomes,
  List<_Outcome> newFailures,
  List<String> nowPassing,
) {
  final counts = <_Status, int>{};
  for (final outcome in outcomes) {
    counts[outcome.status] = (counts[outcome.status] ?? 0) + 1;
  }
  final out = StringBuffer('esctest2: ${outcomes.length} tests: ')
    ..writeAll([
      for (final status in _Status.values)
        if (counts[status] case final count?) '$count ${status.label}',
    ], ', ')
    ..writeln();
  if (newFailures.isNotEmpty) {
    out.writeln('\nNew failures (not in $_expectedFailuresPath):');
    for (final outcome in newFailures) {
      out
        ..writeln('  ${outcome.name}: ${outcome.status.label}')
        ..writeln(_indent(_failureExcerpt(outcome)));
    }
  }
  if (nowPassing.isNotEmpty) {
    out.writeln('\nListed in $_expectedFailuresPath but no longer failing:');
    for (final name in nowPassing) {
      out.writeln('  $name');
    }
  }
  return out.toString();
}

/// The end of the traceback esctest logged for a failed test, which names
/// the assertion that failed, or what the harness logged.
String _failureExcerpt(_Outcome outcome) {
  final file = File(outcome.logPath);
  if (!file.existsSync()) return '(no log)';
  final lines = const LineSplitter()
      .convert(file.readAsStringSync())
      .where((line) => line.trim().isNotEmpty)
      .takeWhile((line) => !line.startsWith('*** ') || line.contains('FAILED:'))
      .toList();
  return lines.skip(math.max(0, lines.length - 6)).join('\n');
}

String _indent(String text) =>
    const LineSplitter().convert(text).map((line) => '      $line').join('\n');

/// expected_failures.txt: one test name per line. `#` starts a comment, which
/// may follow a name to say why it fails.
class _ExpectedFailures {
  _ExpectedFailures._(this._lines);

  factory _ExpectedFailures.parse(String text) =>
      _ExpectedFailures._(const LineSplitter().convert(text));

  final List<String> _lines;

  static String _nameOf(String line) => line.split('#').first.trim();

  Iterable<String> get names =>
      _lines.map(_nameOf).where((name) => name.isNotEmpty);

  /// The file without the [remove]d tests and with the [add]ed ones at the
  /// end, for someone to sort into the right group.
  String update({required Set<String> remove, required List<String> add}) {
    final lines = [
      ..._lines.where((line) => !remove.contains(_nameOf(line))),
      if (add.isNotEmpty) ...['', '# Not yet sorted into a group above.'],
      ...add,
    ];
    return '${lines.join('\n')}\n';
  }
}
