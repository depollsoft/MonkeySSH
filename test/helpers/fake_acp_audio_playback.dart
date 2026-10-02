// ignore_for_file: public_member_api_docs

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:monkeyssh/domain/services/acp_audio_clip_cache.dart';
import 'package:video_player/video_player.dart';

/// A `video_player` controller that never touches a platform channel.
class FakeAcpAudioController extends ValueNotifier<VideoPlayerValue>
    implements VideoPlayerController {
  FakeAcpAudioController({
    this.duration = const Duration(seconds: 63),
    this.failInitialize = false,
  }) : super(const VideoPlayerValue.uninitialized());

  final Duration duration;
  final bool failInitialize;
  int playCount = 0;
  int pauseCount = 0;
  Duration? lastSeek;
  bool disposed = false;

  @override
  Future<void> initialize() async {
    if (failInitialize) {
      throw PlatformException(code: 'VideoError', message: 'unsupported');
    }
    value = value.copyWith(duration: duration, isInitialized: true);
  }

  @override
  Future<void> play() async {
    playCount++;
    value = value.copyWith(isPlaying: true);
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    value = value.copyWith(isPlaying: false);
  }

  @override
  Future<void> seekTo(Duration position) async {
    lastSeek = position;
    value = value.copyWith(position: position);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A clip cache that hands out leases on a placeholder file without I/O.
class FakeAcpAudioClipCache extends AcpAudioClipCache {
  FakeAcpAudioClipCache({this.fail = false})
    : super(baseDirectory: () async => Directory.systemTemp);

  final bool fail;
  int acquired = 0;
  int released = 0;

  int get outstanding => acquired - released;

  @override
  Future<AcpAudioClipLease> acquire({
    required String data,
    String? mimeType,
  }) async {
    if (fail) {
      throw const AcpAudioClipException('The audio clip could not be read.');
    }
    acquired++;
    return AcpAudioClipLease(
      file: File('/nonexistent/acp-audio/clip.mp3'),
      onRelease: () => released++,
    );
  }
}
