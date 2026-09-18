// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/repositories/port_forward_repository.dart';
import 'package:monkeyssh/data/repositories/snippet_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/presentation/screens/host_edit_screen.dart';

class FakeHostRepository extends HostRepository {
  FakeHostRepository({
    required Host host,
    required AppDatabase database,
    required SecretEncryptionService encryptionService,
  }) : _host = host,
       super(database, encryptionService);

  Host _host;
  Host? updatedHost;
  HostsCompanion? insertedHost;

  @override
  Future<Host?> getById(int id) async => id == _host.id ? _host : null;

  @override
  Stream<List<Host>> watchAll() => Stream.value([_host]);

  @override
  Future<bool> update(Host host) async {
    _host = host;
    updatedHost = host;
    return true;
  }

  @override
  Future<int> insert(HostsCompanion host) async {
    insertedHost = host;
    return 2;
  }
}

class FakeKeyRepository extends KeyRepository {
  FakeKeyRepository({
    required AppDatabase database,
    required SecretEncryptionService encryptionService,
  }) : super(database, encryptionService);

  @override
  Stream<List<SshKey>> watchAll() => const Stream<List<SshKey>>.empty();
}

class FakeSnippetRepository extends SnippetRepository {
  FakeSnippetRepository({
    required List<Snippet> snippets,
    required AppDatabase database,
  }) : _snippets = snippets,
       super(database);

  final List<Snippet> _snippets;

  @override
  Future<Snippet?> getById(int id) async {
    for (final snippet in _snippets) {
      if (snippet.id == id) {
        return snippet;
      }
    }
    return null;
  }

  @override
  Stream<List<Snippet>> watchAll() => Stream.value(_snippets);
}

class FakePortForwardRepository extends PortForwardRepository {
  FakePortForwardRepository({required AppDatabase database}) : super(database);

  @override
  Future<List<PortForward>> getByHostId(int hostId) async => const [];
}

class HostEditFixture {
  HostEditFixture({required this.host}) {
    addTearDown(database.close);
    hostRepository = FakeHostRepository(
      host: host,
      database: database,
      encryptionService: encryptionService,
    );
  }

  final Host host;
  final database = AppDatabase.forTesting(NativeDatabase.memory());
  final encryptionService = SecretEncryptionService.forTesting();
  late final FakeHostRepository hostRepository;

  Future<void> pump(
    WidgetTester tester, {
    bool createHost = false,
    List<Snippet> snippets = const [],
    List<Override> overrides = const [],
    HostRepository? hostRepository,
  }) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: SizedBox.shrink()),
        ),
        GoRoute(
          path: '/edit',
          builder: (context, state) =>
              HostEditScreen(hostId: createHost ? null : host.id),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          hostRepositoryProvider.overrideWithValue(
            hostRepository ?? this.hostRepository,
          ),
          keyRepositoryProvider.overrideWithValue(
            FakeKeyRepository(
              database: database,
              encryptionService: encryptionService,
            ),
          ),
          snippetRepositoryProvider.overrideWithValue(
            FakeSnippetRepository(snippets: snippets, database: database),
          ),
          portForwardRepositoryProvider.overrideWithValue(
            FakePortForwardRepository(database: database),
          ),
          ...overrides,
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    unawaited(router.push('/edit'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> setSurfaceSize(WidgetTester tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(420, 900));
  }
}
