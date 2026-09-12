import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/agent_launch_preset.dart';
import '../../domain/models/agent_usage.dart';
import '../../domain/models/agent_usage_rings.dart';
import '../../domain/models/monetization.dart';
import '../../domain/services/agent_management_service.dart';
import '../../domain/services/monetization_service.dart';
import '../../domain/services/settings_service.dart';
import '../../domain/services/ssh_service.dart';

/// Session identity, rather than only connection ID, prevents reconnect reuse.
typedef AgentUsageRingRequest = ({SshSession session, AgentLaunchTool tool});

/// Clock used for reset boundaries and snapshot freshness.
final agentUsageRingsClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// Pro entitlement and the loaded, persisted preference must both allow checks.
final agentUsageRingsEnabledProvider = Provider<bool>((ref) {
  final access =
      ref.watch(monetizationStateProvider).asData?.value ??
      ref.watch(monetizationServiceProvider).currentState;
  return access.allowsFeature(MonetizationFeature.agentUsageRings) &&
      (ref.watch(showUsageRingsProvider).asData?.value ?? false);
});

/// Shared, visible-subscriber-only refresh of the current agent's account quotas.
/// The icon subscribes only while its route, ticker, and app are active.
final agentUsageRingsProvider = StreamProvider.autoDispose
    .family<AgentUsageRings?, AgentUsageRingRequest>((ref, request) {
      if (!supportsAgentUsageRings(request.tool) ||
          !ref.watch(agentUsageRingsEnabledProvider) ||
          ref.watch(
                activeSessionsProvider.select(
                  (states) => states[request.session.connectionId],
                ),
              ) !=
              SshConnectionState.connected) {
        return Stream.value(null);
      }

      final service = ref.watch(agentManagementServiceProvider);
      final now = ref.watch(agentUsageRingsClockProvider);
      final controller = StreamController<AgentUsageRings?>();
      Timer? timer;
      Timer? expiryTimer;
      var expiryRevision = 0;
      var disposed = false;
      var revision = 0;
      AppLifecycleListener? lifecycle;
      AgentUsage? previous;
      bool foreground() =>
          WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      ref.onDispose(() {
        disposed = true;
        timer?.cancel();
        expiryTimer?.cancel();
        lifecycle?.dispose();
        unawaited(controller.close());
      });

      void publish(AgentUsage? usage) {
        expiryTimer?.cancel();
        final token = ++expiryRevision;
        if (disposed || !foreground()) return;
        final time = now();
        final rings = resolveAgentUsageRings(request.tool, usage, now: time);
        controller.add(rings);
        if (rings == null || usage == null || usage.checkedAt == null) return;
        var deadline = usage.checkedAt!.add(
          agentUsageSnapshotMaxAge(request.tool),
        );
        for (final window in usage.windows) {
          if (!isAgentUsageRingWindow(request.tool, window)) continue;
          final reset = window.resetsAt;
          if (reset != null &&
              reset.isAfter(time) &&
              reset.isBefore(deadline)) {
            deadline = reset;
          }
        }
        // Expiry is presentation-only. A blocked read must neither extend a
        // snapshot's lifetime nor cause an extra quota request at this deadline.
        expiryTimer = Timer(deadline.difference(time), () {
          if (!disposed && token == expiryRevision) publish(usage);
        });
      }

      Future<void> refresh() async {
        if (disposed || !foreground()) return;
        final generation = ++revision;
        bool current() =>
            !disposed && ref.mounted && generation == revision && foreground();
        publish(previous);
        AgentUsage? usage;
        try {
          usage = await service.readUsageForTool(
            request.session,
            request.tool,
            shouldContinue: current,
          );
        } on Object {
          // Usage is best-effort. No raw errors or user metadata are logged.
        }
        if (!current()) return;
        previous = usage;
        publish(usage);
        var delay = agentUsageRefreshInterval(request.tool);
        final checkedAt = usage?.checkedAt;
        final throttled = usage?.isRateLimited ?? false;
        if (throttled) {
          final fallback = (checkedAt ?? now()).add(
            agentUsageThrottleBackoff(1),
          );
          final retryAt = usage?.retryAt;
          final deadline = retryAt != null && retryAt.isAfter(fallback)
              ? retryAt
              : fallback;
          final wait = deadline.difference(now());
          delay = wait > Duration.zero ? wait : agentUsageThrottleBackoff(1);
        } else if (checkedAt != null) {
          final expiry = checkedAt.add(delay).difference(now());
          if (expiry > Duration.zero && expiry < delay) delay = expiry;
        }
        if (!throttled) {
          for (final window in usage?.windows ?? <AgentUsageWindow>[]) {
            if (!isAgentUsageRingWindow(request.tool, window)) continue;
            final reset = window.resetsAt?.difference(now());
            if (reset != null && reset > Duration.zero && reset < delay) {
              delay = reset;
            }
          }
        }
        // Never spin on an elapsed reset or a failed provider.
        timer = Timer(
          delay < const Duration(seconds: 1)
              ? const Duration(seconds: 1)
              : delay,
          refresh,
        );
      }

      // Cancel directly from lifecycle notifications: paused apps cannot rebuild
      // the icon to unsubscribe, so a build-only guard would keep polling.
      lifecycle = AppLifecycleListener(
        onStateChange: (state) {
          if (disposed) return;
          revision++;
          expiryRevision++;
          timer?.cancel();
          expiryTimer?.cancel();
          if (state == AppLifecycleState.resumed) unawaited(refresh());
        },
      );
      unawaited(refresh());
      return controller.stream;
    });
