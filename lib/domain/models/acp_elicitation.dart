/// Typed ACP v1 `elicitation/create` requests and their validation rules.
///
/// Elicitation lets an agent ask the user for structured input, either with a
/// restricted flat JSON Schema form or by sending the user to a URL. Every
/// value here is provider-controlled and may contain user content, so none of
/// it is ever logged, persisted, or sent to telemetry.
library;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import 'acp_json.dart';

/// Largest accepted `elicitation/create` params object, in UTF-8 JSON bytes.
const acpElicitationMaxRequestBytes = 64 * 1024;

/// Most properties rendered for one form.
const acpElicitationMaxProperties = 32;

/// Longest accepted request message, in UTF-16 code units.
const acpElicitationMaxMessageCharacters = 4000;

/// Longest accepted title or description, in UTF-16 code units.
const acpElicitationMaxLabelCharacters = 1000;

/// Longest accepted property name, in UTF-16 code units.
const acpElicitationMaxPropertyNameCharacters = 128;

/// Most choices accepted for one select or multi-select property.
const acpElicitationMaxOptions = 100;

/// Longest accepted choice value or title, in UTF-16 code units.
const acpElicitationMaxOptionCharacters = 500;

/// Longest accepted regular-expression `pattern`, in UTF-16 code units.
const acpElicitationMaxPatternCharacters = 512;

/// Longest accepted string default or submitted string value.
const acpElicitationMaxStringValueCharacters = 4000;

/// Longest accepted URL for URL-mode requests.
const acpElicitationMaxUrlCharacters = 4096;

/// Longest accepted opaque `elicitationId`.
const acpElicitationMaxIdCharacters = 256;

/// A refused `elicitation/create` request. [message] is safe to return to the
/// agent and never echoes request content.
final class AcpElicitationRequestException implements Exception {
  /// Creates a refusal.
  const AcpElicitationRequestException(
    this.message, {
    this.unsupportedMode = false,
  });

  /// Safe, content-free reason.
  final String message;

  /// Whether the request named a mode this client did not advertise.
  final bool unsupportedMode;

  @override
  String toString() => message;
}

/// Where an elicitation belongs.
@immutable
final class AcpElicitationScope {
  /// A request tied to an ACP session, optionally to one of its tool calls.
  const AcpElicitationScope.session(String this.sessionId, {this.toolCallId})
    : requestId = null;

  /// A request tied to an outstanding JSON-RPC request outside a session.
  const AcpElicitationScope.request(Object this.requestId)
    : sessionId = null,
      toolCallId = null;

  /// Owning ACP session, for a session-scoped request.
  final String? sessionId;

  /// Related tool call within [sessionId], if any.
  final String? toolCallId;

  /// Exact JSON-RPC id (int or string) of the request this one belongs to.
  final Object? requestId;

  /// Whether this request is tied to a request rather than a session.
  bool get isRequestScoped => sessionId == null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpElicitationScope &&
          sessionId == other.sessionId &&
          toolCallId == other.toolCallId &&
          requestId == other.requestId &&
          requestId.runtimeType == other.requestId.runtimeType;

  @override
  int get hashCode => Object.hash(sessionId, toolCallId, requestId);
}

/// A parsed `elicitation/create` request.
@immutable
sealed class AcpElicitationRequest {
  const AcpElicitationRequest({required this.message, required this.scope});

