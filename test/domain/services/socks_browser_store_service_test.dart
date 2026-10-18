import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/socks_browser_proxy_service.dart';
import 'package:monkeyssh/domain/services/socks_browser_store_service.dart';

const _channel = MethodChannel(SocksBrowserProxyService.channelName);

String _id(int n) => '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late AppDatabase db;
  late SettingsService settings;
  late Set<int> savedHosts;
  late List<String> nativeStores;
  late List<String> calls;
  late int nextId;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    settings = SettingsService(db);
    savedHosts = {1, 2, 3};
    nativeStores = [];
    calls = [];
    nextId = 100;
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(_channel, null);
    await db.close();
  });

  /// Answers the native bridge like the platforms do: stores exist once a
  /// web view is bound to them, and [refuse] makes a method fail.
  void mockNative({Map<String, String> refuse = const {}}) {
    messenger.setMockMethodCallHandler(_channel, (call) async {
      final arguments = call.arguments as Map?;
      final store = arguments?['store'] as String?;
      calls.add(store == null ? call.method : '${call.method}:$store');
      if (refuse[call.method] case final code?) {
        throw PlatformException(code: code);
      }
      switch (call.method) {
        case 'listDataStores':
          return nativeStores;
        case 'bindDataStore' || 'attachDataStore':
          if (!nativeStores.contains(store)) nativeStores.add(store!);
        case 'deleteDataStore':
          nativeStores.remove(store);
      }
      return null;
    });
  }

  SocksBrowserStoreService service({bool randomIds = false}) =>
      SocksBrowserStoreService(
        settings: settings,
        savedHostIds: () async => savedHosts,
        newStoreId: randomIds ? null : () => _id(nextId++),
      );

  Future<Map<String, dynamic>?> savedIds() =>
      settings.getJson(SettingKeys.socksBrowserStores);

  /// Lets a background purge finish.
  Future<void> settle(SocksBrowserStoreService stores) =>
      stores.purgeUnusedStores();

  test('gives each host its own random store and keeps it', () async {
    mockNative();
    final stores = service(randomIds: true);

    final first = await stores.openHostStore(1);
    final second = await stores.openHostStore(2);
    expect(isSocksBrowserStoreId(first), isTrue);
    expect(isSocksBrowserStoreId(second), isTrue);
    expect(second, isNot(first));
    expect(await stores.openHostStore(1), first);
    // Kept by host id only: nothing about the host names its store.
    expect(await savedIds(), {'1': first, '2': second});

    // Still the same store after a restart.
    expect(await service(randomIds: true).openHostStore(2), second);
  });

  test('replaces an id that is malformed or that another host names', () async {
    mockNative();
    await settings.setJson(SettingKeys.socksBrowserStores, {
      '1': 'nas.local',
      '2': _id(7),
      '3': _id(7),
    });
    final stores = service();

    expect(await stores.openHostStore(1), _id(100));
    // Two hosts naming one store would share data, so neither keeps it
    // while the other does.
    expect(await stores.openHostStore(2), _id(101));
    expect(await stores.openHostStore(3), _id(7));
    expect(await savedIds(), {'1': _id(100), '2': _id(101), '3': _id(7)});
  });

  test('binds web views by store id and fails closed', () async {
    mockNative(refuse: {'attachDataStore': 'store_mismatch'});
    final stores = service();
    final id = await stores.openHostStore(1);

    await stores.bindConfiguration(id, 11);
    await expectLater(
      stores.attachWebView(id, 12),
      throwsA(
        isA<SocksBrowserProxyException>().having(
          (error) => error.code,
          'code',
          'store_mismatch',
        ),
      ),
    );
    expect(
      calls,
      containsAllInOrder(['bindDataStore:$id', 'attachDataStore:$id']),
    );

    // Only ids this service hands out ever reach the platform.
    calls.clear();
    await expectLater(
      stores.bindConfiguration('Default', 11),
      throwsA(isA<SocksBrowserProxyException>()),
    );
    expect(calls, isEmpty);
  });

  test('without a native bridge binding fails and the rest is quiet', () async {
    final stores = service();
    final id = await stores.openHostStore(1);
    await expectLater(
      stores.bindConfiguration(id, 11),
      throwsA(
        isA<SocksBrowserProxyException>().having(
          (error) => error.code,
          'code',
          'unavailable',
        ),
      ),
    );
    await stores.forgetHost(1);
    await stores.purgeUnusedStores();
    expect(await savedIds(), isNull);
  });

  test('deleting a host deletes its store', () async {
    mockNative();
    final stores = service();
    final first = await stores.openHostStore(1);
    final second = await stores.openHostStore(2);
    await stores.bindConfiguration(first, 11);
    await stores.bindConfiguration(second, 12);
    await settle(stores);

    await stores.forgetHost(1);
    expect(nativeStores, [second]);
    expect(await savedIds(), {'2': second});
    // A host that is added later never gets the old store back.
    expect(await stores.openHostStore(1), isNot(first));
  });

  test('a store still in use is deleted by a later purge', () async {
    mockNative(refuse: {'deleteDataStore': 'in_use'});
    final stores = service();
    final id = await stores.openHostStore(1);
    await stores.bindConfiguration(id, 11);
    await settle(stores);

    await stores.forgetHost(1);
    // The id is gone even though the store could not be deleted yet.
    expect(await savedIds(), isNull);
    expect(nativeStores, [id]);

    mockNative();
    await stores.purgeUnusedStores();
    expect(nativeStores, isEmpty);
  });

  test('purges stores no saved host names, and ids of deleted hosts', () async {
    mockNative();
    final stores = service();
    final kept = await stores.openHostStore(1);
    final ofDeletedHost = await stores.openHostStore(2);
    await settle(stores);
    nativeStores.addAll([kept, ofDeletedHost, _id(9), 'not-a-store']);
    savedHosts = {1};

    await stores.purgeUnusedStores();
    expect(nativeStores, [kept, 'not-a-store']);
    expect(await savedIds(), {'1': kept});
  });

  test('opening a host store purges in the background', () async {
    mockNative();
    nativeStores.add(_id(9));
    final stores = service();

    final id = await stores.openHostStore(1);
    await settle(stores);
    expect(nativeStores, isEmpty);
    expect(id, _id(100));
  });

  test('an id saved while a purge runs keeps its store', () async {
    final listed = Completer<void>();
    final release = Completer<void>();
    messenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'listDataStores' && !listed.isCompleted) {
        listed.complete();
        await release.future;
        return <String>[];
      }
      final store = (call.arguments as Map?)?['store'] as String?;
      calls.add(call.method);
      switch (call.method) {
        case 'listDataStores':
          return nativeStores;
        case 'bindDataStore':
          nativeStores.add(store!);
        case 'deleteDataStore':
          nativeStores.remove(store);
      }
      return null;
    });
    final stores = service();

    final purge = stores.purgeUnusedStores();
    await listed.future;
    // Waits for the purge, so the purge never sees a half-saved id.
    final opening = stores.openHostStore(1);
    release.complete();
    await purge;
    final id = await opening;
    await stores.bindConfiguration(id, 11);
    await settle(stores);
    expect(nativeStores, [id]);
    expect(calls, isNot(contains('deleteDataStore')));
  });
}
