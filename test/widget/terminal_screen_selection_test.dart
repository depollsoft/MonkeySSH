import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart' show SftpError;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/remote_file_service.dart';
import 'package:monkeyssh/presentation/models/app_platform_file.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';
import 'package:xterm/xterm.dart';

class _FakeImagePickerPlatform extends ImagePickerPlatform {}

final class _StreamOnlyFile extends PlatformFile {
  _StreamOnlyFile(this.stream);

  final Stream<Uint8List> stream;

  @override
  Future<int> length() async => 2;

  @override
  XFile get xFile => throw StateError('Must stream');

  @override
  String get name => 'stream.txt';

  @override
  Uri get uri => Uri.parse('memory:stream.txt');

  @override
  Future<Uint8List> readAsBytes() => throw StateError('Must stream');

  @override
  Stream<Uint8List> readAsByteStream() => stream;
}

void main() {
  test('picked-file failures preserve category and safe messages', () {
    for (final (error, category) in <(Object, String)>[
      (PlatformException(code: 'denied'), 'picker_failed'),
      (const FileSystemException('private path'), 'picked_file_failed'),
      (SftpError('private remote path'), 'picked_remote_upload_failed'),
      (StateError('private details'), 'picked_upload_failed'),
    ]) {
      final failure = pickedFileFailure(error, 'File picker');
      expect(failure.category, category);
      expect(
        failure.message,
        error is SftpError
            ? 'Remote upload failed. Check permissions and try again.'
            : 'File picker failed. Try again.',
      );
    }
  });

  group('tmux window snapshot matching', () {
    const first = TmuxWindow(
      index: 0,
      id: '@1',
      name: 'first',
      isActive: true,
      panePid: 10,
    );
    const second = TmuxWindow(
      index: 1,
      id: '@2',
      name: 'second',
      isActive: false,
    );
    test('reordered snapshots keep identity', () {
      expect(
        shouldRefreshTmuxThemeAfterWindowChange(
          [first, second],
          [second, first],
        ),
        isFalse,
      );
    });
    test('missing IDs match by index and present IDs do not fall back', () {
      const noId = TmuxWindow(index: 0, name: 'first', isActive: true);
      expect(shouldRefreshTmuxThemeAfterWindowChange([noId], [noId]), isFalse);
      expect(shouldRefreshTmuxThemeAfterWindowChange([noId], [first]), isTrue);
      expect(shouldRefreshTmuxThemeAfterWindowChange([first], [noId]), isTrue);
    });
    test('pane identity changes trigger refresh', () {
      expect(
        shouldRefreshTmuxThemeAfterWindowChange(
          [first],
          [first.copyWith(panePid: 11)],
        ),
        isTrue,
      );
    });
  });

  group('trimTerminalSelectionText', () {
    test('trims trailing padding on each line only', () {
      expect(
        trimTerminalSelectionText('  ls -la   \nnext line    \n    '),
        '  ls -la\nnext line\n',
      );
    });

    test('preserves interior spaces', () {
      expect(trimTerminalLinePadding('a  b   c   '), 'a  b   c');
    });
  });

  group('trimTerminalLinkCandidate', () {
    test('removes trailing punctuation around terminal links', () {
      expect(
        trimTerminalLinkCandidate('https://example.com/docs).'),
        'https://example.com/docs',
      );
    });

    test('keeps balanced parentheses inside links', () {
      expect(
        trimTerminalLinkCandidate('https://example.com/path(test)'),
        'https://example.com/path(test)',
      );
    });

    test('keeps balanced square and curly brackets at the end of links', () {
      expect(
        trimTerminalLinkCandidate('https://example.com/path[tmux]'),
        'https://example.com/path[tmux]',
      );
      expect(
        trimTerminalLinkCandidate('https://example.com/path{tmux}'),
        'https://example.com/path{tmux}',
      );
    });

    test('removes unmatched trailing square and curly brackets', () {
      expect(
        trimTerminalLinkCandidate('https://example.com/path[tmux]]'),
        'https://example.com/path[tmux]',
      );
      expect(
        trimTerminalLinkCandidate('https://example.com/path{tmux}}'),
        'https://example.com/path{tmux}',
      );
    });
  });

  group('trimTerminalFilePathCandidate', () {
    test('drops stack-trace line and column suffixes', () {
      expect(
        trimTerminalFilePathCandidate('/var/log/app.log:42:7'),
        '/var/log/app.log',
      );
    });

    test('drops trailing punctuation around file paths', () {
      expect(
        trimTerminalFilePathCandidate('/var/log/app.log).'),
        '/var/log/app.log',
      );
    });

    test('drops stack-trace suffixes from relative paths too', () {
      expect(
        trimTerminalFilePathCandidate('../lib/main.dart:42:7'),
        '../lib/main.dart',
      );
    });

    test('drops view line-range suffixes from file paths', () {
      expect(
        trimTerminalFilePathCandidate(
          '~/Code/flutty.worktrees/fix-local-path-link-separators/test/widget/terminal_screen_selection_test.dartL360:430',
        ),
        '~/Code/flutty.worktrees/fix-local-path-link-separators/test/widget/terminal_screen_selection_test.dart',
      );
    });

    test('drops trailing shell operators from file paths', () {
      expect(
        trimTerminalFilePathCandidate(
          '/Users/depoll/Code/flutty.worktrees/fix-main-ci&&',
        ),
        '/Users/depoll/Code/flutty.worktrees/fix-main-ci',
      );
      expect(
        trimTerminalFilePathCandidate('/var/log/app.log||'),
        '/var/log/app.log',
      );
      expect(trimTerminalFilePathCandidate('/tmp/output;'), '/tmp/output');
    });

    test('drops wrapped result-count suffixes after unmatched parentheses', () {
      expect(
        trimTerminalFilePathCandidate(
          '~/Code/flutty.worktrees/fix-swipe-keyboard-typing/test/widget/terminal_text_input_handler_test.dart)6',
        ),
        '~/Code/flutty.worktrees/fix-swipe-keyboard-typing/test/widget/terminal_text_input_handler_test.dart',
      );
    });

    test('drops wrapped result-count suffixes from dotless explicit paths', () {
      expect(trimTerminalFilePathCandidate('/etc/hosts)6'), '/etc/hosts');
      expect(trimTerminalFilePathCandidate('~/README)6'), '~/README');
    });

    test('normalizes Windows drive separators', () {
      expect(
        trimTerminalFilePathCandidate(r'C:\Users\demo\notes.txt:42'),
        'C:/Users/demo/notes.txt',
      );
    });
  });

  group('resolveTerminalFilePathVerificationCandidates', () {
    test(
      'offers multiple known-extension parses for ambiguous explicit paths',
      () {
        final candidates = resolveTerminalFilePathVerificationCandidates(
          '/srv/app/archive.tar.gzbackup',
        );

        expect(
          candidates,
          containsAllInOrder([
            '/srv/app/archive.tar.gzbackup',
            '/srv/app/archive.tar.gz',
            '/srv/app/archive.tar',
          ]),
        );
      },
    );

    test('leaves ordinary explicit paths unchanged', () {
      expect(
        resolveTerminalFilePathVerificationCandidates('/srv/app/lib/main.dart'),
        ['/srv/app/lib/main.dart'],
      );
      expect(
        resolveTerminalFilePathVerificationCandidates(
          r'C:\Users\demo\notes.txt',
        ),
        ['C:/Users/demo/notes.txt'],
      );
    });

    test('keeps balanced trailing brackets that are part of the filename', () {
      expect(
        resolveTerminalFilePathVerificationCandidates(
          '/srv/app/archive(test).dart',
        ),
        ['/srv/app/archive(test).dart'],
      );
    });

    test(
      'normalizes unmatched trailing brackets before candidate generation',
      () {
        expect(
          resolveTerminalFilePathVerificationCandidates(
            '/srv/app/archive.dart)',
          ),
          ['/srv/app/archive.dart'],
        );
      },
    );
  });

  group('resolveTerminalFilePathExistenceCandidates', () {
    test('walks back directory prefixes for an absolute path', () {
      expect(
        resolveTerminalFilePathExistenceCandidates('/srv/app/lib/main.dart'),
        ['/srv/app/lib/main.dart', '/srv/app/lib', '/srv/app', '/srv'],
      );
    });

    test('walks back directory prefixes for a Windows drive path', () {
      expect(
        resolveTerminalFilePathExistenceCandidates(r'C:\Users\demo\notes.txt'),
        ['C:/Users/demo/notes.txt', 'C:/Users/demo', 'C:/Users'],
      );
    });

    test('walks back directory prefixes for a relative path', () {
      expect(
        resolveTerminalFilePathExistenceCandidates(
          'lib/presentation/screens/terminal_screen.dart',
        ),
        [
          'lib/presentation/screens/terminal_screen.dart',
          'lib/presentation/screens',
          'lib/presentation',
        ],
      );
    });

    test('stops directory walk-back before the bare home directory', () {
      expect(
        resolveTerminalFilePathExistenceCandidates('~/Code/app/main.dart'),
        ['~/Code/app/main.dart', '~/Code/app', '~/Code'],
      );
    });

    test('orders ambiguous parses and prefixes longest first', () {
      expect(
        resolveTerminalFilePathExistenceCandidates(
          '/srv/app/archive.tar.gzbackup',
        ),
        [
          '/srv/app/archive.tar.gzbackup',
          '/srv/app/archive.tar.gz',
          '/srv/app/archive.tar',
          '/srv/app',
          '/srv',
        ],
      );
    });
  });

  group('hasAmbiguousTerminalFilePathParsing', () {
    test(
      'returns false for ordinary explicit paths with a final known extension',
      () {
        expect(
          hasAmbiguousTerminalFilePathParsing('/srv/app/lib/main.dart'),
          isFalse,
        );
        expect(hasAmbiguousTerminalFilePathParsing('~/.ssh/config'), isFalse);
        expect(hasAmbiguousTerminalFilePathParsing('/etc/hosts'), isFalse);
      },
    );

    test(
      'returns true when a known extension is followed by extra suffix text',
      () {
        expect(
          hasAmbiguousTerminalFilePathParsing('/srv/app/archive.tar.gzbackup'),
          isTrue,
        );
      },
    );
  });

  group('resolvePickedTerminalUploadFileName', () {
    test('prefers the picker-provided name when present', () {
      final file = AppPlatformFile(name: 'Screenshot.png', size: 0);

      expect(resolvePickedTerminalUploadFileName(file), 'Screenshot.png');
    });

    test('falls back to the local path basename when needed', () {
      final file = AppPlatformFile(
        name: '   ',
        path: '/tmp/copilot/screenshot.png',
        size: 0,
      );

      expect(resolvePickedTerminalUploadFileName(file), 'screenshot.png');
    });

    test('uses a stable generated fallback when no name is available', () {
      final file = AppPlatformFile(name: '', size: 0);

      expect(
        resolvePickedTerminalUploadFileName(file, index: 2),
        'selected-file-3',
      );
    });
  });

  group('resolvePickedTerminalUploadReadStream', () {
    test('streams a pathless file without reading all bytes', () async {
      final file = _StreamOnlyFile(Stream.value(Uint8List.fromList([1, 2])));
      expect(file.path, isNull);
      expect(await resolvePickedTerminalUploadReadStream(file).toList(), [
        [1, 2],
      ]);
    });

    test('propagates a pathless stream error', () async {
      final file = _StreamOnlyFile(
        Stream.error(const FileSystemException('read')),
      );
      await expectLater(
        resolvePickedTerminalUploadReadStream(file).drain<void>(),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('opens a stream from the picked file path when needed', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'terminal-upload-test',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));

      final fileOnDisk = File('${tempDirectory.path}/notes.txt');
      await fileOnDisk.writeAsString('copilot');

      final file = AppPlatformFile(
        name: 'notes.txt',
        path: fileOnDisk.path,
        size: 7,
      );
      final stream = resolvePickedTerminalUploadReadStream(file);

      expect(stream, isNotNull);
      expect(
        await stream.transform(const SystemEncoding().decoder).join(),
        'copilot',
      );
    });
  });

  group('resolveTerminalUploadPickerRequest', () {
    test('allows selecting multiple images or videos for terminal uploads', () {
      final request = resolveTerminalUploadPickerRequest(media: true);

      expect(request.dialogTitle, 'Select images or videos to upload');
      expect(request.pickerType, FileType.media);
      expect(request.itemLabelSingular, 'image or video');
      expect(request.itemLabelPlural, 'images or videos');
      expect(request.allowMultiple, isTrue);
      expect(request.failureContext, 'Media picker upload');
    });

    test('allows selecting multiple files for terminal uploads', () {
      final request = resolveTerminalUploadPickerRequest(media: false);

      expect(request.dialogTitle, 'Select files to upload');
      expect(request.pickerType, FileType.any);
      expect(request.itemLabelSingular, 'file');
      expect(request.itemLabelPlural, 'files');
      expect(request.allowMultiple, isTrue);
      expect(request.failureContext, 'File picker upload');
    });
  });

  group('shouldUsePhotoLibraryPickerForTerminalMedia', () {
    test('uses the photo library picker on native mobile platforms', () {
      expect(
        shouldUsePhotoLibraryPickerForTerminalMedia(
          platform: TargetPlatform.android,
          isWeb: false,
        ),
        isTrue,
      );
      expect(
        shouldUsePhotoLibraryPickerForTerminalMedia(
          platform: TargetPlatform.iOS,
          isWeb: false,
        ),
        isTrue,
      );
    });

    test('keeps the file picker on web and desktop platforms', () {
      expect(
        shouldUsePhotoLibraryPickerForTerminalMedia(
          platform: TargetPlatform.android,
          isWeb: true,
        ),
        isFalse,
      );
      expect(
        shouldUsePhotoLibraryPickerForTerminalMedia(
          platform: TargetPlatform.macOS,
          isWeb: false,
        ),
        isFalse,
      );
      expect(
        shouldUsePhotoLibraryPickerForTerminalMedia(
          platform: TargetPlatform.windows,
          isWeb: false,
        ),
        isFalse,
      );
    });
  });

  group('resolveTmuxBarActiveWindowBracketedPasteMode', () {
    test('reads bracketed paste mode from the active mux window', () {
      final windows = [
        const TmuxWindow(
          index: 0,
          name: 'shell',
          isActive: false,
          terminalBracketedPasteMode: true,
        ),
        const TmuxWindow(
          index: 1,
          name: 'composer',
          isActive: true,
          terminalBracketedPasteMode: true,
        ),
      ];

      expect(resolveTmuxBarActiveWindowBracketedPasteMode(windows), isTrue);
    });

    test('leaves unknown mux state unknown', () {
      expect(
        resolveTmuxBarActiveWindowBracketedPasteMode(const [
          TmuxWindow(index: 0, name: 'shell', isActive: true),
        ]),
        isNull,
      );
    });
  });

  group('inheritTerminalBracketedPasteModeFromMuxWindow', () {
    test('applies known active mux window bracketed paste mode locally', () {
      final terminal = Terminal();

      expect(terminal.bracketedPasteMode, isFalse);
      expect(
        inheritTerminalBracketedPasteModeFromMuxWindow(
          terminal: terminal,
          activeWindowBracketedPasteMode: true,
        ),
        isTrue,
      );
      expect(terminal.bracketedPasteMode, isTrue);
      expect(
        inheritTerminalBracketedPasteModeFromMuxWindow(
          terminal: terminal,
          activeWindowBracketedPasteMode: false,
        ),
        isTrue,
      );
      expect(terminal.bracketedPasteMode, isFalse);
    });

    test('leaves local mode alone when mux window mode is unknown', () {
      final terminal = Terminal()..setBracketedPasteMode(true);

      expect(
        inheritTerminalBracketedPasteModeFromMuxWindow(
          terminal: terminal,
          activeWindowBracketedPasteMode: null,
        ),
        isFalse,
      );
      expect(terminal.bracketedPasteMode, isTrue);
    });

    test('inherited local mode frames uploaded path segments', () {
      final terminal = Terminal();

      inheritTerminalBracketedPasteModeFromMuxWindow(
        terminal: terminal,
        activeWindowBracketedPasteMode: true,
      );

      expect(
        buildTerminalAttachmentPasteSegments(const [
          '/home/u/.cache/monkeyssh/uploads/a.png',
        ], bracketedPasteMode: terminal.bracketedPasteMode),
        const ['\x1b[200~/home/u/.cache/monkeyssh/uploads/a.png\x1b[201~ '],
      );
    });
  });

  group('shouldInjectTerminalAttachmentViaMonkeyMuxControl', () {
    test('uses framed control delivery only for active MonkeyMux pastes', () {
      expect(
        shouldInjectTerminalAttachmentViaMonkeyMuxControl(
          bracketedPasteMode: true,
          isMuxActive: true,
          muxBackend: RemoteMuxBackend.monkeyMux,
          hasSession: true,
          hasSessionName: true,
          supportsBracketedPasteControlInput: true,
        ),
        isTrue,
      );
      expect(
        shouldInjectTerminalAttachmentViaMonkeyMuxControl(
          bracketedPasteMode: true,
          isMuxActive: true,
          muxBackend: RemoteMuxBackend.monkeyMux,
          hasSession: true,
          hasSessionName: true,
          supportsBracketedPasteControlInput: false,
        ),
        isFalse,
      );
      expect(
        shouldInjectTerminalAttachmentViaMonkeyMuxControl(
          bracketedPasteMode: false,
          isMuxActive: true,
          muxBackend: RemoteMuxBackend.monkeyMux,
          hasSession: true,
          hasSessionName: true,
          supportsBracketedPasteControlInput: true,
        ),
        isFalse,
      );
      expect(
        shouldInjectTerminalAttachmentViaMonkeyMuxControl(
          bracketedPasteMode: true,
          isMuxActive: true,
          muxBackend: RemoteMuxBackend.tmux,
          hasSession: true,
          hasSessionName: true,
          supportsBracketedPasteControlInput: true,
        ),
        isFalse,
      );
      expect(
        shouldInjectTerminalAttachmentViaMonkeyMuxControl(
          bracketedPasteMode: true,
          isMuxActive: true,
          muxBackend: RemoteMuxBackend.monkeyMux,
          hasSession: false,
          hasSessionName: false,
          supportsBracketedPasteControlInput: true,
        ),
        isFalse,
      );
    });
  });

  group('deliverTerminalAttachmentPasteSegments', () {
    test('injects once without writing the raw terminal fallback', () async {
      var inputGeneration = 0;
      final injected = <String>[];
      final terminalOutput = <String>[];

      final result = await deliverTerminalAttachmentPasteSegments(
        segments: const ['first'],
        injectViaMonkeyMuxControl:
            shouldInjectTerminalAttachmentViaMonkeyMuxControl(
              bracketedPasteMode: true,
              isMuxActive: true,
              muxBackend: RemoteMuxBackend.monkeyMux,
              hasSession: true,
              hasSessionName: true,
              supportsBracketedPasteControlInput: true,
            ),
        injectInput: (segment) async {
          injected.add(segment);
          return true;
        },
        writeTerminalOutput: terminalOutput.add,
        initialInputGeneration: inputGeneration,
        currentInputGeneration: () => inputGeneration,
        recordDeliveredInput: () => inputGeneration++,
        blockedReason: () => null,
        waitBetweenSegments: () async {},
      );

      expect(injected, const ['first']);
      expect(terminalOutput, isEmpty);
      expect(result.deliveredSegmentCount, 1);
      expect(result.stopReason, isNull);
    });

    test('falls back when control declines before dispatch', () async {
      var inputGeneration = 0;
      final terminalOutput = <String>[];

      final result = await deliverTerminalAttachmentPasteSegments(
        segments: const ['first'],
        injectViaMonkeyMuxControl: true,
        injectInput: (_) async => false,
        writeTerminalOutput: terminalOutput.add,
        initialInputGeneration: inputGeneration,
        currentInputGeneration: () => inputGeneration,
        recordDeliveredInput: () => inputGeneration++,
        blockedReason: () => null,
        waitBetweenSegments: () async {},
      );

      expect(terminalOutput, const ['first']);
      expect(result.deliveredSegmentCount, 1);
      expect(result.stopReason, isNull);
    });

    test('does not retry an indeterminate control failure', () async {
      var inputGeneration = 0;
      final terminalOutput = <String>[];

      await expectLater(
        deliverTerminalAttachmentPasteSegments(
          segments: const ['first'],
          injectViaMonkeyMuxControl: true,
          injectInput: (_) async => throw StateError('acknowledgement lost'),
          writeTerminalOutput: terminalOutput.add,
          initialInputGeneration: inputGeneration,
          currentInputGeneration: () => inputGeneration,
          recordDeliveredInput: () => inputGeneration++,
          blockedReason: () => null,
          waitBetweenSegments: () async {},
        ),
        throwsA(isA<StateError>()),
      );

      expect(terminalOutput, isEmpty);
      expect(inputGeneration, 0);
    });

    test('rechecks input before a declined-control fallback', () async {
      var inputGeneration = 0;
      final terminalOutput = <String>[];

      final result = await deliverTerminalAttachmentPasteSegments(
        segments: const ['first'],
        injectViaMonkeyMuxControl: true,
        injectInput: (_) async {
          inputGeneration++;
          return false;
        },
        writeTerminalOutput: terminalOutput.add,
        initialInputGeneration: inputGeneration,
        currentInputGeneration: () => inputGeneration,
        recordDeliveredInput: () => inputGeneration++,
        blockedReason: () => null,
        waitBetweenSegments: () async {},
      );

      expect(terminalOutput, isEmpty);
      expect(result.deliveredSegmentCount, 0);
      expect(
        result.stopReason,
        TerminalAttachmentPasteStopReason.interveningInput,
      );
    });

    test('stops after input arrives during the first control await', () async {
      var inputGeneration = 0;
      var waits = 0;
      final injected = <String>[];
      final terminalOutput = <String>[];

      final result = await deliverTerminalAttachmentPasteSegments(
        segments: const ['first', 'second'],
        injectViaMonkeyMuxControl: true,
        injectInput: (segment) async {
          injected.add(segment);
          inputGeneration++;
          return true;
        },
        writeTerminalOutput: terminalOutput.add,
        initialInputGeneration: inputGeneration,
        currentInputGeneration: () => inputGeneration,
        recordDeliveredInput: () => inputGeneration++,
        blockedReason: () => null,
        waitBetweenSegments: () async => waits++,
      );

      expect(injected, const ['first']);
      expect(terminalOutput, isEmpty);
      expect(waits, 0);
      expect(result.deliveredSegmentCount, 1);
      expect(
        result.stopReason,
        TerminalAttachmentPasteStopReason.interveningInput,
      );
    });
  });

  group('refreshTerminalBracketedPasteModeFromMuxWindows', () {
    test('refreshes a stale disabled mode before terminal paste', () async {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);
      final windows = Completer<Iterable<TmuxWindow>>();
      final refresh = refreshTerminalBracketedPasteModeFromMuxWindows(
        terminal: terminal,
        loadWindows: () => windows.future,
      );

      expect(terminal.bracketedPasteMode, isFalse);
      windows.complete(const [
        TmuxWindow(
          index: 0,
          name: 'copilot',
          isActive: true,
          terminalBracketedPasteMode: true,
        ),
      ]);

      expect(await refresh, (
        bracketedPasteMode: true,
        bracketedPasteModeKnown: true,
        activeWindowKey: '#0',
      ));
      expect(terminal.bracketedPasteMode, isTrue);

      pasteTerminalTextWithBracketedPasteMode(
        terminal: terminal,
        text: 'clipboard text',
        bracketedPasteMode: true,
      );

      expect(output, ['\x1b[200~clipboard text\x1b[201~']);
    });

    test('applies known disabled mode and preserves unknown mode', () async {
      final terminal = Terminal()..setBracketedPasteMode(true);

      expect(
        await refreshTerminalBracketedPasteModeFromMuxWindows(
          terminal: terminal,
          loadWindows: () async => const [
            TmuxWindow(
              index: 0,
              name: 'shell',
              isActive: true,
              terminalBracketedPasteMode: false,
            ),
          ],
        ),
        (
          bracketedPasteMode: false,
          bracketedPasteModeKnown: true,
          activeWindowKey: '#0',
        ),
      );

      terminal.setBracketedPasteMode(true);
      expect(
        await refreshTerminalBracketedPasteModeFromMuxWindows(
          terminal: terminal,
          loadWindows: () async => const [
            TmuxWindow(index: 0, name: 'legacy', isActive: true),
          ],
        ),
        (
          bracketedPasteMode: true,
          bracketedPasteModeKnown: false,
          activeWindowKey: '#0',
        ),
      );
    });

    test('returns the stable id for the refreshed active window', () async {
      final terminal = Terminal();

      expect(
        await refreshTerminalBracketedPasteModeFromMuxWindows(
          terminal: terminal,
          loadWindows: () async => const [
            TmuxWindow(
              index: 4,
              id: '@9',
              name: 'copilot',
              isActive: true,
              terminalBracketedPasteMode: true,
            ),
          ],
        ),
        (
          bracketedPasteMode: true,
          bracketedPasteModeKnown: true,
          activeWindowKey: '@9',
        ),
      );
    });

    test('can conservatively paste without mutating cached terminal mode', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add)
        ..setBracketedPasteMode(true);

      pasteTerminalTextWithBracketedPasteMode(
        terminal: terminal,
        text: 'clipboard text',
        bracketedPasteMode: false,
      );

      expect(output, ['clipboard text']);
      expect(terminal.bracketedPasteMode, isTrue);
    });
  });

  group('terminalAttachmentPasteTargetsCurrentMuxWindow', () {
    test('rejects an optimistic window switch before its snapshot arrives', () {
      expect(
        terminalAttachmentPasteTargetsCurrentMuxWindow(
          hasPendingWindowSelection: true,
          pasteWindowKey: '@1',
          currentWindowKey: '@1',
        ),
        isFalse,
      );
    });

    test('accepts the same settled window or an unavailable snapshot', () {
      expect(
        terminalAttachmentPasteTargetsCurrentMuxWindow(
          hasPendingWindowSelection: false,
          pasteWindowKey: '@1',
          currentWindowKey: '@1',
        ),
        isTrue,
      );
      expect(
        terminalAttachmentPasteTargetsCurrentMuxWindow(
          hasPendingWindowSelection: false,
          pasteWindowKey: '@1',
          currentWindowKey: null,
        ),
        isTrue,
      );
    });
  });

  group('shouldRetryTerminalPasteModeSettle', () {
    test('does not retry a failed refresh', () {
      expect(
        shouldRetryTerminalPasteModeSettle(
          refreshAttempted: true,
          refreshSucceeded: false,
          hasActiveWindow: true,
          modeReliable: false,
          targetsCurrentWindow: false,
        ),
        isFalse,
      );
    });

    test('only retries successful snapshots for window settling', () {
      expect(
        shouldRetryTerminalPasteModeSettle(
          refreshAttempted: true,
          refreshSucceeded: true,
          hasActiveWindow: true,
          modeReliable: false,
          targetsCurrentWindow: true,
        ),
        isFalse,
      );
      expect(
        shouldRetryTerminalPasteModeSettle(
          refreshAttempted: true,
          refreshSucceeded: true,
          hasActiveWindow: false,
          modeReliable: false,
          targetsCurrentWindow: true,
        ),
        isTrue,
      );
      expect(
        shouldRetryTerminalPasteModeSettle(
          refreshAttempted: true,
          refreshSucceeded: true,
          hasActiveWindow: true,
          modeReliable: true,
          targetsCurrentWindow: false,
        ),
        isTrue,
      );
      expect(
        shouldRetryTerminalPasteModeSettle(
          refreshAttempted: true,
          refreshSucceeded: true,
          hasActiveWindow: true,
          modeReliable: true,
          targetsCurrentWindow: true,
        ),
        isFalse,
      );
    });
  });

  group('enableAndroidPhotoPickerForTerminalMedia', () {
    test('enables the existing Android image picker implementation', () {
      final imagePicker = ImagePickerAndroid();

      final configuredPicker = enableAndroidPhotoPickerForTerminalMedia(
        imagePicker,
      );

      expect(identical(configuredPicker, imagePicker), isTrue);
      expect(configuredPicker.useAndroidPhotoPicker, isTrue);
    });

    test(
      'replaces fallback implementations with the Android implementation',
      () {
        final configuredPicker = enableAndroidPhotoPickerForTerminalMedia(
          _FakeImagePickerPlatform(),
        );

        expect(configuredPicker, isA<ImagePickerAndroid>());
        expect(configuredPicker.useAndroidPhotoPicker, isTrue);
      },
    );
  });

  group('platformFileFromPickedTerminalMedia', () {
    test('wraps photo-library media for terminal uploads', () async {
      final directory = Directory.systemTemp.createTempSync(
        'terminal-media-picker-',
      );
      addTearDown(() {
        if (directory.existsSync()) {
          directory.deleteSync(recursive: true);
        }
      });
      final mediaFile = File('${directory.path}/photo.jpg')
        ..writeAsBytesSync([1, 2, 3]);

      final file = await platformFileFromPickedTerminalMedia(
        XFile(mediaFile.path),
      );

      expect(file.name, 'photo.jpg');
      expect(file.path, mediaFile.path);
      expect(await file.length(), 3);
    });
  });

  group('detectTerminalFilePaths', () {
    test('returns supported file path ranges in text order', () {
      const text =
          'Open /var/log/app.log:42:7 and lib/main.dart but not feature/sftp-browser';
      final detectedPaths = detectTerminalFilePaths(text);

      expect(detectedPaths.map((path) => path.path).toList(), [
        '/var/log/app.log',
        'lib/main.dart',
      ]);
      expect(detectedPaths.map((path) => path.start).toList(), [
        text.indexOf('/var/log/app.log'),
        text.indexOf('lib/main.dart'),
      ]);
      expect(
        text.substring(detectedPaths.first.start, detectedPaths.first.end),
        '/var/log/app.log',
      );
    });

    test('detects Windows drive-letter paths', () {
      const text = r'Open C:\Users\demo\Documents\notes.txt now';
      final detectedPaths = detectTerminalFilePaths(text);

      expect(detectedPaths.map((path) => path.path), [
        'C:/Users/demo/Documents/notes.txt',
      ]);
      expect(detectedPaths.single.start, text.indexOf(r'C:\Users'));
      expect(
        text.substring(detectedPaths.single.start, detectedPaths.single.end),
        r'C:\Users\demo\Documents\notes.txt',
      );
    });
  });

  group('detectTerminalLinkAtTextOffset', () {
    test('detects an https link at the tapped offset', () {
      final detectedLink = detectTerminalLinkAtTextOffset(
        'Visit https://example.com/docs for details.',
        12,
      );

      expect(detectedLink, isNotNull);
      expect(detectedLink!.uri.toString(), 'https://example.com/docs');
    });

    test('normalizes case-insensitive www links to https', () {
      final detectedLink = detectTerminalLinkAtTextOffset(
        'Open WWW.github.com/features/copilot now',
        10,
      );

      expect(detectedLink, isNotNull);
      expect(
        detectedLink!.uri.toString(),
        'https://www.github.com/features/copilot',
      );
    });

    test('returns null when the tapped offset is outside a link', () {
      expect(
        detectTerminalLinkAtTextOffset(
          'Visit https://example.com/docs for details.',
          2,
        ),
        isNull,
      );
    });

    test('detects visible tel links at the tapped offset', () {
      final detectedLink = detectTerminalLinkAtTextOffset(
        'Call tel:+15551234567 for help.',
        10,
      );

      expect(detectedLink, isNotNull);
      expect(detectedLink!.uri.toString(), 'tel:+15551234567');
    });

    test('detects file links at the tapped offset', () {
      final detectedLink = detectTerminalLinkAtTextOffset(
        'Open file:///srv/app/main.dart in the browser.',
        12,
      );

      expect(detectedLink, isNotNull);
      expect(detectedLink!.uri.toString(), 'file:///srv/app/main.dart');
    });

    test('reconstructs a URL split across rendered lines', () {
      const text =
          'See PR https://github.com/depoll-personal/LANbu-Han │\n'
          'dy/pull/187 for details';
      final detectedLink = detectTerminalLinkAtTextOffset(
        text,
        text.indexOf('https'),
      );

      expect(detectedLink, isNotNull);
      expect(
        detectedLink!.uri.toString(),
        'https://github.com/depoll-personal/LANbu-Handy/pull/187',
      );
    });

    test('resolves a tap on a URL continuation line to the full URL', () {
      const text =
          'See PR https://github.com/depoll-personal/LANbu-Han │\n'
          'dy/pull/187 for details';
      final detectedLink = detectTerminalLinkAtTextOffset(
        text,
        text.indexOf('dy/pull'),
      );

      expect(detectedLink, isNotNull);
      expect(
        detectedLink!.uri.toString(),
        'https://github.com/depoll-personal/LANbu-Handy/pull/187',
      );
    });

    test('reconstructs a URL wrapped past a TUI gutter and scrollbar', () {
      const text =
          'See https://github.com/depoll-personal/LANbu-Han █\n'
          '  dy/pull/187 done                              █';
      final detectedLink = detectTerminalLinkAtTextOffset(
        text,
        text.indexOf('https'),
      );

      expect(detectedLink, isNotNull);
      expect(
        detectedLink!.uri.toString(),
        'https://github.com/depoll-personal/LANbu-Handy/pull/187',
      );
    });

    test('reconstructs a URL wrapped after a trailing slash (Copilot)', () {
      const text =
          'See PR #590 at https://github.com/ │\n'
          'depollsoft/MonkeySSH/pull/590 done';
      final detectedLink = detectTerminalLinkAtTextOffset(
        text,
        text.indexOf('depollsoft'),
      );

      expect(detectedLink, isNotNull);
      expect(
        detectedLink!.uri.toString(),
        'https://github.com/depollsoft/MonkeySSH/pull/590',
      );
    });

    test('does not weld prose onto a URL across a plain newline', () {
      // A complete URL ending a line followed by ordinary prose has no
      // gutter/border chrome at the boundary, so the next line must not be
      // welded onto the URL (which would resolve a corrupted destination).
      const text = 'Homepage: https://example.com\nReturns a list of users';

      expect(
        detectTerminalLinkAtTextOffset(
          text,
          text.indexOf('https'),
        )?.uri.toString(),
        'https://example.com',
      );
    });

    test('does not weld a following sentence onto a bare URL line', () {
      const text = 'https://example.com\nDone.';

      expect(
        detectTerminalLinkAtTextOffset(text, 4)?.uri.toString(),
        'https://example.com',
      );
    });

    test('does not merge adjacent bare-URL list items', () {
      const text =
          '- https://github.com/depoll/a/pull/1\n'
          '- https://github.com/depoll/b/pull/2';

      expect(
        detectTerminalLinkAtTextOffset(
          text,
          text.indexOf('github.com/depoll/a'),
        )?.uri.toString(),
        'https://github.com/depoll/a/pull/1',
      );
      expect(
        detectTerminalLinkAtTextOffset(
          text,
          text.indexOf('github.com/depoll/b'),
        )?.uri.toString(),
        'https://github.com/depoll/b/pull/2',
      );
    });

    test('excludes a box border flush against the end of a URL', () {
      // A TUI (e.g. Copilot CLI) char-wraps a URL against its right box border
      // with no separating space, so the border glyph sits immediately after
      // the URL. The border must not be swallowed into the link.
      const text =
          '\u2502https://github.com/depollsoft/MonkeySSH/pull/590\u2502';
      final detectedLink = detectTerminalLinkAtTextOffset(
        text,
        text.indexOf('https'),
      );

      expect(detectedLink, isNotNull);
      expect(
        detectedLink!.uri.toString(),
        'https://github.com/depollsoft/MonkeySSH/pull/590',
      );
    });

    test('reconstructs a URL char-wrapped flush against box borders', () {
      // Copilot CLI on a narrow screen char-wraps a URL flush against the box
      // borders on both rendered lines, with no spaces separating the URL
      // fragments from the U+2502 borders.
      const text =
          '\u2502https://github.com/depollsoft/Mon\u2502\n'
          '\u2502keySSH/pull/592 ok\u2502';
      final detectedFirstHalf = detectTerminalLinkAtTextOffset(
        text,
        text.indexOf('https'),
      );
      final detectedSecondHalf = detectTerminalLinkAtTextOffset(
        text,
        text.indexOf('keySSH'),
      );

      const expected = 'https://github.com/depollsoft/MonkeySSH/pull/592';
      expect(detectedFirstHalf?.uri.toString(), expected);
      expect(detectedSecondHalf?.uri.toString(), expected);
    });
  });

  group('resolveTerminalFileUriPath', () {
    test('extracts the path from a host-qualified file URI', () {
      expect(
        resolveTerminalFileUriPath('file://build-host/srv/app/main.dart'),
        '/srv/app/main.dart',
      );
    });

    test('extracts the path from an authority-less file URI', () {
      expect(
        resolveTerminalFileUriPath('file:///var/log/app.log'),
        '/var/log/app.log',
      );
    });

    test('decodes percent-encoded path segments', () {
      expect(
        resolveTerminalFileUriPath('file:///srv/my%20app/main.dart'),
        '/srv/my app/main.dart',
      );
    });

    test('returns null for non-file links', () {
      expect(resolveTerminalFileUriPath('https://example.com'), isNull);
    });

    test('returns null for a file URI without a path', () {
      expect(resolveTerminalFileUriPath('file://build-host'), isNull);
    });
  });

  group('isTerminalFileUri', () {
    test('accepts file URIs with a path', () {
      expect(isTerminalFileUri(Uri.parse('file:///srv/app')), isTrue);
      expect(isTerminalFileUri(Uri.parse('file://host/srv/app')), isTrue);
    });

    test('rejects non-file and pathless file URIs', () {
      expect(isTerminalFileUri(Uri.parse('https://example.com')), isFalse);
      expect(isTerminalFileUri(Uri.parse('file://host')), isFalse);
    });

    test('treats file URIs as resolvable but not launchable', () {
      final uri = Uri.parse('file:///srv/app/main.dart');
      expect(isResolvableTerminalLinkUri(uri), isTrue);
      expect(isLaunchableTerminalUri(uri), isFalse);
    });
  });

  group('detectTerminalFilePathAtTextOffset', () {
    test('detects an absolute remote path at the tapped offset', () {
      final detectedPath = detectTerminalFilePathAtTextOffset(
        'Open /var/log/nginx/access.log in SFTP.',
        12,
      );

      expect(detectedPath, isNotNull);
      expect(detectedPath!.path, '/var/log/nginx/access.log');
    });

    test('detects tilde-prefixed paths at the tapped offset', () {
      final detectedPath = detectTerminalFilePathAtTextOffset(
        'Open ~/.config/ghostty/config in SFTP.',
        10,
      );

      expect(detectedPath, isNotNull);
      expect(detectedPath!.path, '~/.config/ghostty/config');
    });

    test('normalizes stack-trace line suffixes before navigation', () {
      final detectedPath = detectTerminalFilePathAtTextOffset(
        'Error in /srv/app/lib/main.dart:42:7',
        15,
      );

      expect(detectedPath, isNotNull);
      expect(detectedPath!.path, '/srv/app/lib/main.dart');
    });

    test('detects absolute paths split across wrapped lines', () {
      const text =
          'Open /srv/app/lib/presentation/screens/\nterminal_screen.dart next.';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('terminal_screen'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '/srv/app/lib/presentation/screens/terminal_screen.dart',
      );
    });

    test('detects paths split across indented continuation lines', () {
      const text =
          'Open /srv/app/lib/presentation/\n'
          '    screens/terminal_screen.dart next.';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('screens'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '/srv/app/lib/presentation/screens/terminal_screen.dart',
      );
    });

    test(
      'detects relative paths split immediately after a directory slash',
      () {
        const text =
            'Open lib/presentation/\n'
            '    screens/terminal_screen.dart next.';
        final detectedPath = detectTerminalFilePathAtTextOffset(
          text,
          text.indexOf('screens'),
        );

        expect(detectedPath, isNotNull);
        expect(
          detectedPath!.path,
          'lib/presentation/screens/terminal_screen.dart',
        );
      },
    );

    test('detects tilde-root paths split before the next segment', () {
      const text = 'Open ~/\nCode/flutty next.';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('Code'),
      );

      expect(detectedPath, isNotNull);
      expect(detectedPath!.path, '~/Code/flutty');
    });

    test('detects slash-root paths split before the next segment', () {
      const text = 'Open /\nvar/log/app.log next.';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('var/log'),
      );

      expect(detectedPath, isNotNull);
      expect(detectedPath!.path, '/var/log/app.log');
    });

    test(
      'detects absolute paths that resume with a slash after leading context',
      () {
        const text = 'Open /Users/tester\n/project/lib/main.dart next.';
        final detectedPath = detectTerminalFilePathAtTextOffset(
          text,
          text.indexOf('project/lib'),
        );

        expect(detectedPath, isNotNull);
        expect(detectedPath!.path, '/Users/tester/project/lib/main.dart');
      },
    );

    test('ignores colored guide prefixes in continuation indentation', () {
      const text =
          'Open /srv/app/lib/presentation/\n'
          '│   screens/terminal_screen.dart next.';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('screens'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '/srv/app/lib/presentation/screens/terminal_screen.dart',
      );
    });

    test('detects paths split across TUI guide continuation rows', () {
      const text =
          "│ p = Path('/Users/depoll/.copilot/session-state/6745\n"
          "  │ 9a12-f8a8-405a-a838-2fc3a30dadd4/plan.md')";
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('9a12'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '/Users/depoll/.copilot/session-state/67459a12-f8a8-405a-a838-2fc3a30dadd4/plan.md',
      );
    });

    test('detects tilde paths split across TUI guide continuation rows', () {
      const text =
          '│ Edit ~/Code/flutty.worktrees/fix-local-path-link-sepa\n'
          '  │ rators/lib/presentation/screens/terminal_screen.dart';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('rators'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '~/Code/flutty.worktrees/fix-local-path-link-separators/lib/presentation/screens/terminal_screen.dart',
      );
    });

    test('detects tilde paths split across unindented continuation lines', () {
      const text =
          'Edit ~/Code/flutty.worktrees/fix-sftp-local-path-link\n'
          's/lib/presentation/screens/terminal_screen.dart';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('terminal_screen'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '~/Code/flutty.worktrees/fix-sftp-local-path-links/lib/presentation/screens/terminal_screen.dart',
      );
    });

    test('detects local paths split across three wrapped lines', () {
      const text =
          'Read ~/Code/flutty.worktrees/fix-swipe-keyboard-typing/lib/\n'
          'presentation/widgets/terminal_text_input_handler.dar\n'
          't';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.lastIndexOf('t'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '~/Code/flutty.worktrees/fix-swipe-keyboard-typing/lib/presentation/widgets/terminal_text_input_handler.dart',
      );
    });

    test('detects local paths split across three TUI continuation rows', () {
      const text =
          '│ Read ~/Code/flutty.worktrees/fix-swipe-keyboard-typing/lib/\n'
          '│ presentation/widgets/terminal_text_input_handler.dar\n'
          '│ t';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.lastIndexOf('t'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '~/Code/flutty.worktrees/fix-swipe-keyboard-typing/lib/presentation/widgets/terminal_text_input_handler.dart',
      );
    });

    test('detects paths split across lines ending with a scrollbar glyph', () {
      const text =
          'Read ~/Code/flutty/lib/presentation/screens/   █\n'
          'terminal_screen.dart for the link logic.       █';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('terminal_screen'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '~/Code/flutty/lib/presentation/screens/terminal_screen.dart',
      );
    });

    test('detects absolute paths split before a right-edge scrollbar', () {
      const text =
          'Open /srv/app/lib/presentation/                ▐\n'
          'screens/terminal_screen.dart next.            ▐';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('screens'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '/srv/app/lib/presentation/screens/terminal_screen.dart',
      );
    });

    test('detects paths split across three scrollbar-padded rows', () {
      const text =
          'Read ~/Code/flutty/lib/                        ▌\n'
          'presentation/widgets/terminal_text_input_handl ▌\n'
          'er.dart for review.                            ▌';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('er.dart'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '~/Code/flutty/lib/presentation/widgets/terminal_text_input_handler.dart',
      );
    });

    test('detects paths split across mixed scrollbar thumb and track rows', () {
      const text =
          'Read /srv/app/lib/presentation/screens/        ░\n'
          'terminal_screen.dart for the link logic.       █';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('terminal_screen'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '/srv/app/lib/presentation/screens/terminal_screen.dart',
      );
    });

    test('drops wrapped result counts from grep-style file path matches', () {
      const text =
          '(~/Code/flutty.worktrees/fix-swipe-keyboard-typing/test/\n'
          'widget/terminal_text_input_handler_test.dart)6 lines found';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('terminal_text_input_handler_test.dart'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '~/Code/flutty.worktrees/fix-swipe-keyboard-typing/test/widget/terminal_text_input_handler_test.dart',
      );
    });

    test('keeps suffix taps inside the hit-test range for stack traces', () {
      const line = 'Error in /srv/app/lib/main.dart:42:7';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        line,
        line.indexOf('42'),
      );

      expect(detectedPath, isNotNull);
      expect(detectedPath!.path, '/srv/app/lib/main.dart');
      expect(
        line.substring(detectedPath.start, detectedPath.end),
        '/srv/app/lib/main.dart',
      );
    });

    test('ignores plain filenames without any path context', () {
      expect(
        detectTerminalFilePathAtTextOffset('Inspect main.dart next.', 12),
        isNull,
      );
    });

    test(
      'detects verified-looking relative paths with file-like basenames',
      () {
        final detectedPath = detectTerminalFilePathAtTextOffset(
          'Inspect lib/presentation/screens/terminal_screen.dart next.',
          12,
        );

        expect(detectedPath, isNotNull);
        expect(
          detectedPath!.path,
          'lib/presentation/screens/terminal_screen.dart',
        );
      },
    );

    test('detects dot-relative paths', () {
      final detectedPath = detectTerminalFilePathAtTextOffset(
        'Inspect ../lib/main.dart next.',
        12,
      );

      expect(detectedPath, isNotNull);
      expect(detectedPath!.path, '../lib/main.dart');
    });

    test('stops before shell operators that follow a wrapped path', () {
      const text =
          'cd /Users/depoll/Code/flutty.worktrees/fix-main-ci&& git status';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('fix-main-ci'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '/Users/depoll/Code/flutty.worktrees/fix-main-ci',
      );
      expect(
        text.substring(detectedPath.start, detectedPath.end),
        '/Users/depoll/Code/flutty.worktrees/fix-main-ci',
      );
    });

    test('drops wrapped view line-range suffixes from detected paths', () {
      const text =
          '~/Code/flutty.worktrees/fix-local-path-link-separators/'
          'lib/presentation/screens/terminal_screen.dartL360:430';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('terminal_screen'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '~/Code/flutty.worktrees/fix-local-path-link-separators/lib/presentation/screens/terminal_screen.dart',
      );
    });

    test('ignores separate view metadata rows after wrapped worktree paths', () {
      const text =
          'Read terminal_screen.dart\n'
          '~/Code/flutty.worktrees/session-resumption-all-provide\n'
          'rs/lib/presentation/screens/terminal_screen.dart\n'
          '└ L330:390 (61 lines read)';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('session-resumption'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '~/Code/flutty.worktrees/session-resumption-all-providers/lib/presentation/screens/terminal_screen.dart',
      );
      expect(
        detectTerminalFilePathAtTextOffset(text, text.indexOf('L330')),
        isNull,
      );
    });

    test('detects prompt-style explicit paths after ordinary prose rows', () {
      const text =
          'metadata rows no longer get folded into the path\n'
          '~/Code/flutty [⇢main]';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('Code'),
      );

      expect(detectedPath, isNotNull);
      expect(detectedPath!.path, '~/Code/flutty');
    });

    test('does not merge separate absolute paths on adjacent lines', () {
      const text = '/tmp/foo\n/var/log/app.log';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('/var/log'),
      );

      expect(detectedPath, isNotNull);
      expect(detectedPath!.path, '/var/log/app.log');
    });

    test('does not merge separate relative paths on adjacent lines', () {
      const text =
          'lib/presentation/screens/terminal_screen.dart\n'
          'test/widget/terminal_screen_selection_test.dart';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('test/widget'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        'test/widget/terminal_screen_selection_test.dart',
      );
    });

    test('ignores branch-like slash paths without a file-like basename', () {
      expect(
        detectTerminalFilePathAtTextOffset(
          'Inspect feature/sftp-browser next.',
          12,
        ),
        isNull,
      );
    });

    test('returns null when the tapped offset is outside the path', () {
      expect(
        detectTerminalFilePathAtTextOffset(
          'Open /var/log/nginx/access.log in SFTP.',
          2,
        ),
        isNull,
      );
    });
  });

  group('resolveTerminalFilePathSegmentOnRow', () {
    test('excludes continuation indentation from the visible segment', () {
      const snapshotText =
          'Open /srv/app/lib/presentation/\n'
          '    screens/terminal_screen.dart next.';
      const rowText = '    screens/terminal_screen.dart next.';
      expect(
        resolveTerminalFilePathSegmentOnRowForPath(
          snapshotText: snapshotText,
          rowText: rowText,
          rowStartOffset: snapshotText.indexOf(rowText),
          rowColumnOffsets: List<int>.generate(rowText.length + 1, (i) => i),
          path: '/srv/app/lib/presentation/screens/terminal_screen.dart',
        ),
        (text: 'screens/terminal_screen.dart', startColumn: 4, endColumn: 31),
      );
    });

    test('excludes TUI guide prefixes from wrapped visible segments', () {
      const snapshotText =
          "│ p = Path('/Users/depoll/.copilot/session-state/6745\n"
          "  │ 9a12-f8a8-405a-a838-2fc3a30dadd4/plan.md')";
      const rowText = '  │ 9a12-f8a8-405a-a838-2fc3a30dadd4/plan.md\')';
      expect(
        resolveTerminalFilePathSegmentOnRowForPath(
          snapshotText: snapshotText,
          rowText: rowText,
          rowStartOffset: snapshotText.indexOf(rowText),
          rowColumnOffsets: List<int>.generate(rowText.length + 1, (i) => i),
          path:
              '/Users/depoll/.copilot/session-state/67459a12-f8a8-405a-a838-2fc3a30dadd4/plan.md',
        ),
        (
          text: '9a12-f8a8-405a-a838-2fc3a30dadd4/plan.md',
          startColumn: 4,
          endColumn: 43,
        ),
      );
    });

    test('excludes guide prefixes from wrapped tilde path segments', () {
      const snapshotText =
          '│ Edit ~/Code/flutty.worktrees/fix-local-path-link-sepa\n'
          '  │ rators/lib/presentation/screens/terminal_screen.dart';
      const rowText =
          '  │ rators/lib/presentation/screens/terminal_screen.dart';
      expect(
        resolveTerminalFilePathSegmentOnRowForPath(
          snapshotText: snapshotText,
          rowText: rowText,
          rowStartOffset: snapshotText.indexOf(rowText),
          rowColumnOffsets: List<int>.generate(rowText.length + 1, (i) => i),
          path:
              '~/Code/flutty.worktrees/fix-local-path-link-separators/lib/presentation/screens/terminal_screen.dart',
        ),
        (
          text: 'rators/lib/presentation/screens/terminal_screen.dart',
          startColumn: 4,
          endColumn: 55,
        ),
      );
    });

    test(
      'keeps unindented continuation rows anchored to the first path cell',
      () {
        const snapshotText =
            'Edit ~/Code/flutty.worktrees/fix-sftp-local-path-link\n'
            's/lib/presentation/screens/terminal_screen.dart';
        const rowText = 's/lib/presentation/screens/terminal_screen.dart';
        expect(
          resolveTerminalFilePathSegmentOnRowForPath(
            snapshotText: snapshotText,
            rowText: rowText,
            rowStartOffset: snapshotText.indexOf(rowText),
            rowColumnOffsets: List<int>.generate(rowText.length + 1, (i) => i),
            path:
                '~/Code/flutty.worktrees/fix-sftp-local-path-links/lib/presentation/screens/terminal_screen.dart',
          ),
          (
            text: 's/lib/presentation/screens/terminal_screen.dart',
            startColumn: 0,
            endColumn: 46,
          ),
        );
      },
    );

    test('resolves single-character third-line path continuations', () {
      const snapshotText =
          'Read ~/Code/flutty.worktrees/fix-swipe-keyboard-typing/lib/\n'
          'presentation/widgets/terminal_text_input_handler.dar\n'
          't';
      const rowText = 't';
      expect(
        resolveTerminalFilePathSegmentOnRowForPath(
          snapshotText: snapshotText,
          rowText: rowText,
          rowStartOffset: snapshotText.lastIndexOf(rowText),
          rowColumnOffsets: List<int>.generate(rowText.length + 1, (i) => i),
          path:
              '~/Code/flutty.worktrees/fix-swipe-keyboard-typing/lib/presentation/widgets/terminal_text_input_handler.dart',
        ),
        (text: 't', startColumn: 0, endColumn: 0),
      );
    });

    test('resolves guided single-character third-line path continuations', () {
      const snapshotText =
          '│ Read ~/Code/flutty.worktrees/fix-swipe-keyboard-typing/lib/\n'
          '│ presentation/widgets/terminal_text_input_handler.dar\n'
          '│ t';
      const rowText = '│ t';
      expect(
        resolveTerminalFilePathSegmentOnRowForPath(
          snapshotText: snapshotText,
          rowText: rowText,
          rowStartOffset: snapshotText.lastIndexOf(rowText),
          rowColumnOffsets: List<int>.generate(rowText.length + 1, (i) => i),
          path:
              '~/Code/flutty.worktrees/fix-swipe-keyboard-typing/lib/presentation/widgets/terminal_text_input_handler.dart',
        ),
        (text: 't', startColumn: 2, endColumn: 2),
      );
    });
  });

  group('normalizeTerminalLinkCandidate', () {
    test('prepends https for uppercase www links', () {
      expect(
        normalizeTerminalLinkCandidate('WWW.example.com/docs'),
        'https://WWW.example.com/docs',
      );
    });
  });

  group('isLaunchableTerminalUri', () {
    test('allows supported external link schemes', () {
      expect(isLaunchableTerminalUri(Uri.parse('https://example.com')), isTrue);
      expect(
        isLaunchableTerminalUri(Uri.parse('mailto:test@example.com')),
        isTrue,
      );
      expect(isLaunchableTerminalUri(Uri.parse('tel:+15551234567')), isTrue);
    });

    test('rejects unsupported schemes', () {
      expect(
        isLaunchableTerminalUri(Uri.parse('file:///tmp/test.txt')),
        isFalse,
      );
      expect(
        isLaunchableTerminalUri(Uri.parse('intent://example.com')),
        isFalse,
      );
    });
  });

  group('isSupportedTerminalFilePath', () {
    test('allows explicit paths and conservative relative file paths', () {
      expect(isSupportedTerminalFilePath('/var/log/app.log'), isTrue);
      expect(isSupportedTerminalFilePath(r'C:\Users\demo\notes.txt'), isTrue);
      expect(isSupportedTerminalFilePath('C:/Users/demo/notes.txt'), isTrue);
      expect(isSupportedTerminalFilePath('~/.ssh/config'), isTrue);
      expect(isSupportedTerminalFilePath('lib/main.dart'), isTrue);
      expect(isSupportedTerminalFilePath('../lib/main.dart'), isTrue);
      expect(isSupportedTerminalFilePath('feature/sftp-browser'), isFalse);
      expect(isSupportedTerminalFilePath('//example.com/path'), isFalse);
    });
  });

  group('shouldActivateTerminalFilePath', () {
    test('activates unambiguous explicit paths without verification', () {
      expect(
        shouldActivateTerminalFilePath(
          '/var/log/app.log',
          hasVerifiedPath: false,
        ),
        isTrue,
      );
      expect(
        shouldActivateTerminalFilePath('~/.ssh/config', hasVerifiedPath: false),
        isTrue,
      );
      expect(
        shouldActivateTerminalFilePath(
          r'C:\Users\demo\notes.txt',
          hasVerifiedPath: false,
        ),
        isTrue,
      );
    });

    test('only activates ambiguous slash commands after verification', () {
      expect(
        shouldActivateTerminalFilePath('/commands', hasVerifiedPath: false),
        isFalse,
      );
      expect(
        shouldActivateTerminalFilePath('/commands', hasVerifiedPath: true),
        isTrue,
      );
    });

    test('only activates ambiguous explicit paths after verification', () {
      expect(
        hasAmbiguousTerminalFilePathParsing('/srv/app/lib/main.dartlines'),
        isTrue,
      );
      expect(
        shouldActivateTerminalFilePath(
          '/srv/app/lib/main.dartlines',
          hasVerifiedPath: false,
        ),
        isFalse,
      );
      expect(
        shouldActivateTerminalFilePath(
          '/srv/app/lib/main.dartlines',
          hasVerifiedPath: true,
        ),
        isTrue,
      );
    });

    test('only activates conservative relative paths after verification', () {
      expect(
        shouldActivateTerminalFilePath('lib/main.dart', hasVerifiedPath: false),
        isFalse,
      );
      expect(
        shouldActivateTerminalFilePath('lib/main.dart', hasVerifiedPath: true),
        isTrue,
      );
      expect(
        shouldActivateTerminalFilePath(
          '../lib/main.dart',
          hasVerifiedPath: false,
        ),
        isFalse,
      );
      expect(
        shouldActivateTerminalFilePath(
          '../lib/main.dart',
          hasVerifiedPath: true,
        ),
        isTrue,
      );
    });
  });

  group('resolveForgivingTerminalTapOffsets', () {
    test('checks nearby horizontal and adjacent-row cells first', () {
      expect(
        resolveForgivingTerminalTapOffsets(const CellOffset(10, 5)).take(8),
        const [
          CellOffset(10, 5),
          CellOffset(9, 5),
          CellOffset(11, 5),
          CellOffset(8, 5),
          CellOffset(12, 5),
          CellOffset(7, 5),
          CellOffset(13, 5),
          CellOffset(6, 5),
        ],
      );
    });
  });

  group('resolveVisibleTerminalRowRange', () {
    test('uses rendered viewport height to cover all visible rows', () {
      expect(
        resolveVisibleTerminalRowRange(
          scrollOffset: 24,
          lineHeight: 12,
          viewportHeight: 72,
          bufferHeight: 200,
        ),
        (topRow: 2, bottomRow: 7),
      );
    });

    test('returns null when layout metrics are not ready', () {
      expect(
        resolveVisibleTerminalRowRange(
          scrollOffset: 0,
          lineHeight: 0,
          viewportHeight: 72,
          bufferHeight: 200,
        ),
        isNull,
      );
      expect(
        resolveVisibleTerminalRowRange(
          scrollOffset: 0,
          lineHeight: 12,
          viewportHeight: 0,
          bufferHeight: 200,
        ),
        isNull,
      );
    });
  });

  group('resolveTerminalPathInlineUnderline', () {
    test('returns the requested cell range', () {
      expect(
        resolveTerminalPathInlineUnderline(
          row: 12,
          startColumn: 4,
          endColumn: 18,
          rowCount: 100,
          columnCount: 80,
        ),
        (row: 12, startColumn: 4, endColumn: 18),
      );
    });

    test('clamps columns to the terminal width', () {
      expect(
        resolveTerminalPathInlineUnderline(
          row: 2,
          startColumn: -4,
          endColumn: 100,
          rowCount: 20,
          columnCount: 80,
        ),
        (row: 2, startColumn: 0, endColumn: 79),
      );
    });

    test('returns null for invalid rows or empty terminal width', () {
      expect(
        resolveTerminalPathInlineUnderline(
          row: -1,
          startColumn: 0,
          endColumn: 4,
          rowCount: 20,
          columnCount: 80,
        ),
        isNull,
      );
      expect(
        resolveTerminalPathInlineUnderline(
          row: 20,
          startColumn: 0,
          endColumn: 4,
          rowCount: 20,
          columnCount: 80,
        ),
        isNull,
      );
      expect(
        resolveTerminalPathInlineUnderline(
          row: 0,
          startColumn: 0,
          endColumn: 4,
          rowCount: 20,
          columnCount: 0,
        ),
        isNull,
      );
    });

    test('returns null when the normalized range is empty', () {
      expect(
        resolveTerminalPathInlineUnderline(
          row: 0,
          startColumn: 8,
          endColumn: 4,
          rowCount: 20,
          columnCount: 80,
        ),
        isNull,
      );
    });
  });

  group('isTerminalPathContinuationAcrossLines', () {
    for (final (previous, next, expected) in <(String, String, bool)>[
      (
        'Edit ~/Code/flutty.worktrees/fix-sftp-local-path-link',
        's/lib/presentation/screens/terminal_screen.dart',
        true,
      ),
      ('Read terminal_screen.dart', 'Read sftp_screen.dart', false),
      (
        'Read terminal_screen.dart',
        '~/Code/flutty.worktrees/session-resumption-all-provide',
        false,
      ),
      (
        '~/Code/flutty.worktrees/session-resumption-all-provide',
        '└ L330:390 (61 lines read)',
        false,
      ),
      ('/tmp/foo', '/var/log/app.log', false),
      ('Open lib/presentation/', 'screens/terminal_screen.dart', true),
      ('Open ~/', 'Code/flutty', true),
      ('Open /', 'var/log/app.log', true),
      ('Open /Users/tester', '/project/lib/main.dart', true),
      (
        'lib/presentation/screens/terminal_screen.dart',
        'test/widget/terminal_screen_selection_test.dart',
        false,
      ),
      (
        'metadata rows no longer get folded into the path',
        '~/Code/flutty [⇢main]',
        false,
      ),
    ]) {
      test('joins "$previous" to "$next": $expected', () {
        expect(
          isTerminalPathContinuationAcrossLines(
            previousLineText: previous,
            nextLineText: next,
          ),
          expected,
        );
      });
    }
  });

  group('terminalRowMayContainPath', () {
    BufferLine buildLineWithText(String text) {
      final t = Terminal()..write(text);
      return t.buffer.lines[0];
    }

    test('returns true for a row with an absolute path prefix', () {
      expect(
        terminalRowMayContainPath(buildLineWithText('ls /var/log/app.log'), 80),
        isTrue,
      );
    });

    test('returns true for a row with a tilde home-relative path', () {
      expect(
        terminalRowMayContainPath(
          buildLineWithText('cat ~/Documents/notes.txt'),
          80,
        ),
        isTrue,
      );
    });

    test('returns true for a row with a Windows drive-letter path', () {
      expect(
        terminalRowMayContainPath(
          buildLineWithText(r'type C:\Users\demo\notes.txt'),
          80,
        ),
        isTrue,
      );
    });

    test('returns true for a row containing only a slash', () {
      expect(terminalRowMayContainPath(buildLineWithText('cd /'), 80), isTrue);
    });

    test('returns false for a row with plain text and no path characters', () {
      expect(
        terminalRowMayContainPath(buildLineWithText('echo hello world'), 80),
        isFalse,
      );
    });

    test('returns false for an empty (blank) row', () {
      expect(terminalRowMayContainPath(buildLineWithText(''), 80), isFalse);
    });

    test('returns false for a row with only digits and letters', () {
      expect(
        terminalRowMayContainPath(
          buildLineWithText('git status on branch main'),
          80,
        ),
        isFalse,
      );
    });
  });

  group('resolveTerminalPathTouchTargetRect', () {
    test('covers the path text with nearby padding', () {
      expect(
        resolveTerminalPathTouchTargetRect(
          lineTopLeft: const Offset(24, 18),
          lineEndOffset: const Offset(104, 18),
          lineHeight: 20,
          viewportHeight: 300,
        ),
        const Rect.fromLTRB(14, 10, 114, 46),
      );
    });
  });

  group('resolveTerminalPathTouchTargetTap', () {
    test('matches touches on the text and nearby surrounding space', () {
      expect(
        resolveTerminalPathTouchTargetTap(const Offset(18, 30), const [
          (path: '/var/log/app.log', touchRect: Rect.fromLTRB(14, 10, 114, 46)),
        ]),
        '/var/log/app.log',
      );
    });

    test('ignores touches outside every touch target', () {
      expect(
        resolveTerminalPathTouchTargetTap(const Offset(160, 80), const [
          (path: '/var/log/app.log', touchRect: Rect.fromLTRB(14, 10, 114, 46)),
        ]),
        isNull,
      );
    });
  });

  group('shouldResolveTerminalTapLinks', () {
    test('allows link taps when the native selection overlay is hidden', () {
      expect(
        shouldResolveTerminalTapLinks(showsNativeSelectionOverlay: false),
        isTrue,
      );
    });

    test('blocks link taps while the native selection overlay is visible', () {
      expect(
        shouldResolveTerminalTapLinks(showsNativeSelectionOverlay: true),
        isFalse,
      );
    });
  });

  group('applyTerminalCursorInsertion', () {
    test('appends inserted text at the current cursor offset', () {
      final nextValue = applyTerminalCursorInsertion(
        currentText: 'echo ready &',
        cursorOffset: 12,
        insertedText: ' echo done',
      );

      expect(nextValue, 'echo ready & echo done');
    });

    test('inserts text in the middle of the current terminal input', () {
      final nextValue = applyTerminalCursorInsertion(
        currentText: 'echo done',
        cursorOffset: 5,
        insertedText: 'ready && ',
      );

      expect(nextValue, 'echo ready && done');
    });
  });

  group('applyTerminalInputDelta', () {
    test('applies backspaces before inserting committed text', () {
      expect(
        applyTerminalInputDelta(
          currentText: 'teh ',
          cursorOffset: 4,
          deletedCount: 3,
          appendedText: 'he ',
        ),
        'the ',
      );
    });
  });

  group('terminalSensitivePromptTextBeforeCursor', () {
    test('rejects the entire overlong wrapped prefix, not just its suffix', () {
      final terminal = Terminal(maxLines: 10000)
        ..resize(80, 24)
        ..write('${'x' * 100000} Password:');
      expect(terminalSensitivePromptTextBeforeCursor(terminal), isNull);
    });

    test('keeps the 220 UTF-16 boundary and ignores trailing whitespace', () {
      final terminal = Terminal()
        ..resize(20, 24)
        ..write('${'x' * 210} Password:${' ' * 400}');
      expect(
        terminalSensitivePromptTextBeforeCursor(terminal),
        '${'x' * 210} Password:',
      );
      expect(
        terminalTextLooksLikeSensitiveInputPrompt(
          terminalSensitivePromptTextBeforeCursor(terminal),
        ),
        isTrue,
      );
      terminal.write('x');
      expect(terminalSensitivePromptTextBeforeCursor(terminal), isNull);
    });

    test('counts supplementary characters as two UTF-16 code units', () {
      // Move past the final column so the colon is before the reported cursor.
      final terminal = Terminal()
        ..resize(20, 24)
        ..write('${'😀' * 105} Password: ');
      expect(
        terminalSensitivePromptTextBeforeCursor(terminal),
        '${'😀' * 105} Password:',
      );
      terminal.write('x');
      expect(terminalSensitivePromptTextBeforeCursor(terminal), isNull);
    });

    test('stops at the cursor and the start of its wrapped group', () {
      final terminal = Terminal()
        ..resize(10, 24)
        ..write('${'x' * 300}\r\nPassword: ignored')
        ..write('\x1b[1A\x1b[10G');
      expect(terminalSensitivePromptTextBeforeCursor(terminal), 'Password:');
    });

    test(
      'preserves wrapped padding after a wide character at the row edge',
      () {
        // The trailing space wraps the cursor onto a third row, past the colon.
        final terminal = Terminal()
          ..resize(10, 24)
          ..write('123456789界Password: ');
        expect(
          terminalSensitivePromptTextBeforeCursor(terminal),
          '123456789界 Password:',
        );
        terminal.write('\x1b[2A\x1b[10G');
        expect(terminalSensitivePromptTextBeforeCursor(terminal), '123456789');
      },
    );

    test('excludes a wide character when the cursor is inside its cell', () {
      final terminal = Terminal()
        ..resize(10, 24)
        ..write('12界Password:')
        ..write('\x1b[1A\x1b[4G');
      expect(terminalSensitivePromptTextBeforeCursor(terminal), '12');
    });

    test('returns an empty prefix for a blank line', () {
      final terminal = Terminal()
        ..resize(10, 24)
        ..write('   ');
      expect(terminalSensitivePromptTextBeforeCursor(terminal), isEmpty);
    });
  });

  group('resolveTerminalLineSnapshotTextLength', () {
    test('preserves trailing spaces through the cursor offset', () {
      expect(
        resolveTerminalLineSnapshotTextLength(
          text: 'cat     ',
          preserveOffset: 4,
          preserveTrailingPadding: false,
        ),
        4,
      );
    });

    test('keeps full wrapped-row padding when requested', () {
      expect(
        resolveTerminalLineSnapshotTextLength(
          text: 'cat     ',
          preserveOffset: 0,
          preserveTrailingPadding: true,
        ),
        8,
      );
    });
  });
}
