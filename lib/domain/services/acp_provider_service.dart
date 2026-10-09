import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/acp_provider.dart';
import 'settings_json_list.dart';
import 'settings_service.dart';

/// Raised when a custom agent definition cannot be saved, approved or
/// imported. [message] is short, user-facing and free of user content.
final class AcpCustomProviderException implements Exception {
  /// Creates an exception with a user-facing [message].
  const AcpCustomProviderException(this.message);

  /// Short user-facing reason.
  final String message;

  @override
  String toString() => 'AcpCustomProviderException($message)';
}

/// Looks up user-defined ACP providers by ID at launch time.
abstract interface class AcpCustomProviderLookup {
  /// The stored definition for [id], or `null` when there is none.
  Future<AcpCustomProviderDefinition?> getCustomProvider(String id);
}

/// Counts from importing custom agent definitions.
final class AcpCustomProviderImportResult {
  /// Creates an import result.
  const AcpCustomProviderImportResult({
    required this.added,
    required this.replaced,
    required this.needsApproval,
  });

  /// Definitions with a new ID.
  final int added;

  /// Definitions that replaced a local one with the same ID.
  final int replaced;

  /// Imported definitions that must be reviewed before they can launch.
  final int needsApproval;

  /// Total definitions imported.
  int get total => added + replaced;
}

/// Persists user-defined ACP agent definitions and their approvals.
///
/// Definitions live in [SettingsService] as a JSON array under
/// [SettingKeys.acpCustomProviders]. Approval is device-local: exports never
/// carry it, and an imported or edited definition launches only after the
/// user approves its exact fingerprint. Nothing here is logged, and only
/// environment variable names are ever stored.
class AcpCustomProviderService implements AcpCustomProviderLookup {
  /// Creates a custom provider store.
  AcpCustomProviderService(
    this._settings, {
    DateTime Function() clock = DateTime.now,
  }) : _clock = clock;

  final SettingsService _settings;
  final DateTime Function() _clock;
  final _mutations = SerializedMutations();

  /// Loads every stored definition in display order. Unreadable entries are
  /// skipped.
  Future<List<AcpCustomProviderDefinition>> listCustomProviders() async =>
      _decode(await _settings.getString(SettingKeys.acpCustomProviders));

  /// Streams the stored definitions, re-emitting whenever storage changes
  /// (including after a migration import).
  Stream<List<AcpCustomProviderDefinition>> watchCustomProviders() =>
      _settings.watchString(SettingKeys.acpCustomProviders).map(_decode);

  @override
  Future<AcpCustomProviderDefinition?> getCustomProvider(String id) async =>
      (await listCustomProviders()).firstWhereOrNull(
        (definition) => definition.id == id,
      );

  /// Saves a new, unapproved definition with an ID derived from [label].
  ///
  /// Throws [AcpCustomProviderException] when a field is invalid or the
  /// definition limit is reached.
  Future<AcpCustomProviderDefinition> create({
    required String label,
    required AcpLaunchCommand launchCommand,
    Iterable<String> environmentVariableNames = const <String>[],
    AcpCustomProviderCwdPolicy cwdPolicy =
        AcpCustomProviderCwdPolicy.chosenDirectory,
  }) async {
    late AcpCustomProviderDefinition created;
    await _mutate((definitions) {
      if (definitions.length >= acpCustomProviderMaxCount) {
        throw const AcpCustomProviderException(
          'You can save up to $acpCustomProviderMaxCount custom agents.',
        );
      }
      created = _validated(
        () => AcpCustomProviderDefinition.create(
          id: suggestAcpCustomProviderId(label, {
            for (final definition in definitions) definition.id,
          }),
          label: label,
          launchCommand: launchCommand,
          environmentVariableNames: environmentVariableNames,
          cwdPolicy: cwdPolicy,
          now: _clock(),
        ),
      );
      return [...definitions, created];
    });
    return created;
  }

  /// Saves edits to the definition [id].
  ///
  /// Changing what runs (the command, environment variable names or working
  /// directory policy) leaves the definition unapproved until it is reviewed
  /// again; renaming keeps its approval.
  Future<AcpCustomProviderDefinition> update(
    String id, {
    required String label,
    required AcpLaunchCommand launchCommand,
    required Iterable<String> environmentVariableNames,
    required AcpCustomProviderCwdPolicy cwdPolicy,
  }) async {
    late AcpCustomProviderDefinition updated;
    await _mutate((definitions) {
      final index = definitions.indexWhere((candidate) => candidate.id == id);
      if (index < 0) throw const AcpCustomProviderException(_missingMessage);
      updated = _validated(
        () => definitions[index].edit(
          label: label,
          launchCommand: launchCommand,
          environmentVariableNames: environmentVariableNames,
          cwdPolicy: cwdPolicy,
          now: _clock(),
        ),
      );
      return [...definitions]..[index] = updated;
    });
    return updated;
  }