  /// Parses [params], refusing modes this client does not support.
  ///
  /// Throws [AcpElicitationRequestException] for an unadvertised or unknown
  /// mode (`unsupportedMode`) and for structurally invalid or oversized input.
  factory AcpElicitationRequest.parse(
    AcpJsonMap params, {
    required bool formSupported,
    required bool urlSupported,
  }) {
    final mode = params['mode'];
    if (mode is! String) {
      throw const AcpElicitationRequestException('Elicitation mode is missing');
    }
    final supported = switch (mode) {
      'form' => formSupported,
      'url' => urlSupported,
      _ => false,
    };
    if (!supported) {
      throw const AcpElicitationRequestException(
        'Unsupported elicitation mode',
        unsupportedMode: true,
      );
    }
    final message = params['message'];
    if (message is! String) {
      throw const AcpElicitationRequestException(
        'Elicitation message is missing',
      );
    }
    if (message.length > acpElicitationMaxMessageCharacters) {
      throw const AcpElicitationRequestException(
        'Elicitation message is too long',
      );
    }
    final scope = _parseScope(params);
    if (mode == 'form') {
      final schema = AcpJson.object(params['requestedSchema']);
      if (schema == null) {
        throw const AcpElicitationRequestException(
          'Elicitation schema is missing',
        );
      }
      return AcpFormElicitation(
        message: message,
        scope: scope,
        schema: AcpElicitationSchema.parse(schema),
      );
    }
    final elicitationId = params['elicitationId'];
    if (elicitationId is! String ||
        elicitationId.isEmpty ||
        elicitationId.length > acpElicitationMaxIdCharacters) {
      throw const AcpElicitationRequestException('Invalid elicitation id');
    }
    final url = params['url'];
    if (url is! String ||
        url.isEmpty ||
        url.length > acpElicitationMaxUrlCharacters) {
      throw const AcpElicitationRequestException('Invalid elicitation URL');
    }
    return AcpUrlElicitation(
      message: message,
      scope: scope,
      elicitationId: elicitationId,
      url: url,
    );
  }

  /// Human-readable reason supplied by the agent. Plain text, never linkified.
  final String message;

  /// Session or request this elicitation belongs to.
  final AcpElicitationScope scope;

  static AcpElicitationScope _parseScope(AcpJsonMap params) {
    final sessionId = params['sessionId'];
    if (sessionId is String &&
        sessionId.isNotEmpty &&
        sessionId.length <= acpMaxIdentifierCharacters) {
      final toolCallId = params['toolCallId'];
      return AcpElicitationScope.session(
        sessionId,
        toolCallId:
            toolCallId is String &&
                toolCallId.isNotEmpty &&
                toolCallId.length <= acpMaxIdentifierCharacters
            ? toolCallId
            : null,
      );
    }
    final requestId = params['requestId'];
    if (requestId is int ||
        (requestId is String &&
            requestId.length <= acpMaxIdentifierCharacters)) {
      return AcpElicitationScope.request(requestId!);
    }
    throw const AcpElicitationRequestException(
      'Elicitation needs a session or request scope',
    );
  }
}

/// A form-mode elicitation collecting non-sensitive structured input.
final class AcpFormElicitation extends AcpElicitationRequest {
  /// Creates a form-mode request.
  const AcpFormElicitation({
    required super.message,
    required super.scope,
    required this.schema,
  });

  /// The flat form to render.
  final AcpElicitationSchema schema;

  /// Whether every required field can be rendered, so the form can be sent.
  bool get canSubmit => schema.fields.every(
    (field) => !field.isRequired || field is! AcpUnsupportedElicitationField,
  );

  /// Validates a submitted `content` map against [schema].
  ///
  /// Returns a field-name-to-message map; empty means valid. Unknown keys are
  /// rejected so a caller can never send values the agent did not request.
  Map<String, String> validateContent(Map<String, Object?> content) {
    final errors = <String, String>{};
    final known = <String, AcpElicitationField>{
      for (final field in schema.fields) field.name: field,
    };
    for (final key in content.keys) {
      if (!known.containsKey(key)) errors[key] = 'Unknown field';
    }
    for (final field in schema.fields) {
      final error = field.validate(content[field.name]);
      if (error != null) errors[field.name] = error;
    }
    return errors;
  }
}

/// A URL-mode elicitation that sends the user to an out-of-band page.
final class AcpUrlElicitation extends AcpElicitationRequest {
  /// Creates a URL-mode request.
  const AcpUrlElicitation({
    required super.message,
    required super.scope,
    required this.elicitationId,
    required this.url,
  });

  /// Opaque id the agent later names in `elicitation/complete`.
  final String elicitationId;

