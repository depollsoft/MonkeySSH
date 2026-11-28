part of 'monkeymux_service.dart';

class _AppReviewDemoMonkeyMuxState {
  _AppReviewDemoMonkeyMuxState()
    : _windows = List<_AppReviewDemoWindowSpec>.of(_initialWindows());

  static const _workspace = '/home/reviewer/work/monkeyssh-demo';

  final _controller = StreamController<TmuxWindowChangeEvent>.broadcast();
  final List<_AppReviewDemoWindowSpec> _windows;
  int _activeIndex = 0;
  int _nextId = 10;
  bool _renderedInitial = false;

  Stream<TmuxWindowChangeEvent> get stream => _controller.stream;

  TmuxWindow get activeWindow => windows.firstWhere(
    (window) => window.isActive,
    orElse: () => windows.first,
  );

  List<TmuxWindow> get windows => [
    for (var index = 0; index < _windows.length; index += 1)
      _windows[index].toWindow(index: index, isActive: index == _activeIndex),
  ];

  bool consumeInitialRender() {
    if (_renderedInitial) {
      return false;
    }
    _renderedInitial = true;
    return true;
  }

  TmuxWindow createWindow({
    String? command,
    String? name,
    String? workingDirectory,
  }) {
    final tool =
        agentLaunchToolForCommandText(command) ??
        agentLaunchToolForCommandText(name);
    final id = _nextId++;
    final windowName =
        trimmedOrNull(name) ??
        tool?.label ??
        trimmedOrNull(command)?.split(RegExp(r'\s+')).first ??
        'shell $id';
    final spec = _AppReviewDemoWindowSpec(
      id: '@$id',
      panePid: 7300 + id,
      name: windowName,
      currentCommand: tool?.commandName ?? trimmedOrNull(command) ?? 'zsh',
      currentPath: trimmedOrNull(workingDirectory) ?? _workspace,
      paneTitle: tool == null ? windowName : '${tool.label} · demo window',
      agentTool: tool,
      agentSessionTitle: tool == null ? null : 'Demo ${tool.label} session',
    );
    _windows.add(spec);
    _activeIndex = _windows.length - 1;
    emitWindowList();
    return spec.toWindow(index: _activeIndex, isActive: true);
  }

  TmuxWindow selectWindow(int windowIndex, {String? windowId}) {
    final targetIndex = windowId == null
        ? windowIndex
        : _windows.indexWhere((window) => window.id == windowId);
    if (targetIndex >= 0 && targetIndex < _windows.length) {
      _activeIndex = targetIndex;
    }
    emitWindowList();
    return activeWindow;
  }

  TmuxWindow? killWindow(int windowIndex, {String? windowId}) {
    final targetIndex = windowId == null
        ? windowIndex
        : _windows.indexWhere((window) => window.id == windowId);
    if (_windows.length <= 1 ||
        targetIndex < 0 ||
        targetIndex >= _windows.length) {
      return null;
    }
    final closed = _windows.removeAt(targetIndex);
    if (_activeIndex >= _windows.length) {
      _activeIndex = _windows.length - 1;
    } else if (targetIndex < _activeIndex) {
      _activeIndex -= 1;
    }
    emitWindowList();
    return closed.toWindow(index: targetIndex, isActive: false);
  }

  void emitWindowList() {
    if (!_controller.isClosed) {
      _controller.add(TmuxWindowListEvent(windows));
    }
  }

  void dispose() {
    if (!_controller.isClosed) {
      unawaited(_controller.close());
    }
  }

