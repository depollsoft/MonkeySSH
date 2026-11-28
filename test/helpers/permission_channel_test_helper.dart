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
