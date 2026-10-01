// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/controllers/system_keyboard_visibility_controller.dart';

const _keyboardVisibilityChannel = MethodChannel(
  'xyz.depollsoft.monkeyssh/keyboard_visibility',
);

/// Answers the native keyboard-visibility channel like a real platform.
///
/// Returns the methods called. `getVisibility` answers [live], which defaults
/// to the visibility last set with `debugSetVisible`.
List<String> mockKeyboardVisibilityChannel(
  WidgetTester tester, {
  FutureOr<bool?> Function()? live,
}) {
  final calls = <String>[];
  final answer =
      live ?? () => SystemKeyboardVisibilityController.instance.visible;
  final messenger = tester.binding.defaultBinaryMessenger
    ..setMockMethodCallHandler(_keyboardVisibilityChannel, (call) async {
      calls.add(call.method);
      return call.method == 'getVisibility' ? answer() : null;
    });
  addTearDown(
    () => messenger.setMockMethodCallHandler(_keyboardVisibilityChannel, null),
  );
  return calls;
}
