import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/presentation/models/app_platform_file.dart';
import 'package:monkeyssh/presentation/screens/sftp_browser_logic.dart';

class _MockXFile extends Mock implements XFile {}

void main() {
  test('parentRemotePath resolves POSIX parents', () {
    expect(parentRemotePath('/tmp/monkeyssh'), '/tmp');
    expect(parentRemotePath('/tmp'), '/');
    expect(parentRemotePath('/'), '/');
  });

  test('parentRemotePath resolves Windows drive parents', () {
    expect(parentRemotePath('C:/Users/demo'), 'C:/Users');
    expect(parentRemotePath('C:/Users'), 'C:/');
    expect(parentRemotePath('C:/'), 'C:/');
    expect(parentRemotePath('/C:/Users/demo'), '/C:/Users');
    expect(parentRemotePath('/C:/Users'), '/C:/');
    expect(parentRemotePath('/C:/'), '/C:/');
  });

  test('breadcrumbs preserve Windows drive roots', () {
    expect(buildSftpBreadcrumbItems('C:/Users/demo'), [
      (path: 'C:/', label: 'C:/'),
      (path: 'C:/Users', label: 'Users'),
      (path: 'C:/Users/demo', label: 'demo'),
    ]);
    expect(buildSftpBreadcrumbItems('/C:/Users/demo'), [
      (path: '/C:/', label: '/C:/'),
      (path: '/C:/Users', label: 'Users'),
      (path: '/C:/Users/demo', label: 'demo'),
    ]);
  });

  test('pushSftpPathHistory appends new locations without duplicates', () {
    expect(pushSftpPathHistory(const ['/tmp'], '/tmp'), ['/tmp']);
    expect(pushSftpPathHistory(const ['/tmp'], '/tmp/monkeyssh'), [
      '/tmp',
      '/tmp/monkeyssh',
    ]);
  });

  test('popSftpPathHistory keeps at least one history entry', () {
    expect(popSftpPathHistory(const ['/']), ['/']);
    expect(popSftpPathHistory(const ['/', '/tmp', '/tmp/monkeyssh']), [
      '/',
      '/tmp',
    ]);
  });

  test('requested directories open directly without file highlighting', () {
    expect(
      resolveRequestedSftpNavigationTarget('/var/log', isDirectory: true),
      (directoryPath: '/var/log', highlightedFileName: null),
    );
  });

  test('requested files target their parent directory and file row', () {
    expect(
      resolveRequestedSftpNavigationTarget(
        '/var/log/app.log',
        isDirectory: false,
      ),
      (directoryPath: '/var/log', highlightedFileName: 'app.log'),
    );
  });

  test('location shortcuts normalize and de-duplicate paths', () {
    expect(
      resolveSftpLocationShortcuts(
        homeDirectory: '/home/depoll',
        connectionStartDirectory: '/home/depoll/./',
        tmuxPaneDirectory: '/home/depoll/project',
      ),
      ['/home/depoll', '/home/depoll/project'],
    );
  });

  test('location shortcuts keep Windows home directories', () {
    expect(
      resolveSftpLocationShortcuts(
        homeDirectory: r'C:\Users\depoll',
        connectionStartDirectory: 'C:/Users/depoll/./',
        tmuxPaneDirectory: 'C:/Users/depoll/project',
      ),
      ['C:/Users/depoll', 'C:/Users/depoll/project'],
    );
  });

  test('scrolls upward when the highlighted file is above the viewport', () {
    expect(
      resolveSftpHighlightedFileScrollOffset(
        highlightedIndex: 2,
        currentOffset: 300,
        itemExtentEstimate: 64,
        viewportExtent: 240,
        maxScrollExtent: 2000,
      ),
      112,
    );
  });

  test('scrolls downward when the highlighted file is below the viewport', () {
    expect(
      resolveSftpHighlightedFileScrollOffset(
        highlightedIndex: 12,
        currentOffset: 120,
        itemExtentEstimate: 64,
        viewportExtent: 240,
        maxScrollExtent: 2000,
      ),
      608,
    );
  });

  test(
    'keeps the current offset when the highlighted file is already visible',
    () {
      expect(
        resolveSftpHighlightedFileScrollOffset(
          highlightedIndex: 4,
          currentOffset: 180,
          itemExtentEstimate: 64,
          viewportExtent: 240,
          maxScrollExtent: 2000,
        ),
        180,
      );
    },
  );

  test('detects previewable image file names including svg', () {
    expect(isPreviewableImageFileName('screenshot.png'), isTrue);
    expect(isPreviewableImageFileName('diagram.svg'), isTrue);
    expect(isPreviewableImageFileName('notes.txt'), isFalse);
  });

  test('detects previewable video file names', () {
    expect(isPreviewableVideoFileName('screen-recording.mp4'), isTrue);
    expect(isPreviewableVideoFileName('clip.MOV'), isTrue);
    expect(isPreviewableVideoFileName('capture.m4v'), isTrue);
    expect(isPreviewableVideoFileName('browser.webm'), isTrue);
    expect(isPreviewableVideoFileName('notes.txt'), isFalse);
  });

  test('resolves video MIME candidates from file names', () {
    expect(remoteVideoMimeTypeForFileName('recording.mp4'), 'video/mp4');
    expect(remoteVideoMimeTypeForFileName('recording.mov'), 'video/quicktime');
    expect(remoteVideoMimeTypeForFileName('recording.m4v'), 'video/x-m4v');
    expect(remoteVideoMimeTypeForFileName('recording.webm'), 'video/webm');
    expect(remoteVideoMimeTypeForFileName('notes.txt'), isNull);
  });

  test('infers MIME types from previewable remote file names', () {
    expect(inferRemoteFileMimeType('diagram.svg'), 'image/svg+xml');
    expect(inferRemoteFileMimeType('photo.JPG'), 'image/jpeg');
    expect(inferRemoteFileMimeType('clip.webm'), 'video/webm');
    expect(inferRemoteFileMimeType('notes.txt'), isNull);
  });

  test('toggles remote file selection while preserving selection order', () {
    const alpha = RemoteFileSelection(
      remotePath: '/home/demo/alpha.txt',
      displayName: 'alpha.txt',
    );
    const beta = RemoteFileSelection(
      remotePath: '/home/demo/beta.txt',
      displayName: 'beta.txt',
    );

    expect(
      toggleRemoteFileSelection(
        currentSelection: const [alpha],
        file: beta,
        allowMultiple: true,
      ),
      const [alpha, beta],
    );
    expect(
      toggleRemoteFileSelection(
        currentSelection: const [alpha, beta],
        file: alpha,
        allowMultiple: true,
      ),
      const [beta],
    );
    expect(
      toggleRemoteFileSelection(
        currentSelection: const [alpha],
        file: beta,
        allowMultiple: false,
      ),
      const [beta],
    );
    expect(
      toggleRemoteFileSelection(
        currentSelection: const [beta],
        file: beta,
        allowMultiple: false,
      ),
      isEmpty,
    );
  });

  test('describes disabled remote file selections from filters and limits', () {
    const alpha = RemoteFileSelection(
      remotePath: '/home/demo/alpha.txt',
      displayName: 'alpha.txt',
    );
    const beta = RemoteFileSelection(
      remotePath: '/home/demo/beta.txt',
      displayName: 'beta.txt',
    );
    const blocked = RemoteFileSelection(
      remotePath: '/home/demo/blocked.png',
      displayName: 'blocked.png',
    );
    final constraints = RemoteFilePickerConstraints(
      allowMultiple: true,
      maxSelectionCount: 1,
      selectionAvailability: (file) => file.displayName.endsWith('.png')
          ? 'Only text attachments are supported.'
          : null,
    );

    expect(
      resolveRemoteFileSelectionDisabledReason(
        constraints: constraints,
        currentSelection: const [alpha],
        candidate: beta,
      ),
      'You can select up to 1 file.',
    );
    expect(
      resolveRemoteFileSelectionDisabledReason(
        constraints: constraints,
        currentSelection: const [alpha],
        candidate: blocked,
      ),
      'Only text attachments are supported.',
    );
  });

  test('builds selection semantics labels, hints, and touch tooltips', () {
    expect(
      remoteFileSelectionSemanticsLabel(
        isDirectory: true,
        fileName: 'docs',
        isSelected: false,
      ),
      'Open folder docs',
    );
    expect(
      remoteFileSelectionSemanticsHint(isDirectory: true, isSelected: false),
      'Opens this folder.',
    );
    expect(
      remoteFileSelectionSemanticsLabel(
        isDirectory: false,
        fileName: 'notes.txt',
        isSelected: false,
      ),
      'Select remote file notes.txt',
    );
    expect(
      remoteFileSelectionSemanticsHint(isDirectory: false, isSelected: true),
      'Removes this file from the current selection.',
    );
    expect(
      remoteFileSelectionTooltip(
        isDirectory: false,
        fileName: 'notes.txt',
        isSelected: true,
      ),
      'Deselect notes.txt',
    );
    expect(
      remoteFileSelectionTooltip(
        isDirectory: false,
        fileName: 'blocked.png',
        isSelected: false,
        disabledReason: 'Only text attachments are supported.',
      ),
      'blocked.png is unavailable: Only text attachments are supported.',
    );
  });

  test('rejects known oversized video previews', () {
    expect(isRemoteVideoPreviewSizeAllowed(maxRemoteVideoPreviewBytes), isTrue);
    expect(
      isRemoteVideoPreviewSizeAllowed(maxRemoteVideoPreviewBytes + 1),
      isFalse,
    );

    expect(
      remoteVideoPreviewTooLargeMessage(
        sizeBytes: maxRemoteVideoPreviewBytes + 1,
      ),
      allOf(
        contains('Video is too large to preview here'),
        contains('100.0 MB'),
        contains('Download it instead'),
      ),
    );
  });

  test('detects svg file names', () {
    expect(isSvgFileName('diagram.svg'), isTrue);
    expect(isSvgFileName('diagram.SVG'), isTrue);
    expect(isSvgFileName('diagram.png'), isFalse);
  });

  test('detects video fixtures for placeholder icon coverage', () {
    expect(isPreviewableVideoFileName('demo.mp4'), isTrue);
    expect(isPreviewableVideoFileName('demo.MOV'), isTrue);
    expect(isPreviewableVideoFileName('demo.webm'), isTrue);
    expect(isPreviewableVideoFileName('demo.avi'), isFalse);
    expect(isPreviewableVideoFileName('demo.png'), isFalse);
    expect(
      resolveSftpFileIcon(isDirectory: false, filename: 'demo.mp4'),
      Icons.video_file,
    );
    expect(
      resolveSftpFileIcon(isDirectory: false, filename: 'diagram.svg'),
      Icons.image,
    );
  });

  test('builds shell-safe clipboard text for copied remote paths', () {
    expect(
      buildSftpCopyPathClipboardText(
        directory: '/home/demo/Project Files',
        filename: "today's notes.txt",
      ),
      r"'/home/demo/Project Files/today'\''s notes.txt'",
    );
  });

  test('blocks oversized image previews before reading remote bytes', () {
    expect(
      resolveSftpImagePreviewBlockMessage(byteCount: 10 * 1024 * 1024 + 1),
      'File is too large to preview here (max 10 MB)',
    );
    expect(
      resolveSftpImagePreviewBlockMessage(byteCount: 10 * 1024 * 1024),
      isNull,
    );
  });

  test('blocks oversized and binary text edits', () {
    expect(
      resolveSftpTextEditBlockMessage(byteCount: 1024 * 1024 + 1),
      'File is too large to edit here (max 1 MB)',
    );
    expect(
      resolveSftpTextEditBlockMessage(
        byteCount: 4,
        loadedBytes: Uint8List.fromList([0x66, 0x6f, 0x00, 0x6f]),
      ),
      'Binary files cannot be edited here',
    );
    expect(
      resolveSftpTextEditBlockMessage(
        byteCount: 5,
        loadedBytes: Uint8List.fromList('hello'.codeUnits),
      ),
      isNull,
    );
  });

  test('treats unknown picker lengths as an unknown upload size', () async {
    expect(
      await selectedUploadSizeBytes([
        AppPlatformFile(name: 'a.txt', size: 3),
        AppPlatformFile(name: 'b.txt', size: 4),
      ]),
      7,
    );

    final broken = _MockXFile();
    when(broken.length).thenThrow(const FileSystemException('stat failed'));
    expect(
      await selectedUploadSizeBytes([
        AppPlatformFile(name: 'a.txt', size: 3),
        AppPlatformFile(name: 'unknown.bin', xFile: broken),
      ]),
      isNull,
    );
  });

  test('rejects picker names that can escape the upload directory', () {
    expect(validateSftpUploadFileName('notes.txt'), isNull);
    expect(validateSftpUploadFileName('..'), isNotNull);
    expect(validateSftpUploadFileName('../authorized_keys'), isNotNull);
    expect(validateSftpUploadFileName(r'..\authorized_keys'), isNotNull);
    expect(validateSftpUploadFileName('/tmp/payload'), isNotNull);
    expect(validateSftpUploadFileName('bad\x00name'), isNotNull);
  });

  test('does not echo unsafe upload names in validation feedback', () {
    expect(
      resolveUnsafeSftpUploadNameMessage([
        AppPlatformFile(name: '../authorized_keys', size: 0),
      ]),
      'The selected file has an unsafe name',
    );
    expect(
      resolveUnsafeSftpUploadNameMessage([
        AppPlatformFile(name: '../one', size: 0),
        AppPlatformFile(name: r'..\two', size: 0),
      ]),
      '2 selected files have unsafe names',
    );
  });

  test('validates new folder names before creating directories', () {
    expect(validateSftpDirectoryName(''), 'Folder name is required');
    expect(validateSftpDirectoryName('  '), 'Folder name is required');
    expect(
      validateSftpDirectoryName('nested/folder'),
      'Folder name cannot contain /',
    );
    expect(
      validateSftpDirectoryName('..'),
      'Choose a folder name, not a navigation shortcut',
    );
    expect(validateSftpDirectoryName('release'), isNull);
  });

  test('includes remote paths in copy and create feedback', () {
    expect(
      sftpCopyPathSnackBarMessage('/var/www/site config'),
      'Copied shell-safe path for "/var/www/site config"',
    );
    expect(
      sftpCreatedDirectorySnackBarMessage('/var/www/releases'),
      'Created folder "/var/www/releases"',
    );
  });

  test('bounds stale SFTP operations with a timeout', () async {
    final completer = Completer<String>();

    await expectLater(
      withSftpOperationTimeout(
        completer.future,
        timeout: const Duration(milliseconds: 1),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('describes stale SFTP timeout recovery', () {
    expect(
      sftpTimeoutMessage('listing "/home/demo"'),
      'Timed out listing "/home/demo". The SSH connection may be stale; reconnect and try again.',
    );
  });

  test('resolves directory taps as navigation', () {
    expect(
      resolveSftpFileTapIntent(isDirectory: true, filename: 'Documents'),
      SftpFileTapIntent.navigate,
    );
  });

  test('resolves image taps as preview', () {
    expect(
      resolveSftpFileTapIntent(isDirectory: false, filename: 'diagram.png'),
      SftpFileTapIntent.preview,
    );
  });

  test('resolves video taps as video preview', () {
    expect(
      resolveSftpFileTapIntent(
        isDirectory: false,
        filename: 'screen-recording.mp4',
      ),
      SftpFileTapIntent.previewVideo,
    );
  });

  test('resolves preview kind for row action availability', () {
    expect(
      resolveSftpPreviewKind(isDirectory: true, filename: 'clip.mp4'),
      isNull,
    );
    expect(
      resolveSftpPreviewKind(isDirectory: false, filename: 'diagram.png'),
      SftpPreviewKind.image,
    );
    expect(
      resolveSftpPreviewKind(isDirectory: false, filename: 'clip.webm'),
      SftpPreviewKind.video,
    );
    expect(
      resolveSftpPreviewKind(isDirectory: false, filename: 'notes.txt'),
      isNull,
    );
  });

  test('resolves other file taps as edit', () {
    expect(
      resolveSftpFileTapIntent(isDirectory: false, filename: 'notes.txt'),
      SftpFileTapIntent.edit,
    );
  });
}
