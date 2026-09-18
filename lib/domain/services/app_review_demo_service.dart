import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import '../../data/repositories/group_repository.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/key_repository.dart';
import '../../data/repositories/port_forward_repository.dart';
import '../../data/repositories/snippet_repository.dart';
import '../models/agent_launch_preset.dart';
import '../models/host_cli_launch_preferences.dart';
import '../models/remote_multiplexer.dart';
import '../models/terminal_themes.dart';
import 'agent_launch_preset_service.dart';
import 'host_cli_launch_preferences_service.dart';
import 'settings_service.dart';

/// Returns whether [host] is one of the seeded offline App Review demo hosts.
bool isAppReviewDemoHost(Host host) {
  if (!host.label.startsWith(AppReviewDemoService.demoHostLabelPrefix)) {
    return false;
  }
  final tags = host.tags
      ?.split(',')
      .map((tag) => tag.trim())
      .where((tag) => tag.isNotEmpty)
      .toSet();
  return tags?.containsAll(const {'app-review', 'demo'}) ?? false;
}

/// Result returned after preparing the local App Review demo workspace.
class AppReviewDemoSetupResult {
  /// Creates a setup result.
  const AppReviewDemoSetupResult({
    required this.createdHosts,
    required this.createdKeys,
    required this.createdSnippets,
    required this.createdPortForwards,
  });

  /// Number of demo hosts inserted during this setup pass.
  final int createdHosts;

  /// Number of demo SSH keys inserted during this setup pass.
  final int createdKeys;

  /// Number of demo snippets inserted during this setup pass.
  final int createdSnippets;

  /// Number of demo port forwards inserted during this setup pass.
  final int createdPortForwards;

  /// Whether any database-backed demo content was newly created.
  bool get createdAny =>
      createdHosts > 0 ||
      createdKeys > 0 ||
      createdSnippets > 0 ||
      createdPortForwards > 0;
}

/// Seeds deterministic local content for App Review without external servers.
class AppReviewDemoService {
  /// Creates an App Review demo service.
  const AppReviewDemoService({
    required GroupRepository groupRepository,
    required HostRepository hostRepository,
    required KeyRepository keyRepository,
    required SnippetRepository snippetRepository,
    required PortForwardRepository portForwardRepository,
    required AgentLaunchPresetService agentLaunchPresetService,
    required HostCliLaunchPreferencesService hostCliLaunchPreferencesService,
    required SettingsService settingsService,
  }) : _groupRepository = groupRepository,
       _hostRepository = hostRepository,
       _keyRepository = keyRepository,
       _snippetRepository = snippetRepository,
       _portForwardRepository = portForwardRepository,
       _agentLaunchPresetService = agentLaunchPresetService,
       _hostCliLaunchPreferencesService = hostCliLaunchPreferencesService,
       _settingsService = settingsService;

  final GroupRepository _groupRepository;
  final HostRepository _hostRepository;
  final KeyRepository _keyRepository;
  final SnippetRepository _snippetRepository;
  final PortForwardRepository _portForwardRepository;
  final AgentLaunchPresetService _agentLaunchPresetService;
  final HostCliLaunchPreferencesService _hostCliLaunchPreferencesService;
  final SettingsService _settingsService;

  static const _groupName = 'App Review Demo';
  static const _snippetFolderName = 'App Review Demo';
  static const _keyName = 'App Review Demo Key';
  static const _workspaceHostLabel = 'App Review Demo · MonkeyMux workspace';
  static const _agentHostLabel = 'App Review Demo · MonkeyMux agents';
  static const _sftpHostLabel = 'App Review Demo · SFTP and tunnels';
  static const _bastionHostLabel = 'App Review Demo · bastion jump host';
  static const _demoSeededAtSetting = 'app_review_demo_seeded_at';

  /// Shared prefix used to identify seeded demo hosts.
  static const demoHostLabelPrefix = 'App Review Demo ·';

  /// Returns whether the review demo has been prepared on this device.
  Future<bool> isPrepared() async =>
      await _settingsService.getString(_demoSeededAtSetting) != null;

