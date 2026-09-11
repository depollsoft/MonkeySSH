import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// OSC 52 clipboard sharing between local and remote terminals.
///
/// OSC 52 is the standard terminal escape sequence for clipboard
/// synchronisation. The remote process sends
/// `ESC ] 52 ; <target> ; <base64-data> ST` to set the local clipboard, or
/// `ESC ] 52 ; <target> ; ? ST` to query it.
///
/// This service handles both directions:
///
///  * **Remote → Local** – decodes the base64 payload and writes to the
///    system clipboard.
///  * **Local → Remote** – reads the system clipboard, base64-encodes it, and
///    returns an OSC 52 response for the caller to send back through the shell.
class ClipboardSharingService {
  /// Creates a new [ClipboardSharingService].
  const ClipboardSharingService();

  /// The OSC code for clipboard operations.
  static const oscCode = '52';

  /// Maximum payload size (in decoded bytes) we accept from the remote.
  ///
  /// Prevents a malicious server from flooding the clipboard with huge data.
  static const maxPayloadBytes = 1024 * 1024; // 1 MiB

  /// Upper bound on the encoded (base64) length before we attempt to decode.
  ///
  /// Base64 encodes 3 bytes into 4 characters, so the encoded ceiling is
  /// `maxPayloadBytes * 4 / 3` rounded up, plus a small margin for padding.
  static const maxEncodedLength = (maxPayloadBytes * 4 ~/ 3) + 4;

  /// Handles an incoming OSC 52 sequence from the remote terminal.
  ///
  /// [args] is the list produced by xterm's OSC parser, split on `;`.
  /// For `ESC ] 52 ; c ; <base64> ST` this is `['c', '<base64>']`.
  /// For a query `ESC ] 52 ; c ; ? ST` this is `['c', '?']`.
  ///
  /// Returns an OSC 52 response string to send back through the shell when
  /// the remote queries the clipboard, or `null` when no response is needed.
  Future<String?> handleOsc52(
    List<String> args, {
    required bool allowLocalClipboardRead,
  }) async {
    try {
      final parsed = parseOsc52Args(args);
      if (parsed == null) return null;

      final (target, payload) = parsed;

      if (payload == '?') {
        if (!allowLocalClipboardRead) return null;
        return await _handleQuery(target);
      }

      await _handleSet(payload);
    } on PlatformException catch (e) {
      if (kDebugMode) {
        debugPrint('OSC 52 clipboard operation failed: $e');
      }
    }
    return null;
  }

  /// Parses OSC 52 arguments into (target, payload).
  ///
  /// Returns `null` if the arguments are malformed.
  static (String target, String payload)? parseOsc52Args(List<String> args) {
    if (args.isEmpty) return null;

    // Some terminals send the target and payload as a single semicolon-
    // delimited string (e.g. `['c;SGVsbG8=']`), while xterm's parser already
    // splits them into separate list elements (`['c', 'SGVsbG8=']`).
    if (args.length == 1) {
      final parts = args[0].split(';');
      if (parts.length < 2) return null;
      return (parts[0], parts.sublist(1).join(';'));
    }

    return (args[0], args.sublist(1).join(';'));
  }

  /// Decodes and validates an OSC 52 base64 payload.
  ///
  /// Returns the decoded text, or `null` if the payload is invalid or too
  /// large. Rejects encoded strings that exceed [maxEncodedLength] before
  /// allocating memory for the decode.
  static String? decodePayload(String base64Payload) {
    if (base64Payload.length > maxEncodedLength) return null;
    try {
      final bytes = base64Decode(base64Payload);
      if (bytes.length > maxPayloadBytes) return null;
      return utf8.decode(bytes, allowMalformed: true);
    } on FormatException {
      return null;
    }
  }

  /// Encodes a text string as a base64 OSC 52 payload.
  static String encodePayload(String text) => base64Encode(utf8.encode(text));

  /// Builds a complete OSC 52 response string.
  ///
  /// The response uses BEL (`\x07`) as the string terminator for maximum
  /// compatibility.
  static String buildOsc52Response(String target, String base64Data) =>
      '\x1b]52;$target;$base64Data\x07';

  Future<String?> _handleQuery(String target) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) {
      return buildOsc52Response(target, '');
    }
    // Enforce the same size limit on outbound responses.
    final encoded = utf8.encode(text);
    if (encoded.length > maxPayloadBytes) return null;
    return buildOsc52Response(target, base64Encode(encoded));
  }

  Future<void> _handleSet(String base64Payload) async {
    // An empty payload clears the clipboard.
    if (base64Payload.isEmpty) {
      await Clipboard.setData(const ClipboardData(text: ''));
      return;
    }

    final text = decodePayload(base64Payload);
    if (text == null) return;

    await Clipboard.setData(ClipboardData(text: text));
  }
}
