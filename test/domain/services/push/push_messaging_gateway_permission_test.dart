import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/app_permission_service.dart';
import 'package:monkeyssh/domain/services/push/push_messaging_gateway.dart';

import '../app_permission_service_cases.dart' show answerPermissionChannel;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    group('FirebasePushMessagingGateway.requestPermission on $platform', () {
      setUp(() => debugDefaultTargetPlatformOverride = platform);
      tearDown(() => debugDefaultTargetPlatformOverride = null);

      for (final status in AppPermissionStatus.values) {
        test('reads ${status.name} from the permissions channel', () async {
          final calls = answerPermissionChannel((_) async => status.name);

          expect(
            await FirebasePushMessagingGateway().requestPermission(),
            status.isGranted,
          );
          expect(calls.map((call) => (call.method, call.arguments)), [
            ('request', AppPermission.notifications.name),
          ]);
        });
      }

      test('surfaces a failed request', () async {
        answerPermissionChannel(
          (_) async => throw PlatformException(code: 'invalid_args'),
        );

        await expectLater(
          FirebasePushMessagingGateway().requestPermission(),
          throwsA(isA<PlatformException>()),
        );
      });
    });
  }
}
