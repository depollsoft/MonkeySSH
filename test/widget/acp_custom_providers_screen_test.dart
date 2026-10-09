// ignore_for_file: public_member_api_docs

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/services/acp_provider_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/presentation/screens/acp_custom_providers_screen.dart';

Future<AcpCustomProviderService> _pump(
  WidgetTester tester,
  AppDatabase db, {
  Widget home = const AcpCustomProvidersScreen(),
}) async {
  tester.view.physicalSize = const Size(430, 932);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final settings = SettingsService(db);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [settingsServiceProvider.overrideWithValue(settings)],
      // The empty state's cursor blinks forever unless motion is reduced.
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return AcpCustomProviderService(settings);
}

/// Unmounts the tree so drift's stream-close timer runs inside the test.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(Duration.zero);
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  late AppDatabase db;
  String? clipboardText;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    clipboardText = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          if (call.method == 'Clipboard.getData') {
            return <String, Object?>{'text': clipboardText};
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    await db.close();
  });

  testWidgets('settings tile opens the custom agent list', (tester) async {
    await _pump(
      tester,
      db,
      home: const Scaffold(body: AcpCustomProvidersSettingsTile()),
    );
    await tester.tap(find.text('Custom agents'));
    await tester.pumpAndSettle();
    expect(find.text('Custom Agents'), findsOneWidget);
    expect(find.text('no custom agents'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('adding an agent shows its exact command and fingerprint, and '
      'it runs only after approval', (tester) async {
    final service = await _pump(tester, db);

    await tester.tap(find.text('Add custom agent'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('custom-agent-label')),
      'Goose',
    );
    await tester.enterText(
      find.byKey(const ValueKey('custom-agent-command')),
      'goose',
    );
    await tester.enterText(
      find.byKey(const ValueKey('custom-agent-arguments')),
      'acp\n--with-builtin\ndeveloper tools',
    );
    await tester.enterText(
      find.byKey(const ValueKey('custom-agent-environment')),
      'GOOSE_PROVIDER, OPENAI_API_KEY',
    );
    await _tapVisible(tester, find.byKey(const ValueKey('custom-agent-save')));

    final expected = AcpCustomProviderDefinition.create(
      id: 'goose',
      label: 'Goose',
      launchCommand: AcpLaunchCommand(
        executable: 'goose',
        arguments: const ['acp', '--with-builtin', 'developer tools'],
      ),
      environmentVariableNames: const ['GOOSE_PROVIDER', 'OPENAI_API_KEY'],
    );
    expect(find.text('approve agent'), findsOneWidget);
    expect(
      find.text("goose acp --with-builtin 'developer tools'"),
      findsOneWidget,
    );
    expect(
      find.text(formatAcpFingerprintForDisplay(expected.fingerprint)),
      findsOneWidget,
    );
    expect(find.text('GOOSE_PROVIDER  OPENAI_API_KEY'), findsOneWidget);
    expect(
      (await tester.runAsync(service.listCustomProviders))!
          .single
          .isCommandApproved,
      isFalse,
    );

    await _tapVisible(
      tester,
      find.byKey(const ValueKey('custom-agent-approve')),
    );

    expect(find.text('approve agent'), findsNothing);
    expect(find.text('Goose'), findsOneWidget);
    expect(find.text('approved'), findsOneWidget);
    final stored = (await tester.runAsync(service.listCustomProviders))!;
    expect(stored.single.isCommandApproved, isTrue);
    expect(stored.single.fingerprint, expected.fingerprint);
    await _unmount(tester);
  });

  testWidgets('changing an approved command requires approval again', (
    tester,
  ) async {
    final settings = SettingsService(db);
    final service = AcpCustomProviderService(settings);
    await tester.runAsync(() async {
      final created = await service.create(
        label: 'Goose',
        launchCommand: AcpLaunchCommand(
          executable: 'goose',
          arguments: const ['acp'],
        ),
      );
      await service.approve(
        created.id,
        reviewedFingerprint: created.fingerprint,
      );
    });
    await _pump(tester, db);
    expect(find.text('approved'), findsOneWidget);

    await tester.tap(find.text('Goose'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('custom-agent-arguments')),
      'acp\n--yolo',
    );
    await _tapVisible(tester, find.byKey(const ValueKey('custom-agent-save')));

    expect(find.text('approve agent'), findsOneWidget);
    expect(
      find.text('This agent changed since you last approved it.'),
      findsOneWidget,
    );
    await _tapVisible(tester, find.text('Not now'));

    expect(find.text('needs approval'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Review'), findsOneWidget);
    final stored = (await tester.runAsync(service.listCustomProviders))!;
    expect(stored.single.isCommandApproved, isFalse);
    await _unmount(tester);
  });

  testWidgets('saving keeps empty and padded arguments exactly', (
    tester,
  ) async {
    final service = AcpCustomProviderService(SettingsService(db));
    await tester.runAsync(
      () => service.create(
        label: 'Goose',
        launchCommand: AcpLaunchCommand(
          executable: 'goose',
          arguments: const ['acp', '', ' padded '],
        ),
      ),
    );
    await _pump(tester, db);

    await tester.tap(find.text('Goose'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('custom-agent-label')),
      'Goose CLI',
    );
    await _tapVisible(tester, find.byKey(const ValueKey('custom-agent-save')));
    await _tapVisible(tester, find.text('Not now'));

    var stored = (await tester.runAsync(service.listCustomProviders))!.single;
    expect(stored.label, 'Goose CLI');
    expect(stored.launchCommand.arguments, ['acp', '', ' padded ']);

    // Typed arguments keep their spaces too.
    await tester.tap(find.text('Goose CLI'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('custom-agent-arguments')),
      'acp\n --flag \n\n',
    );
    await _tapVisible(tester, find.byKey(const ValueKey('custom-agent-save')));
    await _tapVisible(tester, find.text('Not now'));

    stored = (await tester.runAsync(service.listCustomProviders))!.single;
    expect(stored.launchCommand.arguments, ['acp', ' --flag ']);
    await _unmount(tester);
  });

  testWidgets('imported agents wait for approval', (tester) async {
    final service = await _pump(tester, db);
    clipboardText = jsonEncode({
      'format': acpCustomProviderExportFormat,
      'version': 1,
      'agents': [
        {
          'id': 'kimi',
          'label': 'Kimi',
          'command': ['kimi', 'acp'],
          'environmentVariables': ['MOONSHOT_API_KEY'],
          // Imports never trust an approval, whatever they claim.
          'approval': {
            'commandFingerprint': 'f' * 64,
            'approvedAt': '2026-01-01T00:00:00Z',
          },
        },
      ],
    });

    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('custom-agent-import')));
    await tester.pumpAndSettle();

    expect(
      find.text('Imported 1 agent. Review each one before it can run.'),
      findsOneWidget,
    );
    expect(find.text('Kimi'), findsOneWidget);
    expect(find.text('needs approval'), findsOneWidget);
    final stored = (await tester.runAsync(service.listCustomProviders))!;
    expect(stored.single.isCommandApproved, isFalse);
    await _unmount(tester);
  });

  testWidgets('import shows why a document was rejected', (tester) async {
    await _pump(tester, db);
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('custom-agent-import-text')),
      jsonEncode({
        'id': 'kimi',
        'label': 'Kimi',
        'command': ['kimi', 'acp'],
        'environmentVariables': {'MOONSHOT_API_KEY': 'sk-secret'},
      }),
    );
    await tester.tap(find.byKey(const ValueKey('custom-agent-import')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('List environment variables by name only'),
      findsOneWidget,
    );
    await _unmount(tester);
  });

  testWidgets('export copies definitions without approvals or values', (
    tester,
  ) async {
    final service = AcpCustomProviderService(SettingsService(db));
    late AcpCustomProviderDefinition created;
    await tester.runAsync(() async {
      created = await service.create(
        label: 'Goose',
        launchCommand: AcpLaunchCommand(
          executable: 'goose',
          arguments: const ['acp'],
        ),
        environmentVariableNames: ['OPENAI_API_KEY'],
      );
      await service.approve(
        created.id,
        reviewedFingerprint: created.fingerprint,
      );
    });
    await _pump(tester, db);

    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export all'));
    await tester.pumpAndSettle();

    expect(clipboardText, isNotNull);
    expect(clipboardText, contains('OPENAI_API_KEY'));
    expect(clipboardText, isNot(contains('approval')));
    expect(clipboardText, isNot(contains(created.fingerprint)));
    expect(
      find.textContaining('Environment variables are listed by name only'),
      findsOneWidget,
    );
    await _unmount(tester);
  });

  testWidgets('deleting asks first and removes the agent', (tester) async {
    final service = AcpCustomProviderService(SettingsService(db));
    await tester.runAsync(
      () => service.create(
        label: 'Goose',
        launchCommand: AcpLaunchCommand(executable: 'goose'),
      ),
    );
    await _pump(tester, db);

    await tester.tap(find.text('Goose'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.text('no custom agents'), findsOneWidget);
    await _unmount(tester);
  });

  test('argv display quotes only what needs quoting', () {
    expect(
      formatAcpArgvForDisplay(const [
        '/usr/local/bin/goose',
        'acp',
        '--name=dev',
        'two words',
        "it's",
        '',
        r'$HOME',
      ]),
      r"/usr/local/bin/goose acp --name=dev 'two words' 'it'\''s' '' '$HOME'",
    );
    expect(formatAcpFingerprintForDisplay('0123456789'), '0123 4567 89');
    expect(parseAcpArgumentLines('a\n\n b \r\n\n'), ['a', '', ' b ']);
  });
}
