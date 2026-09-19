// ignore_for_file: public_member_api_docs

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';
import 'package:monkeyssh/presentation/widgets/acp_slash_command_picker.dart';

const _commands = [
  AcpAvailableCommand(name: 'deploy', description: 'Deploy the build'),
  AcpAvailableCommand(
    name: 'test',
    description: 'Run tests',
    input: AcpCommandInput(hint: '<pattern>'),
  ),
];

void registerAcpSlashCommandPickerTests() {
  group('acp_slash_command_picker', () {
    testWidgets('renders commands, hints, and reports touch selection', (
      tester,
    ) async {
      AcpAvailableCommand? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AcpSlashCommandPicker(
              commands: _commands,
              highlightedIndex: 0,
              onSelected: (command) => selected = command,
            ),
          ),
        ),
      );

      expect(find.text('/deploy'), findsOneWidget);
      expect(find.textContaining('<pattern>'), findsOneWidget);

      await tester.tap(find.text('Run tests'));
      await tester.pump();
      expect(selected?.name, 'test');
    });

    testWidgets('hover reports a highlight change', (tester) async {
      var highlighted = -1;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AcpSlashCommandPicker(
              commands: _commands,
              highlightedIndex: 0,
              onSelected: (_) {},
              onHighlightChanged: (index) => highlighted = index,
            ),
          ),
        ),
      );

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.text('Run tests')));
      await tester.pump();
      expect(highlighted, 1);
    });
  });
}
