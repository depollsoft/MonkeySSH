import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/security/secret_encryption_service.dart';
import '../models/acp_json.dart';
import '../models/acp_mcp_server.dart';
import 'settings_json_list.dart';
import 'settings_service.dart';

/// Raised when an MCP server definition fails validation on save.
final class AcpMcpServerValidationException implements Exception {
  /// Creates a validation failure with a user-facing [message].
  const AcpMcpServerValidationException(this.message);

  /// Short user-facing reason.
  final String message;

  @override
  String toString() => 'AcpMcpServerValidationException($message)';
}

/// Persists user-defined MCP servers for native agent sessions.
///
/// Definitions live in [SettingsService] as a JSON array. Environment
/// variable values and HTTP header values are frequently credentials, so each
/// one is encrypted with [SecretEncryptionService] (an AES-GCM key held in the
/// platform keychain/keystore) before it is written; names, commands, and URLs
/// are stored as plain configuration. Nothing here is logged.
class AcpMcpServerService {
  /// Creates an MCP server store.
  AcpMcpServerService(this._settings, this._encryption, {Random? random})
    : _random = random ?? Random.secure();

  final SettingsService _settings;
  final SecretEncryptionService _encryption;
  final Random _random;

  final _mutations = SerializedMutations();

  /// Loads every configured server, in stored order, with secrets decrypted.
  ///
  /// Malformed entries are skipped. A value that cannot be decrypted (for
  /// example after moving settings to another device) is returned empty and
  /// the server is flagged [AcpMcpServerConfig.hasUnreadableSecrets].
  Future<List<AcpMcpServerConfig>> listServers() async =>
      _decode(await _settings.getString(SettingKeys.acpMcpServers));

  /// Streams the configured servers, re-emitting whenever storage changes.
  Stream<List<AcpMcpServerConfig>> watchServers() =>
      _settings.watchString(SettingKeys.acpMcpServers).asyncMap(_decode);

