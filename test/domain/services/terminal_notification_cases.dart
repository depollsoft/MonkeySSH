import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/terminal_notification.dart';

/// Registers tests from terminal_notification_test.dart.
void registerDomainServicesTerminalNotificationTests() {
  group('terminal_notification', () {
    late TerminalNotificationParser parser;

    setUp(() => parser = TerminalNotificationParser());

    group('OSC 9 (iTerm2)', () {
      test('plain message becomes the body', () {
        final req = parser.handleOsc('9', ['Build finished']);
        expect(req, isNotNull);
        expect(req!.title, isNull);
        expect(req.body, 'Build finished');
      });

      test('message containing semicolons is rejoined', () {
        final req = parser.handleOsc('9', ['a', 'b', 'c']);
        expect(req!.body, 'a;b;c');
      });

      test('ConEmu structured OSC 9 (numeric subcommand) is ignored', () {
        expect(parser.handleOsc('9', ['4', '1', '50']), isNull);
        expect(parser.handleOsc('9', ['9', '/home/user']), isNull);
      });

      test('a message that merely starts with a number still notifies', () {
        final req = parser.handleOsc('9', ['5 tests failed']);
        expect(req!.body, '5 tests failed');
      });

      test('empty payload yields nothing', () {
        expect(parser.handleOsc('9', []), isNull);
        expect(parser.handleOsc('9', ['']), isNull);
      });
    });

    group('OSC 777 (urxvt)', () {
      test('notify with title and body', () {
        final req = parser.handleOsc('777', ['notify', 'Title', 'Body text']);
        expect(req!.title, 'Title');
        expect(req.body, 'Body text');
      });

      test('notify with only a title demotes it to the body', () {
        final req = parser.handleOsc('777', ['notify', 'Just a title']);
        expect(req!.title, isNull);
        expect(req.body, 'Just a title');
      });

      test('body containing semicolons is rejoined', () {
        final req = parser.handleOsc('777', ['notify', 'T', 'a', 'b']);
        expect(req!.title, 'T');
        expect(req.body, 'a;b');
      });

      test('non-notify subcommand is ignored', () {
        expect(parser.handleOsc('777', ['something', 'x']), isNull);
        expect(parser.handleOsc('777', []), isNull);
      });
    });

    group('OSC 99 (kitty)', () {
      test('single chunk with no metadata is a title-only notification', () {
        final req = parser.handleOsc('99', ['', 'Hello there']);
        expect(req!.title, isNull);
        expect(req.body, 'Hello there');
      });

      test('separate title and body chunks assemble by id', () {
        expect(
          parser.handleOsc('99', ['i=1:d=0', 'My Title']),
          isNull,
          reason: 'd=0 means more chunks follow',
        );
        final req = parser.handleOsc('99', ['i=1:p=body', 'My Body']);
        expect(req!.title, 'My Title');
        expect(req.body, 'My Body');
      });

      test('a title delivered across multiple chunks is concatenated', () {
        expect(parser.handleOsc('99', ['i=7:d=0', 'Hello ']), isNull);
        expect(parser.handleOsc('99', ['i=7:d=0', 'beautiful ']), isNull);
        final req = parser.handleOsc('99', ['i=7:d=1', 'world']);
        expect(req!.body, 'Hello beautiful world');
      });

      test('base64-encoded payload (e=1) is decoded', () {
        final encoded = base64.encode(utf8.encode('Encoded title'));
        final req = parser.handleOsc('99', ['i=2:e=1', encoded]);
        expect(req!.body, 'Encoded title');
      });

      test('same identifiers update and p=close clears a notification', () {
        final created = parser.handleOsc('99', ['i=build-3', 'Started']);
        expect(created?.identifier, 'build-3');
        expect(created?.action, TerminalNotificationAction.show);

        final updated = parser.handleOsc('99', [
          'i=build-3:p=body',
          'Finished',
        ]);
        expect(updated?.identifier, 'build-3');
        expect(updated?.body, 'Finished');

        expect(
          parser.handleOsc('99', ['i=build-3:p=close']),
          const TerminalNotificationRequest.close(identifier: 'build-3'),
        );
      });

      test('notification metadata maps urgency, sound, and reports', () {
        final silent = base64.encode(utf8.encode('silent'));
        final request = parser.handleOsc('99', [
          'i=build:a=focus,report:c=1:u=2:s=$silent:w=1500',
          'Ready',
        ]);

        expect(request?.reportsActivation, isTrue);
        expect(request?.focusOnActivation, isTrue);
        expect(request?.reportsClose, isTrue);
        expect(request?.urgency, TerminalNotificationUrgency.critical);
        expect(request?.sound, TerminalNotificationSound.silent);
        expect(request?.timeout, const Duration(milliseconds: 1500));
        expect(
          buildKittyNotificationActivationReport(request?.identifier),
          '\x1b]99;i=build;\x1b\\',
        );
        expect(
          buildKittyNotificationCloseReport(request?.identifier),
          '\x1b]99;i=build:p=close;\x1b\\',
        );
        expect(
          buildKittyNotificationCloseReport(
            request?.identifier,
            untracked: true,
          ),
          '\x1b]99;i=build:p=close;untracked\x1b\\',
        );
      });

      test('later -report metadata disables activation feedback', () {
        final system = base64.encode(utf8.encode('system'));
        expect(
          parser.handleOsc('99', [
            'i=build:a=report:d=0:u=0:s=$system',
            'Working',
          ]),
          isNull,
        );
        final request = parser.handleOsc('99', ['i=build:a=-report:d=1', '']);
        expect(request?.reportsActivation, isFalse);
        expect(request?.urgency, TerminalNotificationUrgency.low);
        expect(request?.sound, TerminalNotificationSound.system);
      });

      test('alive queries list only presented identified notifications', () {
        parser
          ..markPresented('z-job')
          ..markPresented('a-job')
          ..markPresented(null);
        expect(
          buildKittyNotificationAliveResponse(const [
            'i=query:p=alive',
          ], parser.activeIdentifiers),
          '\x1b]99;i=query:p=alive;a-job,z-job\x1b\\',
        );

        parser.handleOsc('99', const ['i=a-job:p=close']);
        expect(
          buildKittyNotificationAliveResponse(const [
            'p=alive',
          ], parser.activeIdentifiers),
          '\x1b]99;p=alive;z-job\x1b\\',
        );
        parser.reset();
        expect(parser.activeIdentifiers, isEmpty);
      });

      test('unidentified identities stay distinct across shell resets', () {
        final first = parser.handleOsc('99', ['', 'One']);
        final second = parser.handleOsc('99', ['', 'Two']);
        parser.reset();
        final afterReset = parser.handleOsc('99', ['', 'Three']);

        expect(first?.identifier, isNull);
        expect(second?.identifier, isNull);
        expect(afterReset?.identifier, isNull);
        expect(first?.platformIdentifier, isNot(second?.platformIdentifier));
        expect(
          afterReset?.platformIdentifier,
          isNot(first?.platformIdentifier),
        );
        expect(
          afterReset?.platformIdentifier,
          isNot(second?.platformIdentifier),
        );
      });

      test('builds a truthful capability response', () {
        expect(
          buildKittyNotificationCapabilityResponse(const ['i=q1:p=?']),
          '\x1b]99;i=q1:p=?;a=focus,report:o=always:p=title,body:'
          's=system,silent:u=0,1,2:w=1\x1b\\',
        );
      });

      test('preserves distinct printable identifiers without aliasing', () {
        final slash = parser.handleOsc('99', ['i=build/a', 'Slash']);
        final plus = parser.handleOsc('99', ['i=build+a', 'Plus']);
        final spaced = parser.handleOsc('99', ['i=build job', 'Space']);

        expect(slash?.identifier, 'build/a');
        expect(plus?.identifier, 'build+a');
        expect(spaced?.identifier, 'build job');
        expect(slash?.identifier, isNot(plus?.identifier));
        expect(parser.handleOsc('99', ['i=${'x' * 129}', 'Too long']), isNull);
        expect(parser.handleOsc('99', ['i=bad\u0007id', 'Control']), isNull);
      });

      test('rejects Base64 payloads before oversized decode allocation', () {
        final oversized = base64.encode(List<int>.filled(4097, 0x41));
        expect(parser.handleOsc('99', ['i=large:e=1', oversized]), isNull);
      });

      test('tracks focus independently from activation reporting', () {
        expect(
          parser.handleOsc('99', ['i=focus:a=focus,report:d=0', 'Working']),
          isNull,
        );
        final request = parser.handleOsc('99', ['i=focus:a=-focus:d=1', '']);
        expect(request?.reportsActivation, isTrue);
        expect(request?.focusOnActivation, isFalse);
      });

      test('treats w=-1 and w=0 as never expire and bounds positives', () {
        expect(
          parser.handleOsc('99', const ['i=minus:w=-1', 'Minus'])?.timeout,
          isNull,
        );
        expect(
          parser.handleOsc('99', const ['i=zero:w=0', 'Zero'])?.timeout,
          isNull,
        );
        expect(
          parser.handleOsc('99', const ['i=one:w=1', 'One'])?.timeout,
          const Duration(milliseconds: 1),
        );
        expect(
          parser.handleOsc('99', const [
            'i=bounded:w=999999999999',
            'Bounded',
          ])?.timeout,
          const Duration(days: 7),
        );
      });

      test('interleaved ids stay independent', () {
        expect(parser.handleOsc('99', ['i=a:d=0', 'Alpha']), isNull);
        expect(parser.handleOsc('99', ['i=b:d=0', 'Bravo']), isNull);
        expect(parser.handleOsc('99', ['i=a:d=1', ''])!.body, 'Alpha');
        expect(parser.handleOsc('99', ['i=b:d=1', ''])!.body, 'Bravo');
      });
    });

    group('sanitization', () {
      test('control characters are stripped from the message', () {
        final req = parser.handleOsc('9', ['hi\x07\x1b[31mthere']);
        expect(req!.body, isNot(contains('\x1b')));
        expect(req.body, isNot(contains('\x07')));
      });
    });

    test('unrelated OSC codes are ignored', () {
      expect(parser.handleOsc('8', ['', 'https://example.com']), isNull);
      expect(parser.handleOsc('52', ['c', 'ZGF0YQ==']), isNull);
    });
  });
}
