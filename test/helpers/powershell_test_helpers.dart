import 'dart:convert';
import 'dart:io';

/// Decodes an encoded PowerShell command independently of production encoding.
/// Handles both the plain `-EncodedCommand` form and the gzip-compressed
/// `FromBase64String('...')` form. Commands without an encoded script are
/// returned unchanged.
String decodeEncodedPowerShell(String command) {
  final compressed = RegExp(
    r"FromBase64String\('([^']+)'\)",
  ).firstMatch(command);
  if (compressed != null) {
    return utf8.decode(gzip.decode(base64.decode(compressed[1]!)));
  }
  const marker = '-EncodedCommand ';
  final index = command.indexOf(marker);
  if (index < 0) return command;
  final bytes = base64.decode(command.substring(index + marker.length).trim());
  final buffer = StringBuffer();
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    buffer.writeCharCode(bytes[i] | (bytes[i + 1] << 8));
  }
  return buffer.toString();
}