  /// Creates a fresh, stable local server id.
  String newServerId() {
    final buffer = StringBuffer('mcp-');
    for (var index = 0; index < 8; index++) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  /// Inserts or replaces [server] (matched by id) after validating it.
  ///
  /// Throws [AcpMcpServerValidationException] when the definition is invalid,
  /// its name collides with another server, or the server limit is reached.
  Future<AcpMcpServerConfig> saveServer(AcpMcpServerConfig server) async {
    final normalized = _normalized(server);
    await _mutations.run(() async {
      final entries = await _readRawEntries();
      final otherNames = <String>[
        for (final entry in entries)
          if (entry['id'] != normalized.id) ?_string(entry['name']),
      ];
      final error = AcpMcpServerValidation.server(
        normalized,
        otherNames: otherNames,
      );
      if (error != null) throw AcpMcpServerValidationException(error);
      final index = entries.indexWhere((entry) => entry['id'] == normalized.id);
      final encoded = await _encode(
        normalized,
        previous: index >= 0 ? entries[index] : null,
      );
      if (index >= 0) {
        entries[index] = encoded;
      } else {
        if (entries.length >= kAcpMcpServerMaxCount) {
          throw const AcpMcpServerValidationException(
            'You can save up to $kAcpMcpServerMaxCount MCP servers.',
          );
        }
        entries.add(encoded);
      }
      await _writeRawEntries(entries);
    });
    return normalized;
  }

  /// Removes the server identified by [id], if present.
  Future<void> deleteServer(String id) => _mutations.run(() async {
    final entries = await _readRawEntries();
    final before = entries.length;
    entries.removeWhere((entry) => entry['id'] == id);
    if (entries.length != before) await _writeRawEntries(entries);
  });

  /// Sets whether new sessions attach the server [id] by default.
  ///
  /// Only the flag is rewritten: stored secrets are never decrypted or
  /// re-encrypted, so an unreadable server keeps its original ciphertext.
  Future<void> setUseByDefault(String id, {required bool enabled}) =>
      _mutations.run(() async {
        final entries = await _readRawEntries();
        final index = entries.indexWhere((entry) => entry['id'] == id);
        if (index < 0) return;
        entries[index] = <String, Object?>{
          ...entries[index],
          'useByDefault': enabled,
        };
        await _writeRawEntries(entries);
      });

  AcpMcpServerConfig _normalized(AcpMcpServerConfig server) {
    List<AcpMcpNameValue> trimNames(List<AcpMcpNameValue> values) => [
      for (final value in values)
        AcpMcpNameValue(name: value.name.trim(), value: value.value),
    ];
    return server.transport.isRemote
        ? server.copyWith(
            name: server.name.trim(),
            command: '',
            args: const <String>[],
            env: const <AcpMcpNameValue>[],
            url: server.url.trim(),
            headers: trimNames(server.headers),
            hasUnreadableSecrets: false,
          )
        : server.copyWith(
            name: server.name.trim(),
            command: server.command.trim(),
            env: trimNames(server.env),
            url: '',
            headers: const <AcpMcpNameValue>[],
            hasUnreadableSecrets: false,
          );
  }

  /// Encodes [server] for storage, encrypting its secret values.
  ///
  /// A secret that could not be decrypted is loaded blank. If it is still
  /// blank when [previous] (the stored entry being replaced) is saved over,
  /// its original ciphertext is kept, so an unrelated edit never erases it.
  Future<AcpJsonMap> _encode(
    AcpMcpServerConfig server, {
    AcpJsonMap? previous,
  }) async {
    Future<List<AcpJsonMap>> encodePairs(
      List<AcpMcpNameValue> pairs,
      Object? previousPairs,
    ) async {
      final unreadable = await _unreadableStoredValues(previousPairs);
      return [
        for (final pair in pairs)
          <String, Object?>{
            'name': pair.name,
            // Repeated names (such as two headers) keep their own values,
            // matched in stored order.
            'value':
                pair.value.isEmpty &&
                    (unreadable[pair.name]?.isNotEmpty ?? false)
                ? unreadable[pair.name]!.removeFirst()
                : await _encryption.encryptRequired(pair.value),
          },
      ];
    }

    return <String, Object?>{
      'id': server.id,
      'name': server.name,
      'transport': server.transport.storageValue,
      if (!server.transport.isRemote) ...<String, Object?>{
        'command': server.command,
        'args': server.args,
        'env': await encodePairs(server.env, previous?['env']),
      } else ...<String, Object?>{
        'url': server.url,
        'headers': await encodePairs(server.headers, previous?['headers']),
      },
      'useByDefault': server.useByDefault,
    };
  }

  /// Stored ciphertexts in [pairs] that cannot be decrypted, by pair name
  /// in stored order. A name without any is absent.
  Future<Map<String, Queue<String>>> _unreadableStoredValues(
    Object? pairs,
  ) async {
    final unreadable = <String, Queue<String>>{};
    if (pairs is! List) return unreadable;
    for (final item in pairs) {
      if (item is! Map) continue;
      final name = _string(item['name'])?.trim();
      final stored = _string(item['value']) ?? '';
      if (name == null || name.isEmpty || stored.isEmpty) continue;
      try {
        await _encryption.decryptNullable(stored);
      } on Object {
        unreadable.putIfAbsent(name, Queue<String>.new).add(stored);
      }
    }
    return unreadable;
  }

  Future<List<AcpMcpServerConfig>> _decode(String? raw) async {
    final servers = <AcpMcpServerConfig>[];
    final seenIds = <String>{};
    for (final entry in _decodeRawEntries(raw)) {
      final server = await _decodeEntry(entry);
      if (server == null || !seenIds.add(server.id)) continue;
      servers.add(server);
      if (servers.length >= kAcpMcpServerMaxCount) break;
    }
    return List<AcpMcpServerConfig>.unmodifiable(servers);
  }

  Future<AcpMcpServerConfig?> _decodeEntry(AcpJsonMap entry) async {
    final id = _string(entry['id'])?.trim();
    final name = _string(entry['name'])?.trim();
    final transport = AcpMcpServerTransport.fromStorageValue(
      entry['transport'],
    );
    if (id == null ||
        id.isEmpty ||
        id.length > acpMaxIdentifierCharacters ||
        name == null ||
        name.isEmpty ||
        transport == null) {
      return null;
    }
    var unreadable = false;
    Future<List<AcpMcpNameValue>> decodePairs(Object? value) async {
      final pairs = <AcpMcpNameValue>[];
      if (value is! List) return pairs;
      for (final item in value.take(kAcpMcpServerMaxEntries)) {
        if (item is! Map) continue;
        final pairName = _string(item['name']);
        if (pairName == null || pairName.isEmpty) continue;
        final stored = _string(item['value']) ?? '';
        var plain = '';
        if (stored.isNotEmpty) {
          try {
            plain = await _encryption.decryptNullable(stored) ?? '';
          } on Object {
            unreadable = true;
          }
        }
        pairs.add(AcpMcpNameValue(name: pairName, value: plain));
      }
      return pairs;
    }

    final useByDefault = entry['useByDefault'] == true;
    if (transport.isRemote) {
      final url = _string(entry['url']) ?? '';
      final headers = await decodePairs(entry['headers']);
      return AcpMcpServerConfig(
        id: id,
        name: name,
        transport: transport,
        url: url,
        headers: headers,
        useByDefault: useByDefault,
        hasUnreadableSecrets: unreadable,
      );
    }
    final command = _string(entry['command']) ?? '';
    final args = entry['args'] is List
        ? <String>[
            for (final arg in (entry['args']! as List).take(
              kAcpMcpServerMaxEntries,
            ))
              if (arg is String) arg,
          ]
        : const <String>[];
    final env = await decodePairs(entry['env']);
    return AcpMcpServerConfig(
      id: id,
      name: name,
      transport: transport,
      command: command,
      args: args,
      env: env,
      useByDefault: useByDefault,
      hasUnreadableSecrets: unreadable,
    );
  }

  Future<List<AcpJsonMap>> _readRawEntries() async =>
      _decodeRawEntries(await _settings.getString(SettingKeys.acpMcpServers));

  List<AcpJsonMap> _decodeRawEntries(String? raw) => <AcpJsonMap>[
    for (final item in decodeJsonList(raw))
      if (item is Map) item.cast<String, Object?>(),
  ];

  Future<void> _writeRawEntries(List<AcpJsonMap> entries) async {
    if (entries.isEmpty) {
      await _settings.delete(SettingKeys.acpMcpServers);
      return;
    }
    await _settings.setString(SettingKeys.acpMcpServers, jsonEncode(entries));
  }

  static String? _string(Object? value) => value is String ? value : null;
}

/// Provider for [AcpMcpServerService].
final acpMcpServerServiceProvider = Provider<AcpMcpServerService>(
  (ref) => AcpMcpServerService(
    ref.watch(settingsServiceProvider),
    ref.watch(secretEncryptionServiceProvider),
  ),
);

/// Streams the configured MCP servers.
final acpMcpServersProvider = StreamProvider<List<AcpMcpServerConfig>>(
  (ref) => ref.watch(acpMcpServerServiceProvider).watchServers(),
);
