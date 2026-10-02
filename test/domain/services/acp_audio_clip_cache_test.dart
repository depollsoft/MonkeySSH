import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/acp_audio_clip_cache.dart';

import '../../helpers/recording_diagnostics_logger.dart';

void main() {
  late Directory base;

  setUp(() async {
    base = await Directory.systemTemp.createTemp('acp-audio-cache-test');
  });

  tearDown(() async {
    if (base.existsSync()) await base.delete(recursive: true);
  });

  AcpAudioClipCache cache({
    int maxFiles = 6,
    int maxClipBytes = 1024 * 1024,
    RecordingDiagnosticsLogger? diagnostics,
  }) => AcpAudioClipCache(
    baseDirectory: () async => base,
    maxFiles: maxFiles,
    maxClipBytes: maxClipBytes,
    diagnostics: diagnostics ?? RecordingDiagnosticsLogger(),
  );

  test('decodes a clip to a private file named by an opaque id', () async {
    final diagnostics = RecordingDiagnosticsLogger();
    final bytes = List<int>.generate(700 * 1024, (index) => index % 251);
    final lease = await cache(diagnostics: diagnostics)
        .acquire(data: base64.encode(bytes), mimeType: 'audio/x-wav');

    expect(lease.file.readAsBytesSync(), bytes);
    expect(lease.file.path, endsWith('.wav'));
    expect(lease.file.path, contains('monkeyssh-acp-audio'));
    expect(
      lease.file.uri.pathSegments.last,
      matches(RegExp(r'^clip-\d+\.wav$')),
    );
    final decoded = diagnostics.events.single;
    expect(decoded.message, 'clip_decoded');
    expect(decoded.fields['bytes'], bytes.length);
    lease.release();
  });

  test('reuses a decoded file for the same payload', () async {
    final subject = cache();
    final data = base64.encode(utf8.encode('same clip'));
    final first = await subject.acquire(data: data, mimeType: 'audio/mpeg');
    final second = await subject.acquire(data: data, mimeType: 'audio/mpeg');

    expect(second.file.path, first.file.path);
    expect(subject.length, 1);
    first.release();
    second.release();
  });

  test('restores omitted base64 padding', () async {
    final data = base64.encode(utf8.encode('ab')).replaceAll('=', '');
    final lease = await cache().acquire(data: data, mimeType: 'audio/ogg');

    expect(utf8.decode(lease.file.readAsBytesSync()), 'ab');
    expect(lease.file.path, endsWith('.ogg'));
    lease.release();
  });

  test('rejects oversize payloads before writing anything', () async {
    final subject = cache(maxClipBytes: 16);

    await expectLater(
      subject.acquire(data: base64.encode(List<int>.filled(64, 1))),
      throwsA(isA<AcpAudioClipException>()),
    );
    expect(Directory('${base.path}/monkeyssh-acp-audio').existsSync(), isFalse);
  });

  test('cleans up a partial file when the payload is malformed', () async {
    final diagnostics = RecordingDiagnosticsLogger();
    final subject = cache(diagnostics: diagnostics);

    await expectLater(
      subject.acquire(data: 'not*base64!', mimeType: 'audio/mpeg'),
      throwsA(isA<AcpAudioClipException>()),
    );
    final directory = Directory('${base.path}/monkeyssh-acp-audio');
    expect(directory.listSync(), isEmpty);
    expect(subject.length, 0);
    expect(diagnostics.events.single.message, 'clip_decode_failed');
  });

  test('evicts the oldest released clip but never a leased one', () async {
    final subject = cache(maxFiles: 2);
    Future<AcpAudioClipLease> clip(int seed) => subject.acquire(
      data: base64.encode(List<int>.filled(32, seed)),
      mimeType: 'audio/mpeg',
    );

    final first = await clip(1);
    final second = await clip(2);
    final third = await clip(3);
    // All three are leased, so nothing could be evicted yet.
    expect(subject.length, 3);
    expect(first.file.existsSync(), isTrue);

    second.release();
    await pumpEventQueue();
    expect(subject.length, 2);
    expect(second.file.existsSync(), isFalse);
    expect(first.file.existsSync(), isTrue);
    expect(third.file.existsSync(), isTrue);

    first.release();
    third.release();
  });

  test('clears clips left by an earlier process on first use', () async {
    final stale = File('${base.path}/monkeyssh-acp-audio/clip-99.mp3')
      ..createSync(recursive: true)
      ..writeAsStringSync('stale');

    final lease = await cache().acquire(
      data: base64.encode(utf8.encode('fresh')),
      mimeType: 'audio/mpeg',
    );

    expect(stale.existsSync(), isFalse);
    expect(lease.file.existsSync(), isTrue);
    lease.release();
  });
}
