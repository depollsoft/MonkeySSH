import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_link.dart';
import 'diagnostics_log_service.dart';

/// Receives `monkeyssh://` and `ssh://` links from the platform and holds the
/// latest one until the app may navigate.
///
/// iOS delivers links through Flutter's deep-linking route channel, which the
/// router hands to [receive]. Android runs a cached Flutter engine that never
/// sees the intent that launched the activity, so it delivers links through
/// [channelName] instead: the activity keeps the newest link and signals
/// `linkAvailable`, and Dart pulls it with `consumePendingLink` so each link
/// is delivered once however the signal and the startup pull interleave.
class AppLinkService extends ChangeNotifier {
  /// Creates an app link service.
  AppLinkService({MethodChannel? channel, DiagnosticsLogger? diagnostics})
    : _channel = channel ?? const MethodChannel(channelName),
      _diagnostics = diagnostics ?? DiagnosticsLogService.instance;

  /// Platform channel used by the Android activity.
  static const channelName = 'xyz.depollsoft.monkeyssh/app_links';

  final MethodChannel _channel;
  final DiagnosticsLogger _diagnostics;
  AppLink? _pending;
  bool _platformChannelAttached = false;

  /// Whether a received link is waiting to be handled.
  bool get hasPending => _pending != null;

  /// Parses and queues [uri], replacing any link not yet handled.
  void receive(Uri uri) => _queue(parseAppLink(uri));

  /// Parses and queues raw link text, replacing any link not yet handled.
  void receiveString(String raw) => _queue(parseAppLinkString(raw));

  /// Returns and clears the pending link, if any.
  AppLink? takePending() {
    final link = _pending;
    _pending = null;
    return link;
  }

  /// Starts receiving links from the Android activity and pulls the link
  /// that launched the app, if any. Safe to call more than once.
  void attachPlatformChannel() {
    if (_platformChannelAttached) {
      return;
    }
    _platformChannelAttached = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'linkAvailable') {
        await consumePlatformLink();
      }
    });
    unawaited(consumePlatformLink());
  }

  /// Pulls the newest link held by the platform, if any.
  @visibleForTesting
  Future<void> consumePlatformLink() async {
    final String? raw;
    try {
      raw = await _channel.invokeMethod<String>('consumePendingLink');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
    if (raw == null || raw.isEmpty) {
      return;
    }
    receiveString(raw);
  }

  void _queue(AppLink link) {
    _diagnostics.info(
      'app_link',
      'received',
      fields: {
        'action': link.diagnosticsAction,
        if (link case RejectedAppLink(:final reason)) 'reason': reason.name,
        'replacedPending': _pending != null,
      },
    );
    _pending = link;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_platformChannelAttached) {
      _channel.setMethodCallHandler(null);
    }
    super.dispose();
  }
}

/// Provider for the app-wide [AppLinkService].
final appLinkServiceProvider = Provider<AppLinkService>((ref) {
  final service = AppLinkService();
  ref.onDispose(service.dispose);
  return service;
});
