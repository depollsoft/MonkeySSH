import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../../domain/models/acp_elicitation.dart';
import 'acp_elicitation_sheet_parts.dart';

/// How the user resolved a form-mode elicitation sheet. A dismissed sheet
/// resolves to `null`, which the caller answers as `cancel`.
sealed class AcpElicitationFormOutcome {
  const AcpElicitationFormOutcome();
}

/// The user reviewed and submitted the form.
final class AcpElicitationFormSubmitted extends AcpElicitationFormOutcome {
  /// Creates a submission.
  const AcpElicitationFormSubmitted(this.content);

  /// Validated values keyed by property name.
  final Map<String, Object?> content;
}

/// The user explicitly declined to answer.
final class AcpElicitationFormDeclined extends AcpElicitationFormOutcome {
  /// Creates a decline.
  const AcpElicitationFormDeclined();
}

/// Shows [request] as an editable form. Defaults are pre-filled and every
/// value stays editable until the user submits. Completing [withdrawn] (the
/// agent cancelled the request) closes the sheet with `null`.
Future<AcpElicitationFormOutcome?> showAcpElicitationFormSheet(
  BuildContext context, {
  required String agentLabel,
  required AcpFormElicitation request,
  Future<void>? withdrawn,
}) => showAcpWithdrawableSheet<AcpElicitationFormOutcome>(
  context,
  withdrawn: withdrawn,
  builder: (context) =>
      AcpElicitationFormSheet(agentLabel: agentLabel, request: request),
);

/// The body of the form-mode elicitation sheet.
class AcpElicitationFormSheet extends StatefulWidget {
  /// Creates the sheet body.
  const AcpElicitationFormSheet({
    required this.agentLabel,
    required this.request,
    super.key,
  });

  /// Display name of the agent asking.
  final String agentLabel;

  /// The form to render.
  final AcpFormElicitation request;

  @override
  State<AcpElicitationFormSheet> createState() =>
      _AcpElicitationFormSheetState();
}

class _AcpElicitationFormSheetState extends State<AcpElicitationFormSheet> {
  final _formKey = GlobalKey<FormState>();
  final _controllers = <String, TextEditingController>{};
  final _choices = <String, String?>{};
  final _toggles = <String, bool>{};
  final _selections = <String, Set<String>>{};
  // Pattern failures found at submit; a field's entry clears when it changes.
  final _patternErrors = <String, String>{};
  var _submitted = false;
  var _checkingPatterns = false;

  List<AcpElicitationField> get _fields => widget.request.schema.fields;

