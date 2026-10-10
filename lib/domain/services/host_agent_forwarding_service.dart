import 'dart:async';

import 'package:collection/collection.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import '../../data/repositories/key_repository.dart';
import '../models/monetization.dart';
import 'auth_service.dart';
import 'diagnostics_log_service.dart';
import 'monetization_service.dart';
import 'openssh_key_generator.dart';
import 'serial_task_queue.dart';
import 'settings_service.dart';
import 'ssh_agent_forwarding.dart';

/// A host's SSH agent forwarding settings. Forwarding defaults to off.
@immutable
class HostAgentForwardingSettings {
  /// Creates [HostAgentForwardingSettings].
  const HostAgentForwardingSettings({
    this.enabled = false,
    this.confirmEachSignature = false,
    this.keyIds = const [],
  });

  /// Reads settings saved by [toJson]; anything but a literal `true` is off,
  /// and only integer key IDs are kept.
  factory HostAgentForwardingSettings.fromJson(Map<String, dynamic> json) {
    final rawKeyIds = json['keyIds'];
    return HostAgentForwardingSettings(
      enabled: json['enabled'] == true,
      confirmEachSignature: json['confirmEachSignature'] == true,
      keyIds: rawKeyIds is List
          ? List.unmodifiable(rawKeyIds.whereType<int>().toSet())
          : const [],
    );
  }

  /// Whether the host may use the app's keys through agent forwarding.
  final bool enabled;

  /// Whether each signature asks the user first.
  final bool confirmEachSignature;

  /// The app keys the host may use, by key ID, in the order offered.
  final List<int> keyIds;

  /// Whether nothing differs from the defaults.
  bool get isDefault => !enabled && !confirmEachSignature && keyIds.isEmpty;

  /// Returns a copy with the given fields replaced.
  HostAgentForwardingSettings copyWith({
    bool? enabled,
    bool? confirmEachSignature,
    List<int>? keyIds,
  }) => HostAgentForwardingSettings(
    enabled: enabled ?? this.enabled,
    confirmEachSignature: confirmEachSignature ?? this.confirmEachSignature,
    keyIds: keyIds ?? this.keyIds,
  );

  /// JSON form stored in app settings.
  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'confirmEachSignature': confirmEachSignature,
    'keyIds': keyIds,
  };

  @override
  bool operator ==(Object other) =>
      other is HostAgentForwardingSettings &&
      other.enabled == enabled &&
      other.confirmEachSignature == confirmEachSignature &&
      const ListEquality<int>().equals(other.keyIds, keyIds);

  @override
  int get hashCode =>
      Object.hash(enabled, confirmEachSignature, Object.hashAll(keyIds));
}

/// Persists per-host agent forwarding settings in app settings.
///
/// Stored as one JSON map keyed by host ID, like other host-scoped
/// preferences, so no database migration is needed. Host IDs are never
/// reused, so a deleted host's entry cannot turn forwarding on for a new one.
class HostAgentForwardingService {
  /// Creates a [HostAgentForwardingService].
  HostAgentForwardingService(this._settings);

  final SettingsService _settings;
  final _changes = StreamController<int>.broadcast();
  final _turnedOff = <int>{};

  /// Host IDs whose settings were saved through this service, so live
  /// connections can apply a change at once.
  Stream<int> get changes => _changes.stream;

  /// Releases the change stream.
  Future<void> dispose() => _changes.close();

  /// Loads the settings for [hostId].
  Future<HostAgentForwardingSettings> getForHost(int hostId) async {
    final saved = await _settings.getJson(SettingKeys.hostAgentForwarding);
    final value = saved?[hostId.toString()];
    final stored = value is Map<String, dynamic>
        ? HostAgentForwardingSettings.fromJson(value)
        : const HostAgentForwardingSettings();
    return _turnedOff.contains(hostId)
        ? stored.copyWith(enabled: false)
        : stored;
  }

