import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../domain/models/acp_protocol.dart';
import '../../domain/models/acp_session_keys.dart';
import '../../domain/models/acp_session_state.dart';
import '../../domain/services/acp_session_manager.dart';

/// Sets a generic session configuration option by id.
typedef AcpConfigOptionSetter =
    Future<void> Function(String configId, Object value);

/// Sets the legacy session mode by id.
typedef AcpLegacyModeSetter = Future<void> Function(String modeId);

/// Sets the legacy session model by id.
typedef AcpLegacyModelSetter = Future<void> Function(String modelId);

const _categoryOrder = <String>[
  'model',
  'mode',
  'agent',
  'thought',
  'permissions',
];

/// Opens the ACP session configuration surface.
///
/// Uses a bottom sheet on narrow layouts (one-handed reach) and a centered
/// dialog on wide layouts, so the same generic controls adapt to phone and
/// desktop form factors.
Future<void> showAcpConfigOptions(
  BuildContext context, {
  required AcpSessionKey sessionKey,
}) {
  final content = Consumer(
    builder: (context, ref, child) {
      final session = ref.watch(
        acpSessionManagerStateProvider.select(
          (state) => state.asData?.value.byKeyValue(sessionKey.value),
        ),
      );
      final manager = ref.watch(acpSessionManagerProvider);
      return AcpConfigOptionControls(
        options: session?.configOptions ?? const [],
        onSetConfigOption: (configId, value) => manager.setConfigOption(
          sessionKey,
          configId: configId,
          value: value,
        ),
        modeState: session?.modeState,
        modelState: session?.modelState,
        onSetMode: (modeId) => manager.setMode(sessionKey, modeId),
        onSetModel: (modelId) => manager.setModel(sessionKey, modelId),
        enabled: session?.status == AcpConnectionStatus.ready,
      );
    },
  );
  final wide = MediaQuery.sizeOf(context).width >= 600;
  if (wide) {
    return showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
          child: content,
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => content,
  );
}

/// A generic list of ACP session configuration controls.
///
/// Renders [AcpSelectConfigOption] and [AcpBooleanConfigOption] values from the
/// agent's advertised metadata, grouped by category (model, mode, agent,
/// thought, permissions, then any others). Unknown option types degrade to a
/// visible, disabled row rather than breaking the surface. Generic options are
/// always applied through [onSetConfigOption]; the legacy mode/model states are
/// only surfaced as a fallback when no generic option already covers them.
class AcpConfigOptionControls extends StatefulWidget {
  /// Creates configuration controls.
  const AcpConfigOptionControls({
    required this.options,
    required this.onSetConfigOption,
    super.key,
    this.modeState,
    this.modelState,
    this.onSetMode,
    this.onSetModel,
    this.enabled = true,
  });

  /// The generic configuration options advertised by the session.
  final List<AcpSessionConfigOption> options;

  /// Applies a generic configuration change.
  final AcpConfigOptionSetter onSetConfigOption;

  /// Latest legacy mode state, when reported.
  final AcpSessionModeState? modeState;

  /// Latest legacy model state, when reported.
  final AcpModelState? modelState;

  /// Legacy mode setter used only when no generic mode option exists.
  final AcpLegacyModeSetter? onSetMode;

  /// Legacy model setter used only when no generic model option exists.
  final AcpLegacyModelSetter? onSetModel;

  /// Whether the controls accept input.
  final bool enabled;

  @override
  State<AcpConfigOptionControls> createState() =>
      _AcpConfigOptionControlsState();
}

class _AcpConfigOptionControlsState extends State<AcpConfigOptionControls> {
  final Set<String> _pending = <String>{};
  final Map<String, String> _errors = <String, String>{};

  bool get _hasGenericMode =>
      widget.options.any((option) => _categoryOf(option) == 'mode');

  bool get _hasGenericModel =>
      widget.options.any((option) => _categoryOf(option) == 'model');

  String _categoryOf(AcpSessionConfigOption option) =>
      (option.category ?? 'other').toLowerCase();

