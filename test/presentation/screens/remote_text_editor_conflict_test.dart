import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/terminal_theme.dart';
import 'package:monkeyssh/domain/services/remote_file_edit_session.dart';
import 'package:monkeyssh/domain/services/remote_file_service.dart';
import 'package:monkeyssh/presentation/screens/remote_text_editor_conflict.dart';
import 'package:monkeyssh/presentation/screens/remote_text_editor_screen.dart';

/// Records what the editor asked the host to do.
class _FakeHost {
  RemoteFileChange change = RemoteFileChange.unchanged;

  /// Results for the next checks, before falling back to [change].
  final queuedChanges = <RemoteFileChange>[];
  String hostText = 'agent version';
  Object? checkError;
  Object? reloadError;
  Exception? copyError;

  /// How many saves report a change between the check and the write.
  int changesDuringSave = 0;
  final saved = <String>[];
  final overwritten = <String>[];
  final recreated = <String>[];

  /// How many recreates find the file back on the host.
  int recreateConflicts = 0;
  final copies = <String>[];
  int reloads = 0;
  int checks = 0;

  Future<void> save(String text) async {
    if (changesDuringSave > 0) {
      changesDuringSave--;
      throw const RemoteFileChangedDuringSaveException();
    }
    saved.add(text);
  }

  RemoteEditorConflictHandler get handler => RemoteEditorConflictHandler(
    checkForChanges: () async {
      checks++;
      // ignore: only_throw_errors, dartssh2 models SSH errors as interfaces.
      if (checkError case final error?) throw error;
      return queuedChanges.isEmpty ? change : queuedChanges.removeAt(0);
    },
    overwrite: (text) async => overwritten.add(text),
    recreate: (text) async {
      if (recreateConflicts > 0) {
        recreateConflicts--;
        throw const RemoteFileChangedDuringSaveException();
      }
      recreated.add(text);
    },
    reload: () async {
      reloads++;
      // ignore: only_throw_errors, dartssh2 models SFTP errors as interfaces.
      if (reloadError case final error?) throw error;
      change = RemoteFileChange.unchanged;
      return hostText;
    },
    saveCopy: (text) async {
      if (copyError case final error?) throw error;
      copies.add(text);
      return 'notes (copy).txt';
    },
  );
}

class _EditorHarness {
  _EditorHarness(this.host);

  final _FakeHost host;
  final controller = TextEditingController(text: 'original');
  Object? result = 'open';

  Widget build() => MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () async {
              final popped = await Navigator.of(context).push<Object?>(
                MaterialPageRoute(
                  builder: (_) => buildRemoteTextEditorScreenForTesting(
                    fileName: 'notes.txt',
                    controller: controller,
                    onSave: host.save,
                    conflictHandler: host.handler,
                  ),
                ),
              );
              result = popped;
            },
            child: const Text('Open editor'),
          ),
        ),
      ),
    ),
  );
}

Future<_EditorHarness> _openEditor(
  WidgetTester tester,
  _FakeHost host, {
  String? edit = 'phone version',
}) async {
  final harness = _EditorHarness(host);
  addTearDown(harness.controller.dispose);
  await tester.pumpWidget(harness.build());
  await tester.tap(find.text('Open editor'));
  await tester.pumpAndSettle();
  if (edit != null) {
    await tester.enterText(find.byType(TextField), edit);
    await tester.pump();
  }
  return harness;
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(TextButton, 'Save'));
  await tester.pumpAndSettle();
}

bool _editorIsEditable(WidgetTester tester) =>
    !tester.widget<TextField>(find.byType(TextField)).readOnly;