  /// Creates any missing demo content and records the setup timestamp.
  Future<AppReviewDemoSetupResult> prepare() async {
    var createdHosts = 0;
    var createdKeys = 0;
    var createdSnippets = 0;
    var createdPortForwards = 0;

    final groupId = await _ensureGroup();
    final snippetFolderId = await _ensureSnippetFolder();
    final keyResult = await _ensureKey();
    if (keyResult.created) {
      createdKeys += 1;
    }
    final keyId = keyResult.id;

    final bootstrapSnippet = await _ensureSnippet(
      name: 'Review: launch Copilot in MonkeyMux',
      command: 'cd ~/work/monkeyssh-demo && copilot --yolo',
      description:
          'Shows an agent launch command saved for the review workspace.',
      folderId: snippetFolderId,
      sortOrder: 0,
    );
    if (bootstrapSnippet.created) {
      createdSnippets += 1;
    }
    final logsSnippet = await _ensureSnippet(
      name: 'Review: tail app logs',
      command: 'tail -f ~/work/monkeyssh-demo/logs/app.log',
      description: 'A reusable terminal snippet for the demo workspace.',
      folderId: snippetFolderId,
      sortOrder: 1,
    );
    if (logsSnippet.created) {
      createdSnippets += 1;
    }
    final deploySnippet = await _ensureSnippet(
      name: 'Review: dry-run deploy',
      command: './scripts/deploy-demo.sh --dry-run --target staging',
      description: 'Demonstrates saved automation that requires review.',
      folderId: snippetFolderId,
      sortOrder: 2,
    );
    if (deploySnippet.created) {
      createdSnippets += 1;
    }

    final bastionHost = await _ensureHost(
      label: _bastionHostLabel,
      hostname: '127.0.0.1',
      port: 2200,
      username: 'reviewer',
      keyId: keyId,
      groupId: groupId,
      color: '#58A38C',
      notes:
          'Sample jump host for App Review. This row is local demo data; no '
          'external SSH server is required to browse app setup screens.',
      tags: 'app-review,demo,jump-host',
      sortOrder: 0,
    );
    if (bastionHost.created) {
      createdHosts += 1;
    }

    final workspaceHost = await _ensureHost(
      label: _workspaceHostLabel,
      hostname: '127.0.0.1',
      port: 2201,
      username: 'reviewer',
      keyId: keyId,
      groupId: groupId,
      jumpHostId: bastionHost.id,
      color: '#14756C',
      notes:
          'Primary App Review sample workspace. It shows MonkeyMux startup, '
          'agent launch presets, SFTP, snippets, port forwarding, and '
          'host-specific terminal themes in local app data.',
      tags: 'app-review,demo,monkeymux,copilot,agent',
      terminalThemeLightId: TerminalThemes.githubLightDefault.id,
      terminalThemeDarkId: TerminalThemes.dracula.id,
      autoConnectSnippetId: bootstrapSnippet.id,
      autoConnectRequiresConfirmation: true,
      tmuxSessionName: 'review-workspace',
      tmuxWorkingDirectory: '~/work/monkeyssh-demo',
      remoteMuxBackend: RemoteMuxBackend.monkeyMux,
      sortOrder: 1,
    );
    if (workspaceHost.created) {
      createdHosts += 1;
    }

    final agentHost = await _ensureHost(
      label: _agentHostLabel,
      hostname: '127.0.0.1',
      port: 2202,
      username: 'reviewer',
      keyId: keyId,
      groupId: groupId,
      color: '#8BCBE5',
      notes:
          'Shows additional MonkeyMux windows and saved startup presets for '
          'agent-oriented review workflows.',
      tags: 'app-review,demo,monkeymux,agents',
      terminalThemeLightId: TerminalThemes.monkeyLight.id,
      terminalThemeDarkId: TerminalThemes.githubDarkDefault.id,
      autoConnectSnippetId: logsSnippet.id,
      autoConnectRequiresConfirmation: true,
      tmuxSessionName: 'review-agents',
      tmuxWorkingDirectory: '~/work/monkeyssh-demo',
      remoteMuxBackend: RemoteMuxBackend.monkeyMux,
      sortOrder: 2,
    );
    if (agentHost.created) {
      createdHosts += 1;
    }

    final sftpHost = await _ensureHost(
      label: _sftpHostLabel,
      hostname: '127.0.0.1',
      port: 2222,
      username: 'reviewer',
      keyId: keyId,
      groupId: groupId,
      color: '#D6CC76',
      notes:
          'Shows SFTP-oriented saved configuration plus local and remote port '
          'forward rules for App Review.',
      tags: 'app-review,demo,sftp,port-forward',
      autoConnectSnippetId: deploySnippet.id,
      autoConnectRequiresConfirmation: true,
      sortOrder: 3,
    );
    if (sftpHost.created) {
      createdHosts += 1;
    }

    createdPortForwards += await _ensurePortForward(
      name: 'Review web preview',
      hostId: workspaceHost.id,
      forwardType: 'local',
      localPort: 8080,
      remoteHost: '127.0.0.1',
      remotePort: 3000,
      autoStart: true,
    );
    createdPortForwards += await _ensurePortForward(
      name: 'Review API tunnel',
      hostId: sftpHost.id,
      forwardType: 'local',
      localPort: 8081,
      remoteHost: '127.0.0.1',
      remotePort: 8000,
      autoStart: false,
    );

    await _agentLaunchPresetService.setPresetForHost(
      workspaceHost.id,
      const AgentLaunchPreset(
        tool: AgentLaunchTool.copilotCli,
        workingDirectory: '~/work/monkeyssh-demo',
        tmuxSessionName: 'review-workspace',
        remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        additionalArguments: '--yolo',
      ),
    );
    await _agentLaunchPresetService.setPresetForHost(
      agentHost.id,
      const AgentLaunchPreset(
        tool: AgentLaunchTool.claudeCode,
        workingDirectory: '~/work/monkeyssh-demo',
        tmuxSessionName: 'review-agents',
        remoteMuxBackend: RemoteMuxBackend.monkeyMux,
      ),
    );
    await _hostCliLaunchPreferencesService.setPreferencesForHost(
      workspaceHost.id,
      const HostCliLaunchPreferences(startInYoloMode: true),
    );

    await _settingsService.setString(
      _demoSeededAtSetting,
      DateTime.now().toIso8601String(),
    );

    return AppReviewDemoSetupResult(
      createdHosts: createdHosts,
      createdKeys: createdKeys,
      createdSnippets: createdSnippets,
      createdPortForwards: createdPortForwards,
    );
  }