  static List<_AppReviewDemoWindowSpec> _initialWindows() => const [
    _AppReviewDemoWindowSpec(
      id: '@0',
      panePid: 7300,
      name: 'Copilot CLI',
      currentCommand: 'copilot',
      currentPath: _workspace,
      paneTitle: 'Copilot CLI · planning review notes',
      agentTool: AgentLaunchTool.copilotCli,
      agentSessionTitle: 'Planning review notes',
    ),
    _AppReviewDemoWindowSpec(
      id: '@1',
      panePid: 7301,
      name: 'Claude Code',
      currentCommand: 'claude',
      currentPath: _workspace,
      paneTitle: 'Claude Code · running tests',
      agentTool: AgentLaunchTool.claudeCode,
      agentSessionTitle: 'Running focused tests',
    ),
    _AppReviewDemoWindowSpec(
      id: '@2',
      panePid: 7302,
      name: 'OpenCode',
      currentCommand: 'opencode',
      currentPath: '$_workspace/src',
      paneTitle: 'OpenCode · editing README.md',
      agentTool: AgentLaunchTool.openCode,
      agentSessionTitle: 'Editing README.md',
    ),
    _AppReviewDemoWindowSpec(
      id: '@3',
      panePid: 7303,
      name: 'SFTP',
      currentCommand: 'zsh',
      currentPath: _workspace,
      paneTitle: 'SFTP · sample workspace',
    ),
  ];
}

class _AppReviewDemoWindowSpec {
  const _AppReviewDemoWindowSpec({
    required this.id,
    required this.panePid,
    required this.name,
    required this.currentCommand,
    required this.currentPath,
    required this.paneTitle,
    this.agentTool,
    this.agentSessionTitle,
  });

  final String id;
  final int panePid;
  final String name;
  final String currentCommand;
  final String currentPath;
  final String paneTitle;
  final AgentLaunchTool? agentTool;
  final String? agentSessionTitle;

  TmuxWindow toWindow({required int index, required bool isActive}) =>
      TmuxWindow(
        index: index,
        id: id,
        panePid: panePid,
        name: name,
        isActive: isActive,
        currentCommand: currentCommand,
        currentPath: currentPath,
        flags: isActive ? '*' : null,
        paneTitle: paneTitle,
        paneStartCommand: currentCommand,
        agentTool: agentTool,
        activeAgentSessionId: agentTool == null ? null : 'demo-$panePid',
        agentSessionTitle: agentSessionTitle,
        activeAgentSessionConfidence: agentTool == null
            ? null
            : AgentSessionConfidence.medium,
        idleSeconds: isActive ? 2 : 30,
      );
}

void _renderAppReviewDemoWindow(SshSession session, TmuxWindow window) {
  writeAppReviewDemoTerminalOutput(
    session,
    _appReviewDemoWindowScreen(window),
    replaceScreen: true,
    showPrompt: false,
  );
}

String _ansi(String code, String text) => '\x1b[${code}m$text\x1b[0m';

