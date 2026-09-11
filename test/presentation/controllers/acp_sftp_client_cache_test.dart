// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/controllers/acp_sftp_client_cache.dart';

class _FakeSftpClient extends Fake implements SftpClient {
  _FakeSftpClient(this.id);
  final int id;
}

void main() {
  group('AcpSftpClientCache', () {
    for (final liveConnection in <int?>[null, 2]) {
      test(
        'invalidation to $liveConnection supersedes an in-flight open',
        () async {
          final cache = AcpSftpClientCache();
          final pending = Completer<SftpClient>();
          final opening = cache.ensure(
            connectionId: 1,
            open: () => pending.future,
          );
          cache.invalidateIfStale(liveConnection);
          pending.complete(_FakeSftpClient(1));
          expect(await opening, isNull);
          expect(cache.connectionId, isNull);
        },
      );
    }

    test(
      'disconnect does not reuse an invalidated same-connection open',
      () async {
        final cache = AcpSftpClientCache();
        final pending = Completer<SftpClient>();
        final opening = cache.ensure(
          connectionId: 1,
          open: () => pending.future,
        );
        await cache.ensure(
          connectionId: null,
          open: () async => _FakeSftpClient(9),
        );
        final fresh = _FakeSftpClient(2);
        final reopened = cache.ensure(connectionId: 1, open: () async => fresh);
        pending.complete(_FakeSftpClient(1));
        expect(await opening, isNull);
        expect(await reopened, same(fresh));
        expect(cache.clientForConnection(1), same(fresh));
      },
    );

    test('same-connection invalidation keeps the pending open', () async {
      final cache = AcpSftpClientCache();
      final pending = Completer<SftpClient>();
      final opening = cache.ensure(connectionId: 1, open: () => pending.future);
      cache.invalidateIfStale(1);
      final client = _FakeSftpClient(1);
      pending.complete(client);
      expect(await opening, same(client));
    });
    test('opens once and reuses the client for the same connection', () async {
      final cache = AcpSftpClientCache();
      var opens = 0;
      Future<SftpClient> open() async {
        opens++;
        return _FakeSftpClient(1);
      }

      final first = await cache.ensure(connectionId: 1, open: open);
      final second = await cache.ensure(connectionId: 1, open: open);

      expect(opens, 1);
      expect(identical(first, second), isTrue);
      expect(cache.connectionId, 1);
      expect(cache.clientForConnection(1), same(first));
    });

    test('reopens against a new connectionId after a reconnect', () async {
      final cache = AcpSftpClientCache();
      var nextId = 1;
      Future<SftpClient> open() async => _FakeSftpClient(nextId);

      await cache.ensure(connectionId: 1, open: open);
      // Host reconnected under a new connectionId.
      nextId = 2;
      final reopened = await cache.ensure(connectionId: 2, open: open);

      expect((reopened! as _FakeSftpClient).id, 2);
      expect(cache.connectionId, 2);
      // The stale connection no longer resolves to a client.
      expect(cache.clientForConnection(1), isNull);
      expect(cache.clientForConnection(2), same(reopened));
    });

    test(
      'clientForConnection returns null for a mismatched connection',
      () async {
        final cache = AcpSftpClientCache();
        final client = await cache.ensure(
          connectionId: 7,
          open: () async => _FakeSftpClient(7),
        );

        expect(cache.clientForConnection(7), same(client));
        expect(cache.clientForConnection(8), isNull);
        expect(cache.clientForConnection(null), isNull);
      },
    );

    test(
      'invalidateIfStale drops a client owned by a different connection',
      () async {
        final cache = AcpSftpClientCache();
        await cache.ensure(
          connectionId: 3,
          open: () async => _FakeSftpClient(3),
        );

        cache.invalidateIfStale(3); // same connection: kept
        expect(cache.clientForConnection(3), isNotNull);

        cache.invalidateIfStale(4); // different connection: dropped
        expect(cache.clientForConnection(3), isNull);
        expect(cache.connectionId, isNull);
      },
    );

    test('a null connectionId clears the cache and resolves to null', () async {
      final cache = AcpSftpClientCache();
      await cache.ensure(connectionId: 5, open: () async => _FakeSftpClient(5));

      final result = await cache.ensure(
        connectionId: null,
        open: () async => _FakeSftpClient(99),
      );

      expect(result, isNull);
      expect(cache.connectionId, isNull);
      expect(cache.clientForConnection(5), isNull);
    });

    test('a failed open resolves to null without caching', () async {
      final cache = AcpSftpClientCache();
      final result = await cache.ensure(
        connectionId: 1,
        open: () async => throw StateError('boom'),
      );

      expect(result, isNull);
      expect(cache.connectionId, isNull);
      expect(cache.clientForConnection(1), isNull);
    });

    test('concurrent ensures for one connection share a single open', () async {
      final cache = AcpSftpClientCache();
      var opens = 0;
      Future<SftpClient> open() async {
        opens++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return _FakeSftpClient(1);
      }

      final results = await Future.wait([
        cache.ensure(connectionId: 1, open: open),
        cache.ensure(connectionId: 1, open: open),
      ]);

      expect(opens, 1);
      expect(identical(results[0], results[1]), isTrue);
    });

    test('a stale open (A) finishing after a newer open (B) never overwrites '
        'the cache', () async {
      final cache = AcpSftpClientCache();
      final completerA = Completer<SftpClient>();
      final completerB = Completer<SftpClient>();
      final clientA = _FakeSftpClient(1);
      final clientB = _FakeSftpClient(2);

      // Connection A starts opening, then connection B (a reconnect) supersedes
      // it before A resolves.
      final futureA = cache.ensure(
        connectionId: 1,
        open: () => completerA.future,
      );
      final futureB = cache.ensure(
        connectionId: 2,
        open: () => completerB.future,
      );

      // B resolves first and populates the cache.
      completerB.complete(clientB);
      final resultB = await futureB;
      expect(resultB, same(clientB));
      expect(cache.connectionId, 2);
      expect(cache.clientForConnection(2), same(clientB));

      // A resolves later; being stale, it must resolve to null and leave the
      // cache pointing at the newer connection B.
      completerA.complete(clientA);
      final resultA = await futureA;
      expect(resultA, isNull);
      expect(cache.connectionId, 2);
      expect(cache.clientForConnection(2), same(clientB));
      expect(cache.clientForConnection(1), isNull);
    });

    test(
      'a stale open (A) finishing before the newer open (B) still yields B',
      () async {
        final cache = AcpSftpClientCache();
        final completerA = Completer<SftpClient>();
        final completerB = Completer<SftpClient>();
        final clientA = _FakeSftpClient(1);
        final clientB = _FakeSftpClient(2);

        final futureA = cache.ensure(
          connectionId: 1,
          open: () => completerA.future,
        );
        final futureB = cache.ensure(
          connectionId: 2,
          open: () => completerB.future,
        );

        // A resolves first but is already superseded by B's request.
        completerA.complete(clientA);
        final resultA = await futureA;
        expect(resultA, isNull);
        expect(cache.clientForConnection(1), isNull);

        // B resolves and becomes the cached client.
        completerB.complete(clientB);
        final resultB = await futureB;
        expect(resultB, same(clientB));
        expect(cache.connectionId, 2);
        expect(cache.clientForConnection(2), same(clientB));
      },
    );
  });
}
