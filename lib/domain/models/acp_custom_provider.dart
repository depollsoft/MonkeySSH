part of 'acp_provider.dart';

/// Maximum length of a custom ACP provider ID.
const acpCustomProviderIdMaxLength = 64;

/// Maximum length of a custom ACP provider label.
///
/// MonkeyMux accepts provider labels up to 128 characters.
const acpProviderLabelMaxLength = 120;

/// Maximum length of an ACP launch command executable.
const acpLaunchCommandExecutableMaxLength = 1024;

/// Maximum length of a single ACP launch command argument.
const acpLaunchCommandArgumentMaxLength = 4096;

/// Maximum number of arguments in an ACP launch command.
const acpLaunchCommandMaxArgumentCount = 64;

/// Maximum combined length of a custom launch command's executable and
/// arguments.
///
/// The bridge rejects provider commands above 8 KiB once the profile prefix
/// and quoting are added, so a definition that saves must also launch.
const acpLaunchCommandMaxTotalLength = 4096;

/// Maximum number of host environment variables one definition can require.
const acpCustomProviderMaxEnvironmentVariables = 32;

/// Maximum length of a required environment variable name.
const acpEnvironmentVariableNameMaxLength = 128;

/// Maximum number of saved custom ACP providers.
const acpCustomProviderMaxCount = 32;

/// `format` value of an exported custom agent document.
const acpCustomProviderExportFormat = 'monkeyssh.acp-agents';

/// Schema version of an exported custom agent document.
const acpCustomProviderExportVersion = 1;

final _controlCharacterPattern = RegExp(r'[\x00-\x1F\x7F]');
final _customProviderIdPattern = RegExp(r'^[a-z0-9][a-z0-9._-]*$');
final _environmentVariableNamePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// Validates and normalizes a custom ACP provider ID.
///
/// IDs are lowercase slugs (`goose`, `gemini-cli`) so they stay safe in
/// session keys, routes and MonkeyMux arguments. Throws a [FormatException]
/// when [id] is blank, too long, uses the reserved built-in prefix, or
/// contains anything other than `a-z`, `0-9`, `.`, `_` and `-`.
String validateAcpCustomProviderId(String id) {
  final trimmed = id.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('Agent ID must not be blank.');
  }
  if (trimmed.startsWith(acpBuiltinProviderIdPrefix)) {
    throw const FormatException('Agent ID must not use the built-in prefix.');
  }
  if (trimmed.length > acpCustomProviderIdMaxLength) {
    throw const FormatException(
      'Agent ID must be $acpCustomProviderIdMaxLength characters or fewer.',
    );
  }
  if (!_customProviderIdPattern.hasMatch(trimmed)) {
    throw const FormatException(
      'Agent ID may only use lowercase letters, digits, ".", "_" and "-".',
    );
  }
  return trimmed;
}

/// Validates and normalizes an ACP provider label.
///
/// Throws a [FormatException] when [label] is blank, too long, or contains
/// control characters.
String validateAcpProviderLabel(String label) {
  final trimmed = label.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('Name must not be blank.');
  }
  if (trimmed.length > acpProviderLabelMaxLength) {
    throw const FormatException(
      'Name must be $acpProviderLabelMaxLength characters or fewer.',
    );
  }
  if (_controlCharacterPattern.hasMatch(trimmed)) {
    throw const FormatException('Name must not contain control characters.');
  }
  return trimmed;
}

/// Validates an ACP launch command.
///
/// Throws a [FormatException] when the executable is blank or has
/// surrounding whitespace, the executable or an argument contains control
/// characters (including NUL), or the command exceeds the length and count
/// limits.
void validateAcpLaunchCommand(AcpLaunchCommand command) {
  final executable = command.executable;
  if (executable.trim().isEmpty) {
    throw const FormatException('Command must not be blank.');
  }
  if (executable.trim() != executable) {
    throw const FormatException(
      'Command must not start or end with whitespace.',
    );
  }
  if (executable.length > acpLaunchCommandExecutableMaxLength) {
    throw const FormatException(
      'Command must be $acpLaunchCommandExecutableMaxLength characters or '
      'fewer.',
    );
  }
  if (_controlCharacterPattern.hasMatch(executable)) {
    throw const FormatException('Command must not contain control characters.');
  }
  if (command.arguments.length > acpLaunchCommandMaxArgumentCount) {
    throw const FormatException(
      'Use $acpLaunchCommandMaxArgumentCount arguments or fewer.',
    );
  }
  for (final argument in command.arguments) {
    if (argument.length > acpLaunchCommandArgumentMaxLength) {
      throw const FormatException(
        'Each argument must be $acpLaunchCommandArgumentMaxLength characters '
        'or fewer.',
      );
    }
    if (_controlCharacterPattern.hasMatch(argument)) {
      throw const FormatException(
        'Arguments must not contain control characters.',
      );
    }
  }
  final totalLength = command.argv.fold<int>(
    0,
    (total, value) => total + value.length,
  );
  if (totalLength > acpLaunchCommandMaxTotalLength) {
    throw const FormatException(
      'The command and its arguments must total '
      '$acpLaunchCommandMaxTotalLength characters or fewer.',
    );
  }
}