  /// The exact URL supplied by the agent, shown in full before consent.
  final String url;

  /// Safety review of [url]. Computed without any network access.
  AcpElicitationUrlReview get review => AcpElicitationUrlReview.of(url);
}

/// A content-free safety review of a URL-mode elicitation target.
@immutable
final class AcpElicitationUrlReview {
  const AcpElicitationUrlReview._({
    required this.uri,
    required this.host,
    required this.canOpen,
    required this.insecure,
    required this.punycode,
    required this.hasUserInfo,
  });

  /// Reviews [url] without fetching it.
  factory AcpElicitationUrlReview.of(String url) {
    final uri = Uri.tryParse(url.trim());
    final scheme = uri?.scheme.toLowerCase() ?? '';
    final host = uri?.host ?? '';
    final web = scheme == 'http' || scheme == 'https';
    return AcpElicitationUrlReview._(
      uri: uri,
      host: host,
      canOpen: uri != null && web && host.isNotEmpty,
      insecure: scheme == 'http',
      punycode: host
          .toLowerCase()
          .split('.')
          .any((label) => label.startsWith('xn--')),
      hasUserInfo: uri?.userInfo.isNotEmpty ?? false,
    );
  }

  /// Parsed URL, or `null` when it is malformed.
  final Uri? uri;

  /// Host to emphasize; empty when absent.
  final String host;

  /// Whether MonkeySSH will open it (absolute `http`/`https` with a host).
  final bool canOpen;

  /// Whether it uses unencrypted `http`.
  final bool insecure;

  /// Whether any host label is Punycode (`xn--`), which can imitate others.
  final bool punycode;

  /// Whether it embeds a `user@` prefix that can disguise the real host.
  final bool hasUserInfo;

  /// Whether the user should acknowledge a warning before opening.
  bool get needsAcknowledgement => insecure || punycode || hasUserInfo;
}

/// A restricted, flat JSON Schema for a form-mode elicitation.
@immutable
final class AcpElicitationSchema {
  /// Creates a schema.
  AcpElicitationSchema({
    required List<AcpElicitationField> fields,
    this.title,
    this.description,
  }) : fields = List<AcpElicitationField>.unmodifiable(fields);

  /// Parses `requestedSchema`.
  factory AcpElicitationSchema.parse(AcpJsonMap json) {
    final properties = AcpJson.object(json['properties']) ?? const {};
    if (properties.length > acpElicitationMaxProperties) {
      throw const AcpElicitationRequestException(
        'Elicitation form has too many fields',
      );
    }
    final requiredNames = AcpJson.strings(json['required']).toSet();
    final fields = <AcpElicitationField>[];
    for (final entry in properties.entries) {
      final name = entry.key;
      if (name.isEmpty ||
          name.length > acpElicitationMaxPropertyNameCharacters) {
        throw const AcpElicitationRequestException(
          'Invalid elicitation field name',
        );
      }
      fields.add(
        AcpElicitationField.parse(
          name,
          AcpJson.object(entry.value),
          isRequired: requiredNames.contains(name),
        ),
      );
    }
    return AcpElicitationSchema(
      fields: fields,
      title: _label(json, 'title'),
      description: _label(json, 'description'),
    );
  }

  /// Optional form title.
  final String? title;

  /// Optional form description.
  final String? description;

  /// Fields in the agent's declared order.
  final List<AcpElicitationField> fields;
}

/// Supported string formats.
enum AcpElicitationStringFormat {
  /// An email address.
  email('email'),

  /// An absolute URI. Rendered as plain text, never as a link.
  uri('uri'),

  /// A calendar date (`YYYY-MM-DD`).
  date('date'),

  /// An RFC 3339 date-time.
  dateTime('date-time');

  const AcpElicitationStringFormat(this.value);

  /// Wire value.
  final String value;

  static AcpElicitationStringFormat? _parse(Object? value) =>
      AcpElicitationStringFormat.values.firstWhereOrNull(
        (format) => format.value == value,
      );
}

