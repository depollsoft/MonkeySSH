// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _keyboardVisibilityChannel = MethodChannel(
  'xyz.depollsoft.monkeyssh/keyboard_visibility',
);

/// Answers the native keyboard-visibility channel like a real platform.
///
/// Returns the methods called. `getVisibility` answers [live], whose `null`
/// default leaves the visibility set by `debugSetVisible` in place.
List<String> mockKeyboardVisibilityChannel(
  WidgetTester tester, {
  FutureOr<bool?> Function()? live,
}) {
  final calls = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger
    ..setMockMethodCallHandler(_keyboardVisibilityChannel, (call) async {
      calls.add(call.method);
      return call.method == 'getVisibility' ? live?.call() : null;
    });
  addTearDown(
    () => messenger.setMockMethodCallHandler(_keyboardVisibilityChannel, null),
  );
  return calls;
}
