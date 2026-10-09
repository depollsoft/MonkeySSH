/// A prompt did not finish on this device because another device took the
/// chat's input lease.
final class AcpInputHeldElsewhereException implements Exception {
  /// Creates a lease-moved failure.
  const AcpInputHeldElsewhereException({required this.delivered});

  /// Whether the prompt reached the agent before the lease moved. Its turn
  /// then keeps running on the host, where the device that took over sees it,
  /// so the prompt must not be offered for sending again.
  final bool delivered;

  @override
  String toString() => 'AcpInputHeldElsewhereException(delivered: $delivered)';
}
