// ignore_for_file: public_member_api_docs

import 'dart:convert' show utf8;
import 'dart:io' show File, gzip;

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';

/// Reads `monkeyMuxVersion` from the MonkeyMux helper source.
String _compiledMonkeyMuxVersion() {
  final source = File('remote/monkeymux/main.go').readAsStringSync();
  final match = RegExp(
    r'^\s*monkeyMuxVersion\s*=\s*"([^"]+)"',
    multiLine: true,
  ).firstMatch(source);
  expect(
    match,
    isNotNull,
    reason: 'monkeyMuxVersion not found in remote/monkeymux/main.go',
  );
  return match!.group(1)!;
}

bool _containsBytes(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || needle.length > haystack.length) {
    return false;
  }
  for (var start = 0; start <= haystack.length - needle.length; start++) {
    var matched = true;
    for (var offset = 0; offset < needle.length; offset++) {
      if (haystack[start + offset] != needle[offset]) {
        matched = false;
        break;
      }
    }
    if (matched) {
      return true;
    }
  }
  return false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled MonkeyMux assets match the manifest', () async {
    final manifest = await MonkeyMuxManifest.load();

    expect(manifest.entries, isNotEmpty);
    for (final entry in manifest.entries) {
      final bytes = await rootBundle.load(entry.asset);
      final assetBytes = bytes.buffer.asUint8List(
        bytes.offsetInBytes,
        bytes.lengthInBytes,
      );
      final binaryBytes = switch (entry.encoding) {
        null || '' || 'none' => assetBytes,
        'gzip' => Uint8List.fromList(gzip.decode(assetBytes)),
        final encoding => throw StateError(
          'Unsupported MonkeyMux asset encoding: $encoding',
        ),
      };

      expect(entry.encoding, 'gzip', reason: entry.asset);
      expect(entry.asset, endsWith('.gz'));
      expect(binaryBytes.length, entry.size, reason: entry.asset);
      expect(sha256.convert(binaryBytes).toString(), entry.sha256);
    }
  });

  // The helper only restarts a running server when the running version differs
  // from its compiled `monkeyMuxVersion`, while the app decides whether to
  // offer "update and restore" from the manifest version. When those drift the
  // app offers an update that the helper treats as a no-op, so the prompt
  // reappears on every connect and never applies.
  test('manifest version matches the compiled MonkeyMux helper version', () async {
    final manifest = await MonkeyMuxManifest.load();

    expect(
      manifest.version,
      _compiledMonkeyMuxVersion(),
      reason:
          'assets/monkeymux/manifest.json is out of step with monkeyMuxVersion '
          'in remote/monkeymux/main.go. Bump monkeyMuxVersion and rebuild with '
          'scripts/build_monkeymux_assets.sh.',
    );
  });

  test('bundled MonkeyMux binaries report the manifest version', () async {
    final manifest = await MonkeyMuxManifest.load();
    final versionBytes = utf8.encode(manifest.version);

    expect(manifest.entries, isNotEmpty);
    for (final entry in manifest.entries) {
      final bytes = await rootBundle.load(entry.asset);
      final binaryBytes = gzip.decode(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );

      expect(
        _containsBytes(binaryBytes, versionBytes),
        isTrue,
        reason:
            '${entry.asset} does not embed manifest version '
            '${manifest.version}. Rebuild the assets with '
            'scripts/build_monkeymux_assets.sh after bumping monkeyMuxVersion.',
      );
    }
  });
}