void main() {
  group('remote editor save conflicts', () {
    testWidgets('an unchanged file saves without asking', (tester) async {
      final host = _FakeHost();
      final harness = await _openEditor(tester, host);

      await _save(tester);

      expect(find.text('File changed on the host'), findsNothing);
      expect(host.saved, ['phone version']);
      expect(find.byType(RemoteTextEditorScreen), findsNothing);
      expect(harness.result, isTrue);
    });

    testWidgets('a changed file asks before writing; cancel keeps editing', (
      tester,
    ) async {
      final host = _FakeHost()..change = RemoteFileChange.modified;
      await _openEditor(tester, host);

      await _save(tester);

      expect(find.text('File changed on the host'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('notes.txt'),
        ),
        findsOne,
      );
      expect(find.textContaining('Reloading discards your edits'), findsOne);
      for (final label in [
        'Save as a copy',
        'Reload from host',
        'Overwrite host file',
        'Cancel',
      ]) {
        final button = find.ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate(
            (widget) => widget is ButtonStyleButton,
          ),
        );
        expect(button, findsOneWidget, reason: label);
        expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      }
      expect(host.saved, isEmpty);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.byType(RemoteTextEditorScreen), findsOneWidget);
      expect(host.saved, isEmpty);
      expect(_editorIsEditable(tester), isTrue);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'phone version',
      );
    });

    testWidgets('overwrite writes the edits over the host version', (
      tester,
    ) async {
      final host = _FakeHost()..change = RemoteFileChange.modified;
      final harness = await _openEditor(tester, host);

      await _save(tester);
      await tester.tap(find.text('Overwrite host file'));
      await tester.pumpAndSettle();

      // The chosen overwrite skips the version comparison.
      expect(host.overwritten, ['phone version']);
      expect(host.saved, isEmpty);
      expect(harness.result, isTrue);
    });

    testWidgets('save as a copy leaves the original and closes', (
      tester,
    ) async {
      final host = _FakeHost()..change = RemoteFileChange.modified;
      final harness = await _openEditor(tester, host);

      await _save(tester);
      await tester.tap(find.text('Save as a copy'));
      await tester.pumpAndSettle();

      expect(host.copies, ['phone version']);
      expect(host.saved, isEmpty);
      expect(find.text('Discard changes?'), findsNothing);
      expect(find.byType(RemoteTextEditorScreen), findsNothing);
      expect(
        harness.result,
        isA<RemoteEditorSavedCopy>().having(
          (copy) => copy.fileName,
          'fileName',
          'notes (copy).txt',
        ),
      );
    });

    testWidgets('a failed copy keeps the edits open', (tester) async {
      final host = _FakeHost()
        ..change = RemoteFileChange.modified
        ..copyError = Exception('permission denied');
      await _openEditor(tester, host);

      await _save(tester);
      await tester.tap(find.text('Save as a copy'));
      await tester.pumpAndSettle();

      expect(
        find.text('Could not save a copy. Check permissions and try again.'),
        findsOneWidget,
      );
      expect(find.byType(RemoteTextEditorScreen), findsOneWidget);
      expect(_editorIsEditable(tester), isTrue);
      expect(host.saved, isEmpty);
    });

    testWidgets('reload confirms before discarding edits', (tester) async {
      final host = _FakeHost()..change = RemoteFileChange.modified;
      final harness = await _openEditor(tester, host);

      await _save(tester);
      await tester.tap(find.text('Reload from host'));
      await tester.pumpAndSettle();
      expect(find.text('Discard your edits?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();

      expect(host.reloads, 0);
      expect(harness.controller.text, 'phone version');
      expect(_editorIsEditable(tester), isTrue);

      await _save(tester);
      await tester.tap(find.text('Reload from host'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard and reload'));
      await tester.pumpAndSettle();

      expect(host.reloads, 1);
      expect(host.saved, isEmpty);
      expect(harness.controller.text, 'agent version');
      expect(find.text('Loaded the host version of "notes.txt"'), findsOne);
      expect(find.byType(RemoteTextEditorScreen), findsOneWidget);
      expect(_editorIsEditable(tester), isTrue);

      // The reloaded text is the new baseline: closing needs no prompt.
      await tester.tap(find.byTooltip('Close editor'));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsNothing);
      expect(find.byType(RemoteTextEditorScreen), findsNothing);
    });

    testWidgets('reload without edits needs no confirmation', (tester) async {
      final host = _FakeHost()..change = RemoteFileChange.modified;
      final harness = await _openEditor(tester, host, edit: null);

      await _save(tester);
      await tester.tap(find.text('Reload from host'));
      await tester.pumpAndSettle();

      expect(find.text('Discard your edits?'), findsNothing);
      expect(harness.controller.text, 'agent version');
    });

    testWidgets('a reload the editor cannot open keeps the edits', (
      tester,
    ) async {
      final host = _FakeHost()
        ..change = RemoteFileChange.modified
        ..reloadError = const RemoteEditorReloadBlockedException(
          'Binary files cannot be edited here',
        );
      final harness = await _openEditor(tester, host);

      await _save(tester);
      await tester.tap(find.text('Reload from host'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard and reload'));
      await tester.pumpAndSettle();

      expect(find.text('Binary files cannot be edited here'), findsOneWidget);
      expect(harness.controller.text, 'phone version');
      expect(_editorIsEditable(tester), isTrue);
    });

    testWidgets('a deleted file offers to recreate it', (tester) async {
      final host = _FakeHost()..change = RemoteFileChange.deleted;
      final harness = await _openEditor(tester, host);

      await _save(tester);

      expect(find.text('File deleted on the host'), findsOneWidget);
      expect(find.text('Reload from host'), findsNothing);
      expect(find.text('Save as a copy'), findsOneWidget);
      await tester.tap(find.text('Recreate file'));
      await tester.pumpAndSettle();

      // Recreate is create-only; it never goes through overwrite.
      expect(host.recreated, ['phone version']);
      expect(host.overwritten, isEmpty);
      expect(harness.result, isTrue);
    });

    testWidgets('a file that came back before Recreate asks again', (
      tester,
    ) async {
      final host = _FakeHost()
        ..recreateConflicts = 1
        ..queuedChanges.addAll([
          RemoteFileChange.deleted,
          RemoteFileChange.modified,
        ]);
      await _openEditor(tester, host);

      await _save(tester);
      await tester.tap(find.text('Recreate file'));
      await tester.pumpAndSettle();

      expect(find.text('File changed on the host'), findsOneWidget);
      expect(host.recreated, isEmpty);
      expect(host.overwritten, isEmpty);
    });

    testWidgets('a refusal by the save says why', (tester) async {
      final host = _FakeHost()
        ..checkError = const RemoteFileRefusedException(
          'The path is now a folder on the host.',
        );
      await _openEditor(tester, host);

      await _save(tester);

      expect(
        find.text(
          'Could not save changes. The path is now a folder on the host.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a folder at the path only offers a copy', (tester) async {
      final host = _FakeHost()..change = RemoteFileChange.notAFile;
      await _openEditor(tester, host);

      await _save(tester);

      expect(find.text('No longer a file'), findsOneWidget);
      expect(find.text('Save as a copy'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Reload from host'), findsNothing);
      expect(find.text('Overwrite host file'), findsNothing);
      expect(find.text('Recreate file'), findsNothing);
    });

    testWidgets('a change caught during the write is checked again', (
      tester,
    ) async {
      final host = _FakeHost()..changesDuringSave = 1;
      final harness = await _openEditor(tester, host);

      await _save(tester);

      // The second check found identical content, so the save went ahead.
      expect(host.checks, 2);
      expect(host.saved, ['phone version']);
      expect(find.text('File changed on the host'), findsNothing);
      expect(harness.result, isTrue);
    });

    testWidgets('a real change caught during the write asks first', (
      tester,
    ) async {
      final host = _FakeHost()
        ..changesDuringSave = 1
        ..queuedChanges.addAll([
          RemoteFileChange.unchanged,
          RemoteFileChange.modified,
        ]);
      await _openEditor(tester, host);

      await _save(tester);

      expect(find.text('File changed on the host'), findsOneWidget);
      expect(host.saved, isEmpty);
      expect(host.overwritten, isEmpty);
    });

    testWidgets('a failed check does not write', (tester) async {
      final host = _FakeHost()..checkError = Exception('refused');
      await _openEditor(tester, host);

      await _save(tester);

      expect(host.saved, isEmpty);
      expect(
        find.text('Could not save changes. Check permissions and try again.'),
        findsOneWidget,
      );
      expect(_editorIsEditable(tester), isTrue);
    });

    testWidgets('a lost connection says so instead of permissions', (
      tester,
    ) async {
      final host = _FakeHost()..checkError = SSHStateError('closed');
      await _openEditor(tester, host);

      await _save(tester);

      expect(host.saved, isEmpty);
      expect(
        find.text(
          'Could not save changes. Check the connection and try again.',
        ),
        findsOneWidget,
      );
    });
  });

  group('conflict dialog', () {
    Future<void> showDialogIn(
      WidgetTester tester,
      ThemeData theme, {
      Size size = const Size(390, 844),
    }) async {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => showRemoteEditorConflictDialog(
                    context,
                    fileName: 'settings.local.json',
                    change: RemoteFileChange.modified,
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
    }

    testWidgets('the overwrite label reads on a light dialog', (tester) async {
      final theme = FluttyTheme.light;
      await showDialogIn(tester, theme);

      final label = tester.renderObject<RenderParagraph>(
        find.text('Overwrite host file'),
      );
      expect(
        contrastRatio(
          label.text.style!.color!,
          theme.dialogTheme.backgroundColor!,
        ),
        greaterThanOrEqualTo(4.5),
      );
    });

    testWidgets('the dialog keeps a phone width on a tablet', (tester) async {
      await showDialogIn(
        tester,
        FluttyTheme.dark,
        size: const Size(1024, 1366),
      );

      final surface = find
          .descendant(of: find.byType(Dialog), matching: find.byType(Material))
          .first;
      expect(tester.getSize(surface).width, lessThanOrEqualTo(420));
    });

    testWidgets('the file name sits on its own line', (tester) async {
      await showDialogIn(tester, FluttyTheme.dark);

      final name = tester.widget<Text>(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('settings.local.json'),
        ),
      );
      expect(name.style?.fontFamily, FluttyTheme.monoStyle.fontFamily);
    });
  });

  group('readableDestructiveColor', () {
    test('darkens the light theme red until it reads on the dialog', () {
      final scheme = FluttyTheme.light.colorScheme;
      final background = FluttyTheme.light.dialogTheme.backgroundColor!;
      // The theme red alone is too pale on a white dialog.
      expect(contrastRatio(scheme.error, background), lessThan(4.5));

      final color = readableDestructiveColor(scheme, background);

      expect(contrastRatio(color, background), greaterThanOrEqualTo(4.5));
      expect(color.r, greaterThan(color.g));
    });

    test('keeps a red that already reads', () {
      final scheme = FluttyTheme.dark.colorScheme;
      final background = FluttyTheme.dark.dialogTheme.backgroundColor!;

      expect(readableDestructiveColor(scheme, background), scheme.error);
    });
  });
}