/// One selectable value with a display title.
@immutable
final class AcpElicitationOption {
  /// Creates an option.
  const AcpElicitationOption({required this.value, required this.title});

  /// Exact value sent back to the agent.
  final String value;

  /// Display title.
  final String title;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpElicitationOption &&
          value == other.value &&
          title == other.title;

  @override
  int get hashCode => Object.hash(value, title);
}

/// One form field.
@immutable
sealed class AcpElicitationField {
  const AcpElicitationField({
    required this.name,
    required this.isRequired,
    this.title,
    this.description,
  });

  /// Parses property [name] from its schema [json].
  factory AcpElicitationField.parse(
    String name,
    AcpJsonMap? json, {
    required bool isRequired,
  }) {
    if (json == null) {
      return AcpUnsupportedElicitationField(
        name: name,
        isRequired: isRequired,
        type: '',
      );
    }
    final title = _label(json, 'title');
    final description = _label(json, 'description');
    final type = json['type'];
    switch (type) {
      case 'string':
        final options = _stringOptions(json);
        final pattern = json['pattern'];
        final defaultValue = json['default'];
        return AcpStringElicitationField(
          name: name,
          isRequired: isRequired,
          title: title,
          description: description,
          minLength: _nonNegativeInt(json['minLength']),
          maxLength: _nonNegativeInt(json['maxLength']),
          pattern: pattern is String && pattern.isNotEmpty
              ? _compilePattern(pattern)
              : null,
          format: AcpElicitationStringFormat._parse(json['format']),
          options: options,
          defaultValue:
              defaultValue is String &&
                  defaultValue.length <=
                      acpElicitationMaxStringValueCharacters &&
                  (options == null ||
                      options.any((option) => option.value == defaultValue))
              ? defaultValue
              : null,
        );
      case 'number' || 'integer':
        final integer = type == 'integer';
        num? bound(Object? value) =>
            value is num && value.isFinite && (!integer || value is int)
            ? value
            : null;
        return AcpNumberElicitationField(
          name: name,
          isRequired: isRequired,
          title: title,
          description: description,
          integer: integer,
          minimum: bound(json['minimum']),
          maximum: bound(json['maximum']),
          defaultValue: bound(json['default']),
        );
      case 'boolean':
        final defaultValue = json['default'];
        return AcpBooleanElicitationField(
          name: name,
          isRequired: isRequired,
          title: title,
          description: description,
          defaultValue: defaultValue is bool ? defaultValue : null,
        );
      case 'array':
        final options = _multiSelectOptions(AcpJson.object(json['items']));
        if (options == null) {
          return AcpUnsupportedElicitationField(
            name: name,
            isRequired: isRequired,
            title: title,
            description: description,
            type: 'array',
          );
        }
        final values = options.map((option) => option.value).toSet();
        return AcpMultiSelectElicitationField(
          name: name,
          isRequired: isRequired,
          title: title,
          description: description,
          options: options,
          minItems: _nonNegativeInt(json['minItems']),
          maxItems: _nonNegativeInt(json['maxItems']),
          defaultValue: AcpJson.strings(json['default'])
              .where(values.contains)
              .toSet()
              .toList(growable: false),
        );
      default:
        return AcpUnsupportedElicitationField(
          name: name,
          isRequired: isRequired,
          title: title,
          description: description,
          type: type is String && type.length <= 32 ? type : '',
        );
    }
  }

  /// Property key sent back in `content`.
  final String name;

  /// Optional display title.
  final String? title;

  /// Optional plain-text help.
  final String? description;

  /// Whether the agent requires a value.
  final bool isRequired;

  /// Display label: the title, falling back to the property name.
  String get label {
    final value = title?.trim();
    return value == null || value.isEmpty ? name : value;
  }

  /// Validates one submitted value; `null` means valid. An omitted value is
  /// passed as `null`.
  String? validate(Object? value);
}

