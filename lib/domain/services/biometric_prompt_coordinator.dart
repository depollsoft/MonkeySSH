import 'dart:async';

import 'package:flutter/widgets.dart';

/// Keeps the app's biometric prompts from overlapping.
///
/// On Android every androidx `BiometricPrompt` on an activity shares one view
/// model, so a second prompt replaces the first one's callback and the first
/// caller never hears back. The app lock (through local_auth) and hardware key
/// signing therefore run their prompts through [run] one at a time. Hardware
/// key prompts also wait until the app lock is gone, so a reconnect on resume
/// never stacks a key prompt on the lock screen.
class BiometricPromptCoordinator {
  /// Creates a coordinator; the app uses [instance].
  ///
  /// [isAppInForeground] defaults to the Flutter lifecycle state.
  BiometricPromptCoordinator({bool Function()? isAppInForeground})
    : _isAppInForeground = isAppInForeground ?? _lifecycleIsForeground;

  /// The coordinator shared by the app lock and hardware key signing.
  static final instance = BiometricPromptCoordinator();

  final bool Function() _isAppInForeground;
  Future<void> _tail = Future<void>.value();
  bool _appLocked = false;
  Completer<void>? _unlocked;

  /// Whether the app lock is showing.
  bool get isAppLocked => _appLocked;

  /// Whether the app is on screen, so the user could answer a prompt.
  bool get isAppInForeground => _isAppInForeground();

  static bool _lifecycleIsForeground() {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  /// Records whether the app lock is showing.
  void setAppLocked({required bool locked}) {
    _appLocked = locked;
    if (!locked) {
      _unlocked?.complete();
      _unlocked = null;
    }
  }

  /// Completes once the app lock is gone.
  Future<void> waitUntilAppUnlocked() async {
    while (_appLocked) {
      await (_unlocked ??= Completer<void>()).future;
    }
  }

  /// Runs [prompt] after every prompt queued before it has finished.
  Future<T> run<T>(Future<T> Function() prompt) {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return () async {
      await previous;
      try {
        return await prompt();
      } finally {
        done.complete();
      }
    }();
  }
}
