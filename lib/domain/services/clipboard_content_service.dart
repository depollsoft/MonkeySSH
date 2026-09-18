import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Reads Android content-URI clipboard entries via the platform channel.
///
/// The native side handles the `xyz.depollsoft.monkeyssh/clipboard_content`
/// channel and exposes a single `readContentUri` method that accepts a
/// `content://` URI and returns the file name and raw bytes.  This service
/// wraps that channel so the screen widget can be tested without a live
/// platform channel.
class ClipboardContentService {
  /// Creates a [ClipboardContentService] backed by the given [channel].
  ///
  /// The default value uses the production channel name so callers do not need
  /// to specify it in app code.
  const ClipboardContentService({
    MethodChannel channel = const MethodChannel(
      'xyz.depollsoft.monkeyssh/clipboard_content',
    ),
  }) : _channel = channel;

  final MethodChannel _channel;

  /// Reads the content at [uri] and returns its file name and raw bytes.
  ///
  /// Throws a [PlatformException] if the native side returns an unexpected or
  /// incomplete response.
  Future<({String name, Uint8List bytes})> readContentUri(String uri) async {
    final response = await _channel.invokeMethod<Object>('readContentUri', {
      'uri': uri,
    });
    if (response is! Map<Object?, Object?>) {
      throw PlatformException(
        code: 'invalid_clipboard_content',
        message: 'Unexpected clipboard content response',
      );
    }

    final name = response['name'];
    final bytes = response['bytes'];
    if (name is! String || bytes is! Uint8List) {
      throw PlatformException(
        code: 'invalid_clipboard_content',
        message: 'Clipboard content response was incomplete',
      );
    }

    return (name: name, bytes: bytes);
  }
}

/// Provider for [ClipboardContentService].
final clipboardContentServiceProvider = Provider<ClipboardContentService>(
  (ref) => const ClipboardContentService(),
);
