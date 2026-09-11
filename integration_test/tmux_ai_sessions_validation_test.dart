// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/app/app.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/host_key_prompt_handler_provider.dart';
import 'package:monkeyssh/domain/services/host_key_verification.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';

const _hostLabel = 'Local tmux AI sessions';
const _sshPort = String.fromEnvironment('FLUTTY_TMUX_BAR_SSH_PORT');
const _sshUser = String.fromEnvironment('FLUTTY_TMUX_BAR_SSH_USER');
const _sshPrivateKeyBase64 = String.fromEnvironment(
  'FLUTTY_TMUX_BAR_SSH_KEY_B64',
);
const _sshPublicKeyBase64 = String.fromEnvironment(
  'FLUTTY_TMUX_BAR_SSH_PUB_B64',
);
const _tmuxSessionName = String.fromEnvironment(
  'FLUTTY_TMUX_BAR_SESSION',
  defaultValue: 'MonkeySSH',
);
const _tmuxWorkingDirectory = String.fromEnvironment('FLUTTY_TMUX_BAR_WORKDIR');
const _tmuxHandleBarKey = ValueKey<String>('tmux-handle-bar');
const _expectedProviders = <String>[
  'Claude Code',
  'Codex',
  'Copilot CLI',
  'OpenCode',
];

String get _deviceReachableHost =>
    Platform.isAndroid ? '10.0.2.2' : '127.0.0.1';

MonetizationState _proMonetizationState() => const MonetizationState(
  billingAvailability: MonetizationBillingAvailability.available,
  entitlements: MonetizationEntitlements.pro(),
  offers: [],
  debugUnlockAvailable: false,
  debugUnlocked: false,
);

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
  Duration step = const Duration(milliseconds: 200),
}) async {
  await _pumpUntil(
    tester,
    () => finder.evaluate().isNotEmpty,
    description: 'finder: $finder',
    timeout: timeout,
    step: step,
  );
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() predicate, {
  required String description,
  String Function()? debugState,
  Duration timeout = const Duration(seconds: 30),
  Duration step = const Duration(milliseconds: 200),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(step);
    if (predicate()) {
      return;
    }
  }

  final details = debugState?.call();
  fail(
    details == null || details.isEmpty
        ? 'Timed out waiting for $description'
        : 'Timed out waiting for $description\n$details',
  );
}

String _describeVisibleAiSessionState(WidgetTester tester) {
  final providerTiles = _expectedProviders
      .map((provider) {
        final titleFinder = find.text(provider);
        if (titleFinder.evaluate().isEmpty) {
          return '$provider=<missing>';
        }
        final tileFinder = find.ancestor(
          of: titleFinder.first,
          matching: find.byType(ListTile),
        );
        if (tileFinder.evaluate().isEmpty) {
          return '$provider=<no tile>';
        }
        final tileTexts = find
            .descendant(of: tileFinder.first, matching: find.byType(Text))
            .evaluate()
            .map((element) => (element.widget as Text).data?.trim())
            .whereType<String>()
            .where((text) => text.isNotEmpty)
            .toList(growable: false);
        return '$provider=${tileTexts.join(' / ')}';
      })
      .join(' || ');
  final visibleTexts =
      tester.allWidgets
          .whereType<Text>()
          .map((widget) => widget.data?.trim())
          .whereType<String>()
          .where((text) => text.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
  return 'Provider tiles: $providerTiles\n'
      'Visible text widgets: ${visibleTexts.join(' | ')}';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final binding = IntegrationTestWidgetsFlutterBinding.instance;

  testWidgets(
    'shows recent AI sessions for every expected provider on device',
    (tester) async {
      expect(_sshPort, isNotEmpty);
      expect(_sshUser, isNotEmpty);
      expect(_sshPrivateKeyBase64, isNotEmpty);
      expect(_sshPublicKeyBase64, isNotEmpty);
      expect(_tmuxWorkingDirectory, isNotEmpty);

      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      if (Platform.isAndroid) {
        await binding.convertFlutterSurfaceToImage();
      }

      final container = ProviderContainer(
        overrides: [
          hostKeyPromptHandlerProvider.overrideWithValue(
            (_) async => HostKeyTrustDecision.trust,
          ),
          monetizationStateProvider.overrideWith(
            (ref) => Stream<MonetizationState>.value(_proMonetizationState()),
          ),
        ],
      );
      addTearDown(container.dispose);

      final db = container.read(databaseProvider);
      await db.customStatement('DELETE FROM known_hosts;');
      await db.customStatement('DELETE FROM hosts;');
      await db.customStatement('DELETE FROM ssh_keys;');

      final keyId = await container
          .read(keyRepositoryProvider)
          .insert(
            SshKeysCompanion.insert(
              name: 'Temporary tmux AI session validation key',
              keyType: 'ed25519',
              publicKey: utf8.decode(base64Decode(_sshPublicKeyBase64)),
              privateKey: utf8.decode(base64Decode(_sshPrivateKeyBase64)),
            ),
          );

      final hostId = await container
          .read(hostRepositoryProvider)
          .insert(
            HostsCompanion.insert(
              label: _hostLabel,
              hostname: _deviceReachableHost,
              port: Value(int.parse(_sshPort)),
              username: _sshUser,
              keyId: Value(keyId),
              autoConnectRequiresConfirmation: const Value(false),
              tmuxSessionName: const Value(_tmuxSessionName),
              tmuxWorkingDirectory: const Value(_tmuxWorkingDirectory),
            ),
          );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const FluttyApp(),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 2));

      final hostRow = find.byKey(ValueKey('home-host-$hostId'));
      await _pumpUntilFound(tester, hostRow);

      await tester.tap(hostRow);
      await tester.pump();

      await _pumpUntilFound(
        tester,
        find.byType(TerminalScreen),
        timeout: const Duration(seconds: 20),
      );
      final handleBar = find.byKey(_tmuxHandleBarKey);
      await _pumpUntilFound(tester, handleBar);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await tester.tap(handleBar);
      await tester.pumpAndSettle(const Duration(seconds: 2));

      await _pumpUntilFound(
        tester,
        find.text('AI Sessions'),
        timeout: const Duration(seconds: 15),
      );
      await tester.tap(find.text('AI Sessions'));
      await tester.pump();

      try {
        await _pumpUntil(
          tester,
          () =>
              _expectedProviders.every(
                (provider) => find.text(provider).evaluate().isNotEmpty,
              ) &&
              find
                  .text('No recent sessions for this project')
                  .evaluate()
                  .isEmpty &&
              find.text('No recent sessions found').evaluate().isEmpty &&
              find
                  .text('Could not load recent AI sessions.')
                  .evaluate()
                  .isEmpty,
          description:
              'all expected AI session providers with non-empty results',
          debugState: () => _describeVisibleAiSessionState(tester),
          timeout: const Duration(seconds: 90),
        );
      } on TestFailure {
        await binding.takeScreenshot('tmux-ai-sessions-timeout');
        rethrow;
      }

      for (final provider in _expectedProviders) {
        expect(find.text(provider), findsWidgets);
      }
      expect(find.text('No recent sessions for this project'), findsNothing);
      expect(find.text('No recent sessions found'), findsNothing);
      expect(find.text('Could not load recent AI sessions.'), findsNothing);

      await binding.takeScreenshot('tmux-ai-sessions-populated');
    },
  );
}
