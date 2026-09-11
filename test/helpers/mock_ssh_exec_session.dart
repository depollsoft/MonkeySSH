import 'package:dartssh2/dartssh2.dart';
import 'package:dartssh2/src/ssh_channel.dart';
import 'package:mocktail/mocktail.dart';

/// Models both graceful session close and forced underlying channel cleanup.
class MockSessionWithChannel extends Mock implements SSHSession {
  @override
  final channel = MockUnderlyingSshChannel();
}

/// Allows tests to assert CHANNEL_CLOSE cleanup independently of stdin EOF.
class MockUnderlyingSshChannel extends Mock implements SSHChannel {}
