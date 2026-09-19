// ignore_for_file: public_member_api_docs

import 'package:flutter/foundation.dart';

import '../../domain/models/acp_protocol.dart';
import '../../domain/models/acp_provider.dart';
import '../../domain/models/acp_session_state.dart';
import '../../domain/services/pi_model_scope_metadata_service.dart';

List<AcpQuickSelectorData> buildAcpQuickSelectors(
  AcpSessionState session, {
  required String providerId,
  required List<String>? piEnabledModelPatterns,
  required Future<void> Function(String configId, Object value) setConfigOption,
  required Future<void> Function(String value) setModel,
  required Future<void> Function(String value) setMode,
  required Future<void> Function({required bool enabled})
  setAutoApprovePermissions,
}) {
  ({List<AcpQuickChoice> visible, List<AcpQuickChoice> hidden})
  partitionPiModelChoices(
    List<AcpQuickChoice> allChoices,
    String currentValue,
  ) {
    final patterns = piEnabledModelPatterns;
    if (providerId != AcpBuiltinProviderIds.pi ||
        patterns == null ||
        patterns.isEmpty) {
      return (visible: allChoices, hidden: const <AcpQuickChoice>[]);
    }
    final byValue = <String, AcpQuickChoice>{
      for (final choice in allChoices) choice.value: choice,
    };
    final scopedIds = resolvePiScopedModelIds(
      patterns: patterns,
      availableModelIds: byValue.keys.toList(growable: false),
      modelNames: <String, String>{
        for (final choice in allChoices) choice.value: choice.label,
      },
    );
    final visible = <AcpQuickChoice>[for (final id in scopedIds) ?byValue[id]];
    final current = byValue[currentValue];
    if (current != null &&
        !visible.any((choice) => choice.value == currentValue)) {
      visible.insert(0, current);
    }
    final visibleValues = visible.map((choice) => choice.value).toSet();
    final hidden = allChoices
        .where((choice) => !visibleValues.contains(choice.value))
        .toList(growable: false);
    return (
      visible: List<AcpQuickChoice>.unmodifiable(visible),
      hidden: List<AcpQuickChoice>.unmodifiable(hidden),
    );
  }

  final generic = session.configOptions.whereType<AcpSelectConfigOption>();
  AcpSelectConfigOption? firstMatching(
    bool Function(AcpSelectConfigOption option) matches,
  ) => generic.where(matches).firstOrNull;

  final modelOption = firstMatching(
    (option) => (option.category ?? '').toLowerCase() == 'model',
  );
  final effortOption = firstMatching(_quickConfigOptionIsEffort);
  final permissionOption = firstMatching(_quickConfigOptionIsPermissionMode);
  final permissionToggle = session.configOptions
      .whereType<AcpBooleanConfigOption>()
      .where(_quickConfigOptionIsPermissionMode)
      .firstOrNull;
  final modeOption = firstMatching(
    (option) =>
        (option.category ?? '').toLowerCase() == 'mode' &&
        !_quickConfigOptionIsEffort(option) &&
        !_quickConfigOptionIsPermissionMode(option),
  );
  final selectors = <AcpQuickSelectorData>[];
  final displayedOptionIds = <String>{};

  void addGeneric(
    String label,
    AcpSelectConfigOption? option, {
    bool scopePiModels = false,
  }) {
    if (option == null) {
      return;
    }
    final allChoices = _quickConfigChoices(option);
    if (allChoices.isEmpty) {
      return;
    }
    displayedOptionIds.add(option.id);
    final partition = scopePiModels
        ? partitionPiModelChoices(allChoices, option.currentValue)
        : (visible: allChoices, hidden: const <AcpQuickChoice>[]);
    selectors.add(
      AcpQuickSelectorData(
        label: label,
        currentValue: option.currentValue,
        choices: partition.visible,
        hiddenChoices: partition.hidden,
        onSelected: (value) => setConfigOption(option.id, value),
      ),
    );
  }

  addGeneric('Model', modelOption, scopePiModels: true);
  if (modelOption == null) {
    final state = session.modelState;
    if (state != null && state.availableModels.isNotEmpty) {
      final allChoices = [
        for (final model in state.availableModels)
          AcpQuickChoice(
            value: model.id,
            label: model.name.isEmpty ? model.id : model.name,
            description: model.description,
          ),
      ];
      final partition = partitionPiModelChoices(
        allChoices,
        state.currentModelId,
      );
      selectors.add(
        AcpQuickSelectorData(
          label: 'Model',
          currentValue: state.currentModelId,
          choices: partition.visible,
          hiddenChoices: partition.hidden,
          onSelected: (value) => setModel(value),
        ),
      );
    }
  }

  addGeneric('Effort', effortOption);
  final legacyModeState = session.modeState;
  final legacyModeIsEffort =
      legacyModeState != null && _legacyModeStateIsEffort(legacyModeState);
  if (legacyModeState != null &&
      legacyModeState.availableModes.isNotEmpty &&
      (legacyModeIsEffort ? effortOption == null : modeOption == null)) {
    selectors.add(
      AcpQuickSelectorData(
        label: legacyModeIsEffort ? 'Effort' : 'Mode',
        currentValue: legacyModeState.currentModeId,
        choices: [
          for (final mode in legacyModeState.availableModes)
            AcpQuickChoice(
              value: mode.id,
              label: mode.name.isEmpty ? mode.id : mode.name,
              description: mode.description,
            ),
        ],
        onSelected: (value) => setMode(value),
      ),
    );
  }
  addGeneric('Mode', modeOption);

  addGeneric('Permission', permissionOption);
  if (permissionOption == null) {
    if (permissionToggle != null) {
      displayedOptionIds.add(permissionToggle.id);
    }
    final autoApprove =
        permissionToggle?.currentValue ?? session.autoApprovePermissions;
    final onSelected = permissionToggle != null
        ? (String value) =>
              setConfigOption(permissionToggle.id, value == 'true')
        : (String value) => setAutoApprovePermissions(enabled: value == 'true');
    selectors.add(
      AcpQuickSelectorData(
        label: 'Permission',
        currentValue: autoApprove ? 'true' : 'false',
        choices: const [
          AcpQuickChoice(
            value: 'false',
            label: 'Ask',
            description: 'Ask before protected actions.',
          ),
          AcpQuickChoice(
            value: 'true',
            label: 'YOLO',
            description: 'Auto-approve supported actions for this session.',
          ),
        ],
        onSelected: onSelected,
      ),
    );
  }

  // ACP providers may use extension categories such as Codex's
  // model_config (Fast mode) or collaboration_mode. Preserve the canonical
  // Model / Effort / Mode ordering above, then surface every remaining
  // advertised select option instead of silently hiding it.
  for (final option in generic) {
    if (!displayedOptionIds.contains(option.id)) {
      addGeneric(option.name.isEmpty ? option.id : option.name, option);
    }
  }
  return selectors;
}