/// A text field, or a single choice when [options] is present.
final class AcpStringElicitationField extends AcpElicitationField {
  /// Creates a string field.
  AcpStringElicitationField({
    required super.name,
    required super.isRequired,
    super.title,
    super.description,
    this.minLength,
    this.maxLength,
    this.pattern,
    this.format,
    List<AcpElicitationOption>? options,
    this.defaultValue,
  }) : options = options == null
           ? null
           : List<AcpElicitationOption>.unmodifiable(options);

  /// Minimum length in Unicode code points.
  final int? minLength;

  /// Maximum length in Unicode code points.
  final int? maxLength;

  /// Compiled pattern, or `null` when absent or not compilable here.
  final RegExp? pattern;

  /// Expected format.
  final AcpElicitationStringFormat? format;

  /// Single-choice values from `enum` or `oneOf`.
  final List<AcpElicitationOption>? options;

  /// Default value to pre-fill.
  final String? defaultValue;

  /// Largest number of characters the UI should accept.
  int get inputLimit => switch (maxLength) {
    final max? when max < acpElicitationMaxStringValueCharacters => max,
    _ => acpElicitationMaxStringValueCharacters,
  };

  @override
  String? validate(Object? value) {
    if (value == null || (value is String && value.isEmpty)) {
      return isRequired ? 'Required' : null;
    }
    if (value is! String) return 'Enter text';
    if (options case final choices?) {
      return choices.any((option) => option.value == value)
          ? null
          : 'Choose one of the options';
    }
    final length = value.runes.length;
    if (value.length > acpElicitationMaxStringValueCharacters) {
      return 'Too long';
    }
    if (minLength case final min? when length < min) {
      return 'Use at least $min characters';
    }
    if (maxLength case final max? when length > max) {
      return 'Use at most $max characters';
    }
    switch (format) {
      case AcpElicitationStringFormat.email:
        if (!_emailPattern.hasMatch(value)) return 'Enter an email address';
      case AcpElicitationStringFormat.uri:
        final uri = Uri.tryParse(value);
        if (uri == null || !uri.hasScheme || uri.scheme.isEmpty) {
          return 'Enter a full address, including its scheme';
        }
      case AcpElicitationStringFormat.date:
        if (!isValidAcpElicitationDate(value)) return 'Use YYYY-MM-DD';
      case AcpElicitationStringFormat.dateTime:
        if (!isValidAcpElicitationDateTime(value)) {
          return 'Use a date and time like 2026-10-01T09:30:00Z';
        }
      case null:
        break;
    }
    if (pattern case final regex? when !regex.hasMatch(value)) {
      return 'Does not match the expected format';
    }
    return null;
  }
}

/// A number or integer field.
final class AcpNumberElicitationField extends AcpElicitationField {
  /// Creates a numeric field.
  const AcpNumberElicitationField({
    required super.name,
    required super.isRequired,
    required this.integer,
    super.title,
    super.description,
    this.minimum,
    this.maximum,
    this.defaultValue,
  });

  /// Whether only whole numbers are accepted.
  final bool integer;

  /// Inclusive lower bound.
  final num? minimum;

  /// Inclusive upper bound.
  final num? maximum;

  /// Default value to pre-fill.
  final num? defaultValue;

  /// Parses user text into a value for this field, or `null` if invalid.
  num? parse(String text) {
    final trimmed = text.trim();
    if (integer) return int.tryParse(trimmed);
    final value = num.tryParse(trimmed);
    return value != null && value.isFinite ? value : null;
  }

  @override
  String? validate(Object? value) {
    if (value == null) return isRequired ? 'Required' : null;
    if (value is! num || !value.isFinite) return 'Enter a number';
    if (integer && value is! int) return 'Enter a whole number';
    if (minimum case final min? when value < min) return 'Use $min or more';
    if (maximum case final max? when value > max) return 'Use $max or less';
    return null;
  }
}

/// A yes/no field.
final class AcpBooleanElicitationField extends AcpElicitationField {
  /// Creates a boolean field.
  const AcpBooleanElicitationField({
    required super.name,
    required super.isRequired,
    super.title,
    super.description,
    this.defaultValue,
  });

