import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/remote_file_edit_session.dart';
import 'package:monkeyssh/presentation/screens/remote_text_editor_conflict.dart';
import 'package:monkeyssh/presentation/screens/remote_text_editor_screen.dart';

/// Records what the editor asked the host to do.
class _FakeHost {
  RemoteFileChange change = RemoteFileChange.unchanged;
  String hostText = 'agent version';
  Exception? checkError;
  Exception? reloadError;
  Exception? copyError;
  final saved = <String>[];
  final copies = <String>[];
  int reloads = 0;

  RemoteEditorConflictHandler get handler => RemoteEditorConflictHandler(
    checkForChanges: () async {
      if (checkError case final error?) throw error;
      return change;
    },
    reload: () async {
      reloads++;
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
                    onSave: (text) async => host.saved.add(text),
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
      expect(find.textContaining('notes.txt changed on the host'), findsOne);
      for (final label in [
        'Save as a copy',
        'Reload host version',
        'Overwrite host version',
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
      await tester.tap(find.text('Overwrite host version'));
      await tester.pumpAndSettle();

      expect(host.saved, ['phone version']);
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
      await tester.tap(find.text('Reload host version'));
      await tester.pumpAndSettle();
      expect(find.text('Discard your edits?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();

      expect(host.reloads, 0);
      expect(harness.controller.text, 'phone version');
      expect(_editorIsEditable(tester), isTrue);

      await _save(tester);
      await tester.tap(find.text('Reload host version'));
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
      await tester.tap(find.text('Reload host version'));
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
      await tester.tap(find.text('Reload host version'));
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
      expect(find.text('Reload host version'), findsNothing);
      expect(find.text('Save as a copy'), findsOneWidget);
      await tester.tap(find.text('Recreate file'));
      await tester.pumpAndSettle();

      expect(host.saved, ['phone version']);
      expect(harness.result, isTrue);
    });

    testWidgets('a failed check does not write', (tester) async {
      final host = _FakeHost()..checkError = Exception('connection lost');
      await _openEditor(tester, host);

      await _save(tester);

      expect(host.saved, isEmpty);
      expect(
        find.text('Could not save changes. Check permissions and try again.'),
        findsOneWidget,
      );
      expect(_editorIsEditable(tester), isTrue);
    });
  });
}
