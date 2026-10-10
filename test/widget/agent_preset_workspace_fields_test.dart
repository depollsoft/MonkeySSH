// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/agent_worktree.dart';
import 'package:monkeyssh/presentation/widgets/agent_preset_workspace_fields.dart';

Future<AgentPresetWorkspaceFormState> _pump(
  WidgetTester tester, {
  bool enabled = true,
  String workingDirectory = '~/src/app',
  AgentLaunchPreset? preset,
}) async {
  final state = AgentPresetWorkspaceFormState()..load(preset);
  final workingDirectoryController = TextEditingController(
    text: workingDirectory,
  );
  addTearDown(state.dispose);
  addTearDown(workingDirectoryController.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Form(
            child: StatefulBuilder(
              builder: (context, setState) => AgentPresetWorkspaceFields(
                state: state,
                enabled: enabled,
                tool: AgentLaunchTool.claudeCode,
                workingDirectory: workingDirectoryController,
                onChanged: () => setState(() {}),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return state;
}

void main() {
  testWidgets('turning on worktrees shows the settings and a preview', (
    tester,
  ) async {
    final state = await _pump(tester);

    expect(
      find.byKey(const Key('host-agent-worktree-repository-field')),
      findsNothing,
    );
    expect(
      tester
          .getSize(find.byKey(const Key('host-agent-worktree-switch')))
          .height,
      greaterThanOrEqualTo(44),
    );

    await tester.tap(find.byKey(const Key('host-agent-worktree-switch')));
    await tester.pump();

    expect(state.worktreeEnabled, isTrue);
    expect(state.worktree, const AgentWorktreeLaunchOptions());
    expect(
      find.byKey(const Key('host-agent-worktree-branch-field')),
      findsOneWidget,
    );
    expect(find.text('HEAD → agent/claude-20261009-k3x9q2'), findsOneWidget);
    expect(
      find.text('{repo}.worktrees/agent-claude-20261009-k3x9q2'),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const Key('host-agent-worktree-base-field')),
      'origin/main',
    );
    await tester.enterText(
      find.byKey(const Key('host-agent-worktree-path-field')),
      '~/trees/{branch}',
    );
    await tester.pump();

    expect(state.worktree?.baseRef, 'origin/main');
    expect(
      find.text('origin/main → agent/claude-20261009-k3x9q2'),
      findsOneWidget,
    );
    expect(find.text('~/trees/agent/claude-20261009-k3x9q2'), findsOneWidget);
  });

  testWidgets('explains an invalid branch template with an icon', (
    tester,
  ) async {
    await _pump(
      tester,
      preset: const AgentLaunchPreset(
        tool: AgentLaunchTool.claudeCode,
        worktree: AgentWorktreeLaunchOptions(),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('host-agent-worktree-branch-field')),
      'agent {prompt}',
    );
    await tester.pump();

    final error = find.byKey(const Key('host-agent-worktree-preview-error'));
    expect(error, findsOneWidget);
    expect(
      find.descendant(of: error, matching: find.byIcon(Icons.error_outline)),
      findsOneWidget,
    );
    expect(find.textContaining('{prompt}'), findsWidgets);
  });

  testWidgets('needs a repository or a working directory', (tester) async {
    await _pump(
      tester,
      workingDirectory: '',
      preset: const AgentLaunchPreset(
        tool: AgentLaunchTool.codex,
        worktree: AgentWorktreeLaunchOptions(),
      ),
    );

    expect(
      find.text('Set a repository or a working directory for the worktree.'),
      findsOneWidget,
    );
  });

  testWidgets('loads a saved preset and stays read-only without Pro', (
    tester,
  ) async {
    final state = await _pump(
      tester,
      enabled: false,
      preset: const AgentLaunchPreset(
        tool: AgentLaunchTool.codex,
        worktree: AgentWorktreeLaunchOptions(branchTemplate: 'wip/{id}'),
        initialPrompt: 'Summarise the open tasks.',
      ),
    );

    expect(state.branchTemplate.text, 'wip/{id}');
    expect(state.initialPrompt.text, 'Summarise the open tasks.');
    final toggle = tester.widget<SwitchListTile>(
      find.byKey(const Key('host-agent-worktree-switch')),
    );
    expect(toggle.value, isTrue);
    expect(toggle.onChanged, isNull);
    final prompt = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('host-agent-initial-prompt-field')),
        matching: find.byType(EditableText),
      ),
    );
    expect(prompt.readOnly, isTrue);
  });
}