/// Validates and normalizes the names of host environment variables a custom
/// provider needs.
///
/// Names are trimmed, deduplicated and sorted, so the same set always
/// fingerprints the same way. Throws a [FormatException] for a name that is
/// not a portable identifier, or for too many names.
List<String> validateAcpEnvironmentVariableNames(Iterable<String> names) {
  final normalized = <String>{};
  for (final raw in names) {
    final name = raw.trim();
    if (name.isEmpty) continue;
    if (name.length > acpEnvironmentVariableNameMaxLength ||
        !_environmentVariableNamePattern.hasMatch(name)) {
      throw const FormatException(
        'Environment variable names may only use letters, digits and "_", '
        'and must not start with a digit.',
      );
    }
    normalized.add(name);
  }
  if (normalized.length > acpCustomProviderMaxEnvironmentVariables) {
    throw const FormatException(
      'Require $acpCustomProviderMaxEnvironmentVariables environment '
      'variables or fewer.',
    );
  }
  return List<String>.unmodifiable(normalized.toList()..sort());
}

/// Where a custom provider's agent process starts.
enum AcpCustomProviderCwdPolicy {
  /// The folder chosen for each new session.
  chosenDirectory('chosen'),

  /// Always the host user's home folder, for agents not tied to a project.
  homeDirectory('home');

  const AcpCustomProviderCwdPolicy(this.storageValue);

  /// Stable value persisted in settings, exports and the fingerprint.
  final String storageValue;

  /// Parses a stored policy, or returns `null` for an unknown value.
  static AcpCustomProviderCwdPolicy? fromStorageValue(Object? value) =>
      AcpCustomProviderCwdPolicy.values.firstWhereOrNull(
        (policy) => policy.storageValue == value,
      );
}

/// Computes the approval fingerprint for everything that decides what a
/// custom provider runs and where: the exact argv, the required environment
/// variable names, and the working-directory policy.
///
/// The result is a lowercase hex SHA-256 digest. It changes whenever any of
/// those inputs change, so an approval recorded against an older fingerprint
/// no longer authorizes the launch.
String computeAcpCustomProviderFingerprint({
  required AcpLaunchCommand command,
  List<String> environmentVariableNames = const <String>[],
  AcpCustomProviderCwdPolicy cwdPolicy =
      AcpCustomProviderCwdPolicy.chosenDirectory,
}) {
  final canonical = jsonEncode(<String, Object?>{
    'v': 1,
    'argv': command.argv,
    'env': [...environmentVariableNames]..sort(),
    'cwd': cwdPolicy.storageValue,
  });
  return sha256.convert(utf8.encode(canonical)).toString();
}

/// Approval record for a custom ACP provider's exact launch.
///
/// Approval is device-local: it is never exported, and migration imports
/// drop it unless the same fingerprint was already approved here.
@immutable
class AcpCommandApproval {
  /// Creates a new [AcpCommandApproval].
  const AcpCommandApproval({
    required this.commandFingerprint,
    required this.approvedAt,
  });

  /// Decodes an [AcpCommandApproval] from untrusted JSON, returning `null`
  /// instead of throwing when [json] is malformed.
  static AcpCommandApproval? tryFromJson(Object? json) {
    if (json is! Map || json.keys.any((key) => key is! String)) {
      return null;
    }
    final fingerprint = json['commandFingerprint'];
    if (fingerprint is! String || fingerprint.isEmpty) {
      return null;
    }
    final rawApprovedAt = json['approvedAt'];
    if (rawApprovedAt is! String) {
      return null;
    }
    final approvedAt = DateTime.tryParse(rawApprovedAt);
    if (approvedAt == null) {
      return null;
    }
    return AcpCommandApproval(
      commandFingerprint: fingerprint,
      approvedAt: approvedAt,
    );
  }