  /// Default value to pre-fill.
  final bool? defaultValue;

  @override
  String? validate(Object? value) {
    if (value == null) return isRequired ? 'Required' : null;
    return value is bool ? null : 'Choose yes or no';
  }
}

/// A multiple-choice field returning a list of strings.
final class AcpMultiSelectElicitationField extends AcpElicitationField {
  /// Creates a multi-select field.
  AcpMultiSelectElicitationField({
    required super.name,
    required super.isRequired,
    required List<AcpElicitationOption> options,
    super.title,
    super.description,
    this.minItems,
    this.maxItems,
    List<String> defaultValue = const <String>[],
  }) : options = List<AcpElicitationOption>.unmodifiable(options),
       defaultValue = List<String>.unmodifiable(defaultValue);

  /// Selectable values.
  final List<AcpElicitationOption> options;

  /// Minimum selections.
  final int? minItems;

  /// Maximum selections.
  final int? maxItems;

  /// Values selected by default.
  final List<String> defaultValue;

  @override
  String? validate(Object? value) {
    if (value == null) return isRequired ? 'Required' : null;
    if (value is! List || value.any((item) => item is! String)) {
      return 'Choose from the options';
    }
    final values = options.map((option) => option.value).toSet();
    if (value.any((item) => !values.contains(item))) {
      return 'Choose from the options';
    }
    if (value.toSet().length != value.length) return 'Choose each option once';
    if (isRequired && value.isEmpty) return 'Required';
    if (minItems case final min? when value.length < min) {
      return 'Choose at least $min';
    }
    if (maxItems case final max? when value.length > max) {
      return 'Choose at most $max';
    }
    return null;
  }
}

/// A property this client cannot render. It is never submitted; a required
/// one blocks submission, leaving only decline or cancel.
final class AcpUnsupportedElicitationField extends AcpElicitationField {
  /// Creates an unsupported field.
  const AcpUnsupportedElicitationField({
    required super.name,
    required super.isRequired,
    required this.type,
    super.title,
    super.description,
  });

  /// The declared type, bounded, for display only.
  final String type;

  @override
  String? validate(Object? value) {
    if (value != null) return 'This field is not supported';
    return isRequired ? 'This required field is not supported' : null;
  }
}

/// A pending elicitation surfaced on a session for a user decision.
@immutable
final class AcpSessionElicitation {
  /// Creates a pending elicitation reference.
  const AcpSessionElicitation({
    required this.requestKey,
    required this.request,
    required this.requestedAt,
  });

  /// Type-tagged JSON-RPC request key used to answer the request.
  final String requestKey;

  /// The parsed request.
  final AcpElicitationRequest request;

  /// When the request was first observed locally.
  final DateTime requestedAt;

  /// Whether this request belongs to a request rather than one session.
  bool get isRequestScoped => request.scope.isRequestScoped;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpSessionElicitation &&
          requestKey == other.requestKey &&
          requestedAt == other.requestedAt &&
          identical(request, other.request);

  @override
  int get hashCode =>
      Object.hash(requestKey, requestedAt, identityHashCode(request));
}

/// An accepted URL elicitation the user is finishing in the browser.
@immutable
final class AcpAwaitingElicitation {
  /// Creates an awaiting-completion entry.
  const AcpAwaitingElicitation({
    required this.elicitationId,
    required this.url,
    required this.acceptedAt,
    this.sessionId,
  });

  /// Opaque id the agent will name in `elicitation/complete`.
  final String elicitationId;

  /// The URL the user consented to open.
  final String url;

  /// Owning session, or `null` for a request-scoped elicitation.
  final String? sessionId;

  /// When the user consented.
  final DateTime acceptedAt;

  /// Host shown while waiting.
  String get host => AcpElicitationUrlReview.of(url).host;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpAwaitingElicitation &&
          elicitationId == other.elicitationId &&
          url == other.url &&
          sessionId == other.sessionId &&
          acceptedAt == other.acceptedAt;