bool _quickConfigOptionIsPermissionMode(AcpSessionConfigOption option) {
  final category = (option.category ?? '').toLowerCase();
  final identity = '${option.id} ${option.name}'.toLowerCase();
  return category == 'permission' ||
      category == 'permissions' ||
      identity.contains('permission') ||
      identity.contains('approval') ||
      identity.contains('auto-approve') ||
      identity.contains('yolo');
}

bool _quickConfigOptionIsEffort(AcpSelectConfigOption option) {
  final identity = '${option.id} ${option.name}'.toLowerCase();
  if (identity.contains('effort') ||
      identity.contains('reasoning') ||
      identity.contains('thinking')) {
    return true;
  }
  final values = [
    for (final value in option.options) value.value,
    for (final group in option.groups)
      for (final value in group.options) value.value,
  ];
  return values.any(_isEffortStrengthLevel) && values.every(_isEffortLevel);
}

bool _legacyModeStateIsEffort(AcpSessionModeState state) =>
    state.availableModes.any(
      (mode) =>
          _isEffortStrengthLevel(mode.id) || _isEffortStrengthLevel(mode.name),
    ) &&
    state.availableModes.every(
      (mode) => _isEffortLevel(mode.id) || _isEffortLevel(mode.name),
    );

bool _isEffortStrengthLevel(String value) => const {
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
}.contains(_normalizedConfigValue(value));

bool _isEffortLevel(String value) {
  final normalized = _normalizedConfigValue(value);
  return const {
    'off',
    'none',
    'minimal',
    'low',
    'medium',
    'high',
    'xhigh',
    'max',
    'auto',
    'default',
  }.contains(normalized);
}

String _normalizedConfigValue(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]+'), '');

List<AcpQuickChoice> _quickConfigChoices(AcpSelectConfigOption option) => [
  for (final value in option.options)
    AcpQuickChoice(
      value: value.value,
      label: value.name.isEmpty ? value.value : value.name,
      description: value.description,
    ),
  for (final group in option.groups)
    for (final value in group.options)
      AcpQuickChoice(
        value: value.value,
        label: group.name.isEmpty
            ? (value.name.isEmpty ? value.value : value.name)
            : '${group.name} · ${value.name.isEmpty ? value.value : value.name}',
        description: value.description,
      ),
];

@immutable
class AcpQuickChoice {
  const AcpQuickChoice({
    required this.value,
    required this.label,
    this.description,
  });

  final String value;
  final String label;
  final String? description;
}

@immutable
class AcpQuickSelectorData {
  const AcpQuickSelectorData({
    required this.label,
    required this.currentValue,
    required this.choices,
    required this.onSelected,
    this.hiddenChoices = const <AcpQuickChoice>[],
  });

  final String label;
  final String currentValue;
  final List<AcpQuickChoice> choices;
  final List<AcpQuickChoice> hiddenChoices;
  final Future<void> Function(String value) onSelected;
}