  Future<int> _ensureGroup() async {
    final groups = await _groupRepository.getAll();
    for (final group in groups) {
      if (group.name == _groupName) {
        return group.id;
      }
    }
    return _groupRepository.insert(
      GroupsCompanion.insert(
        name: _groupName,
        color: const Value('#14756C'),
        icon: const Value('terminal'),
      ),
    );
  }

  Future<int> _ensureSnippetFolder() async {
    final folders = await _snippetRepository.getAllFolders();
    for (final folder in folders) {
      if (folder.name == _snippetFolderName) {
        return folder.id;
      }
    }
    return _snippetRepository.insertFolder(
      SnippetFoldersCompanion.insert(name: _snippetFolderName),
    );
  }

  Future<({bool created, int id})> _ensureKey() async {
    final keys = await _keyRepository.getAll();
    for (final key in keys) {
      if (key.name == _keyName) {
        return (created: false, id: key.id);
      }
    }
    final keyId = await _keyRepository.insert(
      SshKeysCompanion.insert(
        name: _keyName,
        keyType: 'ed25519',
        publicKey: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemoAppReviewOnlyNotARealKey monkeyssh-app-review-demo',
        privateKey: _demoPrivateKey,
        fingerprint: const Value('SHA256:MonkeySSHAppReviewDemoOnly'),
      ),
    );
    return (created: true, id: keyId);
  }

