import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../models/monetization.dart';

/// Decision produced by [AcpConcurrencyPolicy.evaluate].
@immutable
sealed class AcpConcurrencyDecision {
  const AcpConcurrencyDecision();
}

/// The requested live ACP session may start or continue without any
/// entitlement gating.
@immutable
final class AcpConcurrencyAllowed extends AcpConcurrencyDecision {
  /// Creates an allowed decision.
  const AcpConcurrencyAllowed();
}

/// Starting the requested live ACP session would exceed the free
/// concurrency limit.
///
/// The caller must resolve this by stopping or replacing one of the
/// sessions identified in [blockingSessionKeys] to free capacity, or by
/// unlocking [requiredFeature].
@immutable
final class AcpConcurrencyRequiresChoice extends AcpConcurrencyDecision {
  /// Creates a decision requiring the user to stop/replace a session or
  /// unlock [requiredFeature].
  ///
  /// [blockingSessionKeys] is defensively copied so later mutations to a
  /// caller-owned list can never change this decision after construction.
  AcpConcurrencyRequiresChoice({
    required List<String> blockingSessionKeys,
    this.requiredFeature = MonetizationFeature.concurrentAcpSessions,
  }) : blockingSessionKeys = List.unmodifiable(blockingSessionKeys);

  /// Keys of the currently live sessions that block the requested session.
  final List<String> blockingSessionKeys;

  /// The monetization feature that would unlock this transition.
  final MonetizationFeature requiredFeature;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpConcurrencyRequiresChoice &&
          requiredFeature == other.requiredFeature &&
          const ListEquality<String>().equals(
            blockingSessionKeys,
            other.blockingSessionKeys,
          );

  @override
  int get hashCode => Object.hash(
    requiredFeature,
    const ListEquality<String>().hash(blockingSessionKeys),
  );
}

/// Pure policy describing how many live ACP sessions a free user may keep
/// open at once.
///
/// This policy only decides whether starting or resuming one additional
/// distinct live session is allowed. It intentionally never gates any other
/// ACP capability: custom providers, attachments, rendering, slash commands,
/// and every other part of the ACP experience stay fully available to free
/// users with a single live session.
class AcpConcurrencyPolicy {
  /// Creates a new [AcpConcurrencyPolicy].
  const AcpConcurrencyPolicy();

  /// The number of live ACP sessions a free (non-Pro) user may keep open at
  /// once.
  static const freeConcurrentSessionLimit = 1;

  /// Evaluates whether [candidateSessionKey] may become (or remain) live.
  ///
  /// [currentLiveSessionKeys] identifies every session that is currently
  /// live, keyed however the caller distinguishes one live session from
  /// another (for example, a composite of host, provider, and remote ACP
  /// session ID). Reopening, reattaching, or resuming an already-live
  /// session must pass that same key as [candidateSessionKey] so it is
  /// never double-counted as a second session.
  AcpConcurrencyDecision evaluate({
    required Set<String> currentLiveSessionKeys,
    required String candidateSessionKey,
    required bool isProUnlocked,
  }) {
    if (isProUnlocked || currentLiveSessionKeys.contains(candidateSessionKey)) {
      return const AcpConcurrencyAllowed();
    }

    final otherLiveSessionKeys =
        currentLiveSessionKeys
            .where((key) => key != candidateSessionKey)
            .toList(growable: false)
          ..sort();

    if (otherLiveSessionKeys.length < freeConcurrentSessionLimit) {
      return const AcpConcurrencyAllowed();
    }

    return AcpConcurrencyRequiresChoice(
      blockingSessionKeys: otherLiveSessionKeys,
    );
  }
}
