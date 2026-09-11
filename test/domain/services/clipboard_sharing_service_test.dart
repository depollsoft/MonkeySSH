import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/clipboard_sharing_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('ClipboardSharingService', () {
    group('handleOsc52', () {
      test(
        'ignores platform failures while answering clipboard queries',
        () async {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, (call) async {
                throw PlatformException(code: 'clipboard_unavailable');
              });

          expect(
            await const ClipboardSharingService().handleOsc52([
              'c',
              '?',
            ], allowLocalClipboardRead: true),
            isNull,
          );
        },
      );

      test(
        'does not answer clipboard queries when local read is disabled',
        () async {
          var clipboardRead = false;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, (call) async {
                if (call.method == 'Clipboard.getData') {
                  clipboardRead = true;
                  return <String, Object?>{'text': 'local-secret'};
                }
                return null;
              });

          final result = await const ClipboardSharingService().handleOsc52([
            'c',
            '?',
          ], allowLocalClipboardRead: false);

          expect(result, isNull);
          expect(clipboardRead, isFalse);
        },
      );

      test('answers clipboard queries when local read is enabled', () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.getData') {
                expect(call.arguments, Clipboard.kTextPlain);
                return <String, Object?>{'text': 'local-secret'};
              }
              return null;
            });

        final result = await const ClipboardSharingService().handleOsc52([
          'c',
          '?',
        ], allowLocalClipboardRead: true);

        expect(
          result,
          ClipboardSharingService.buildOsc52Response(
            'c',
            base64Encode(utf8.encode('local-secret')),
          ),
        );
      });
    });

    group('parseOsc52Args', () {
      test('parses split args [target, payload]', () {
        final result = ClipboardSharingService.parseOsc52Args([
          'c',
          'SGVsbG8=',
        ]);
        expect(result, isNotNull);
        expect(result!.$1, 'c');
        expect(result.$2, 'SGVsbG8=');
      });

      test('parses single combined arg target;payload', () {
        final result = ClipboardSharingService.parseOsc52Args(['c;SGVsbG8=']);
        expect(result, isNotNull);
        expect(result!.$1, 'c');
        expect(result.$2, 'SGVsbG8=');
      });

      test('parses query marker', () {
        final result = ClipboardSharingService.parseOsc52Args(['c', '?']);
        expect(result, isNotNull);
        expect(result!.$1, 'c');
        expect(result.$2, '?');
      });

      test('parses primary selection target', () {
        final result = ClipboardSharingService.parseOsc52Args([
          'p',
          'SGVsbG8=',
        ]);
        expect(result, isNotNull);
        expect(result!.$1, 'p');
        expect(result.$2, 'SGVsbG8=');
      });

      test('returns null for empty args', () {
        expect(ClipboardSharingService.parseOsc52Args([]), isNull);
      });

      test('returns null for single arg without semicolon', () {
        expect(ClipboardSharingService.parseOsc52Args(['c']), isNull);
      });

      test('joins multiple args after target', () {
        // If the base64 payload contained semicolons (unlikely but defensive).
        final result = ClipboardSharingService.parseOsc52Args([
          'c',
          'part1',
          'part2',
        ]);
        expect(result, isNotNull);
        expect(result!.$1, 'c');
        expect(result.$2, 'part1;part2');
      });
    });

    group('decodePayload', () {
      test('decodes valid base64', () {
        final encoded = base64Encode(utf8.encode('Hello, World!'));
        expect(ClipboardSharingService.decodePayload(encoded), 'Hello, World!');
      });

      test('decodes UTF-8 content', () {
        final encoded = base64Encode(utf8.encode('こんにちは'));
        expect(ClipboardSharingService.decodePayload(encoded), 'こんにちは');
      });

      test('returns null for invalid base64', () {
        expect(ClipboardSharingService.decodePayload('not-valid!!!'), isNull);
      });

      test('returns empty string for empty base64', () {
        expect(ClipboardSharingService.decodePayload(''), '');
      });

      test('rejects encoded strings exceeding maxEncodedLength', () {
        // Build a base64 string just over the limit without decoding.
        final oversized = 'A' * (ClipboardSharingService.maxEncodedLength + 1);
        expect(ClipboardSharingService.decodePayload(oversized), isNull);
      });
    });

    group('encodePayload', () {
      test('encodes text to base64', () {
        final encoded = ClipboardSharingService.encodePayload('Hello');
        expect(base64Decode(encoded), utf8.encode('Hello'));
      });

      test('round-trips through decode', () {
        const original = 'ssh root@example.com';
        final encoded = ClipboardSharingService.encodePayload(original);
        expect(ClipboardSharingService.decodePayload(encoded), original);
      });
    });

    group('buildOsc52Response', () {
      test('builds response with BEL terminator', () {
        final response = ClipboardSharingService.buildOsc52Response(
          'c',
          'SGVsbG8=',
        );
        expect(response, '\x1b]52;c;SGVsbG8=\x07');
      });

      test('builds empty response', () {
        final response = ClipboardSharingService.buildOsc52Response('c', '');
        expect(response, '\x1b]52;c;\x07');
      });

      test('uses the provided target', () {
        final response = ClipboardSharingService.buildOsc52Response(
          'p',
          'data',
        );
        expect(response, '\x1b]52;p;data\x07');
      });
    });
  });
}
