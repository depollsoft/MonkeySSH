import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/services/auth_service.dart';
import '../domain/services/settings_service.dart';

/// Provider for the current clock used by auth lifecycle handling.
final dateTimeNowProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// Provider for auth lifecycle coordination.
final authLifecycleControllerProvider = Provider<AuthLifecycleController>(
  (ref) => AuthLifecycleController(ref, now: ref.watch(dateTimeNowProvider)),
);

/// Coordinates app lifecycle transitions with app locking behavior.
class AuthLifecycleController {
  /// Creates a new [AuthLifecycleController].
  AuthLifecycleController(this._ref, {required DateTime Function() now})
    : _now = now;

  final Ref _ref;
  final DateTime Function() _now;
  DateTime? _backgroundedAt;

  /// Handle an application lifecycle state change.
  Future<void> handleLifecycleStateChanged(AppLifecycleState state) async {
    switch (state) {
      case AppLifecycleState.resumed:
        await _handleForegrounded();
        return;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _handleBackgrounded();
        return;
    }
  }

  void _handleBackgrounded() {
    final timeoutMinutes = _ref.read(autoLockTimeoutNotifierProvider);
    final authState = _ref.read(authStateProvider);

    if (timeoutMinutes <= 0 || authState != AuthState.unlocked) {
      _backgroundedAt = null;
      return;
    }

    _backgroundedAt ??= _now();
  }

  Future<void> _handleForegrounded() async {
    final timeoutMinutes = _ref.read(autoLockTimeoutNotifierProvider);
    final authState = _ref.read(authStateProvider);

    if (timeoutMinutes <= 0 || authState != AuthState.unlocked) {
      _backgroundedAt = null;
      return;
    }

    final backgroundedAt = _backgroundedAt;
    _backgroundedAt = null;
    if (backgroundedAt == null) {
      return;
    }

    final elapsed = _now().difference(backgroundedAt);
    if (elapsed >= Duration(minutes: timeoutMinutes)) {
      _ref.read(authStateProvider.notifier).lockForAutoLock();
    }
  }
}