  /// SHA-256 fingerprint of the exact launch that was approved.
  final String commandFingerprint;

  /// When this launch was approved.
  final DateTime approvedAt;

  /// Encodes this approval as JSON.
  Map<String, Object?> toJson() => <String, Object?>{
    'commandFingerprint': commandFingerprint,
    'approvedAt': approvedAt.toUtc().toIso8601String(),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpCommandApproval &&
          commandFingerprint == other.commandFingerprint &&
          approvedAt.isAtSameMomentAs(other.approvedAt);

  @override
  int get hashCode =>
      Object.hash(commandFingerprint, approvedAt.millisecondsSinceEpoch);

  @override
  String toString() => 'AcpCommandApproval(fingerprint: $commandFingerprint)';
}

/// User-defined ACP provider: a label plus the exact command that starts an
/// ACP server on the host.
///
/// A definition runs arbitrary commands on the host, so it is executable
/// configuration. It launches only while [isCommandApproved]: the user has
/// reviewed and approved the current [fingerprint]. Any change to the argv,
/// the required environment variable names or the working-directory policy
/// changes the fingerprint and withdraws the approval until the user reviews
/// it again. Environment variables are referenced by name only; their values
/// come from the host and are never stored.
@immutable
final class AcpCustomProviderDefinition implements AcpProvider {
  AcpCustomProviderDefinition._({
    required this.id,
    required this.label,
    required this.launchCommand,
    required List<String> environmentVariableNames,
    required this.cwdPolicy,
    required this.approval,
    required this.createdAt,
    required this.updatedAt,
  }) : environmentVariableNames = List<String>.unmodifiable(
         environmentVariableNames,
       );

  /// Creates a new, validated and **unapproved** definition.
  ///
  /// Throws a [FormatException] when any field fails validation.
  factory AcpCustomProviderDefinition.create({
    required String id,
    required String label,
    required AcpLaunchCommand launchCommand,
    Iterable<String> environmentVariableNames = const <String>[],
    AcpCustomProviderCwdPolicy cwdPolicy =
        AcpCustomProviderCwdPolicy.chosenDirectory,
    DateTime? now,
  }) {
    final timestamp = (now ?? DateTime.now()).toUtc();
    validateAcpLaunchCommand(launchCommand);
    return AcpCustomProviderDefinition._(
      id: validateAcpCustomProviderId(id),
      label: validateAcpProviderLabel(label),
      launchCommand: launchCommand,
      environmentVariableNames: validateAcpEnvironmentVariableNames(
        environmentVariableNames,
      ),
      cwdPolicy: cwdPolicy,
      approval: null,
      createdAt: timestamp,
      updatedAt: timestamp,
    );
  }

  /// Decodes one exported definition.
  ///
  /// The result is always unapproved: an export never carries approval, and
  /// any approval-like field in [json] is ignored. Throws a
  /// [FormatException] with a user-facing message when [json] is invalid,
  /// including when it lists environment variable values instead of names.
  factory AcpCustomProviderDefinition.fromExportJson(
    Object? json, {
    DateTime? now,
  }) {
    if (json is! Map || json.keys.any((key) => key is! String)) {
      throw const FormatException('Each agent must be a JSON object.');
    }
    final environment = json['environmentVariables'];
    if (environment is Map) {
      throw const FormatException(
        'List environment variables by name only. Their values come from '
        'the host.',
      );
    }
    final fields = _AcpCustomProviderFields.parse(json);
    final timestamp = (now ?? DateTime.now()).toUtc();
    return AcpCustomProviderDefinition._(
      id: fields.id,
      label: fields.label,
      launchCommand: fields.command,
      environmentVariableNames: fields.environmentVariableNames,
      cwdPolicy: fields.cwdPolicy,
      approval: null,
      createdAt: timestamp,
      updatedAt: timestamp,
    );
  }

