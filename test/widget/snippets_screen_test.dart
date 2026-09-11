// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/snippet_repository.dart';
import 'package:monkeyssh/presentation/screens/snippet_edit_screen.dart';
import 'package:monkeyssh/presentation/screens/snippets_screen.dart';

class _MockSnippetRepository extends Mock implements SnippetRepository {}

void _callReorderItemCallback(
  ReorderCallback? callback,
  int oldIndex,
  int newIndex,
) {
  expect(callback, isNotNull);
  callback?.call(oldIndex, newIndex);
}

Snippet _buildSnippet({
  required int id,
  required String name,
  required int sortOrder,
  int? folderId,
}) => Snippet(
  id: id,
  name: name,
  command: 'echo $name',
  folderId: folderId,
  autoExecute: false,
  createdAt: DateTime(2026),
  usageCount: 0,
  sortOrder: sortOrder,
);

SnippetFolder _buildFolder({
  required int id,
  required String name,
  int sortOrder = 0,
}) => SnippetFolder(
  id: id,
  name: name,
  sortOrder: sortOrder,
  createdAt: DateTime(2026),
);

void main() {
  setUpAll(() {
    registerFallbackValue(<int>[]);
    registerFallbackValue(SnippetFoldersCompanion.insert(name: 'fallback'));
  });

  group('SnippetsScreen', () {
    testWidgets('shows imported snippets after the stream updates', (
      tester,
    ) async {
      final snippetRepository = _MockSnippetRepository();
      final snippetsController = StreamController<List<Snippet>>();
      addTearDown(snippetsController.close);

      when(
        snippetRepository.watchAll,
      ).thenAnswer((_) => snippetsController.stream);
      when(
        snippetRepository.watchAllFolders,
      ).thenAnswer((_) => Stream.value(const <SnippetFolder>[]));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            snippetRepositoryProvider.overrideWithValue(snippetRepository),
          ],
          child: const MaterialApp(home: SnippetsScreen()),
        ),
      );

      snippetsController.add(const <Snippet>[]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('no snippets yet'), findsOneWidget);

      snippetsController.add([
        _buildSnippet(id: 1, name: 'Imported snippet', sortOrder: 0),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Imported snippet'), findsOneWidget);
    });

    testWidgets(
      'snippet actions are exposed through the context menu trigger',
      (tester) async {
        final snippetRepository = _MockSnippetRepository();
        when(snippetRepository.watchAll).thenAnswer(
          (_) => Stream.value([
            _buildSnippet(id: 1, name: 'Restart API', sortOrder: 0),
          ]),
        );
        when(
          snippetRepository.watchAllFolders,
        ).thenAnswer((_) => Stream.value(const <SnippetFolder>[]));

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              snippetRepositoryProvider.overrideWithValue(snippetRepository),
            ],
            child: const MaterialApp(home: SnippetsScreen()),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byTooltip('Snippet actions'), findsOneWidget);
        expect(find.byIcon(Icons.copy), findsNothing);
        expect(find.byIcon(Icons.edit_outlined), findsNothing);
        expect(find.byIcon(Icons.delete_outline), findsNothing);

        await tester.tap(find.byTooltip('Snippet actions'));
        await tester.pumpAndSettle();

        expect(find.text('Copy command'), findsOneWidget);
        expect(find.text('Edit'), findsOneWidget);
        expect(find.text('Delete'), findsOneWidget);
      },
    );

    testWidgets('routes empty-state creation to the full snippet editor', (
      tester,
    ) async {
      final snippetRepository = _MockSnippetRepository();
      when(
        snippetRepository.watchAll,
      ).thenAnswer((_) => Stream.value(const <Snippet>[]));
      when(
        snippetRepository.watchAllFolders,
      ).thenAnswer((_) => Stream.value(const <SnippetFolder>[]));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            snippetRepositoryProvider.overrideWithValue(snippetRepository),
          ],
          child: MaterialApp.router(
            routerConfig: GoRouter(
              routes: [
                GoRoute(
                  path: '/',
                  builder: (context, state) => const SnippetsScreen(),
                ),
                GoRoute(
                  path: '/snippets/add',
                  builder: (context, state) =>
                      const Scaffold(body: Text('Full snippet editor')),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('no snippets yet'), findsOneWidget);
      expect(find.textContaining('keep retyping'), findsOneWidget);

      await tester.tap(find.text('Add Snippet').last);
      await tester.pumpAndSettle();

      expect(find.text('Full snippet editor'), findsOneWidget);
    });

    testWidgets('creates folders from the snippets screen header', (
      tester,
    ) async {
      final snippetRepository = _MockSnippetRepository();
      final snippetsController = StreamController<List<Snippet>>();
      final foldersController = StreamController<List<SnippetFolder>>();
      addTearDown(snippetsController.close);
      addTearDown(foldersController.close);
      when(
        snippetRepository.watchAll,
      ).thenAnswer((_) => snippetsController.stream);
      when(
        snippetRepository.watchAllFolders,
      ).thenAnswer((_) => foldersController.stream);
      when(() => snippetRepository.insertFolder(any())).thenAnswer((_) async {
        foldersController.add([_buildFolder(id: 7, name: 'Deploy')]);
        return 7;
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            snippetRepositoryProvider.overrideWithValue(snippetRepository),
          ],
          child: const MaterialApp(home: SnippetsScreen()),
        ),
      );
      snippetsController.add(const <Snippet>[]);
      foldersController.add(const <SnippetFolder>[]);
      await tester.pumpAndSettle();

      await tester.tap(find.text('New Folder'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Folder name'),
        'Deploy',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(find.text('Deploy (0)'), findsOneWidget);
      verify(() => snippetRepository.insertFolder(any())).called(1);
    });

    testWidgets('long-pressing a folder chip opens delete action', (
      tester,
    ) async {
      final snippetRepository = _MockSnippetRepository();
      final snippetsController = StreamController<List<Snippet>>();
      final foldersController = StreamController<List<SnippetFolder>>();
      addTearDown(snippetsController.close);
      addTearDown(foldersController.close);
      when(
        snippetRepository.watchAll,
      ).thenAnswer((_) => snippetsController.stream);
      when(
        snippetRepository.watchAllFolders,
      ).thenAnswer((_) => foldersController.stream);
      when(() => snippetRepository.deleteFolder(10)).thenAnswer((_) async {
        foldersController.add(const <SnippetFolder>[]);
        snippetsController.add([
          _buildSnippet(id: 1, name: 'Restart API', sortOrder: 0),
        ]);
        return 1;
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            snippetRepositoryProvider.overrideWithValue(snippetRepository),
          ],
          child: const MaterialApp(home: SnippetsScreen()),
        ),
      );
      snippetsController.add([
        _buildSnippet(id: 1, name: 'Restart API', sortOrder: 0, folderId: 10),
      ]);
      foldersController.add([_buildFolder(id: 10, name: 'Deploy')]);
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Deploy (1)'));
      await tester.pumpAndSettle();

      expect(find.text('Delete folder'), findsOneWidget);
      expect(find.text('Delete "Deploy"?'), findsNothing);
      verifyNever(() => snippetRepository.deleteFolder(10));

      await tester.tap(find.text('Delete folder'));
      await tester.pumpAndSettle();

      expect(find.text('Delete "Deploy"?'), findsOneWidget);
      expect(find.text('1 snippet will move to No folder.'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      verify(() => snippetRepository.deleteFolder(10)).called(1);
      expect(find.text('Deploy (1)'), findsNothing);
      expect(find.text('No folder (1)'), findsOneWidget);
      expect(find.text('Deleted folder "Deploy"'), findsOneWidget);
    });

    for (final fails in [false, true]) {
      testWidgets(
        'full editor handles ${fails ? 'failed' : 'missing'} snippet',
        (tester) async {
          final repository = _MockSnippetRepository();
          when(repository.getAllFolders).thenAnswer((_) async => []);
          when(() => repository.getById(99)).thenAnswer((_) async {
            if (fails) throw StateError('load failed');
            return null;
          });
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                snippetRepositoryProvider.overrideWithValue(repository),
              ],
              child: const MaterialApp(home: SnippetEditScreen(snippetId: 99)),
            ),
          );
          await tester.pumpAndSettle();

          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(find.byType(TextFormField), findsNothing);
          expect(
            find.text(
              fails
                  ? 'Could not load snippet. Try again.'
                  : 'Snippet not found.',
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('full editor updates variable preview as command changes', (
      tester,
    ) async {
      final snippetRepository = _MockSnippetRepository();
      when(
        snippetRepository.getAllFolders,
      ).thenAnswer((_) async => const <SnippetFolder>[]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            snippetRepositoryProvider.overrideWithValue(snippetRepository),
          ],
          child: const MaterialApp(home: SnippetEditScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Command'),
        'docker restart {{container}} && git checkout {{branch}}',
      );
      await tester.pump();

      expect(find.text('Variables'), findsOneWidget);
      expect(find.text('container'), findsOneWidget);
      expect(find.text('branch'), findsOneWidget);
    });

    testWidgets('full editor uses snippet prefill values', (tester) async {
      final snippetRepository = _MockSnippetRepository();
      when(
        snippetRepository.getAllFolders,
      ).thenAnswer((_) async => const <SnippetFolder>[]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            snippetRepositoryProvider.overrideWithValue(snippetRepository),
          ],
          child: const MaterialApp(
            home: SnippetEditScreen(
              prefill: SnippetEditPrefill(
                name: 'git status',
                command: 'git status --short',
                description: 'Selected from terminal',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final nameField = tester.widget<TextFormField>(
        find.widgetWithText(TextFormField, 'Name'),
      );
      final commandField = tester.widget<TextFormField>(
        find.widgetWithText(TextFormField, 'Command'),
      );
      final descriptionField = tester.widget<TextFormField>(
        find.widgetWithText(TextFormField, 'Description (optional)'),
      );

      expect(nameField.controller!.text, 'git status');
      expect(commandField.controller!.text, 'git status --short');
      expect(descriptionField.controller!.text, 'Selected from terminal');
    });

    testWidgets('full editor creates and selects a folder from the picker', (
      tester,
    ) async {
      final snippetRepository = _MockSnippetRepository();
      var getFoldersCallCount = 0;
      when(snippetRepository.getAllFolders).thenAnswer((_) async {
        getFoldersCallCount += 1;
        if (getFoldersCallCount == 1) {
          return const <SnippetFolder>[];
        }
        return [_buildFolder(id: 9, name: 'Deploy')];
      });
      when(
        () => snippetRepository.insertFolder(any()),
      ).thenAnswer((_) async => 9);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            snippetRepositoryProvider.overrideWithValue(snippetRepository),
          ],
          child: const MaterialApp(home: SnippetEditScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<int?>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create folder...').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Folder name'),
        'Deploy',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(find.text('Deploy'), findsOneWidget);
      verify(() => snippetRepository.insertFolder(any())).called(1);
    });

    testWidgets('reordering snippets persists the new order', (tester) async {
      final snippetRepository = _MockSnippetRepository();
      when(snippetRepository.watchAll).thenAnswer(
        (_) => Stream.value([
          _buildSnippet(id: 1, name: 'First', sortOrder: 0),
          _buildSnippet(id: 2, name: 'Second', sortOrder: 1),
        ]),
      );
      when(
        snippetRepository.watchAllFolders,
      ).thenAnswer((_) => Stream.value(const <SnippetFolder>[]));
      when(
        () => snippetRepository.reorderByIds(any()),
      ).thenAnswer((_) async {});

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            snippetRepositoryProvider.overrideWithValue(snippetRepository),
          ],
          child: const MaterialApp(home: SnippetsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Reorder'), findsNWidgets(2));

      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      _callReorderItemCallback(list.onReorderItem, 0, 1);
      await tester.pumpAndSettle();

      verify(() => snippetRepository.reorderByIds([2, 1])).called(1);
    });

    testWidgets('folder filter shows and reorders snippets in that folder', (
      tester,
    ) async {
      final snippetRepository = _MockSnippetRepository();
      when(snippetRepository.watchAll).thenAnswer(
        (_) => Stream.value([
          _buildSnippet(id: 1, name: 'Unfiled', sortOrder: 0),
          _buildSnippet(
            id: 2,
            name: 'Deploy first',
            sortOrder: 1,
            folderId: 10,
          ),
          _buildSnippet(
            id: 3,
            name: 'Deploy second',
            sortOrder: 2,
            folderId: 10,
          ),
          _buildSnippet(id: 4, name: 'Cleanup', sortOrder: 3),
        ]),
      );
      when(
        snippetRepository.watchAllFolders,
      ).thenAnswer((_) => Stream.value([_buildFolder(id: 10, name: 'Deploy')]));
      when(
        () => snippetRepository.reorderByIds(any()),
      ).thenAnswer((_) async {});

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            snippetRepositoryProvider.overrideWithValue(snippetRepository),
          ],
          child: const MaterialApp(home: SnippetsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Deploy (2)'), findsOneWidget);
      expect(find.text('Deploy'), findsNWidgets(2));

      await tester.tap(find.text('Deploy (2)'));
      await tester.pumpAndSettle();

      expect(find.text('Deploy first'), findsOneWidget);
      expect(find.text('Deploy second'), findsOneWidget);
      expect(find.text('Unfiled'), findsNothing);

      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      _callReorderItemCallback(list.onReorderItem, 0, 1);
      await tester.pumpAndSettle();

      verify(() => snippetRepository.reorderByIds([1, 3, 2, 4])).called(1);
    });
  });
}
