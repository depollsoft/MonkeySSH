// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/kitty_clipboard_protocol.dart';

String b64(String value) => base64Encode(utf8.encode(value));

void main() {
  group('parseKittyClipboardMetadata', () {
    test('drops malformed metadata and unknown operations', () {
      for (final raw in [
        '',
        'type=read:bare',
        'bare:type=read',
        'loc=primary',
        'type=bobr',
        'type=',
        'type=read:type=bobr',
      ]) {
        expect(parseKittyClipboardMetadata(raw), isNull, reason: raw);
      }
    });

    test('decodes values, keeps the last repeated key and ignores others', () {
      final parsed = parseKittyClipboardMetadata(
        'type=bobr:type=wdata:mime=${b64('text/plain')}:loc=primary'
        ':id=*a b-1.x*:pw=${b64('secret')}:name=${b64('Editor')}:extra=1',
      );
      final metadata = parsed!.metadata!;
      expect(metadata.operation, KittyClipboardOperation.writeData);
      expect(metadata.mime, 'text/plain');
      expect(metadata.primary, isTrue);
      expect(metadata.id, 'ab-1.x');
      expect(metadata.password, 'secret');
      expect(metadata.name, 'Editor');
    });

    test('reports invalid base64 values with the operation', () {
      for (final raw in [
        'type=wdata:mime=!!!',
        'type=wdata:mime=dGV4dC9wbGFpbg',
        'type=wdata:mime=dGV4dC9w\nbGFpbg==',
        'type=wdata:mime=dGV4dC9wbGFpbg%3D%3D',
        'type=wdata:mime=//4=',
      ]) {
        final parsed = parseKittyClipboardMetadata(raw);
        expect(parsed?.operation, KittyClipboardOperation.writeData);
        expect(parsed?.metadata, isNull, reason: raw);
      }
    });

    test('treats an over-long password as no password', () {
      final parsed = parseKittyClipboardMetadata(
        'type=read:pw=${b64('p' * 200)}:name=${b64('x')}',
      );
      expect(parsed!.metadata!.password, isEmpty);
    });

    test('truncates the id to 512 characters', () {
      final parsed = parseKittyClipboardMetadata('type=read:id=${'a' * 600}');
      expect(parsed!.metadata!.id, hasLength(512));
    });
  });

  group('base64', () {
    test('strict decoding rejects what the spec forbids', () {
      expect(decodeKittyClipboardBase64('YQ=='), [0x61]);
      expect(decodeKittyClipboardBase64(''), isEmpty);
      for (final value in ['YQ', 'Y-_/', 'YQ%3D%3D', 'YW Jj', 'YWJj\n']) {
        expect(decodeKittyClipboardBase64(value), isNull, reason: value);
      }
    });

    test('a stream decodes payloads split anywhere', () {
      final encoded = base64Encode(utf8.encode('hello, clipboard world'));
      for (var split = 0; split <= encoded.length; split++) {
        final stream = KittyClipboardBase64Stream();
        final first = stream.feed(encoded.substring(0, split))!;
        final second = stream.feed(encoded.substring(split))!;
        expect(stream.isComplete, isTrue);
        expect(utf8.decode([...first, ...second]), 'hello, clipboard world');
      }
    });

    test('a stream restarts after padding and rejects bad data', () {
      final stream = KittyClipboardBase64Stream();
      expect(utf8.decode(stream.feed('YQ==YWI=')!), 'aab');
      expect(stream.isComplete, isTrue);

      expect(KittyClipboardBase64Stream().feed('YW Jj'), isNull);
      expect(KittyClipboardBase64Stream().feed('Y=Jj'), isNull);
      expect(KittyClipboardBase64Stream().feed('YWJ'), isNotNull);
      final incomplete = KittyClipboardBase64Stream()..feed('YWJ');
      expect(incomplete.isComplete, isFalse);
    });
  });

  group('KittyClipboardWriteTransaction', () {
    test('collects types, replaces resent types and resolves aliases', () {
      final write = KittyClipboardWriteTransaction(id: 'w');
      expect(write.addData('text/plain', b64('old')), isNull);
      expect(write.addData('text/html', b64('<b>x</b>')), isNull);
      expect(write.addAliases('text/plain', b64('UTF8_STRING  TEXT')), isTrue);
      expect(write.addData('text/plain', b64('ne')), isNull);
      expect(write.addData('text/plain', b64('w')), isNull);
      expect(write.addAliases('missing/type', b64('ignored')), isTrue);

      final entries = write.commit()!;
      expect(
        {for (final entry in entries) entry.mime: utf8.decode(entry.data)},
        {
          'text/plain': 'new',
          'text/html': '<b>x</b>',
          'UTF8_STRING': 'new',
          'TEXT': 'new',
        },
      );
    });

    test('rejects a type left unpadded before the next one', () {
      final write = KittyClipboardWriteTransaction(id: '');
      expect(write.addData('text/plain', 'YWJ'), isNull);
      expect(
        write.addData('text/html', b64('x')),
        KittyClipboardStatus.invalid,
      );
      final unpadded = KittyClipboardWriteTransaction(id: '')
        ..addData('text/plain', 'YWJ');
      expect(unpadded.commit(), isNull);
    });

    test('stops at the size limit', () {
      final write = KittyClipboardWriteTransaction(id: '', maxBytes: 4);
      expect(write.addData('a/b', b64('abc')), isNull);
      expect(write.addData('a/b', b64('de')), KittyClipboardStatus.tooLarge);
    });

    test('rejects an alias list that is not base64 UTF-8', () {
      final write = KittyClipboardWriteTransaction(id: '');
      expect(write.addAliases('text/plain', 'not base64'), isFalse);
      expect(
        write.addAliases('text/plain', base64Encode([0xff, 0xfe])),
        isFalse,
      );
    });
  });

  group('responses', () {
    test('encode fields in kitty order and omit an empty payload', () {
      expect(
        encodeKittyClipboardResponse(
          operation: KittyClipboardOperation.write,
          status: KittyClipboardStatus.permissionDenied,
          id: 'abc',
        ),
        '\x1b]5522;type=write:status=EPERM:id=abc\x1b\\',
      );
      expect(
        encodeKittyClipboardResponse(
          operation: KittyClipboardOperation.read,
          status: KittyClipboardStatus.data,
          primary: true,
          id: 'i',
          mime: 'text/plain',
          password: 'pw',
          payload: utf8.encode('hi'),
        ),
        '\x1b]5522;type=read:status=DATA:loc=primary:id=i'
        ':mime=${b64('text/plain')}:pw=${b64('pw')};${b64('hi')}\x1b\\',
      );
    });

    test('a read success lists types and chunks data at 4096 bytes', () {
      final data = Uint8List.fromList(List.generate(9000, (i) => i % 251));
      final packets = encodeKittyClipboardReadSuccess(
        id: 'r',
        listing: ['image/png', 'text/plain'],
        contents: [(mime: 'image/png', data: data)],
      ).toList();

      expect(packets, hasLength(6));
      expect(packets.first, '\x1b]5522;type=read:status=OK:id=r\x1b\\');
      expect(
        packets[1],
        '\x1b]5522;type=read:status=DATA:id=r:mime=${b64('.')}'
        ';${b64('image/png text/plain\n')}\x1b\\',
      );
      final chunks = [
        for (final packet in packets.sublist(2, 5))
          base64Decode(
            packet.substring(packet.indexOf(';', 8) + 1).split('\x1b').first,
          ),
      ];
      expect(chunks.map((chunk) => chunk.length), [4096, 4096, 808]);
      expect(chunks.expand((chunk) => chunk).toList(), data);
      expect(packets.last, '\x1b]5522;type=read:status=DONE:id=r\x1b\\');
    });

    test('an empty listing is sent without a payload', () {
      final packets = encodeKittyClipboardReadSuccess(listing: []).toList();
      expect(
        packets[1],
        '\x1b]5522;type=read:status=DATA:mime=${b64('.')}\x1b\\',
      );
    });
  });

  test('recognizes text spellings and image signatures', () {
    for (final mime in [
      'text/plain',
      'text/plain;charset=utf-8',
      'TEXT/PLAIN; charset=UTF-8',
      'UTF8_STRING',
      'STRING',
    ]) {
      expect(isKittyClipboardTextMime(mime), isTrue, reason: mime);
    }
    expect(isKittyClipboardTextMime('text/html'), isFalse);

    Uint8List bytes(List<int> values) => Uint8List.fromList(values);
    expect(
      kittyClipboardImageMime(
        bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0]),
      ),
      'image/png',
    );
    expect(
      kittyClipboardImageMime(bytes([0xFF, 0xD8, 0xFF, 0xE0])),
      'image/jpeg',
    );
    expect(
      kittyClipboardImageMime(bytes([...ascii.encode('RIFF1234WEBPVP8 ')])),
      'image/webp',
    );
    expect(kittyClipboardImageMime(bytes([1, 2, 3])), isNull);
  });
}