  /// Decodes a stored definition from untrusted JSON, returning `null`
  /// instead of throwing when [json] is malformed or fails validation.
  ///
  /// Unknown fields are ignored so later schema additions stay readable.
  static AcpCustomProviderDefinition? tryFromJson(Object? json) {
    if (json is! Map || json.keys.any((key) => key is! String)) {
      return null;
    }
    final fields = _AcpCustomProviderFields.tryParse(json);
    if (fields == null) return null;
    final rawCreatedAt = json['createdAt'];
    final rawUpdatedAt = json['updatedAt'];
    if (rawCreatedAt is! String || rawUpdatedAt is! String) {
      return null;
    }
    final createdAt = DateTime.tryParse(rawCreatedAt);
    final updatedAt = DateTime.tryParse(rawUpdatedAt);
    if (createdAt == null || updatedAt == null) {
      return null;
    }
    final rawApproval = json['approval'];
    final approval = AcpCommandApproval.tryFromJson(rawApproval);
    if (rawApproval != null && approval == null) {
      return null;
    }
    return AcpCustomProviderDefinition._(
      id: fields.id,
      label: fields.label,
      launchCommand: fields.command,
      environmentVariableNames: fields.environmentVariableNames,
      cwdPolicy: fields.cwdPolicy,
      approval: approval,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  /// Stable identifier for this custom provider.
  @override
  final String id;

  /// User-provided display label.
  @override
  final String label;

  /// The exact command that starts the agent's ACP server.
  @override
  final AcpLaunchCommand launchCommand;

  /// Names of host environment variables the agent needs. Values are read on
  /// the host and never stored.
  final List<String> environmentVariableNames;

  /// Where the agent process starts.
  final AcpCustomProviderCwdPolicy cwdPolicy;

  /// The most recent approval, which may be for an older [fingerprint].
  final AcpCommandApproval? approval;

  /// When this definition was first created on this device.
  final DateTime createdAt;

  /// When this definition was last changed.
  final DateTime updatedAt;

  @override
  bool get isCustom => true;

  /// Fingerprint of what this definition currently runs.
  String get fingerprint => computeAcpCustomProviderFingerprint(
    command: launchCommand,
    environmentVariableNames: environmentVariableNames,
    cwdPolicy: cwdPolicy,
  );

  /// Whether the current [fingerprint] has been approved for launch.
  bool get isCommandApproved => approval?.commandFingerprint == fingerprint;

  /// Returns an edited copy. Fields left `null` keep their value.
  ///
  /// The stored approval is kept, so an edit that changes what runs leaves
  /// the definition unapproved until it is reviewed again, while a rename
  /// stays approved. Throws a [FormatException] for invalid fields.
  AcpCustomProviderDefinition edit({
    String? label,
    AcpLaunchCommand? launchCommand,
    Iterable<String>? environmentVariableNames,
    AcpCustomProviderCwdPolicy? cwdPolicy,
    DateTime? now,
  }) {
    final command = launchCommand ?? this.launchCommand;
    validateAcpLaunchCommand(command);
    return AcpCustomProviderDefinition._(
      id: id,
      label: label == null ? this.label : validateAcpProviderLabel(label),
      launchCommand: command,
      environmentVariableNames: environmentVariableNames == null
          ? this.environmentVariableNames
          : validateAcpEnvironmentVariableNames(environmentVariableNames),
      cwdPolicy: cwdPolicy ?? this.cwdPolicy,
      approval: approval,
      createdAt: createdAt,
      updatedAt: (now ?? DateTime.now()).toUtc(),
    );
  }

  /// Returns a copy approving the current [fingerprint] as of [now].
  AcpCustomProviderDefinition approve({DateTime? now}) => _withApproval(
    AcpCommandApproval(
      commandFingerprint: fingerprint,
      approvedAt: (now ?? DateTime.now()).toUtc(),
    ),
  );

  /// Returns a copy with no approval record.
  AcpCustomProviderDefinition withoutApproval() => _withApproval(null);

  AcpCustomProviderDefinition _withApproval(AcpCommandApproval? approval) =>
      AcpCustomProviderDefinition._(
        id: id,
        label: label,
        launchCommand: launchCommand,
        environmentVariableNames: environmentVariableNames,
        cwdPolicy: cwdPolicy,
        approval: approval,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );

  /// Encodes this definition for on-device storage, including its approval.
  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': 1,
    ..._exportFields(),
    'approval': ?approval?.toJson(),
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  /// Encodes this definition for export.
  ///
  /// An export carries what to run, never an approval, timestamps or any
  /// environment variable value.
  Map<String, Object?> toExportJson() => _exportFields();

  Map<String, Object?> _exportFields() => <String, Object?>{
    'id': id,
    'label': label,
    'command': launchCommand.argv,
    'environmentVariables': environmentVariableNames,
    'workingDirectory': cwdPolicy.storageValue,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpCustomProviderDefinition &&
          id == other.id &&
          label == other.label &&
          launchCommand == other.launchCommand &&
          _listEquality.equals(
            environmentVariableNames,
            other.environmentVariableNames,
          ) &&
          cwdPolicy == other.cwdPolicy &&
          approval == other.approval &&
          createdAt.isAtSameMomentAs(other.createdAt) &&
          updatedAt.isAtSameMomentAs(other.updatedAt);

  @override
  int get hashCode => Object.hash(
    id,
    label,
    launchCommand,
    _listEquality.hash(environmentVariableNames),
    cwdPolicy,
    approval,
    createdAt.millisecondsSinceEpoch,
    updatedAt.millisecondsSinceEpoch,
  );

  // Never include the label or command: both are user content.
  @override
  String toString() =>
      'AcpCustomProviderDefinition(approved: $isCommandApproved)';
}

/// The validated fields shared by stored and exported definitions.
final class _AcpCustomProviderFields {
  const _AcpCustomProviderFields({
    required this.id,
    required this.label,
    required this.command,
    required this.environmentVariableNames,
    required this.cwdPolicy,
  });

  factory _AcpCustomProviderFields.parse(Map<Object?, Object?> json) {
    final rawId = json['id'];
    final rawLabel = json['label'];
    if (rawId is! String) {
      throw const FormatException('Each agent needs an "id".');
    }
    if (rawLabel is! String) {
      throw const FormatException('Each agent needs a "label".');
    }
    final rawCommand = json['command'];
    if (rawCommand is! List ||
        rawCommand.isEmpty ||
        rawCommand.any((value) => value is! String)) {
      throw const FormatException(
        'Each agent needs a "command": the executable followed by its '
        'arguments, as a list of strings.',
      );
    }
    final argv = rawCommand.cast<String>();
    final command = AcpLaunchCommand(
      executable: argv.first,
      arguments: argv.sublist(1),
    );
    validateAcpLaunchCommand(command);
    final rawEnvironment = json['environmentVariables'];
    if (rawEnvironment != null &&
        (rawEnvironment is! List ||
            rawEnvironment.any((value) => value is! String))) {
      throw const FormatException(
        '"environmentVariables" must be a list of variable names.',
      );
    }
    final rawCwdPolicy = json['workingDirectory'];
    final cwdPolicy = rawCwdPolicy == null
        ? AcpCustomProviderCwdPolicy.chosenDirectory
        : AcpCustomProviderCwdPolicy.fromStorageValue(rawCwdPolicy);
    if (cwdPolicy == null) {
      throw const FormatException(
        '"workingDirectory" must be "chosen" or "home".',
      );
    }
    return _AcpCustomProviderFields(
      id: validateAcpCustomProviderId(rawId),
      label: validateAcpProviderLabel(rawLabel),
      command: command,
      environmentVariableNames: validateAcpEnvironmentVariableNames(
        rawEnvironment == null
            ? const <String>[]
            : (rawEnvironment as List).cast<String>(),
      ),
      cwdPolicy: cwdPolicy,
    );
  }

  final String id;
  final String label;
  final AcpLaunchCommand command;
  final List<String> environmentVariableNames;
  final AcpCustomProviderCwdPolicy cwdPolicy;

  static _AcpCustomProviderFields? tryParse(Map<Object?, Object?> json) {
    try {
      return _AcpCustomProviderFields.parse(json);
    } on FormatException {
      return null;
    }
  }
}

/// Encodes [definitions] as a shareable export document.
///
/// The document lists what each agent runs. It never contains approvals,
/// timestamps or environment variable values.
String encodeAcpCustomProviderExport(
  Iterable<AcpCustomProviderDefinition> definitions,
) => const JsonEncoder.withIndent('  ').convert(<String, Object?>{
  'format': acpCustomProviderExportFormat,
  'version': acpCustomProviderExportVersion,
  'agents': [for (final definition in definitions) definition.toExportJson()],
});

/// Decodes an export document, a bare list of agents, or a single agent
/// object into unapproved definitions.
///
/// Throws a [FormatException] with a user-facing message when [text] is not
/// valid, lists too many agents, or repeats an ID.
List<AcpCustomProviderDefinition> decodeAcpCustomProviderImport(
  String text, {
  DateTime? now,
}) {
  Object? decoded;
  try {
    decoded = jsonDecode(text.trim());
  } on FormatException {
    throw const FormatException('That is not valid JSON.');
  }
  var rawAgents = decoded;
  if (decoded is Map && decoded.containsKey('agents')) {
    final format = decoded['format'];
    if (format != null && format != acpCustomProviderExportFormat) {
      throw const FormatException('That is not a MonkeySSH agent export.');
    }
    final version = decoded['version'];
    if (version is int && version > acpCustomProviderExportVersion) {
      throw const FormatException(
        'This export was made by a newer MonkeySSH. Update the app first.',
      );
    }
    rawAgents = decoded['agents'];
  } else if (decoded is Map) {
    rawAgents = <Object?>[decoded];
  }
  if (rawAgents is! List || rawAgents.isEmpty) {
    throw const FormatException('No agents found to import.');
  }
  if (rawAgents.length > acpCustomProviderMaxCount) {
    throw const FormatException(
      'Import $acpCustomProviderMaxCount agents or fewer at a time.',
    );
  }
  final definitions = <AcpCustomProviderDefinition>[];
  final ids = <String>{};
  for (final rawAgent in rawAgents) {
    final definition = AcpCustomProviderDefinition.fromExportJson(
      rawAgent,
      now: now,
    );
    if (!ids.add(definition.id)) {
      throw FormatException('The ID "${definition.id}" appears twice.');
    }
    definitions.add(definition);
  }
  return List<AcpCustomProviderDefinition>.unmodifiable(definitions);
}

/// Decodes the stored custom provider list, skipping unreadable entries and
/// repeated IDs so one bad entry never hides the rest.
List<AcpCustomProviderDefinition> decodeStoredAcpCustomProviders(Object? raw) {
  if (raw is! List) return const <AcpCustomProviderDefinition>[];
  final definitions = <AcpCustomProviderDefinition>[];
  final ids = <String>{};
  for (final item in raw) {
    final definition = AcpCustomProviderDefinition.tryFromJson(item);
    if (definition == null || !ids.add(definition.id)) continue;
    definitions.add(definition);
    if (definitions.length >= acpCustomProviderMaxCount) break;
  }
  return List<AcpCustomProviderDefinition>.unmodifiable(definitions);
}

/// Merges custom provider definitions that arrive in a settings migration
/// with the ones already stored on this device.
///
/// Imported definitions replace local ones with the same ID. An imported
/// definition keeps an approval only when this device had already approved
/// its exact fingerprint; every other imported definition arrives
/// unapproved, whatever approval the import claims. With
/// [keepUnmatchedLocal], local definitions absent from the import are kept.
List<AcpCustomProviderDefinition> mergeImportedAcpCustomProviders({
  required List<AcpCustomProviderDefinition> local,
  required List<AcpCustomProviderDefinition> imported,
  required bool keepUnmatchedLocal,
}) {
  final localById = {for (final definition in local) definition.id: definition};
  AcpCustomProviderDefinition accept(AcpCustomProviderDefinition definition) {
    final existing = localById[definition.id];
    final keepsApproval =
        existing != null &&
        existing.isCommandApproved &&
        existing.fingerprint == definition.fingerprint;
    return keepsApproval
        ? definition._withApproval(existing.approval)
        : definition.withoutApproval();
  }

  final importedById = {
    for (final definition in imported) definition.id: definition,
  };
  final merged = <AcpCustomProviderDefinition>[];
  if (keepUnmatchedLocal) {
    // Keep the local order, swapping in imported replacements.
    for (final definition in local) {
      final replacement = importedById.remove(definition.id);
      merged.add(replacement == null ? definition : accept(replacement));
    }
  }
  for (final definition in imported) {
    if (keepUnmatchedLocal && !importedById.containsKey(definition.id)) {
      continue;
    }
    merged.add(accept(definition));
  }
  return merged.take(acpCustomProviderMaxCount).toList(growable: false);
}
