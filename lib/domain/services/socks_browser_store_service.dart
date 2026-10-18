import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/database/database.dart';
import 'diagnostics_log_service.dart';
import 'serial_task_queue.dart';
import 'settings_service.dart';
import 'socks_browser_proxy_service.dart';

/// Gives each saved host's SOCKS browser its own website data store.
///
/// Pages reached through a SOCKS forward keep their real origins, so two
/// hosts can serve different sites at the same address, and the loopback
/// browser, which loads pages directly, could open that address as well.
/// Cookies, local and session storage, IndexedDB, the cache and HTTP auth of
/// SOCKS pages therefore live in a store that belongs to one host: a
/// `WKWebsiteDataStore(forIdentifier:)` on iOS 17+ and an androidx.webkit
/// profile on Android. The loopback browser keeps the default store.
///
/// A store is named by a random UUID saved on this device only
/// ([SettingKeys.socksBrowserStores]), never by anything about the host.
/// Deleting a host deletes its store. A store that no saved host names any
/// more, because a web view still used it when its host was deleted or the
/// setting was lost, is deleted the next time a SOCKS browser opens.
class SocksBrowserStoreService {
  /// Creates the service. [savedHostIds] lists the hosts that still exist;
  /// [channel] and [newStoreId] are injectable for tests.
  SocksBrowserStoreService({
    required SettingsService settings,
    required Future<Set<int>> Function() savedHostIds,
    MethodChannel? channel,
    String Function()? newStoreId,
  }) : _settings = settings,
       _savedHostIds = savedHostIds,
       _channel =
           channel ?? const MethodChannel(SocksBrowserProxyService.channelName),
       _newStoreId = newStoreId ?? const Uuid().v4;

  final SettingsService _settings;
  final Future<Set<int>> Function() _savedHostIds;
  final MethodChannel _channel;
  final String Function() _newStoreId;
  // Every change to the saved ids, and every purge, runs here, so a purge
  // never sees a store whose id is still being saved.
  final _queue = SerialTaskQueue();

  /// Returns the store id of [hostId]'s SOCKS browser, creating one on first
  /// use, then deletes in the background any store no saved host names.
  Future<String> openHostStore(int hostId) async {
    final storeId = await _queue.run(() => _storeIdFor(hostId));
    unawaited(purgeUnusedStores());
    return storeId;
  }

  Future<String> _storeIdFor(int hostId) async {
    final hostKey = hostId.toString();
    late String storeId;
    await _settings.updateJson(SettingKeys.socksBrowserStores, (current) {
      final stores = current ?? <String, dynamic>{};
      final saved = stores[hostKey];
      // A malformed id, or one another host also names, would mix data, so
      // it is replaced; the store it named is left to the purge.
      if (saved is String &&
          isSocksBrowserStoreId(saved) &&
          !stores.entries.any(
            (entry) => entry.key != hostKey && entry.value == saved,
          )) {
        storeId = saved;
      } else {
        storeId = _newStoreId();
        stores[hostKey] = storeId;
      }
      return stores;
    });
    return storeId;
  }

  /// Puts the iOS web view configuration [configurationId] in [storeId]'s
  /// store, before the web view is created from it.
  ///
  /// Throws [SocksBrowserProxyException] when the platform refuses; the
  /// caller must not create the web view then.
  Future<void> bindConfiguration(String storeId, int configurationId) =>
      _invoke('bindDataStore', {
        'store': storeId,
        'configuration': configurationId,
      });

  /// Makes sure web view [webViewId] keeps its data in [storeId]'s store: on
  /// Android this sets its profile, on iOS it checks the store
  /// [bindConfiguration] set.
  ///
  /// Throws [SocksBrowserProxyException] when it does not; the caller must
  /// not load pages in that web view then.
  Future<void> attachWebView(String storeId, int webViewId) =>
      _invoke('attachDataStore', {'store': storeId, 'webView': webViewId});

  Future<void> _invoke(String method, Map<String, Object> arguments) async {
    if (!isSocksBrowserStoreId(arguments['store']! as String)) {
      throw const SocksBrowserProxyException('invalid_store');
    }
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      _log('store_failed', code: 'missing_plugin');
      throw const SocksBrowserProxyException('unavailable');
    } on PlatformException catch (error) {
      _log('store_failed', code: error.code);
      throw SocksBrowserProxyException(error.code);
    }
  }

  /// Deletes [hostId]'s store and forgets its id.
  ///
  /// Never throws. A store a web view still uses cannot be deleted yet; the
  /// next purge deletes it.
  Future<void> forgetHost(int hostId) => _queue.run(() async {
    String? storeId;
    try {
      await _settings.updateJson(SettingKeys.socksBrowserStores, (current) {
        if (current == null) {
          return null;
        }
        final saved = current.remove(hostId.toString());
        storeId = saved is String ? saved : null;
        return current.isEmpty ? null : current;
      });
    } on Object catch (error) {
      _log('forget_failed', code: error.runtimeType.toString());
      return;
    }
    final id = storeId;
    if (id != null && isSocksBrowserStoreId(id)) {
      await _deleteStore(id);
    }
  });

  /// Forgets the ids of hosts that no longer exist, then deletes every store
  /// that no saved host names. Never throws.
  Future<void> purgeUnusedStores() => _queue.run(() async {
    try {
      // A store is only created under an id that is already saved, and ids
      // change only on this queue, so a store no saved id names is unused.
      final stores = await _channel.invokeListMethod<String>('listDataStores');
      final hostIds = await _savedHostIds();
      final named = <String>{};
      await _settings.updateJson(SettingKeys.socksBrowserStores, (current) {
        if (current == null) {
          return null;
        }
        current.removeWhere((hostKey, storeId) {
          final hostId = int.tryParse(hostKey);
          return hostId == null ||
              !hostIds.contains(hostId) ||
              storeId is! String;
        });
        named.addAll(current.values.whereType<String>());
        return current.isEmpty ? null : current;
      });
      for (final storeId in stores ?? const <String>[]) {
        if (!named.contains(storeId) && isSocksBrowserStoreId(storeId)) {
          await _deleteStore(storeId);
        }
      }
    } on MissingPluginException {
      // No native bridge, so no stores either.
    } on Object catch (error) {
      _log(
        'purge_failed',
        code: error is PlatformException
            ? error.code
            : error.runtimeType.toString(),
      );
    }
  });

  Future<void> _deleteStore(String storeId) async {
    try {
      await _channel.invokeMethod<void>('deleteDataStore', {'store': storeId});
    } on MissingPluginException {
      // No native bridge, so the store was never created.
    } on PlatformException catch (error) {
      // Usually still in use by a web view; the next purge retries.
      _log('delete_failed', code: error.code);
    }
  }

  void _log(String event, {required String code}) {
    DiagnosticsLogService.instance.warning(
      'browser.socks',
      event,
      fields: {'code': code},
    );
  }
}

final _storeIdPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// Whether [value] is a store id this app hands out: a lowercase UUID, which
/// both `NSUUID` and an androidx.webkit profile name accept.
bool isSocksBrowserStoreId(String value) => _storeIdPattern.hasMatch(value);

/// App-wide per-host SOCKS browser stores.
final socksBrowserStoreServiceProvider = Provider<SocksBrowserStoreService>((
  ref,
) {
  final db = ref.watch(databaseProvider);
  return SocksBrowserStoreService(
    settings: ref.watch(settingsServiceProvider),
    savedHostIds: () async {
      final rows = await (db.selectOnly(
        db.hosts,
      )..addColumns([db.hosts.id])).get();
      return {for (final row in rows) row.read(db.hosts.id)!};
    },
  );
});
