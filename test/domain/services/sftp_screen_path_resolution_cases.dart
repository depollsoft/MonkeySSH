import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/remote_file_service.dart';

void registerSftpScreenPathResolutionTests() {
  group('sftp_screen_path_resolution', () {
    group('resolveRequestedSftpPath', () {
      test('keeps absolute paths absolute while normalizing dot segments', () {
        expect(
          resolveRequestedSftpPath('/var/log/../tmp/app.log'),
          '/var/tmp/app.log',
        );
      });

      test(
        'keeps Windows drive paths absolute while normalizing separators',
        () {
          expect(
            resolveRequestedSftpPath(r'C:\Users\demo\..\Public\notes.txt'),
            'C:/Users/Public/notes.txt',
          );
          expect(
            resolveRequestedSftpPath('/C:/Users/demo/../Public/notes.txt'),
            '/C:/Users/Public/notes.txt',
          );
        },
      );

      test(
        'resolves tilde-prefixed paths against the remote home directory',
        () {
          expect(
            resolveRequestedSftpPath(
              '~/.config/ghostty/config',
              homeDirectory: '/home/depoll',
            ),
            '/home/depoll/.config/ghostty/config',
          );
        },
      );

      test('resolves relative paths against the working directory', () {
        expect(
          resolveRequestedSftpPath(
            '../logs/app.log',
            workingDirectory: '/home/depoll/project/lib',
          ),
          '/home/depoll/project/logs/app.log',
        );
        expect(
          resolveRequestedSftpPath(
            'lib/main.dart',
            workingDirectory: '/home/depoll/project',
          ),
          '/home/depoll/project/lib/main.dart',
        );
        expect(
          resolveRequestedSftpPath(
            r'..\logs\app.log',
            workingDirectory: r'C:\Users\depoll\project\lib',
          ),
          'C:/Users/depoll/project/logs/app.log',
        );
      });
    });
  });
}