  /// Turns forwarding off for [hostId] at once and saves that.
  ///
  /// The host reads as off from this moment for the rest of the app session,
  /// so a reconnect cannot resume forwarding while the save is still running
  /// or if it fails. Saving the host with forwarding on clears it.
  Future<void> turnOff(int hostId) async {
    _turnedOff.add(hostId);
    if (!_changes.isClosed) {
      _changes.add(hostId);
    }
    final current = await getForHost(hostId);
    await setForHost(hostId, current.copyWith(enabled: false));
  }

  /// Saves [settings] for [hostId].
  Future<void> setForHost(
    int hostId,
    HostAgentForwardingSettings settings,
  ) async {
    await _settings.updateJson(SettingKeys.hostAgentForwarding, (current) {
      final saved = current ?? <String, dynamic>{};
      if (settings.isDefault) {
        saved.remove(hostId.toString());
      } else {
        saved[hostId.toString()] = settings.toJson();
      }
      return saved.isEmpty ? null : saved;
    });
    // Only once forwarding on is actually stored.
    if (settings.enabled) {
      _turnedOff.remove(hostId);
    }
    if (!_changes.isClosed) {
      _changes.add(hostId);
    }
  }
}

/// Provider for [HostAgentForwardingService].
final hostAgentForwardingServiceProvider = Provider<HostAgentForwardingService>(
  (ref) {
    final service = HostAgentForwardingService(
      ref.watch(settingsServiceProvider),
    );
    ref.onDispose(() => unawaited(service.dispose()));
    return service;
  },
);

/// Saved agent forwarding settings for one host.
final hostAgentForwardingSettingsProvider = FutureProvider.autoDispose
    .family<HostAgentForwardingSettings, int>((ref, hostId) {
      final service = ref.watch(hostAgentForwardingServiceProvider);
      // Follow saves made elsewhere, such as "Deny and turn off forwarding".
      final subscription = service.changes
          .where((changed) => changed == hostId)
          .listen((_) => ref.invalidateSelf());
      ref.onDispose(subscription.cancel);
      return service.getForHost(hostId);
    });

/// Shows the per-signature confirmation and resolves with the user's answer.
///
/// The prompt closes itself, resolving [SshAgentSignatureDecision.declined],
/// once [timeout] passes, the app leaves the foreground, or the request's
/// connection closes.
typedef SshAgentSignaturePromptHandler =
    Future<SshAgentSignatureDecision> Function(
      SshAgentSignatureRequest request, {
      required Duration timeout,
    });

/// Provider for the UI-backed per-signature prompt. Null refuses every
/// signature that needs confirmation.
final sshAgentSignaturePromptHandlerProvider =
    Provider<SshAgentSignaturePromptHandler?>((_) => null);

/// Asks for per-signature confirmations one at a time.
///
/// Refuses without asking while the app cannot show a prompt, such as when it
/// is in the background or locked.
class SshAgentSignatureConfirmations {
  /// Creates [SshAgentSignatureConfirmations].
  SshAgentSignatureConfirmations({
    required bool Function() canPrompt,
    required SshAgentSignaturePromptHandler? Function() promptHandler,
    this.timeout = const Duration(seconds: 60),
  }) : _canPrompt = canPrompt,
       _promptHandler = promptHandler;

  /// How long a prompt waits for an answer before refusing.
  final Duration timeout;

  // A prompt that does not close itself is refused this long after [timeout].
  static const _closeGrace = Duration(seconds: 5);

  final bool Function() _canPrompt;
  final SshAgentSignaturePromptHandler? Function() _promptHandler;
  final _queue = SerialTaskQueue();

  /// Asks about [request] after any prompt already showing is answered.
  Future<SshAgentSignatureDecision> confirm(SshAgentSignatureRequest request) =>
      _queue.run(() => _confirmNow(request));

  Future<SshAgentSignatureDecision> _confirmNow(
    SshAgentSignatureRequest request,
  ) async {
    final handler = _promptHandler();
    if (request.isConnectionClosed() || handler == null || !_canPrompt()) {
      return SshAgentSignatureDecision.unavailable;
    }
    return Future.any<SshAgentSignatureDecision>([
      handler(request, timeout: timeout).then(
        (decision) => decision == SshAgentSignatureDecision.unavailable
            ? SshAgentSignatureDecision.declined
            : decision,
        onError: (Object _, StackTrace _) => SshAgentSignatureDecision.declined,
      ),
      request.connectionClosed.then(
        (_) => SshAgentSignatureDecision.unavailable,
      ),
    ]).timeout(
      timeout + _closeGrace,
      onTimeout: () => SshAgentSignatureDecision.declined,
    );
  }
}

