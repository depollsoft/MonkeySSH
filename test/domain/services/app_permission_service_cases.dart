// ignore_for_file: public_member_api_docs

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/app_permission_service.dart';

const _channel = MethodChannel(AppPermissionService.channelName);

/// Answers the permissions channel with [reply] and records every call.
List<MethodCall> answerPermissionChannel(
  Future<Object?> Function(MethodCall call) reply,
) {
  final calls = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) {
        calls.add(call);
        return reply(call);
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null),
  );
  return calls;
}

void registerAppPermissionServiceTests() {
  group('AppPermissionService', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    for (final permission in AppPermission.values) {
      for (final status in AppPermissionStatus.values) {
        test('reports ${status.name} for ${permission.name}', () async {
          final calls = answerPermissionChannel((_) async => status.name);

          final result = await const AppPermissionService().request(permission);

          expect(result, status);
          expect(result.isGranted, status == AppPermissionStatus.granted);
          expect(
            result.isPermanentlyDenied,
            status == AppPermissionStatus.permanentlyDenied,
          );
          expect(calls, hasLength(1));
          expect(calls.single.method, 'request');
          expect(calls.single.arguments, permission.name);
        });
      }
    }

    for (final reply in <Object?>[null, 'limited', 'GRANTED', 1]) {
      test('reads an unrecognised status ($reply) as denied', () async {
        answerPermissionChannel((_) async => reply);

        expect(
          await const AppPermissionService().request(AppPermission.camera),
          AppPermissionStatus.denied,
        );
      });
    }

    test('surfaces platform errors to the caller', () async {
      answerPermissionChannel(
        (_) async => throw PlatformException(code: 'invalid_args'),
      );

      await expectLater(
        const AppPermissionService().request(AppPermission.microphone),
        throwsA(isA<PlatformException>()),
      );
    });

    test('throws MissingPluginException where no handler exists', () async {
      await expectLater(
        const AppPermissionService().request(AppPermission.locationWhenInUse),
        throwsA(isA<MissingPluginException>()),
      );
    });

    for (final (reply, expected) in [
      (true, true),
      (false, false),
      (null, false),
    ]) {
      test(
        'openAppSettings returns $expected when the OS answers $reply',
        () async {
          final calls = answerPermissionChannel((_) async => reply);

          expect(
            await const AppPermissionService().openAppSettings(),
            expected,
          );
          expect(calls.single.method, 'openAppSettings');
          expect(calls.single.arguments, isNull);
        },
      );
    }
  });
}
