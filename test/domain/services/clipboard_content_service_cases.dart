// ignore_for_file: public_member_api_docs

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/clipboard_content_service.dart';

void registerClipboardContentServiceTests() {
  group('clipboard_content_service', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    const clipboardChannel = MethodChannel(
      'xyz.depollsoft.monkeyssh/clipboard_content',
    );

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(clipboardChannel, null);
    });

    group('ClipboardContentService', () {
      test(
        'readContentUri returns name and bytes from the platform channel',
        () async {
          final expectedBytes = Uint8List.fromList([1, 2, 3]);
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(clipboardChannel, (call) async {
                if (call.method == 'readContentUri') {
                  return <Object?, Object?>{
                    'name': 'image.png',
                    'bytes': expectedBytes,
                  };
                }
                return null;
              });

          const service = ClipboardContentService();
          final result = await service.readContentUri(
            'content://com.example/image.png',
          );

          expect(result.name, 'image.png');
          expect(result.bytes, expectedBytes);
        },
      );

      test('readContentUri throws when response is not a map', () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(clipboardChannel, (call) async {
              if (call.method == 'readContentUri') {
                return 'unexpected-string';
              }
              return null;
            });

        const service = ClipboardContentService();
        await expectLater(
          service.readContentUri('content://com.example/file.txt'),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'invalid_clipboard_content',
            ),
          ),
        );
      });

      test(
        'readContentUri throws when response map is missing fields',
        () async {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(clipboardChannel, (call) async {
                if (call.method == 'readContentUri') {
                  return <Object?, Object?>{'name': 'file.txt'};
                }
                return null;
              });

          const service = ClipboardContentService();
          await expectLater(
            service.readContentUri('content://com.example/file.txt'),
            throwsA(
              isA<PlatformException>().having(
                (e) => e.code,
                'code',
                'invalid_clipboard_content',
              ),
            ),
          );
        },
      );
    });

    group('clipboardContentServiceProvider', () {
      test('provider yields a ClipboardContentService by default', () {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        final service = container.read(clipboardContentServiceProvider);

        expect(service, isA<ClipboardContentService>());
      });

      test('provider can be overridden with a stub in tests', () async {
        final fakeBytes = Uint8List.fromList([9, 8, 7]);

        final stub = _StubClipboardContentService(
          name: 'stub.png',
          bytes: fakeBytes,
        );

        final container = ProviderContainer(
          overrides: [clipboardContentServiceProvider.overrideWithValue(stub)],
        );
        addTearDown(container.dispose);

        final service = container.read(clipboardContentServiceProvider);
        final result = await service.readContentUri('content://ignored');

        expect(result.name, 'stub.png');
        expect(result.bytes, fakeBytes);
      });

      test('provider override is isolated per ProviderContainer', () {
        final container1 = ProviderContainer();
        final container2 = ProviderContainer(
          overrides: [
            clipboardContentServiceProvider.overrideWith(
              (ref) => _StubClipboardContentService(
                name: 'override',
                bytes: Uint8List(0),
              ),
            ),
          ],
        );
        addTearDown(container1.dispose);
        addTearDown(container2.dispose);

        final service1 = container1.read(clipboardContentServiceProvider);
        final service2 = container2.read(clipboardContentServiceProvider);

        expect(service1, isNot(same(service2)));
        expect(service1, isA<ClipboardContentService>());
        expect(service2, isA<_StubClipboardContentService>());
      });
    });
  });
}

/// Fake [ClipboardContentService] for use in provider override tests.
class _StubClipboardContentService extends ClipboardContentService {
  _StubClipboardContentService({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;

  @override
  Future<({String name, Uint8List bytes})> readContentUri(String uri) async =>
      (name: name, bytes: bytes);
}
