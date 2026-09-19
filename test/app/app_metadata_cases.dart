import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/app_metadata.dart';
import 'package:package_info_plus/package_info_plus.dart';

void registerAppMetadataTests() {
  group('app_metadata', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('appMetadataProvider exposes the platform app name', () async {
      PackageInfo.setMockInitialValues(
        appName: 'MonkeySSH β',
        packageName: 'xyz.depollsoft.monkeyssh.private',
        version: '1.2.3',
        buildNumber: '456',
        buildSignature: '',
      );

      final container = ProviderContainer();
      addTearDown(container.dispose);

      final metadata = await container.read(appMetadataProvider.future);

      expect(metadata.appName, 'MonkeySSH β');
      expect(metadata.versionCodename, 'Baboon');
      expect(metadata.versionLabel, '1.2.3 "Baboon" (456)');
    });
  });
}