  @override
  int get hashCode => Object.hash(elicitationId, url, sessionId, acceptedAt);
}

/// Whether [value] is a valid `YYYY-MM-DD` calendar date.
bool isValidAcpElicitationDate(String value) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
  if (match == null) return false;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final parsed = DateTime.utc(year, month, day);
  return parsed.year == year && parsed.month == month && parsed.day == day;
}

/// Whether [value] is an RFC 3339 date-time with an explicit offset.
bool isValidAcpElicitationDateTime(String value) {
  final match = RegExp(
    r'^(\d{4}-\d{2}-\d{2})[Tt](\d{2}):(\d{2}):(\d{2})(\.\d+)?([Zz]|[+-]\d{2}:\d{2})$',
  ).firstMatch(value);
  if (match == null || !isValidAcpElicitationDate(match.group(1)!)) {
    return false;
  }
  final hour = int.parse(match.group(2)!);
  final minute = int.parse(match.group(3)!);
  final second = int.parse(match.group(4)!);
  return hour < 24 && minute < 60 && second <= 60;
}

final _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

String? _label(AcpJsonMap json, String key) {
  final value = json[key];
  if (value is! String) return null;
  if (value.length > acpElicitationMaxLabelCharacters) {
    throw const AcpElicitationRequestException('Elicitation label is too long');
  }
  return value;
}

int? _nonNegativeInt(Object? value) =>
    value is int && value >= 0 ? value : null;

RegExp? _compilePattern(String pattern) {
  if (pattern.length > acpElicitationMaxPatternCharacters) {
    throw const AcpElicitationRequestException(
      'Elicitation pattern is too long',
    );
  }
  // JSON Schema patterns are ECMA-262 and unanchored. Prefer Unicode mode, but
  // accept legacy escapes it rejects.
  for (final unicode in const [true, false]) {
    try {
      return RegExp(pattern, unicode: unicode);
    } on FormatException {
      continue;
    }
  }
  // The agent validates again; skip a check this client cannot express.
  return null;
}

List<AcpElicitationOption>? _stringOptions(AcpJsonMap json) {
  final oneOf = json['oneOf'];
  if (oneOf is List) return _titledOptions(oneOf);
  final values = json['enum'];
  if (values is List) return _untitledOptions(values);
  return null;
}

List<AcpElicitationOption>? _multiSelectOptions(AcpJsonMap? items) {
  if (items == null) return null;
  final anyOf = items['anyOf'];
  if (anyOf is List) return _titledOptions(anyOf);
  final values = items['enum'];
  if (items['type'] == 'string' && values is List) {
    return _untitledOptions(values);
  }
  return null;
}

List<AcpElicitationOption> _titledOptions(List<Object?> raw) {
  if (raw.length > acpElicitationMaxOptions) {
    throw const AcpElicitationRequestException(
      'Elicitation field has too many options',
    );
  }
  final options = <AcpElicitationOption>[];
  final seen = <String>{};
  for (final item in raw) {
    final json = AcpJson.object(item);
    final value = json?['const'];
    if (value is! String || !seen.add(value)) continue;
    final title = json?['title'];
    options.add(
      AcpElicitationOption(
        value: _boundedOption(value),
        title: title is String && title.trim().isNotEmpty
            ? _boundedOption(title)
            : value,
      ),
    );
  }
  return options;
}

List<AcpElicitationOption> _untitledOptions(List<Object?> raw) {
  if (raw.length > acpElicitationMaxOptions) {
    throw const AcpElicitationRequestException(
      'Elicitation field has too many options',
    );
  }
  final options = <AcpElicitationOption>[];
  final seen = <String>{};
  for (final value in raw) {
    if (value is! String || !seen.add(value)) continue;
    options.add(
      AcpElicitationOption(value: _boundedOption(value), title: value),
    );
  }
  return options;
}

String _boundedOption(String value) {
  if (value.length > acpElicitationMaxOptionCharacters) {
    throw const AcpElicitationRequestException(
      'Elicitation option is too long',
    );
  }
  return value;
}