  Future<({bool created, int id})> _ensureSnippet({
    required String name,
    required String command,
    required String description,
    required int folderId,
    required int sortOrder,
  }) async {
    final snippets = await _snippetRepository.getAll();
    for (final snippet in snippets) {
      if (snippet.name == name) {
        return (created: false, id: snippet.id);
      }
    }
    final id = await _snippetRepository.insert(
      SnippetsCompanion.insert(
        name: name,
        command: command,
        description: Value(description),
        folderId: Value(folderId),
        sortOrder: Value(sortOrder),
      ),
    );
    return (created: true, id: id);
  }

  Future<({bool created, int id})> _ensureHost({
    required String label,
    required String hostname,
    required String username,
    required int keyId,
    required int groupId,
    required String color,
    required String notes,
    required String tags,
    required int sortOrder,
    int port = 22,
    int? jumpHostId,
    String? terminalThemeLightId,
    String? terminalThemeDarkId,
    int? autoConnectSnippetId,
    bool autoConnectRequiresConfirmation = false,
    String? tmuxSessionName,
    String? tmuxWorkingDirectory,
    String? tmuxExtraFlags,
    RemoteMuxBackend? remoteMuxBackend,
  }) async {
    final hosts = await _hostRepository.getAll();
    for (final host in hosts) {
      if (host.label == label) {
        return (created: false, id: host.id);
      }
    }
    final id = await _hostRepository.insert(
      HostsCompanion.insert(
        label: label,
        hostname: hostname,
        port: Value(port),
        username: username,
        keyId: Value(keyId),
        groupId: Value(groupId),
        jumpHostId: Value(jumpHostId),
        isFavorite: const Value(true),
        color: Value(color),
        notes: Value(notes),
        tags: Value(tags),
        terminalThemeLightId: Value(terminalThemeLightId),
        terminalThemeDarkId: Value(terminalThemeDarkId),
        autoConnectSnippetId: Value(autoConnectSnippetId),
        autoConnectRequiresConfirmation: Value(autoConnectRequiresConfirmation),
        tmuxSessionName: Value(tmuxSessionName),
        tmuxWorkingDirectory: Value(tmuxWorkingDirectory),
        tmuxExtraFlags: Value(
          remoteMuxBackend == RemoteMuxBackend.monkeyMux
              ? null
              : tmuxExtraFlags,
        ),
        remoteMuxBackend: Value(remoteMuxBackend?.storageValue),
        sortOrder: Value(sortOrder),
      ),
    );
    return (created: true, id: id);
  }

  Future<int> _ensurePortForward({
    required String name,
    required int hostId,
    required String forwardType,
    required int localPort,
    required String remoteHost,
    required int remotePort,
    required bool autoStart,
  }) async {
    final portForwards = await _portForwardRepository.getAll();
    for (final portForward in portForwards) {
      if (portForward.name == name && portForward.hostId == hostId) {
        return 0;
      }
    }
    await _portForwardRepository.insert(
      PortForwardsCompanion.insert(
        name: name,
        hostId: hostId,
        forwardType: forwardType,
        localPort: localPort,
        remoteHost: remoteHost,
        remotePort: remotePort,
        autoStart: Value(autoStart),
      ),
    );
    return 1;
  }
}

/// Provides the local App Review demo setup service.
final appReviewDemoServiceProvider = Provider<AppReviewDemoService>((ref) {
  final settingsService = ref.watch(settingsServiceProvider);
  return AppReviewDemoService(
    groupRepository: ref.watch(groupRepositoryProvider),
    hostRepository: ref.watch(hostRepositoryProvider),
    keyRepository: ref.watch(keyRepositoryProvider),
    snippetRepository: ref.watch(snippetRepositoryProvider),
    portForwardRepository: ref.watch(portForwardRepositoryProvider),
    agentLaunchPresetService: ref.watch(agentLaunchPresetServiceProvider),
    hostCliLaunchPreferencesService: ref.watch(
      hostCliLaunchPreferencesServiceProvider,
    ),
    settingsService: settingsService,
  );
});

/// Whether the local App Review demo workspace has been prepared.
final appReviewDemoPreparedProvider = FutureProvider<bool>((ref) {
  final service = ref.watch(appReviewDemoServiceProvider);
  return service.isPrepared();
});

const _demoPrivateKey = 'app-review-demo-placeholder-key-material';