/// Whether the app can show an agent signature prompt right now: it is in the
/// foreground and unlocked.
bool canPromptForAgentSignature({
  required AppLifecycleState? lifecycleState,
  required AuthState authState,
}) =>
    lifecycleState == AppLifecycleState.resumed &&
    (authState == AuthState.unlocked || authState == AuthState.notConfigured);

/// Provider for the app's [SshAgentSignatureConfirmations].
final sshAgentSignatureConfirmationsProvider =
    Provider<SshAgentSignatureConfirmations>(
      (ref) => SshAgentSignatureConfirmations(
        canPrompt: () => canPromptForAgentSignature(
          lifecycleState: WidgetsBinding.instance.lifecycleState,
          authState: ref.read(authStateProvider),
        ),
        promptHandler: () => ref.read(sshAgentSignaturePromptHandlerProvider),
      ),
    );

/// Loads the keys a host forwards, reusing keys it has already parsed.
///
/// Keys are read from the repository every time, so a key deleted or edited
/// in the app stops being offered on the next request. Public-only keys and
/// keys whose passphrase is missing or wrong are left out. Hardware-backed
/// keys can join the result as asynchronous [SshAgentKey.identity] signers.
class ForwardedAgentKeyLoader {
  /// Creates a [ForwardedAgentKeyLoader] reading from [repository].
  ///
  /// One loader serves one connection, so its cache only ever holds keys that
  /// connection's host may use.
  ForwardedAgentKeyLoader(
    this._repository, {
    Future<List<List<SSHKeyPair>>> Function(List<(String, String?)> keys)?
    parse,
  }) : _parse = parse ?? parseOpenSshPrivateKeys;

  final KeyRepository _repository;
  final Future<List<List<SSHKeyPair>>> Function(List<(String, String?)> keys)
  _parse;
  final _parsed =
      <
        int,
        ({String privateKey, String? passphrase, List<SSHKeyPair> pairs})
      >{};

  /// Loads the keys with [keyIds], in that order.
  Future<List<SshAgentKey>> load(List<int> keyIds) async {
    final keys = <SshKey>[];
    for (final id in keyIds.toSet()) {
      final key = await _repository.getById(id);
      if (key == null ||
          key.privateKey.trim().isEmpty ||
          _repository.hasUnreadablePrivateKey(id) ||
          _repository.hasUnreadablePassphrase(id)) {
        continue;
      }
      keys.add(key);
    }
    // Everything this load returns is collected here, so another load that
    // prunes the cache while this one waits on parsing cannot take it away.
    final pairsById = <int, List<SSHKeyPair>>{};
    final stale = <SshKey>[];
    for (final key in keys) {
      final cached = _parsed[key.id];
      if (cached != null &&
          cached.privateKey == key.privateKey &&
          cached.passphrase == key.passphrase) {
        pairsById[key.id] = cached.pairs;
      } else {
        stale.add(key);
      }
    }
    if (stale.isNotEmpty) {
      final parsed = await _parse([
        for (final key in stale) (key.privateKey, key.passphrase),
      ]);
      for (var index = 0; index < stale.length; index++) {
        final key = stale[index];
        pairsById[key.id] = parsed[index];
        _parsed[key.id] = (
          privateKey: key.privateKey,
          passphrase: key.passphrase,
          pairs: parsed[index],
        );
      }
    }
    // Forget keys this host no longer uses or that were deleted.
    _parsed.removeWhere((id, _) => !pairsById.containsKey(id));
    return [
      for (final key in keys)
        for (final pair in pairsById[key.id]!)
          SshAgentKey(label: key.name, identity: pair),
    ];
  }
}

