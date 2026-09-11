import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Source guards follow the neighbouring platform-configuration tests. They
// protect lifecycle ordering but do not replace Android device lifecycle tests.
const _nativeRoot = 'android/app/src/main/kotlin/xyz/depollsoft/monkeyssh';

String _body(String source, String name) {
  final declaration = RegExp(
    'fun $name\\s*\\([^{}]*\\)[^{}]*\\{',
  ).firstMatch(source);
  expect(declaration, isNotNull, reason: 'Missing Kotlin function $name');
  final start = declaration!.end;
  var depth = 1;
  for (var index = start; index < source.length; index++) {
    if (source[index] == '{') depth++;
    if (source[index] == '}') {
      depth--;
      if (depth == 0) return source.substring(start, index);
    }
  }
  throw StateError('Unclosed Kotlin function $name');
}

void main() {
  final service = File(
    '$_nativeRoot/SshConnectionService.kt',
  ).readAsStringSync();
  final activity = File('$_nativeRoot/MainActivity.kt').readAsStringSync();
  final channel = File(
    '$_nativeRoot/SshServiceChannelHandler.kt',
  ).readAsStringSync();

  test(
    'bf0aa132/0055b556: every delivered intent promotes before branching',
    () {
      final start = _body(service, 'onStartCommand').trimLeft();
      expect(start, startsWith('if (!promoteImmediately())'));
      final promote = _body(service, 'promoteImmediately');
      expect(
        promote,
        contains('startForeground(NOTIFICATION_ID, startupNotification)'),
      );
      expect(promote, isNot(contains('presentableStatus')));
      expect(promote, isNot(contains('hasNotificationPermission')));
      expect(
        start.indexOf('promoteImmediately()'),
        lessThan(start.indexOf('ACTION_STOP')),
      );
      expect(_body(service, 'onCreate'), contains('promoteImmediately()'));
    },
  );

  test(
    'bf0aa132/0055b556: notification rendering follows promotion with fallback',
    () {
      final create = _body(service, 'onCreate');
      expect(create, isNot(contains('buildNotification(')));
      expect(create, isNot(contains('PendingIntent.')));
      final refresh = _body(service, 'refreshPresentation');
      expect(refresh, contains('catch (error: RuntimeException)'));
      expect(refresh, contains('startupNotification'));
      expect(service, isNot(contains('getLaunchIntentForPackage')));
    },
  );

  test(
    'bf0aa132/0055b556: late Dart updates cannot start a new background service',
    () {
      final sync = _body(service, 'syncServiceState');
      expect(
        sync.indexOf('!isActivityVisible'),
        lessThan(sync.indexOf('ContextCompat.startForegroundService')),
      );
      expect(sync, contains('catch (error: IllegalStateException)'));
      expect(sync, contains('if (startRequested) return'));
      expect(
        _body(service, 'promoteImmediately'),
        contains('error is ForegroundServiceStartNotAllowedException'),
      );
      final pause = _body(activity, 'onPause');
      expect(
        pause.indexOf('setForegroundState(applicationContext, false)'),
        lessThan(pause.indexOf('super.onPause()')),
      );
      expect(_body(activity, 'onStop'), contains('setActivityVisible(false)'));
      expect(
        channel,
        isNot(contains('SshConnectionService.setForegroundState')),
      );
      expect(
        channel,
        contains('SshConnectionService.refresh(applicationContext)'),
      );
      expect(
        _body(channel, 'resumedActivity'),
        contains('Lifecycle.State.RESUMED'),
      );
      expect(
        channel,
        contains('resumedActivity()?.ensureNotificationPermission()'),
      );
    },
  );

  test('320a5e10: live service stops directly before cleanup', () {
    final stop = _body(service, 'stopServiceUnlessStarting');
    expect(
      stop.indexOf('it.stopImmediately()'),
      lessThan(stop.indexOf('!startRequested')),
    );
    final immediate = _body(service, 'stopImmediately');
    expect(
      immediate.indexOf('stopForeground(STOP_FOREGROUND_REMOVE)'),
      lessThan(immediate.indexOf('stopSelf()')),
    );
    expect(
      immediate.indexOf('stopSelf()'),
      lessThan(immediate.indexOf('hidePresentation()')),
    );
    expect(
      _body(service, 'stopAfterForegroundServiceTimeout'),
      contains('stopImmediately()'),
    );
    expect(
      RegExp(
        r'stopAfterForegroundServiceTimeout\(\)',
      ).allMatches(service).length,
      3,
    );
    expect(
      _body(service, 'onMain'),
      contains('Looper.myLooper() == Looper.getMainLooper()'),
    );
    expect(_body(service, 'onMain'), contains('mainHandler.post'));
  });

  test(
    'd6046c28/7487bf9a: optional notification work cannot delay service callbacks',
    () {
      expect(service, isNot(contains('ensureSharedFlutterEngine')));
      final refresh = _body(service, 'refreshPresentation');
      expect(
        refresh.indexOf('notificationExecutor.execute'),
        lessThan(refresh.indexOf('buildNotification(status)')),
      );
      expect(
        refresh,
        contains(
          'instance === this && isPresenting && presentationGeneration == generation',
        ),
      );
      expect(
        _body(service, 'hidePresentation'),
        contains('presentationGeneration++'),
      );
    },
  );

  test(
    'd6046c28/7487bf9a: content provider reads run off the platform thread',
    () {
      final configure = _body(activity, 'configureFlutterEngine');
      expect(configure, contains('makeBackgroundTaskQueue()'));
      final transfer = _body(activity, 'handleTransferIntent');
      expect(
        transfer.indexOf('transferExecutor.execute'),
        lessThan(transfer.indexOf('readBoundedContent(')),
      );
      expect(
        transfer,
        contains('generation == transferGeneration && !isDestroyed'),
      );
      expect(_body(activity, 'onDestroy'), contains('transferGeneration++'));
      expect(
        _body(activity, 'isTransferIntent'),
        isNot(contains('resolveContentDisplayName')),
      );
    },
  );
}
