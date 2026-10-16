/// Whether a prompt reached the agent before this device lost the input.
enum AcpInputDelivery {
  /// The bridge took the prompt and passed it to the agent.
  delivered,

  /// The prompt never left this device, or the bridge dropped it because
  /// another device already held the input.
  notSent,

  /// The prompt was written to a connection that later dropped, so this
  /// device cannot tell whether the bridge received it.
  unknown,
}

/// A prompt did not finish on this device because another device took the
/// chat's input lease.
final class AcpInputHeldElsewhereException implements Exception {
  /// Creates a lease-moved failure.
  const AcpInputHeldElsewhereException({required this.delivery});

  /// Whether the prompt reached the agent before the lease moved.
  final AcpInputDelivery delivery;

  /// Whether the prompt reached the agent. Its turn then keeps running on the
  /// host, where the device that took over sees it, so the prompt must not be
  /// offered for sending again.
  bool get delivered => delivery == AcpInputDelivery.delivered;

  @override
  String toString() => 'AcpInputHeldElsewhereException(${delivery.name})';
}
