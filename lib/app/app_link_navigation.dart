import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/database/database.dart';
import '../data/repositories/host_repository.dart';
import '../domain/models/app_link.dart';
import '../domain/services/acp_recent_sessions_service.dart';
import '../domain/services/agent_launch_preset_service.dart';
import '../domain/services/app_link_service.dart';
import '../domain/services/auth_service.dart';
import '../domain/services/host_cli_launch_preferences_service.dart';
import '../domain/services/monetization_service.dart';
import '../domain/services/ssh_service.dart';
import '../presentation/widgets/app_link_preset_sheet.dart';
import '../presentation/widgets/connection_attempt_dialog.dart';
import 'app_link_handler.dart';
import 'notification_navigation.dart';
import 'router.dart';

/// Whether [authState] lets an app link navigate. Links received while the
/// app is locked wait behind the PIN or biometric screen.
bool appLinkNavigationAllowed(AuthState authState) =>
    authState == AuthState.notConfigured || authState == AuthState.unlocked;

/// Handles app links once authentication allows navigation.
///
/// Sits above the router so it is listening before the first route is
/// parsed. Links are handled one at a time; a link that arrives while another
/// is still being reviewed replaces any link already waiting behind it.
class AppLinkNavigationBridge extends ConsumerStatefulWidget {
  /// Creates the bridge.
  const AppLinkNavigationBridge({required this.child, super.key});

  /// The app below the bridge.
  final Widget child;

  @override
  ConsumerState<AppLinkNavigationBridge> createState() =>
      _AppLinkNavigationBridgeState();
}

class _AppLinkNavigationBridgeState
    extends ConsumerState<AppLinkNavigationBridge>
    implements AppLinkEffects {
  late final AppLinkService _links;
  ProviderSubscription<AuthState>? _authSubscription;
  late final _scheduler = NotificationNavigationScheduler<AppLink>(
    canNavigate: _canNavigate,
    open: _enqueue,
  );
  AppLink? _next;
  bool _handling = false;

  @override
  void initState() {
    super.initState();
    _links = ref.read(appLinkServiceProvider)..addListener(_takePendingLink);
    _authSubscription = ref.listenManual<AuthState>(authStateProvider, (
      previous,
      next,
    ) {
      if (appLinkNavigationAllowed(next)) {
        _scheduler.flush();
      }
    });
    _links.attachPlatformChannel();
    _takePendingLink();
  }

  @override
  void dispose() {
    _links.removeListener(_takePendingLink);
    _authSubscription?.close();
    super.dispose();
  }

  bool _canNavigate() =>
      mounted && appLinkNavigationAllowed(ref.read(authStateProvider));

  void _takePendingLink() {
    final link = _links.takePending();
    if (link != null) {
      _scheduler.add(link);
    }
  }

  void _enqueue(AppLink link) {
    _next = link;
    if (!_handling) {
      unawaited(_drain());
    }
  }

  Future<void> _drain() async {
    _handling = true;
    try {
      while (mounted) {
        final link = _next;
        if (link == null) break;
        _next = null;
        if (!_canNavigate()) {
          // Locked while an earlier link was being reviewed: hold this one
          // until the user unlocks again.
          _scheduler.add(link);
          break;
        }
        try {
          await _handler().handle(link);
        } on Object catch (error, stackTrace) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stackTrace,
              library: 'app',
              context: ErrorDescription('while handling an app link'),
            ),
          );
        }
      }
    } finally {
      _handling = false;
    }
  }

  AppLinkHandler _handler() => AppLinkHandler(
    hostRepository: ref.read(hostRepositoryProvider),
    recentSessions: ref.read(acpRecentSessionsServiceProvider),
    presetService: ref.read(agentLaunchPresetServiceProvider),
    cliLaunchPreferences: ref.read(hostCliLaunchPreferencesServiceProvider),
    monetization: ref.read(monetizationServiceProvider),
    effects: this,
  );

  GoRouter get _router => ref.read(routerProvider);

  BuildContext? get _navigatorContext => appNavigatorKey.currentContext;

  @override
  void openTerminal(String location) {
    if (!_canNavigate()) return;
    final router = _router..go(buildTmuxAlertHomeLocation());
    unawaited(router.push<void>(location));
  }

  @override
  void openNewHostForm(String sshUrl) {
    if (!_canNavigate()) return;
    final router = _router..go('/');
    unawaited(router.push<void>(buildAppLinkHostFormLocation(sshUrl)));
  }

  @override
  void showMessage(String message) {
    final context = _navigatorContext;
    if (!_canNavigate() || context == null) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Future<bool> confirmPresetLaunch(AppLinkPresetReview review) async {
    final context = _navigatorContext;
    if (!_canNavigate() || context == null) return false;
    final confirmed = await showAppLinkPresetSheet(context, review);
    // The sheet closes when the app locks; never act on a stale answer.
    return confirmed && _canNavigate();
  }

  @override
  Future<bool> launchPreset(Host host) async {
    final context = _navigatorContext;
    if (!_canNavigate() || context == null) return false;
    // The review sheet showed only the agent command, so open-port detection
    // waits for the terminal's Start action like any link-opened connection.
    ref
        .read(activeSessionsProvider.notifier)
        .holdAutomaticForwardingUntilStarted(host.id);
    final result = await connectToHostWithProgressDialog(context, ref, host);
    final connectionId = result.connectionId;
    if (!result.success || connectionId == null || !_canNavigate()) {
      return false;
    }
    // No link marker: the user just reviewed the preset, so the new
    // connection's auto-connect runs it without asking again, and starts
    // its agent in a new window if its workspace is already running.
    openTerminal(
      Uri(
        path: '/terminal/${host.id}',
        queryParameters: <String, String>{
          'connectionId': '$connectionId',
          appLinkPresetRunQueryKey: '1',
        },
      ).toString(),
    );
    return true;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
