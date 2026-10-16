import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void registerSocksBrowserWebKitStartTests() {
  group('socks_browser_webkit_start', () {
    // These class methods don't start WebKit. As a launch's first WebKit
    // call (the store purge, or deleting a host) they crash the app, so each
    // call must start WebKit right before it.
    test('ios starts WebKit before listing or deleting data stores', () {
      final lines = File('ios/Runner/SocksBrowserProxyChannel.swift')
          .readAsLinesSync()
          .map((line) => line.trim())
          .toList();
      const calls = [
        'WKWebsiteDataStore.fetchAllDataStoreIdentifiers',
        'WKWebsiteDataStore.remove(forIdentifier:',
      ];

      for (final call in calls) {
        final index = lines.indexWhere((line) => line.startsWith(call));
        expect(index, greaterThan(0), reason: call);
        expect(lines[index - 1], 'Self.startWebKit()', reason: call);
      }
      final start = lines.indexOf('private static func startWebKit() {');
      expect(start, isNot(-1));
      expect(lines[start + 1], '_ = WKWebsiteDataStore.default()');
    });
  });
}