/// Builds the forwarding handler for [host] when it opted in and Pro is
/// unlocked; otherwise returns null. Fails closed: if the settings cannot be
/// read, forwarding stays off.
///
/// The handler reads the host's settings again as requests arrive and when
/// [settingsChanges] reports this host, so turning forwarding off, turning
/// confirmation on, or changing the keys applies to the open connection.
Future<SshAgentForwarding?> resolveHostAgentForwarding(
  Host host, {
  required Future<HostAgentForwardingSettings> Function(int hostId)
  loadSettings,
  required Future<bool> Function() isUnlocked,
  required Future<List<SshAgentKey>> Function(List<int> keyIds) loadKeys,
  required SshAgentSignatureConfirmer confirm,
  Stream<int>? settingsChanges,
  Future<void> Function(int hostId)? turnOff,
  DiagnosticsLogger? diagnostics,
}) async {
  final logger = diagnostics ?? DiagnosticsLogService.instance;
  final HostAgentForwardingSettings hostSettings;
  try {
    hostSettings = await loadSettings(host.id);
  } on Exception catch (error) {
    logger.warning(
      'ssh.agent',
      'settings_load_failed',
      fields: {'hostId': host.id, 'errorType': error.runtimeType},
    );
    return null;
  }
  if (!hostSettings.enabled) {
    return null;
  }
  if (!await isUnlocked()) {
    logger.info(
      'ssh.agent',
      'forwarding_skipped',
      fields: {'hostId': host.id, 'reason': 'pro_required'},
    );
    return null;
  }
  logger.info(
    'ssh.agent',
    'forwarding_enabled',
    fields: {
      'hostId': host.id,
      'confirm': hostSettings.confirmEachSignature,
      'keyCount': hostSettings.keyIds.length,
    },
  );
  return SshAgentForwarding(
    hostId: host.id,
    hostLabel: host.label,
    initiallyConfirmEachSignature: hostSettings.confirmEachSignature,
    loadPolicy: () async {
      final current = await loadSettings(host.id);
      if (!current.enabled) {
        return SshAgentForwardingPolicy.off;
      }
      return SshAgentForwardingPolicy(
        enabled: true,
        confirmEachSignature: current.confirmEachSignature,
        keys: await loadKeys(current.keyIds),
      );
    },
    policyChanges: settingsChanges?.where((hostId) => hostId == host.id),
    confirm: confirm,
    // "Deny and turn off forwarding" outlasts the connection: it turns the
    // host's setting off until the user turns it on again.
    onStop: turnOff == null
        ? null
        : () => unawaited(
            turnOff(host.id).catchError((Object error) {
              logger.warning(
                'ssh.agent',
                'stop_save_failed',
                fields: {'hostId': host.id, 'errorType': error.runtimeType},
              );
            }),
          ),
    diagnostics: logger,
  );
}

/// Whether Pro unlocks agent forwarding, without waiting long on the store.
Future<bool> _agentForwardingUnlocked(MonetizationService service) async {
  const feature = MonetizationFeature.agentForwarding;
  try {
    return await service
        .canUseFeature(feature)
        .timeout(
          const Duration(seconds: 2),
          onTimeout: () => service.currentState.allowsFeature(feature),
        );
  } on Exception {
    return service.currentState.allowsFeature(feature);
  }
}

/// Provider for the [SshAgentForwardingResolver] the SSH service uses.
///
/// Everything is read when a host connects, not when the SSH service is
/// built, so the service never rebuilds (and drops its sessions) because a
/// dependency changed.
final sshAgentForwardingResolverProvider = Provider<SshAgentForwardingResolver>(
  (ref) => (host) {
    final settings = ref.read(hostAgentForwardingServiceProvider);
    final keyLoader = ForwardedAgentKeyLoader(ref.read(keyRepositoryProvider));
    return resolveHostAgentForwarding(
      host,
      loadSettings: settings.getForHost,
      turnOff: settings.turnOff,
      settingsChanges: settings.changes,
      isUnlocked: () =>
          _agentForwardingUnlocked(ref.read(monetizationServiceProvider)),
      loadKeys: keyLoader.load,
      confirm: (request) =>
          ref.read(sshAgentSignatureConfirmationsProvider).confirm(request),
    );
  },
);