  Future<void> _run(String id, Future<void> Function() action) async {
    setState(() {
      _pending.add(id);
      _errors.remove(id);
    });
    try {
      await action();
    } on Object {
      if (mounted) {
        setState(() => _errors[id] = 'Could not apply this setting.');
      }
    } finally {
      if (mounted) {
        setState(() => _pending.remove(id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final grouped = <String, List<Widget>>{};

    void add(String category, Widget tile) =>
        grouped.putIfAbsent(category, () => <Widget>[]).add(tile);

    for (final option in widget.options) {
      add(_categoryOf(option), _buildOption(option));
    }

    final modeState = widget.modeState;
    if (modeState != null &&
        widget.onSetMode != null &&
        !_hasGenericMode &&
        modeState.availableModes.isNotEmpty) {
      add('mode', _buildLegacyMode(modeState));
    }
    final modelState = widget.modelState;
    if (modelState != null &&
        widget.onSetModel != null &&
        !_hasGenericModel &&
        modelState.availableModels.isNotEmpty) {
      add('model', _buildLegacyModel(modelState));
    }

    final categories = grouped.keys.toList()
      ..sort((a, b) {
        final ai = _categoryOrder.indexOf(a);
        final bi = _categoryOrder.indexOf(b);
        if (ai != -1 && bi != -1) return ai.compareTo(bi);
        if (ai != -1) return -1;
        if (bi != -1) return 1;
        return a.compareTo(b);
      });

    final children = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(
          FluttyTheme.spacingMd,
          FluttyTheme.spacingSm,
          FluttyTheme.spacingMd,
          FluttyTheme.spacingSm,
        ),
        child: Text('Session settings', style: theme.textTheme.titleMedium),
      ),
    ];
    if (categories.isEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.all(FluttyTheme.spacingMd),
          child: Text(
            'This agent exposes no adjustable settings.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    for (final category in categories) {
      children
        ..add(
          Padding(
            padding: const EdgeInsets.fromLTRB(
              FluttyTheme.spacingMd,
              FluttyTheme.spacingSm,
              FluttyTheme.spacingMd,
              0,
            ),
            child: Text(
              _categoryLabel(category),
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        )
        ..addAll(grouped[category]!);
    }

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }

  String _categoryLabel(String category) => switch (category) {
    'model' => 'Model',
    'mode' => 'Mode',
    'agent' => 'Agent',
    'thought' => 'Thinking',
    'permissions' => 'Permissions',
    'other' => 'Other',
    _ => category[0].toUpperCase() + category.substring(1),
  };

  Widget _buildOption(AcpSessionConfigOption option) {
    switch (option) {
      case AcpSelectConfigOption():
        return _buildSelect(
          id: option.id,
          name: option.name,
          currentValue: option.currentValue,
          values: _flattenSelectValues(option),
          onSelected: (value) => widget.onSetConfigOption(option.id, value),
        );
      case AcpBooleanConfigOption():
        return _buildBoolean(option);
      case AcpUnknownConfigOption():
        return ListTile(
          enabled: false,
          title: Text(option.name.isEmpty ? option.id : option.name),
          subtitle: const Text('Unsupported setting'),
          trailing: const Icon(Icons.help_outline),
        );
    }
  }

  List<(String value, String label, String? description)> _flattenSelectValues(
    AcpSelectConfigOption option,
  ) {
    final values = <(String, String, String?)>[
      for (final value in option.options)
        (
          value.value,
          value.name.isEmpty ? value.value : value.name,
          value.description,
        ),
    ];
    for (final group in option.groups) {
      for (final value in group.options) {
        values.add((
          value.value,
          '${group.name} · ${value.name.isEmpty ? value.value : value.name}',
          value.description,
        ));
      }
    }
    return values;
  }

  Widget _buildSelect({
    required String id,
    required String name,
    required String currentValue,
    required List<(String value, String label, String? description)> values,
    required Future<void> Function(String value) onSelected,
  }) {
    final theme = Theme.of(context);
    final pending = _pending.contains(id);
    final error = _errors[id];
    final current = values
        .where((entry) => entry.$1 == currentValue)
        .map((entry) => entry.$2)
        .firstOrNull;
    return ListTile(
      enabled: widget.enabled && !pending,
      title: Text(name.isEmpty ? id : name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(current ?? currentValue),
          if (error != null)
            Text(
              error,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
        ],
      ),
      trailing: pending
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.chevron_right),
      onTap: (widget.enabled && !pending)
          ? () async {
              final chosen = await _pickValue(
                title: name,
                currentValue: currentValue,
                values: values,
              );
              if (!mounted) {
                return;
              }
              if (chosen != null && chosen != currentValue) {
                await _run(id, () => onSelected(chosen));
              }
            }
          : null,
    );
  }

  Widget _buildBoolean(AcpBooleanConfigOption option) {
    final theme = Theme.of(context);
    final pending = _pending.contains(option.id);
    final error = _errors[option.id];
    return SwitchListTile(
      value: option.currentValue,
      title: Text(option.name.isEmpty ? option.id : option.name),
      subtitle: (option.description != null || error != null)
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (option.description != null) Text(option.description!),
                if (error != null)
                  Text(
                    error,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
              ],
            )
          : null,
      secondary: pending
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      onChanged: (widget.enabled && !pending)
          ? (value) => _run(
              option.id,
              () => widget.onSetConfigOption(option.id, value),
            )
          : null,
    );
  }

  Widget _buildLegacyMode(AcpSessionModeState state) => _buildSelect(
    id: '__mode__',
    name: 'Mode',
    currentValue: state.currentModeId,
    values: [
      for (final mode in state.availableModes)
        (mode.id, mode.name.isEmpty ? mode.id : mode.name, mode.description),
    ],
    onSelected: (value) => widget.onSetMode!(value),
  );

  Widget _buildLegacyModel(AcpModelState state) => _buildSelect(
    id: '__model__',
    name: 'Model',
    currentValue: state.currentModelId,
    values: [
      for (final model in state.availableModels)
        (
          model.id,
          model.name.isEmpty ? model.id : model.name,
          model.description,
        ),
    ],
    onSelected: (value) => widget.onSetModel!(value),
  );

  Future<String?> _pickValue({
    required String title,
    required String currentValue,
    required List<(String value, String label, String? description)> values,
  }) => showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: RadioGroup<String>(
          groupValue: currentValue,
          onChanged: (value) => Navigator.of(context).pop(value),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(FluttyTheme.spacingMd),
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              for (final entry in values)
                RadioListTile<String>(
                  value: entry.$1,
                  title: Text(entry.$2),
                  subtitle: entry.$3 == null ? null : Text(entry.$3!),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
