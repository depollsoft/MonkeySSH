// ignore_for_file: public_member_api_docs

import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

class FakeWakelockPlusPlatform extends WakelockPlusPlatformInterface {
  final toggleCalls = <bool>[];
  bool _enabled = false;

  @override
  Future<void> toggle({required bool enable}) async {
    _enabled = enable;
    toggleCalls.add(enable);
  }

  @override
  Future<bool> get enabled async => _enabled;
}
