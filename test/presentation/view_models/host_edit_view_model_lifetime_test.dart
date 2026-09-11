// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/port_forward_repository.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/host_cli_launch_preferences.dart';
import 'package:monkeyssh/domain/services/agent_launch_preset_service.dart';
import 'package:monkeyssh/domain/services/host_cli_launch_preferences_service.dart';
import 'package:monkeyssh/presentation/view_models/host_edit_view_model.dart';

final _host = Host(
  id: 1,
  label: 'Host',
  hostname: 'example.com',
  port: 22,
  username: 'root',
  isFavorite: false,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  autoConnectRequiresConfirmation: false,
  autoForwardPorts: false,
  sortOrder: 0,
);

class _LoadGate {
  _LoadGate(this.blockedStage);

  final int blockedStage;
  final reached = Completer<void>();
  final release = Completer<void>();
  final calls = <int>[];

  Future<T> run<T>(int stage, T value) async {
    calls.add(stage);
    if (stage == blockedStage) {
      reached.complete();
      await release.future;
    }
    return value;
  }
}

class _Hosts extends Fake implements HostRepository {
  _Hosts(this.gate, this.host);
  final _LoadGate gate;
  final Host? host;

  @override
  Future<Host?> getById(int id) => gate.run(0, host);
}

class _Ports extends Fake implements PortForwardRepository {
  _Ports(this.gate);
  final _LoadGate gate;

  @override
  Future<List<PortForward>> getByHostId(int hostId) => gate.run(1, []);
}

class _Presets extends Fake implements AgentLaunchPresetService {
  _Presets(this.gate);
  final _LoadGate gate;

  @override
  Future<AgentLaunchPreset?> getPresetForHost(int hostId) => gate.run(2, null);
}

class _Preferences extends Fake implements HostCliLaunchPreferencesService {
  _Preferences(this.gate);
  final _LoadGate gate;

  @override
  Future<HostCliLaunchPreferences> getPreferencesForHost(int hostId) =>
      gate.run(3, const HostCliLaunchPreferences());
}

ProviderContainer _container(_LoadGate gate, {Host? host}) => ProviderContainer(
  overrides: [
    hostRepositoryProvider.overrideWithValue(_Hosts(gate, host)),
    portForwardRepositoryProvider.overrideWithValue(_Ports(gate)),
    agentLaunchPresetServiceProvider.overrideWithValue(_Presets(gate)),
    hostCliLaunchPreferencesServiceProvider.overrideWithValue(
      _Preferences(gate),
    ),
  ],
);

void main() {
  for (var stage = 0; stage < 4; stage++) {
    test('load stops after disposal during dependency $stage', () async {
      final gate = _LoadGate(stage);
      final container = _container(gate, host: _host);
      final provider = hostEditViewModelProvider(_host.id);
      final subscription = container.listen(provider, (_, _) {});
      final viewModel = container.read(provider.notifier);
      final loading = viewModel.loadHost();
      await gate.reached.future;

      subscription.close();
      await container.pump();
      gate.release.complete();

      expect(await loading, isNull);
      expect(gate.calls, List.generate(stage + 1, (index) => index));
      container.dispose();
    });
  }

  test('missing host completion after container disposal is ignored', () async {
    final gate = _LoadGate(0);
    final container = _container(gate);
    final loading = container
        .read(hostEditViewModelProvider(1).notifier)
        .loadHost();
    await gate.reached.future;
    container.dispose();
    gate.release.complete();
    expect(await loading, isNull);
    expect(gate.calls, [0]);
  });

  test('mounted load still publishes all host dependencies', () async {
    final gate = _LoadGate(3);
    final container = _container(gate, host: _host);
    addTearDown(container.dispose);
    final provider = hostEditViewModelProvider(_host.id);
    final subscription = container.listen(provider, (_, _) {});
    addTearDown(subscription.close);
    final loading = container.read(provider.notifier).loadHost();
    await gate.reached.future;
    expect(container.read(provider).isLoading, isTrue);
    gate.release.complete();

    expect((await loading)!.host, _host);
    expect(container.read(provider).existingHost, _host);
    expect(container.read(provider).isLoading, isFalse);
    expect(gate.calls, [0, 1, 2, 3]);
  });
}
