// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/terminal_wake_lock_service.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import '../../helpers/fake_wakelock_plus_platform.dart';

void main() {
  late WakelockPlusPlatformInterface originalWakelockPlatform;
  late FakeWakelockPlusPlatform wakelockPlatform;
  late TerminalWakeLockService service;

  setUp(() {
    originalWakelockPlatform = wakelockPlusPlatformInstance;
    wakelockPlatform = FakeWakelockPlusPlatform();
    wakelockPlusPlatformInstance = wakelockPlatform;
    service = TerminalWakeLockService();
  });

  tearDown(() {
    wakelockPlusPlatformInstance = originalWakelockPlatform;
  });

  test('keeps wake lock enabled while any owner remains active', () async {
    final firstOwnerId = service.createOwner();
    final secondOwnerId = service.createOwner();

    await service.setOwnerActive(firstOwnerId, active: true);
    await service.setOwnerActive(secondOwnerId, active: true);
    await service.releaseOwner(firstOwnerId);

    expect(wakelockPlatform.toggleCalls, [true]);

    await service.releaseOwner(secondOwnerId);

    expect(wakelockPlatform.toggleCalls, [true, false]);
  });
}
