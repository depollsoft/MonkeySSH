/// The free-tier concurrency resolution surface for ACP sessions.
///
/// When starting or resuming a live session would exceed the free one-session
/// limit, the session manager returns [AcpSessionLaunchBlocked]. This surface
/// presents the two explicit choices the product allows: stop the blocking
/// live session(s) and continue for free, or unlock Pro to keep both running.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../domain/models/acp_session_keys.dart';
import '../../domain/models/acp_session_state.dart';
import '../../domain/models/monetization.dart';
import '../../domain/services/acp_concurrency_policy.dart';
import '../../domain/services/acp_session_manager.dart';
import '../../domain/services/monetization_service.dart';
import 'acp_session_presentation.dart';

/// The choice a user made in response to a concurrency block.
enum AcpConcurrencyChoice {
  /// Stop the blocking live session(s) and continue for free.
  stopAndContinue,

  /// Unlock Pro for parallel native chats, then retry without replacing.
  upgrade,
}

/// Presents the concurrency resolution sheet for [decision].
///
/// [managerState] is used to describe the blocking session(s) with safe,
/// content-free labels. Returns the chosen resolution, or `null` if dismissed.
Future<AcpConcurrencyChoice?> showAcpConcurrencyChoice(
  BuildContext context, {
  required AcpConcurrencyRequiresChoice decision,
  required AcpSessionManagerState managerState,
  bool allowStopAndContinue = true,
  Future<void>? cancellation,
}) {
  final blocking = decision.blockingSessionKeys
      .map(managerState.byKeyValue)
      .whereType<AcpSessionState>()
      .toList(growable: false);
  final navigator = Navigator.of(context);
  final sheet = showModalBottomSheet<AcpConcurrencyChoice>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => _ConcurrencyChoiceSheet(
      feature: decision.requiredFeature,
      blocking: blocking,
      blockingCount: decision.blockingSessionKeys.length,
      allowStopAndContinue: allowStopAndContinue,
    ),
  );
  if (cancellation == null) return sheet;

  var sheetOpen = true;
  unawaited(
    cancellation.then((_) {
      if (sheetOpen && navigator.mounted && navigator.canPop()) {
        navigator.pop();
      }
    }),
  );
  return sheet.whenComplete(() => sheetOpen = false);
}

/// Resolves a free-tier concurrency block the shared way: offer the choice
/// sheet, then relaunch through [relaunch] with the blocking sessions to
/// replace (stop-and-continue) or none (after a completed Pro unlock).
///
/// Returns `null` when the user dismisses the sheet, leaves the upgrade flow
/// without unlocking, or the owning widget is gone.
Future<AcpSessionLaunchResult?> resolveAcpConcurrencyBlock(
  BuildContext context,
  WidgetRef ref,
  AcpConcurrencyRequiresChoice decision, {
  required Future<AcpSessionLaunchResult?> Function(List<AcpSessionKey> replace)
  relaunch,
  bool allowStopAndContinue = true,
  Future<void>? cancellation,
}) async {
  final manager = ref.read(acpSessionManagerProvider);
  final choice = await showAcpConcurrencyChoice(
    context,
    decision: decision,
    managerState: manager.state,
    allowStopAndContinue: allowStopAndContinue,
    cancellation: cancellation,
  );
  if (choice == null || !context.mounted) {
    return null;
  }
  switch (choice) {
    case AcpConcurrencyChoice.stopAndContinue:
      final blocking = [
        for (final value in decision.blockingSessionKeys)
          manager.state.byKeyValue(value)?.key,
      ].whereType<AcpSessionKey>().toList(growable: false);
      return relaunch(blocking);
    case AcpConcurrencyChoice.upgrade:
      await context.push<void>(
        Uri(
          path: '/upgrade',
          queryParameters: {
            'feature': MonetizationFeature.concurrentAcpSessions.name,
          },
        ).toString(),
      );
      if (!context.mounted ||
          !ref.read(monetizationServiceProvider).currentState.isProUnlocked) {
        return null;
      }
      return relaunch(const <AcpSessionKey>[]);
  }
}

class _ConcurrencyChoiceSheet extends StatelessWidget {
  const _ConcurrencyChoiceSheet({
    required this.feature,
    required this.blocking,
    required this.blockingCount,
    required this.allowStopAndContinue,
  });

  final MonetizationFeature feature;
  final List<AcpSessionState> blocking;
  final int blockingCount;
  final bool allowStopAndContinue;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final label = blockingCount == 1 ? 'session' : 'sessions';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FluttyTheme.spacingLg,
        0,
        FluttyTheme.spacingLg,
        FluttyTheme.spacingLg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'one native chat on free',
            style: FluttyTheme.displayMono(
              fontSize: 18,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: FluttyTheme.spacingSm),
          Text(
            allowStopAndContinue
                ? 'You already have $blockingCount connected native $label. '
                      'Free includes one at a time — stop it to continue, or '
                      'unlock Pro to keep several connected and switch instantly.'
                : 'Free includes one connected native chat at a time. Forking '
                      'keeps the parent connected, so creating a child requires Pro.',
            style: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          if (blocking.isNotEmpty) ...[
            const SizedBox(height: FluttyTheme.spacingMd),
            for (final session in blocking)
              Padding(
                padding: const EdgeInsets.only(bottom: FluttyTheme.spacingXs),
                child: Row(
                  children: [
                    Icon(
                      acpStatusDisplay(session.status).icon,
                      size: 16,
                      color: acpStatusColor(
                        colorScheme,
                        acpStatusDisplay(session.status).tone,
                      ),
                    ),
                    const SizedBox(width: FluttyTheme.spacingSm),
                    Expanded(
                      child: Text(
                        acpSessionDisplayTitle(session),
                        style: FluttyTheme.monoStyle.copyWith(
                          color: colorScheme.onSurface,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: FluttyTheme.spacingLg),
          if (allowStopAndContinue) ...[
            FilledButton.icon(
              onPressed: () =>
                  Navigator.of(context)
                      .pop(AcpConcurrencyChoice.stopAndContinue),
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('Stop and continue free'),
            ),
            const SizedBox(height: FluttyTheme.spacingSm),
          ],
          OutlinedButton.icon(
            onPressed: () =>
                Navigator.of(context).pop(AcpConcurrencyChoice.upgrade),
            icon: const Icon(Icons.workspace_premium_outlined),
            label: const Text('Unlock parallel native chats'),
          ),
          const SizedBox(height: FluttyTheme.spacingSm),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Not now'),
          ),
        ],
      ),
    );
  }
}
