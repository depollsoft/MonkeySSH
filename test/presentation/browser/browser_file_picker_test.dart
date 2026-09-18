// ignore_for_file: public_member_api_docs

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/browser/browser_file_picker.dart';
import 'package:monkeyssh/presentation/models/app_platform_file.dart';

void main() {
  group('resolveBrowserFilePickerFilter', () {
    test('uses broad native media filters', () {
      expect(
        resolveBrowserFilePickerFilter(const ['image/*']).type,
        FileType.image,
      );
      expect(
        resolveBrowserFilePickerFilter(const ['video/mp4']).type,
        FileType.video,
      );
      expect(
        resolveBrowserFilePickerFilter(const ['image/png', 'video/mp4']).type,
        FileType.media,
      );
      expect(
        resolveBrowserFilePickerFilter(const ['audio/*']).type,
        FileType.audio,
      );
    });

    test('maps exact document MIME types to extensions', () {
      final filter = resolveBrowserFilePickerFilter(const [
        'application/pdf',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      ]);

      expect(filter.type, FileType.custom);
      expect(filter.allowedExtensions, const ['pdf', 'docx']);
    });

    test('preserves HTML extension accept filters', () {
      final filter = resolveBrowserFilePickerFilter(const [
        '.pdf,.csv',
        '.docx',
      ]);

      expect(filter.type, FileType.custom);
      expect(filter.allowedExtensions, const ['pdf', 'csv', 'docx']);
    });

    test('falls back to any file for wildcard and unknown MIME types', () {
      expect(resolveBrowserFilePickerFilter(const ['*/*']).type, FileType.any);
      expect(
        resolveBrowserFilePickerFilter(const ['application/x-project-specific'])
            .type,
        FileType.any,
      );
    });
  });

  group('preferredBrowserMediaCaptureType', () {
    test('recognizes camera-compatible capture requests', () {
      expect(
        preferredBrowserMediaCaptureType(const ['image/*']),
        BrowserMediaCaptureType.image,
      );
      expect(
        preferredBrowserMediaCaptureType(const ['video/mp4']),
        BrowserMediaCaptureType.video,
      );
      expect(
        preferredBrowserMediaCaptureType(const ['image/*', 'application/pdf']),
        isNull,
      );
    });
  });

  group('browserUploadUriForPlatformFile', () {
    test('prefers a platform content URI', () {
      final file = AppPlatformFile(
        name: 'report.pdf',
        size: 12,
        path: '/tmp/report.pdf',
        uri: Uri.parse('content://documents/report'),
      );

      expect(
        browserUploadUriForPlatformFile(file),
        'content://documents/report',
      );
    });

    test('converts a filesystem path to a file URI', () {
      final file = AppPlatformFile(
        name: 'report.pdf',
        size: 12,
        path: '/tmp/report.pdf',
      );

      expect(
        browserUploadUriForPlatformFile(file),
        Uri.file('/tmp/report.pdf').toString(),
      );
    });
  });
}
