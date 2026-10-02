import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../models/acp_attachment.dart';
import 'diagnostics_log_service.dart';

const _diagnosticsCategory = 'acp_audio';
const _cacheDirectoryName = 'monkeyssh-acp-audio';

/// Base64 characters decoded per slice; a multiple of four so each slice is
/// a whole number of base64 quanta.
const _decodeSliceChars = 256 * 1024;

/// Content-free failure raised while preparing an audio clip for playback.
final class AcpAudioClipException implements Exception {
  /// Creates an audio clip exception.
  const AcpAudioClipException(this.message);

  /// Short, content-free explanation.
  final String message;

  @override
  String toString() => 'AcpAudioClipException: $message';
}

/// A held reference to a decoded clip file.
///
/// The cache never deletes a file while a lease on it is outstanding. Callers
/// must call [release] exactly once when they stop using [file], typically
/// when the player widget is disposed.
final class AcpAudioClipLease {
  /// Creates a lease on [file]; [onRelease] runs once, on the first [release].
  AcpAudioClipLease({required this.file, required VoidCallback onRelease})
    : _onRelease = onRelease;

  final VoidCallback _onRelease;
  var _released = false;

  /// The decoded clip on local storage.
  final File file;

  /// Returns the lease so the file can be evicted later.
  void release() {
    if (_released) return;
    _released = true;
    _onRelease();
  }
}

final class _CachedClip {
  _CachedClip(this.file, this.bytes);

  final File file;
  final int bytes;
  int leases = 0;
}

/// Writes bounded inline ACP audio clips to private temporary files.
///
/// Clips are decoded only on request, in slices, straight into a file, so
/// playback never needs a second full copy of the audio in memory and the UI
/// isolate is yielded between slices. Files live in an app-owned temporary
/// directory that is emptied the first time the cache is used in a process.
/// At most [maxFiles] files and [maxBytes] decoded bytes are retained; the
/// least recently used unleased file is deleted first. File names are opaque
/// counters and never derive from clip content.
class AcpAudioClipCache {
  /// Creates an audio clip cache.
  AcpAudioClipCache({
    Future<Directory> Function()? baseDirectory,
    this.maxFiles = 6,
    this.maxBytes = 48 * 1024 * 1024,
    this.maxClipBytes = kAcpAttachmentAudioMaxBytes,
    DiagnosticsLogger diagnostics = const NoopDiagnosticsLogger(),
  }) : assert(maxFiles > 0),
       assert(maxBytes > 0),
       assert(maxClipBytes > 0),
       _baseDirectory = baseDirectory ?? getTemporaryDirectory,
       _diagnostics = diagnostics;

  /// Shared app-wide cache.
  static final AcpAudioClipCache instance = AcpAudioClipCache(
    diagnostics: DiagnosticsLogService.instance,
  );

  /// Maximum retained clip files.
  final int maxFiles;

  /// Maximum retained decoded bytes across all clip files.
  final int maxBytes;

  /// Maximum decoded size of a single clip.
  final int maxClipBytes;

  final Future<Directory> Function() _baseDirectory;
  final DiagnosticsLogger _diagnostics;
  final LinkedHashMap<String, _CachedClip> _entries =
      LinkedHashMap<String, _CachedClip>();
  final Map<String, Future<_CachedClip>> _pending =
      <String, Future<_CachedClip>>{};
  Future<Directory>? _directory;
  var _nextFileId = 0;
  var _retainedBytes = 0;

  /// Number of clip files currently retained.
  @visibleForTesting
  int get length => _entries.length;

  /// Decodes [data] to a private file (or reuses a cached one) and leases it.
  ///
  /// Throws [AcpAudioClipException] when the payload is empty, malformed, or
  /// larger than [maxClipBytes]. The size check runs before any decoding.
  Future<AcpAudioClipLease> acquire({
    required String data,
    String? mimeType,
  }) async {
    final decodedEstimate = _estimatedDecodedLength(data);
    if (data.isEmpty || decodedEstimate <= 0) {
      throw const AcpAudioClipException('The audio clip is empty.');
    }
    if (decodedEstimate > maxClipBytes) {
      throw const AcpAudioClipException('The audio clip is too large.');
    }
    final normalizedMime = normalizeAcpAudioMimeType(mimeType ?? '');
    // String hash codes are cached by the VM after the first computation, so
    // repeated lookups for the same retained payload stay cheap.
    final key = '$normalizedMime\u0000${data.length}\u0000${data.hashCode}';
    var existing = _entries.remove(key);
    if (existing != null &&
        existing.leases == 0 &&
        !existing.file.existsSync()) {
      // The OS may purge temporary storage; decode again.
      _retainedBytes -= existing.bytes;
      existing = null;
    }
    if (existing != null) {
      _entries[key] = existing;
      existing.leases++;
      return AcpAudioClipLease(
        file: existing.file,
        onRelease: () => _release(key),
      );
    }
    final pending = _pending[key] ??=
        _decode(key: key, data: data, mimeType: normalizedMime).whenComplete(
          () {
            // A block body: returning the removed future would make this future
            // wait on itself.
            _pending.remove(key);
          },
        );
    final entry = await pending;
    entry.leases++;
    // Evict only after leasing so the new clip is never its own victim.
    _evict();
    return AcpAudioClipLease(file: entry.file, onRelease: () => _release(key));
  }

