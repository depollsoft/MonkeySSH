import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/acp_provider.dart';
import 'settings_service.dart';

/// Loads persisted ACP provider definitions.
///
/// This service only manages provider *configuration* (built-in presets plus
/// user-approved custom launch commands). It never reads, logs, or persists
/// ACP session transcripts, prompts, or command output.
class AcpProviderService {
  /// Creates a new [AcpProviderService].
  AcpProviderService(this._settings);

  final SettingsService _settings;

  /// All built-in ACP providers bundled with the app.
  List<AcpBuiltinProvider> get builtinProviders => acpBuiltinProviders;

  /// Loads all persisted custom provider definitions, in stored order.
  ///
  /// Malformed storage (invalid JSON, an unexpected shape, or entries that
  /// fail validation) is handled defensively: unreadable entries are skipped
  /// rather than surfaced as an error, so a single corrupt entry never
  /// prevents the rest of the list from loading.
  Future<List<AcpCustomProviderDefinition>> listCustomProviders() async {
    final raw = await _settings.getString(SettingKeys.acpCustomProviders);
    return _decodeCustomProviders(raw);
  }

  /// Loads a single persisted custom provider by [id], if one exists.
  Future<AcpCustomProviderDefinition?> getCustomProvider(String id) async {
    final providers = await listCustomProviders();
    return providers.firstWhereOrNull((provider) => provider.id == id);
  }

  /// Streams the combined list of built-in providers followed by persisted
  /// custom providers, re-emitting automatically whenever custom provider
  /// storage changes.
  ///
  /// Backed by [SettingsService.watchString], so callers (including
  /// [acpProvidersProvider]) never need to manually invalidate or refetch
  /// after imported settings change.
  Stream<List<AcpProvider>> watchAllProviders() => _settings
      .watchString(SettingKeys.acpCustomProviders)
      .map((raw) => _combineProviders(_decodeCustomProviders(raw)));

  // Shared defensive decoding used by both the one-shot future path
  // (listCustomProviders) and the reactive stream path (watchAllProviders),
  // so malformed storage is handled identically no matter how it is read.
  List<AcpCustomProviderDefinition> _decodeCustomProviders(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const [];
    }

    List<dynamic> decoded;
    try {
      final value = jsonDecode(raw);
      if (value is! List) {
        return const [];
      }
      decoded = value;
    } on FormatException {
      return const [];
    }

    final definitions = <AcpCustomProviderDefinition>[];
    for (final item in decoded) {
      final definition = AcpCustomProviderDefinition.tryFromJson(item);
      if (definition != null) {
        definitions.add(definition);
      }
    }
    return List.unmodifiable(definitions);
  }

  List<AcpProvider> _combineProviders(
    List<AcpCustomProviderDefinition> customProviders,
  ) => [...builtinProviders, ...customProviders];
}

/// Provider for [AcpProviderService].
final acpProviderServiceProvider = Provider<AcpProviderService>(
  (ref) => AcpProviderService(ref.watch(settingsServiceProvider)),
);

/// Provider for the combined list of built-in and persisted custom ACP
/// providers.
///
/// Backed by [AcpProviderService.watchAllProviders], which streams from
/// [SettingsService.watchString]. Watchers therefore refresh automatically
/// after imported settings change; callers never need to manually
/// invalidate this provider.
final acpProvidersProvider = StreamProvider<List<AcpProvider>>(
  (ref) => ref.watch(acpProviderServiceProvider).watchAllProviders(),
);