  /// Approves definition [id] for launch.
  ///
  /// [reviewedFingerprint] is the fingerprint the user was shown. When the
  /// stored definition has changed since, nothing is approved and an
  /// [AcpCustomProviderException] asks the user to review it again.
  Future<AcpCustomProviderDefinition> approve(
    String id, {
    required String reviewedFingerprint,
  }) async {
    late AcpCustomProviderDefinition approved;
    await _mutate((definitions) {
      final index = definitions.indexWhere((candidate) => candidate.id == id);
      if (index < 0) throw const AcpCustomProviderException(_missingMessage);
      final current = definitions[index];
      if (current.fingerprint != reviewedFingerprint) {
        throw const AcpCustomProviderException(
          'This agent changed while you were reviewing it. Review it again.',
        );
      }
      approved = current.approve(now: _clock());
      return [...definitions]..[index] = approved;
    });
    return approved;
  }

  /// Removes the definition [id], if present.
  Future<void> delete(String id) => _mutate(
    (definitions) => [
      for (final definition in definitions)
        if (definition.id != id) definition,
    ],
  );

  /// Encodes the definitions in [ids] (or every definition) for sharing.
  ///
  /// The document never carries approvals or environment variable values.
  Future<String> export({Set<String>? ids}) async {
    final definitions = await listCustomProviders();
    return encodeAcpCustomProviderExport(
      ids == null
          ? definitions
          : definitions.where((definition) => ids.contains(definition.id)),
    );
  }

  /// Imports definitions from an export document.
  ///
  /// Imported definitions replace local ones with the same ID and arrive
  /// unapproved, unless this device had already approved the identical
  /// fingerprint. Throws [AcpCustomProviderException] for an invalid document
  /// or when the import would exceed the definition limit.
  Future<AcpCustomProviderImportResult> import(String text) async {
    final imported = _validated(
      () => decodeAcpCustomProviderImport(text, now: _clock()),
    );
    late AcpCustomProviderImportResult result;
    await _mutate((definitions) {
      final localIds = {for (final definition in definitions) definition.id};
      final added = imported
          .where((definition) => !localIds.contains(definition.id))
          .length;
      if (definitions.length + added > acpCustomProviderMaxCount) {
        throw const AcpCustomProviderException(
          'You can save up to $acpCustomProviderMaxCount custom agents.',
        );
      }
      final merged = mergeImportedAcpCustomProviders(
        local: definitions,
        imported: imported,
        keepUnmatchedLocal: true,
      );
      final importedIds = {for (final definition in imported) definition.id};
      result = AcpCustomProviderImportResult(
        added: added,
        replaced: imported.length - added,
        needsApproval: merged
            .where(
              (definition) =>
                  importedIds.contains(definition.id) &&
                  !definition.isCommandApproved,
            )
            .length,
      );
      return merged;
    });
    return result;
  }

  static const _missingMessage = 'This custom agent no longer exists.';

  Future<void> _mutate(
    List<AcpCustomProviderDefinition> Function(
      List<AcpCustomProviderDefinition> definitions,
    )
    change,
  ) => _mutations.run(() async {
    final current = await listCustomProviders();
    final next = change(current);
    if (next.isEmpty) {
      await _settings.delete(SettingKeys.acpCustomProviders);
      return;
    }
    await _settings.setString(
      SettingKeys.acpCustomProviders,
      jsonEncode([for (final definition in next) definition.toJson()]),
    );
  });

  static T _validated<T>(T Function() build) {
    try {
      return build();
    } on FormatException catch (error) {
      throw AcpCustomProviderException(error.message);
    }
  }

  static List<AcpCustomProviderDefinition> _decode(String? raw) =>
      decodeStoredAcpCustomProviders(decodeJsonList(raw));
}

/// Derives a unique custom provider ID slug from [label].
String suggestAcpCustomProviderId(String label, Set<String> takenIds) {
  var base = label
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (base.length > 48) {
    base = base.substring(0, 48).replaceAll(RegExp(r'-+$'), '');
  }
  if (base.isEmpty) base = 'agent';
  var candidate = base;
  for (var suffix = 2; takenIds.contains(candidate); suffix++) {
    candidate = '$base-$suffix';
  }
  return candidate;
}

/// Provider for [AcpCustomProviderService].
final acpCustomProviderServiceProvider = Provider<AcpCustomProviderService>(
  (ref) => AcpCustomProviderService(ref.watch(settingsServiceProvider)),
);

/// Streams every stored custom agent definition, approved or not.
final acpCustomProvidersProvider =
    StreamProvider<List<AcpCustomProviderDefinition>>(
      (ref) =>
          ref.watch(acpCustomProviderServiceProvider).watchCustomProviders(),
    );

/// Provider for the ACP providers offered in session pickers: the built-in
/// providers bundled with the app, then custom agents whose current command
/// the user has approved.
final acpProvidersProvider = StreamProvider<List<AcpProvider>>(
  (ref) => ref
      .watch(acpCustomProviderServiceProvider)
      .watchCustomProviders()
      .map(
        (custom) => List<AcpProvider>.unmodifiable(<AcpProvider>[
          ...acpBuiltinProviders,
          ...custom.where((definition) => definition.isCommandApproved),
        ]),
      ),
);