  /// Deletes every retained clip file, including leased ones.
  Future<void> clear() async {
    final files = [for (final entry in _entries.values) entry.file];
    _entries.clear();
    _retainedBytes = 0;
    for (final file in files) {
      await _deleteQuietly(file);
    }
  }

  Future<_CachedClip> _decode({
    required String key,
    required String data,
    required String mimeType,
  }) async {
    final stopwatch = Stopwatch()..start();
    final directory = await (_directory ??= _prepareDirectory());
    final id = _nextFileId++;
    final extension = acpAudioFileExtension(mimeType);
    final partial = File(path.join(directory.path, 'clip-$id.part'));
    final target = File(path.join(directory.path, 'clip-$id.$extension'));
    var written = 0;
    try {
      final output = partial.openWrite();
      final byteSink = _IOSinkByteSink(output);
      try {
        final input = base64.decoder.startChunkedConversion(byteSink);
        for (var start = 0; start < data.length; start += _decodeSliceChars) {
          final end = math.min(start + _decodeSliceChars, data.length);
          input.addSlice(data, start, end, false);
          if (byteSink.count > maxClipBytes) {
            throw const AcpAudioClipException('The audio clip is too large.');
          }
          // Flushing yields to the event loop and applies back-pressure so a
          // large clip never stalls a frame or buffers unboundedly.
          await output.flush();
        }
        // Agents occasionally omit trailing padding; restore it.
        final remainder = data.length % 4;
        final padding = remainder == 0 ? '' : '=' * (4 - remainder);
        if (padding.isNotEmpty) input.add(padding);
        input.close();
        written = byteSink.count;
        await output.flush();
      } finally {
        byteSink.close();
        await output.close();
      }
      if (written <= 0) {
        throw const AcpAudioClipException('The audio clip is empty.');
      }
      await partial.rename(target.path);
    } on Object catch (error) {
      await _deleteQuietly(partial);
      _diagnostics.warning(
        _diagnosticsCategory,
        'clip_decode_failed',
        fields: <String, Object?>{
          'errorType': error.runtimeType.toString(),
          'durationMs': stopwatch.elapsedMilliseconds,
        },
      );
      if (error is AcpAudioClipException) rethrow;
      throw const AcpAudioClipException('The audio clip could not be read.');
    }
    final entry = _CachedClip(target, written);
    _entries[key] = entry;
    _retainedBytes += written;
    _diagnostics.info(
      _diagnosticsCategory,
      'clip_decoded',
      fields: <String, Object?>{
        'bytes': written,
        'durationMs': stopwatch.elapsedMilliseconds,
        'retainedCount': _entries.length,
      },
    );
    return entry;
  }

  void _release(String key) {
    final entry = _entries[key];
    if (entry == null) return;
    entry.leases = math.max(0, entry.leases - 1);
    _evict();
  }

  void _evict() {
    if (_entries.length <= maxFiles && _retainedBytes <= maxBytes) return;
    for (final key in _entries.keys.toList(growable: false)) {
      if (_entries.length <= maxFiles && _retainedBytes <= maxBytes) return;
      final entry = _entries[key]!;
      if (entry.leases > 0) continue;
      _entries.remove(key);
      _retainedBytes -= entry.bytes;
      unawaited(_deleteQuietly(entry.file));
    }
  }

  Future<Directory> _prepareDirectory() async {
    final base = await _baseDirectory();
    final directory = Directory(path.join(base.path, _cacheDirectoryName));
    // Clips from an earlier process are stale; never let them accumulate.
    try {
      if (directory.existsSync()) {
        await directory.delete(recursive: true);
      }
    } on FileSystemException {
      // Best effort: a leftover file only wastes temporary storage.
    }
    await directory.create(recursive: true);
    return directory;
  }

  static int _estimatedDecodedLength(String data) {
    final length = data.length;
    var padding = 0;
    if (data.endsWith('==')) {
      padding = 2;
    } else if (data.endsWith('=')) {
      padding = 1;
    }
    return (length * 3) ~/ 4 - padding;
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (file.existsSync()) {
        await file.delete();
      }
    } on FileSystemException {
      // Best effort; the OS reclaims temporary storage.
    }
  }
}

final class _IOSinkByteSink implements Sink<List<int>> {
  _IOSinkByteSink(this._sink);

  final IOSink _sink;
  int count = 0;

  @override
  void add(List<int> data) {
    count += data.length;
    _sink.add(data);
  }

  @override
  void close() {}
}
