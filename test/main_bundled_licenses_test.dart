import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/main.dart' as app;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bundled license registry includes both font licenses and ConPTY',
    () async {
      LicenseRegistry.reset();
      addTearDown(LicenseRegistry.reset);
      app.installBundledLicensesForTesting();

      final entries = await LicenseRegistry.licenses.toList();
      const assets = {
        'Microsoft Windows Terminal ConPTY':
            'remote/monkeymux/conpty/LICENSE.microsoft-terminal',
        'Inter': 'assets/fonts/OFL-Inter.txt',
        'JetBrains Mono': 'assets/fonts/OFL-JetBrainsMono.txt',
      };
      expect(entries, hasLength(assets.length));
      for (final asset in assets.entries) {
        final entry = entries.singleWhere(
          (entry) => entry.packages.contains(asset.key),
        );
        expect(entry, isA<LicenseEntryWithLineBreaks>());
        expect(entry.packages, [asset.key]);
        final text = await rootBundle.loadString(asset.value);
        expect(text.trim(), isNotEmpty);
        expect(
          entry.paragraphs.map((paragraph) => paragraph.text),
          LicenseEntryWithLineBreaks([
            asset.key,
          ], text).paragraphs.map((paragraph) => paragraph.text),
        );
        if (asset.key != 'Microsoft Windows Terminal ConPTY') {
          expect(text, contains('SIL OPEN FONT LICENSE Version 1.1'));
        }
      }
    },
  );
}
