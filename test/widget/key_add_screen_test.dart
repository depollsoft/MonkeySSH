import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/hardware_key.dart';
import 'package:monkeyssh/domain/services/hardware_key_service.dart';
import 'package:monkeyssh/domain/services/key_service.dart';
import 'package:monkeyssh/presentation/screens/key_add_screen.dart';

import '../helpers/fake_hardware_key_platform.dart';

class _MockKeyService extends Mock implements KeyService {}

// KeyService is mocked; only the form's PEM envelope check needs to pass.
const _privateKeyFixture =
    '-----BEGIN TEST FIXTURE-----\n-----END TEST FIXTURE-----';

void main() {
  for (final importing in [false, true]) {
    for (final name in ['   ', 'x' * 256]) {
      testWidgets(
        '${importing ? 'import' : 'generation'} rejects invalid key name length ${name.length}',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(800, 1200));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final db = AppDatabase.forTesting(NativeDatabase.memory());
          addTearDown(db.close);
          final service = _MockKeyService();
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                databaseProvider.overrideWithValue(db),
                keyServiceProvider.overrideWithValue(service),
              ],
              child: MaterialApp(
                home: KeyAddScreen(initialTabIndex: importing ? 1 : 0),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.enterText(
            find.widgetWithText(TextFormField, 'Key Name'),
            name,
          );
          if (importing) {
            await tester.enterText(
              find.widgetWithText(TextFormField, 'Private Key (PEM format)'),
              _privateKeyFixture,
            );
          }
          final submit = find.text(importing ? 'Import Key' : 'Generate Key');
          await tester.ensureVisible(submit);
          await tester.tap(submit);
          await tester.pump();
          await tester.ensureVisible(
            find.widgetWithText(TextFormField, 'Key Name'),
          );
          expect(
            find.text(
              name.trim().isEmpty
                  ? 'Please enter a name'
                  : 'Name must be 255 characters or fewer',
            ),
            findsOneWidget,
          );
          verifyZeroInteractions(service);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }

    testWidgets(
      '${importing ? 'import' : 'generation'} accepts a trimmed 255-character name',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 1200));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final service = _MockKeyService();
        final name = 'x' * 255;
        Future<SshKey?> submitKey() => importing
            ? service.importKey(name: name, privateKeyPem: _privateKeyFixture)
            : service.generateKey(name: name, keyType: SshKeyType.ed25519);
        when(submitKey).thenAnswer((_) async => null);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWithValue(db),
              keyServiceProvider.overrideWithValue(service),
            ],
            child: MaterialApp(
              home: KeyAddScreen(initialTabIndex: importing ? 1 : 0),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Key Name'),
          ' $name ',
        );
        if (importing) {
          await tester.enterText(
            find.widgetWithText(TextFormField, 'Private Key (PEM format)'),
            _privateKeyFixture,
          );
        }
        final submit = find.text(importing ? 'Import Key' : 'Generate Key');
        await tester.ensureVisible(submit);
        await tester.tap(submit);
        await tester.pumpAndSettle();
        verify(submitKey).called(1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      '${importing ? 'import' : 'generation'} completes after discarding the screen',
      (tester) async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final service = _MockKeyService();
        final completion = Completer<SshKey?>();
        when(
          () => importing
              ? service.importKey(
                  name: 'Test key',
                  privateKeyPem: _privateKeyFixture,
                  passphrase: 'secret',
                )
              : service.generateKey(
                  name: 'Test key',
                  keyType: SshKeyType.ed25519,
                  passphrase: 'secret',
                ),
        ).thenAnswer((_) => completion.future);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWithValue(db),
              keyServiceProvider.overrideWithValue(service),
            ],
            child: MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) =>
                            KeyAddScreen(initialTabIndex: importing ? 1 : 0),
                      ),
                    ),
                    child: const Text('Add key'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Add key'));
        await tester.pumpAndSettle();
        for (final (label, value) in [
          ('Key Name', 'Test key'),
          if (importing) ('Private Key (PEM format)', _privateKeyFixture),
          (
            importing ? 'Passphrase (if encrypted)' : 'Passphrase (optional)',
            'secret',
          ),
        ]) {
          final field = find.widgetWithText(TextFormField, label);
          await tester.ensureVisible(field);
          await tester.enterText(field, value);
        }
        final submit = find.text(importing ? 'Import Key' : 'Generate Key');
        await tester.ensureVisible(submit);
        await tester.tap(submit);
        await tester.pump();
        expect(
          find.text(importing ? 'Importing...' : 'Generating...'),
          findsOneWidget,
        );

        await tester.tap(find.byType(BackButton));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Discard'));
        await tester.pumpAndSettle();
        expect(find.byType(KeyAddScreen), findsNothing);
        completion.complete(
          SshKey(
            id: 1,
            name: 'Test key',
            keyType: 'ed25519',
            publicKey: 'public key',
            privateKey: _privateKeyFixture,
            createdAt: DateTime(2026),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  group('hardware-backed generation', () {
    setUpAll(() => registerFallbackValue(SshKeyType.ed25519));

    Future<_MockKeyService> pumpHardwareTab(
      WidgetTester tester,
      HardwareKeyCapabilities capabilities, {
      GoRouter? router,
    }) async {
      // A narrow phone: the three key types must still fit.
      await tester.binding.setSurfaceSize(const Size(360, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final service = _MockKeyService();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            keyServiceProvider.overrideWithValue(service),
            hardwareKeyCapabilitiesProvider.overrideWith(
              (ref) async => capabilities,
            ),
          ],
          child: router == null
              ? const MaterialApp(home: KeyAddScreen())
              : MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      if (router != null) {
        unawaited(router.push('/add'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Hardware'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      return service;
    }

    FilledButton generateButton(WidgetTester tester) => tester.widget(
      find.ancestor(
        of: find.text('Generate Key'),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton),
      ),
    );

    testWidgets('generates in the Secure Enclave with per-use confirmation', (
      tester,
    ) async {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) =>
                const Scaffold(body: Text('keys home')),
          ),
          GoRoute(
            path: '/add',
            builder: (context, state) => const KeyAddScreen(),
          ),
        ],
      );
      addTearDown(router.dispose);
      final service = await pumpHardwareTab(
        tester,
        const HardwareKeyCapabilities.available(
          backing: HardwareKeyBacking.secureEnclave,
          userPresenceAvailable: true,
        ),
        router: router,
      );
      when(
        () => service.generateHardwareKey(
          name: 'Phone key',
          requireUserPresence: true,
        ),
      ).thenAnswer((_) async => hardwareSshKeyFixture());

      expect(find.text('Secure Enclave'), findsOneWidget);
      expect(find.textContaining('never leaves it'), findsOneWidget);
      expect(
        find.widgetWithText(TextFormField, 'Passphrase (optional)'),
        findsNothing,
      );
      expect(find.textContaining('background reconnect'), findsNothing);

      await tester.tap(find.text('Confirm each use'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Auto-connect and background reconnect'),
        findsOneWidget,
      );

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Key Name'),
        'Phone key',
      );
      final submit = find.text('Generate Key');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();

      verify(
        () => service.generateHardwareKey(
          name: 'Phone key',
          requireUserPresence: true,
        ),
      ).called(1);
      verifyNever(
        () => service.generateKey(
          name: any(named: 'name'),
          keyType: any(named: 'keyType'),
          passphrase: any(named: 'passphrase'),
        ),
      );
      expect(find.text('keys home'), findsOneWidget);
      expect(find.text('Key generated in the Secure Enclave'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the simulator explains why it cannot generate', (
      tester,
    ) async {
      final service = await pumpHardwareTab(
        tester,
        const HardwareKeyCapabilities.unavailable(
          HardwareKeyUnavailableReason.simulator,
        ),
      );

      expect(find.text('secure hardware unavailable'), findsOneWidget);
      expect(
        find.textContaining('iOS Simulator has no Secure Enclave'),
        findsOneWidget,
      );
      expect(generateButton(tester).onPressed, isNull);
      verifyZeroInteractions(service);
    });

    testWidgets('an emulator labels its simulated TEE', (tester) async {
      await pumpHardwareTab(
        tester,
        const HardwareKeyCapabilities.available(
          backing: HardwareKeyBacking.tee,
          userPresenceAvailable: false,
          isEmulator: true,
        ),
      );

      expect(find.text('TEE (emulator)'), findsOneWidget);
      expect(find.textContaining('simulated in software'), findsOneWidget);
      final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(toggle.onChanged, isNull);
      expect(find.textContaining('Set up biometrics'), findsOneWidget);
      expect(generateButton(tester).onPressed, isNotNull);
    });

    testWidgets('a device without StrongBox says the key uses the TEE', (
      tester,
    ) async {
      await pumpHardwareTab(
        tester,
        const HardwareKeyCapabilities.available(
          backing: HardwareKeyBacking.tee,
          userPresenceAvailable: true,
        ),
      );

      expect(find.text('TEE'), findsOneWidget);
      expect(find.textContaining('no StrongBox'), findsOneWidget);
    });

    testWidgets('hardware failures surface their message', (tester) async {
      final service = await pumpHardwareTab(
        tester,
        const HardwareKeyCapabilities.available(
          backing: HardwareKeyBacking.strongBox,
          userPresenceAvailable: true,
          strongBoxAvailable: true,
        ),
      );
      when(
        () => service.generateHardwareKey(
          name: 'Pixel key',
          requireUserPresence: false,
        ),
      ).thenThrow(
        const HardwareKeyException(HardwareKeyErrorCode.notHardwareBacked),
      );

      expect(find.textContaining('no StrongBox'), findsNothing);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Key Name'),
        'Pixel key',
      );
      final submit = find.text('Generate Key');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pump();

      expect(
        find.text(
          const HardwareKeyException(HardwareKeyErrorCode.notHardwareBacked)
              .message,
        ),
        findsOneWidget,
      );
      expect(find.byType(KeyAddScreen), findsOneWidget);
    });
  });
}
