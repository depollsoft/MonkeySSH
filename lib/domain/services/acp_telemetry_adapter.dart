import 'dart:async';

import 'package:collection/collection.dart';

import '../models/acp_provider.dart';
import 'acp_telemetry.dart';
import 'telemetry_service.dart';

/// Adapts [AcpTelemetrySink] calls from the ACP session manager onto the
/// shared, privacy-preserving [TelemetryService].
///
/// This is the only place a raw ACP provider ID is mapped down to a coarse,
/// allowlisted category before it ever reaches telemetry: built-in providers
/// map to their [AcpBuiltinProvider.telemetryCategory] and any other id
/// collapses to `unknown`, so a raw id is never sent.
final class AcpTelemetryAdapter implements AcpTelemetrySink {
  /// Creates an adapter over [telemetryService].
  const AcpTelemetryAdapter(this._telemetryService);

  final TelemetryService _telemetryService;

  @override
  void featureOpened() {
    unawaited(_telemetryService.logFeatureOpened(feature: 'agents'));
  }

  @override
  void sessionOpened({
    required String providerCategory,
    required bool isReconnect,
  }) {
    unawaited(
      _telemetryService.logAcpSessionOpened(
        providerCategory: _providerCategory(providerCategory),
        isReconnect: isReconnect,
      ),
    );
  }

  @override
  void sessionEnded({required String reason}) {
    unawaited(_telemetryService.logAcpSessionEnded(reason: reason));
  }

  @override
  void reconnectOutcome({required bool succeeded, String? failureCategory}) {
    unawaited(
      _telemetryService.logAcpReconnectOutcome(
        succeeded: succeeded,
        failureCategory: failureCategory,
      ),
    );
  }

  @override
  void attachmentSent({required String category, required int count}) {
    unawaited(
      _telemetryService.logAcpAttachmentSent(category: category, count: count),
    );
  }

  @override
  void permissionOutcome({required String outcome}) {
    unawaited(_telemetryService.logAcpPermissionOutcome(outcome: outcome));
  }

  @override
  void failure({required String category}) {
    unawaited(_telemetryService.logAcpFailure(category: category));
  }

  static String _providerCategory(String providerId) =>
      acpBuiltinProviders
          .firstWhereOrNull((provider) => provider.id == providerId)
          ?.telemetryCategory ??
      'unknown';
}