String _appReviewDemoWindowScreen(TmuxWindow window) {
  final title = window.displayTitle;
  final path = window.currentPath ?? '/home/reviewer/work/monkeyssh-demo';
  final tool = window.foregroundAgentTool;
  if (tool == AgentLaunchTool.copilotCli ||
      window.name.toLowerCase().contains('copilot')) {
    return '''
${_ansi('48;5;24;38;5;231;1', ' GitHub Copilot CLI ')} ${_ansi('38;5;245', 'Build · gpt-5.5')}

${_ansi('38;5;39', '┃')} ${_ansi('48;5;235;38;5;231', ' Ask Copilot to build or review code         ')}
${_ansi('38;5;39', '┃')} Review PR #643
${_ansi('38;5;39', '╹')} ${_ansi('38;5;238', '▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀')}

${_ansi('38;5;75', '●')} ${_ansi('38;5;252;1', 'Reading workspace')}
  ${_ansi('38;5;70', '✓')} monkeymux_service.dart
  ${_ansi('38;5;70', '✓')} ssh_service.dart

${_ansi('38;5;75', '●')} ${_ansi('38;5;252;1', 'Plan')}
  ${_ansi('38;5;70', '✓')} local MonkeyMux state
  ${_ansi('38;5;70', '✓')} repaint terminal on switch
  ${_ansi('38;5;70', '✓')} deterministic App Review data

${_ansi('48;5;25;38;5;231', ' /deploy ')} ${_ansi('38;5;245', 'ready')}

${_ansi('38;5;245', 'tab agents   ctrl+p commands')}
''';
  }
  if (tool == AgentLaunchTool.claudeCode ||
      window.name.toLowerCase().contains('claude')) {
    return '''
${_ansi('38;5;208;1', '✻ Claude Code v2.1.201')}

${_ansi('38;5;245', 'Welcome back')}
${_ansi('38;5;245', 'Opus 4.8 · /fast')}

${_ansi('38;5;208', '▌')} ${_ansi('38;5;252;1', 'Working directory')}
  ${_ansi('38;5;110', path.replaceFirst('/home/reviewer/', '~/'))}

${_ansi('38;5;208', '●')} Plan
 ${_ansi('38;5;70', '✓')} App Review demo flow
 ${_ansi('38;5;70', '✓')} MonkeyMux windows
 ${_ansi('38;5;70', '✓')} flutter analyze

${_ansi('38;5;245', '──────────── ↯ /fast ─')}
${_ansi('38;5;208', '❯')} Try "make the demo panes feel real"
''';
  }
  if (tool == AgentLaunchTool.openCode ||
      window.name.toLowerCase().contains('opencode')) {
    return '''
${_ansi('48;2;10;10;10;38;2;238;238;238;1', '      OPEN CODE      ')}

${_ansi('38;2;92;156;245', '┃')} ${_ansi('48;2;30;30;30;38;2;128;128;128', 'Ask anything...')}
${_ansi('38;2;92;156;245', '╹')} ${_ansi('38;2;30;30;30', '▀▀▀▀▀▀▀▀▀▀▀▀')}

${_ansi('38;2;92;156;245', 'Build')} ${_ansi('38;5;245', '· Claude Opus 4.8 Fast')}
${_ansi('38;5;245', 'GitHub Copilot provider')}

${_ansi('38;5;36', 'files')}
  README.md
  src/main.dart
  logs/app.log

${_ansi('38;5;36', 'editor  README.md')}
 1 # App Review Demo
 2 Local MonkeyMux panes
 3 switch like real CLIs

${_ansi('38;5;252', 'tab')} ${_ansi('38;5;245', 'agents')}   ${_ansi('38;5;252', 'ctrl+p')} ${_ansi('38;5;245', 'commands')}
''';
  }
  if (tool == AgentLaunchTool.codex ||
      window.name.toLowerCase().contains('codex')) {
    return '''
${_ansi('38;5;51;1', 'Codex CLI (demo)')} ${_ansi('38;5;245', 'gpt-5.3-codex')}

${_ansi('38;5;51', '✨')} ${_ansi('38;5;252;1', 'Task')}
  render local MonkeyMux panes

${_ansi('38;5;51', 'thinking')} inspect live TUI references
${_ansi('38;5;51', 'thinking')} build compact ANSI mock screens

${_ansi('38;5;70', '✓')} service branch added
${_ansi('38;5;70', '✓')} tests cover create/select
${_ansi('38;5;70', '✓')} analyzer clean

${_ansi('48;5;23;38;5;231', ' Patch ready ')}
${_ansi('38;5;245', '› Ask Codex for a follow-up')}
''';
  }
  if (tool == AgentLaunchTool.antigravity ||
      window.name.toLowerCase().contains('antigravity')) {
    return '''
${_ansi('48;5;54;38;5;231;1', ' Antigravity (demo) ')}

${_ansi('38;5;141', 'objective')}
  Verify mobile SSH agents

Workspace
  ${_ansi('38;5;111', '~/work/monkeyssh-demo')}

Status
  ${_ansi('38;5;70', '●')} local demo transport online
  ${_ansi('38;5;70', '●')} MonkeyMux navigator online
  ${_ansi('38;5;70', '●')} pane rendering follows window focus

${_ansi('38;5;245', 'Actions: plan · inspect · patch · verify')}
''';
  }
  return '''
${_ansi('48;5;236;38;5;231;1', ' MonkeySSH SFTP / Shell (demo) ')} ${_ansi('38;5;245', 'Window ${window.index} · $title')}

$path

${_ansi('38;5;33', 'drwxr-xr-x')}  logs
${_ansi('38;5;33', 'drwxr-xr-x')}  screenshots
${_ansi('38;5;33', 'drwxr-xr-x')}  src
${_ansi('38;5;245', '-rw-r--r--')}  144  README.md
${_ansi('38;5;245', '-rw-r--r--')}   68  package.json
${_ansi('38;5;245', '-rwxr-xr-x')}   39  deploy-demo.sh

Tip:
  Tap the folder button to browse the same sample files in SFTP.
''';
}