  @override
  void initState() {
    super.initState();
    for (final field in _fields) {
      switch (field) {
        case AcpStringElicitationField(options: _?, :final defaultValue):
          _choices[field.name] = defaultValue;
        case AcpStringElicitationField(:final defaultValue):
          _controllers[field.name] = TextEditingController(text: defaultValue);
        case AcpNumberElicitationField(:final defaultValue):
          _controllers[field.name] = TextEditingController(
            text: defaultValue == null ? '' : '$defaultValue',
          );
        case AcpBooleanElicitationField(:final defaultValue):
          _toggles[field.name] = defaultValue ?? false;
        case AcpMultiSelectElicitationField(:final defaultValue):
          _selections[field.name] = {...defaultValue};
        case AcpUnsupportedElicitationField():
          break;
      }
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Map<String, Object?> _content() {
    final content = <String, Object?>{};
    for (final field in _fields) {
      switch (field) {
        case AcpStringElicitationField(options: _?):
          if (_choices[field.name] case final value?) {
            content[field.name] = value;
          }
        case AcpStringElicitationField():
          final text = _controllers[field.name]!.text;
          if (text.isNotEmpty) content[field.name] = text;
        case AcpNumberElicitationField():
          final text = _controllers[field.name]!.text.trim();
          if (text.isNotEmpty) content[field.name] = field.parse(text);
        case AcpBooleanElicitationField():
          content[field.name] = _toggles[field.name];
        case AcpMultiSelectElicitationField():
          final selected = _selections[field.name]!;
          if (selected.isNotEmpty || field.isRequired) {
            // Keep the agent's option order, not the tap order.
            content[field.name] = [
              for (final option in field.options)
                if (selected.contains(option.value)) option.value,
            ];
          }
        case AcpUnsupportedElicitationField():
          break;
      }
    }
    return content;
  }

  Future<void> _submit() async {
    if (_checkingPatterns) return;
    setState(() {
      _submitted = true;
      _patternErrors.clear();
    });
    final valid = _formKey.currentState?.validate() ?? false;
    final content = _content();
    if (!valid || widget.request.validateContent(content).isNotEmpty) {
      unawaited(HapticFeedback.mediumImpact());
      return;
    }
    setState(() => _checkingPatterns = true);
    final mismatched = await widget.request.patternMismatches(content);
    if (!mounted) return;
    setState(() {
      _checkingPatterns = false;
      for (final name in mismatched) {
        _patternErrors[name] = AcpFormElicitation.patternMismatchMessage;
      }
    });
    if (mismatched.isNotEmpty) {
      _formKey.currentState?.validate();
      unawaited(HapticFeedback.mediumImpact());
      return;
    }
    Navigator.of(context).pop(AcpElicitationFormSubmitted(content));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final schema = widget.request.schema;
    final canSubmit = widget.request.canSubmit;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.86;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AcpElicitationSheetHeader(
              title: '${widget.agentLabel} needs your input',
              onDismiss: () => Navigator.of(context).pop(),
            ),
            Flexible(
              child: Form(
                key: _formKey,
                autovalidateMode: _submitted
                    ? AutovalidateMode.always
                    : AutovalidateMode.onUserInteraction,
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(
                    FluttyTheme.spacingLg,
                    FluttyTheme.spacingXs,
                    FluttyTheme.spacingLg,
                    FluttyTheme.spacingMd,
                  ),
                  children: [
                    if (widget.request.message.trim().isNotEmpty)
                      Text(
                        widget.request.message,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurface,
                          height: 1.45,
                        ),
                      ),
                    if (schema.title?.trim().isNotEmpty ?? false) ...[
                      const SizedBox(height: FluttyTheme.spacingMd),
                      Text(schema.title!, style: theme.textTheme.titleSmall),
                    ],
                    if (schema.description?.trim().isNotEmpty ?? false) ...[
                      const SizedBox(height: FluttyTheme.spacingXs),
                      Text(
                        schema.description!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: FluttyTheme.spacingSm),
                    AcpElicitationNotice(
                      icon: Icons.shield_outlined,
                      text:
                          'Shared with ${widget.agentLabel}. Never enter '
                          'passwords, API keys, or tokens here.',
                    ),
                    for (final field in _fields) ...[
                      const SizedBox(height: FluttyTheme.spacingLg),
                      _buildField(context, field),
                    ],
                  ],
                ),
              ),
            ),
            AcpElicitationSheetFooter(
              notice: canSubmit
                  ? null
                  : 'This request needs a field MonkeySSH can’t show. You '
                        'can decline it or dismiss it.',
              secondary: TextButton(
                style: TextButton.styleFrom(foregroundColor: scheme.error),
                onPressed: () =>
                    Navigator.of(context)
                        .pop(const AcpElicitationFormDeclined()),
                child: const Text('Decline'),
              ),
              primary: FilledButton(
                onPressed: canSubmit && !_checkingPatterns ? _submit : null,
                child: const Text('Submit'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildField(BuildContext context, AcpElicitationField field) =>
      switch (field) {
        AcpStringElicitationField(:final options?)
            when options.length <= _chipLimit =>
          _choiceChips(field, options),
        AcpStringElicitationField(:final options?) => _choiceDropdown(
          field,
          options,
        ),
        AcpStringElicitationField() => _textField(field),
        AcpNumberElicitationField() => _numberField(field),
        AcpBooleanElicitationField() => _switchField(field),
        AcpMultiSelectElicitationField() => _multiSelect(field),
        AcpUnsupportedElicitationField() => _unsupported(field),
      };

  Widget _textField(AcpStringElicitationField field) {
    final controller = _controllers[field.name]!;
    final format = field.format;
    return _Labeled(
      field: field,
      hint: _lengthHint(field),
      child: TextFormField(
        controller: controller,
        keyboardType: switch (format) {
          AcpElicitationStringFormat.email => TextInputType.emailAddress,
          AcpElicitationStringFormat.uri => TextInputType.url,
          AcpElicitationStringFormat.date ||
          AcpElicitationStringFormat.dateTime => TextInputType.datetime,
          null => TextInputType.text,
        },
        autocorrect: format == null,
        enableSuggestions: format == null,
        textCapitalization: format == null
            ? TextCapitalization.sentences
            : TextCapitalization.none,
        textInputAction: TextInputAction.next,
        style: format == null ? null : FluttyTheme.monoStyle,
        inputFormatters: [
          // A zero limit (`maxLength: 0`) only allows an empty answer, and
          // the length formatter rejects zero.
          if (field.inputLimit > 0)
            LengthLimitingTextInputFormatter(field.inputLimit)
          else
            FilteringTextInputFormatter.deny(RegExp(r'[\s\S]')),
        ],
        decoration: InputDecoration(
          hintText: switch (format) {
            AcpElicitationStringFormat.email => 'name@example.com',
            AcpElicitationStringFormat.uri => 'https://',
            AcpElicitationStringFormat.date => 'YYYY-MM-DD',
            AcpElicitationStringFormat.dateTime => '2026-10-01T09:30:00Z',
            null => null,
          },
          suffixIcon: format == AcpElicitationStringFormat.date
              ? IconButton(
                  tooltip: 'Pick a date',
                  icon: const Icon(Icons.calendar_today_outlined, size: 20),
                  onPressed: () => _pickDate(controller),
                )
              : null,
        ),
        onChanged: (_) {
          if (_patternErrors.remove(field.name) != null) setState(() {});
        },
        validator: (text) =>
            field.validate(text == null || text.isEmpty ? null : text) ??
            _patternErrors[field.name],
      ),
    );
  }

  Future<void> _pickDate(TextEditingController controller) async {
    final firstDate = DateTime(1900);
    final lastDate = DateTime(2200);
    final current = isValidAcpElicitationDate(controller.text)
        ? DateTime.parse(controller.text)
        : DateTime.now();
    final picked = await showDatePicker(
      context: context,
      // Same navigator as the sheet, so a withdrawn request closes both.
      useRootNavigator: false,
      // A typed or default date may fall outside the calendar's range; open
      // at the nearest end without changing the entered text.
      initialDate: current.isBefore(firstDate)
          ? firstDate
          : current.isAfter(lastDate)
          ? lastDate
          : current,
      firstDate: firstDate,
      lastDate: lastDate,
    );
    if (picked == null || !mounted) return;
    String two(int value) => value.toString().padLeft(2, '0');
    controller.text =
        '${picked.year.toString().padLeft(4, '0')}-'
        '${two(picked.month)}-${two(picked.day)}';
  }

  Widget _numberField(AcpNumberElicitationField field) {
    final min = field.minimum;
    final max = field.maximum;
    return _Labeled(
      field: field,
      hint: switch ((min, max)) {
        (final low?, final high?) => 'From $low to $high',
        (final low?, null) => '$low or more',
        (null, final high?) => '$high or less',
        _ => field.integer ? 'A whole number' : null,
      },
      child: TextFormField(
        controller: _controllers[field.name],
        keyboardType: TextInputType.numberWithOptions(
          signed: min == null || min < 0,
          decimal: !field.integer,
        ),
        textInputAction: TextInputAction.next,
        style: FluttyTheme.monoStyle,
        inputFormatters: [
          FilteringTextInputFormatter.allow(
            field.integer ? RegExp('[0-9-]') : RegExp(r'[0-9eE+\-.]'),
          ),
          LengthLimitingTextInputFormatter(32),
        ],
        validator: (text) {
          final value = text?.trim() ?? '';
          if (value.isEmpty) return field.validate(null);
          final parsed = field.parse(value);
          if (parsed == null) {
            return field.integer ? 'Enter a whole number' : 'Enter a number';
          }
          return field.validate(parsed);
        },
      ),
    );
  }

  Widget _switchField(AcpBooleanElicitationField field) => FormField<bool>(
    initialValue: _toggles[field.name],
    validator: field.validate,
    builder: (state) => MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _FieldLabel(field: field)),
          const SizedBox(width: FluttyTheme.spacingMd),
          Switch(
            value: state.value ?? false,
            onChanged: (value) {
              state.didChange(value);
              setState(() => _toggles[field.name] = value);
            },
          ),
        ],
      ),
    ),
  );

  Widget _choiceChips(
    AcpStringElicitationField field,
    List<AcpElicitationOption> options,
  ) => FormField<String>(
    initialValue: _choices[field.name],
    validator: field.validate,
    builder: (state) => _Labeled(
      field: field,
      error: state.errorText,
      child: Wrap(
        spacing: FluttyTheme.spacingSm,
        runSpacing: FluttyTheme.spacingXs,
        children: [
          for (final option in options)
            ChoiceChip(
              label: Text(option.title),
              selected: state.value == option.value,
              onSelected: (selected) {
                // An optional choice can be cleared by tapping it again.
                final value = selected
                    ? option.value
                    : (field.isRequired ? option.value : null);
                state.didChange(value);
                setState(() => _choices[field.name] = value);
              },
            ),
        ],
      ),
    ),
  );

  Widget _choiceDropdown(
    AcpStringElicitationField field,
    List<AcpElicitationOption> options,
  ) => _Labeled(
    field: field,
    child: DropdownButtonFormField<String>(
      initialValue: _choices[field.name],
      isExpanded: true,
      hint: const Text('Choose one'),
      items: [
        if (!field.isRequired)
          const DropdownMenuItem<String>(child: Text('No answer')),
        for (final option in options)
          DropdownMenuItem<String>(
            value: option.value,
            child: Text(option.title, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (value) => setState(() => _choices[field.name] = value),
      validator: field.validate,
    ),
  );

  Widget _multiSelect(AcpMultiSelectElicitationField field) {
    final min = field.minItems;
    final max = field.maxItems;
    return FormField<Set<String>>(
      initialValue: _selections[field.name],
      validator: (value) {
        final selected = value ?? const <String>{};
        if (selected.isEmpty && !field.isRequired) return null;
        return field.validate([
          for (final option in field.options)
            if (selected.contains(option.value)) option.value,
        ]);
      },
      builder: (state) => _Labeled(
        field: field,
        hint: switch ((min, max)) {
          (final low?, final high?) when low == high => 'Choose $low',
          (final low?, final high?) => 'Choose $low to $high',
          (final low?, null) when low > 0 => 'Choose at least $low',
          (_, final high?) => 'Choose up to $high',
          _ => 'Choose any',
        },
        error: state.errorText,
        child: Wrap(
          spacing: FluttyTheme.spacingSm,
          runSpacing: FluttyTheme.spacingXs,
          children: [
            for (final option in field.options)
              FilterChip(
                label: Text(option.title),
                selected: state.value?.contains(option.value) ?? false,
                onSelected: (selected) {
                  final next = {...?state.value};
                  selected ? next.add(option.value) : next.remove(option.value);
                  state.didChange(next);
                  setState(() => _selections[field.name] = next);
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _unsupported(AcpUnsupportedElicitationField field) {
    final scheme = Theme.of(context).colorScheme;
    return _Labeled(
      field: field,
      child: AcpElicitationNotice(
        icon: Icons.block,
        color: field.isRequired ? scheme.error : null,
        text: field.isRequired
            ? 'MonkeySSH can’t show this required field.'
            : 'MonkeySSH can’t show this field. It will be left out.',
      ),
    );
  }

  static String? _lengthHint(AcpStringElicitationField field) =>
      switch ((field.minLength, field.maxLength)) {
        (final low?, final high?) when low > 0 => '$low to $high characters',
        (final low?, null) when low > 0 => 'At least $low characters',
        (_, final high?) => 'Up to $high characters',
        _ => null,
      };
}

/// Choices up to this count render as chips; more fall back to a menu.
const _chipLimit = 6;

/// A field label with an optional constraint hint, description, and error,
/// wrapped around the field's control.
class _Labeled extends StatelessWidget {
  const _Labeled({
    required this.field,
    required this.child,
    this.hint,
    this.error,
  });

  final AcpElicitationField field;
  final Widget child;
  final String? hint;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _FieldLabel(field: field, hint: hint),
        const SizedBox(height: FluttyTheme.spacingSm),
        child,
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: FluttyTheme.spacingXs),
            child: Text(
              error!,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.field, this.hint});

  final AcpElicitationField field;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final description = field.description?.trim();
    final details = [
      if (description != null && description.isNotEmpty) description,
      ?hint,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: field.isRequired ? '${field.label}, required' : field.label,
          excludeSemantics: true,
          child: Text.rich(
            TextSpan(
              text: field.label,
              children: [
                if (field.isRequired)
                  TextSpan(
                    text: '  required',
                    style: FluttyTheme.monoStyle.copyWith(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            style: theme.textTheme.labelLarge?.copyWith(
              color: scheme.onSurface,
            ),
          ),
        ),
        for (final detail in details)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              detail,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
