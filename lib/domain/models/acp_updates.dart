import 'acp_content.dart';
import 'acp_json.dart';
import 'acp_protocol.dart';

/// A streamed ACP update associated with a session.
sealed class AcpSessionUpdate implements AcpExtensible {
  const AcpSessionUpdate();

  /// Parses a known or extension session update.
  factory AcpSessionUpdate.fromJson(AcpJsonMap json) => switch (AcpJson.string(
    json,
    'sessionUpdate',
  )) {
    'user_message_chunk' => AcpContentChunkUpdate.fromJson(json),
    'agent_message_chunk' => AcpContentChunkUpdate.fromJson(json),
    'agent_thought_chunk' => AcpContentChunkUpdate.fromJson(json),
    'tool_call' => AcpToolCallUpdate.fromJson(json, isInitial: true),
    'tool_call_update' => AcpToolCallUpdate.fromJson(json),
    'plan' => AcpPlanUpdate.fromJson(json),
    'available_commands_update' => AcpAvailableCommandsUpdate.fromJson(json),
    'current_mode_update' => AcpCurrentModeUpdate.fromJson(json),
    'current_model_update' => AcpCurrentModelUpdate.fromJson(json),
    'config_option_update' => AcpConfigOptionsUpdate.fromJson(json),
    'session_info_update' => AcpSessionInfoUpdate.fromJson(json),
    'usage_update' => AcpUsageUpdate.fromJson(json),
    _ => AcpUnknownSessionUpdate.fromJson(json),
  };

  /// Update discriminator.
  String get kind;
}

/// A content chunk streamed for a user, agent, or thought message.
final class AcpContentChunkUpdate extends AcpSessionUpdate {
  /// Creates a content chunk update.
  const AcpContentChunkUpdate({
    required this.kind,
    required this.content,
    this.messageId,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses a content chunk update.
  factory AcpContentChunkUpdate.fromJson(AcpJsonMap json) {
    final content =
        AcpJson.objectField(json, 'content') ??
        const <String, Object?>{'type': 'text', 'text': ''};
    return AcpContentChunkUpdate(
      kind: AcpJson.string(json, 'sessionUpdate') ?? 'unknown',
      content: AcpContentBlock.fromJson(content),
      messageId: AcpJson.identifier(json, 'messageId'),
      meta: AcpJson.meta(json),
      extensions: AcpJson.extensions(json, const [
        'sessionUpdate',
        'content',
        'messageId',
      ]),
    );
  }

  @override
  final String kind;

  /// Streamed content.
  final AcpContentBlock content;

  /// Identifier grouping chunks into one message.
  final String? messageId;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Priority of an ACP plan entry.
extension type const AcpPlanPriority(String value) {
  /// High priority.
  static const high = AcpPlanPriority('high');

  /// Medium priority.
  static const medium = AcpPlanPriority('medium');

  /// Low priority.
  static const low = AcpPlanPriority('low');
}

/// Status of an ACP plan entry.
extension type const AcpPlanStatus(String value) {
  /// Work has not started.
  static const pending = AcpPlanStatus('pending');

  /// Work is active.
  static const inProgress = AcpPlanStatus('in_progress');

  /// Work is complete.
  static const completed = AcpPlanStatus('completed');
}

/// Maximum entries retained from one provider plan update.
const acpMaxPlanEntries = 200;

/// Maximum characters retained for one provider plan entry.
const acpMaxPlanEntryCharacters = 4096;

/// One task in an ACP execution plan.
final class AcpPlanEntry implements AcpExtensible {
  /// Creates a plan entry.
  const AcpPlanEntry({
    required this.content,
    required this.priority,
    required this.status,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses a plan entry.
  factory AcpPlanEntry.fromJson(AcpJsonMap json) {
    final content = AcpJson.string(json, 'content') ?? '';
    return AcpPlanEntry(
      content: content.length <= acpMaxPlanEntryCharacters
          ? content
          : content.substring(0, acpMaxPlanEntryCharacters),
      priority: AcpPlanPriority(AcpJson.string(json, 'priority') ?? 'medium'),
      status: AcpPlanStatus(AcpJson.string(json, 'status') ?? 'pending'),
      meta: AcpJson.meta(json),
      extensions: AcpJson.extensions(json, const [
        'content',
        'priority',
        'status',
      ]),
    );
  }

  /// Human-readable task content.
  final String content;

  /// Task priority.
  final AcpPlanPriority priority;

  /// Task status.
  final AcpPlanStatus status;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Complete replacement of an agent execution plan.
final class AcpPlanUpdate extends AcpSessionUpdate {
  /// Creates a plan update.
  const AcpPlanUpdate({
    this.entries = const <AcpPlanEntry>[],
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses a plan update.
  factory AcpPlanUpdate.fromJson(AcpJsonMap json) => AcpPlanUpdate(
    entries: AcpJson.objectList(
      json['entries'],
      AcpPlanEntry.fromJson,
      limit: acpMaxPlanEntries,
    ),
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const ['sessionUpdate', 'entries']),
  );

  @override
  String get kind => 'plan';

  /// Complete plan entries.
  final List<AcpPlanEntry> entries;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Forward-compatible ACP tool kind.
extension type const AcpToolKind(String value) {
  /// File or data read.
  static const read = AcpToolKind('read');

  /// File or content edit.
  static const edit = AcpToolKind('edit');

  /// File or data deletion.
  static const delete = AcpToolKind('delete');

  /// File move or rename.
  static const move = AcpToolKind('move');

  /// Search operation.
  static const search = AcpToolKind('search');

  /// Command execution.
  static const execute = AcpToolKind('execute');

  /// Internal reasoning.
  static const think = AcpToolKind('think');

  /// External data fetch.
  static const fetch = AcpToolKind('fetch');

  /// Other tool category.
  static const other = AcpToolKind('other');
}

/// Forward-compatible ACP tool-call status.
extension type const AcpToolStatus(String value) {
  /// Waiting to start or for approval.
  static const pending = AcpToolStatus('pending');

  /// Currently executing.
  static const inProgress = AcpToolStatus('in_progress');

  /// Completed successfully.
  static const completed = AcpToolStatus('completed');

  /// Failed.
  static const failed = AcpToolStatus('failed');

  /// Provider extension for cancellation.
  static const cancelled = AcpToolStatus('cancelled');
}

/// A file location associated with a tool call.
final class AcpToolLocation implements AcpExtensible {
  /// Creates a tool location.
  const AcpToolLocation({
    required this.path,
    this.line,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses a tool location.
  factory AcpToolLocation.fromJson(AcpJsonMap json) => AcpToolLocation(
    path: AcpJson.string(json, 'path') ?? '',
    line: AcpJson.integer(json, 'line'),
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const ['path', 'line']),
  );

  /// Absolute file path.
  final String path;

  /// Optional zero-based or provider-defined line number.
  final int? line;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Base class for content attached to an ACP tool call.
sealed class AcpToolContent implements AcpExtensible {
  const AcpToolContent();

  /// Parses tool-call content.
  factory AcpToolContent.fromJson(AcpJsonMap json) =>
      switch (AcpJson.string(json, 'type')) {
        'content' => AcpToolContentBlock.fromJson(json),
        'text' ||
        'image' ||
        'audio' ||
        'resource' ||
        'resource_link' => AcpToolContentBlock.fromJson(json),
        'diff' => AcpToolDiff.fromJson(json),
        'terminal' => AcpToolTerminal.fromJson(json),
        _ => AcpUnknownToolContent.fromJson(json),
      };

  /// Tool content discriminator.
  String get type;
}

/// A standard content block attached to a tool call.
final class AcpToolContentBlock extends AcpToolContent {
  /// Creates tool content.
  const AcpToolContentBlock({
    required this.content,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses tool content.
  factory AcpToolContentBlock.fromJson(AcpJsonMap json) {
    final raw =
        AcpJson.objectField(json, 'content') ??
        (AcpJson.string(json, 'type') == 'content'
            ? const <String, Object?>{'type': 'text', 'text': ''}
            : json);
    return AcpToolContentBlock(
      content: AcpContentBlock.fromJson(raw),
      meta: AcpJson.meta(json),
      extensions: AcpJson.extensions(json, const ['type', 'content']),
    );
  }

  @override
  String get type => 'content';

  /// Attached display content.
  final AcpContentBlock content;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// A file diff attached to a tool call.
final class AcpToolDiff extends AcpToolContent {
  /// Creates a tool diff.
  const AcpToolDiff({
    required this.path,
    required this.newText,
    this.oldText,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses a tool diff.
  factory AcpToolDiff.fromJson(AcpJsonMap json) => AcpToolDiff(
    path: AcpJson.string(json, 'path') ?? '',
    oldText: AcpJson.string(json, 'oldText'),
    newText: AcpJson.string(json, 'newText') ?? '',
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const [
      'type',
      'path',
      'oldText',
      'newText',
    ]),
  );

  @override
  String get type => 'diff';

  /// Modified file path.
  final String path;

  /// Previous file text, or `null` for a new file.
  final String? oldText;

  /// New file text.
  final String newText;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// A client terminal attached to a tool call.
final class AcpToolTerminal extends AcpToolContent {
  /// Creates terminal tool content.
  const AcpToolTerminal({
    required this.terminalId,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses terminal tool content.
  factory AcpToolTerminal.fromJson(AcpJsonMap json) => AcpToolTerminal(
    terminalId: AcpJson.identifier(json, 'terminalId') ?? '',
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const ['type', 'terminalId']),
  );

  @override
  String get type => 'terminal';

  /// Client terminal identifier.
  final String terminalId;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Unknown tool content retained for future protocol versions.
final class AcpUnknownToolContent extends AcpToolContent {
  /// Creates unknown tool content.
  const AcpUnknownToolContent({
    required this.type,
    required this.raw,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses unknown tool content.
  factory AcpUnknownToolContent.fromJson(AcpJsonMap json) =>
      AcpUnknownToolContent(
        type: AcpJson.string(json, 'type') ?? 'unknown',
        raw: AcpJson.immutableObject(json),
        meta: AcpJson.meta(json),
        extensions: AcpJson.extensions(json, const ['type']),
      );

  @override
  final String type;

  /// Complete unrecognized object.
  final AcpJsonMap raw;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Creation or partial update of an ACP tool call.
final class AcpToolCallUpdate extends AcpSessionUpdate {
  /// Creates a tool-call update.
  const AcpToolCallUpdate({
    required this.toolCallId,
    this.isInitial = false,
    this.title,
    this.toolKind,
    this.status,
    this.content,
    this.locations,
    this.rawInput,
    this.rawOutput,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses a tool-call creation or update.
  factory AcpToolCallUpdate.fromJson(
    AcpJsonMap json, {
    bool isInitial = false,
  }) {
    final toolKind = AcpJson.string(json, 'kind');
    final status = AcpJson.string(json, 'status');
    return AcpToolCallUpdate(
      toolCallId: AcpJson.identifier(json, 'toolCallId') ?? '',
      isInitial: isInitial,
      title: AcpJson.string(json, 'title'),
      toolKind: toolKind == null ? null : AcpToolKind(toolKind),
      status: status == null ? null : AcpToolStatus(status),
      content: json['content'] is List
          ? AcpJson.objectList(json['content'], AcpToolContent.fromJson)
          : null,
      locations: json['locations'] is List
          ? AcpJson.objectList(json['locations'], AcpToolLocation.fromJson)
          : null,
      rawInput: json['rawInput'],
      rawOutput: json['rawOutput'],
      meta: AcpJson.meta(json),
      extensions: AcpJson.extensions(json, const [
        'sessionUpdate',
        'toolCallId',
        'title',
        'kind',
        'status',
        'content',
        'locations',
        'rawInput',
        'rawOutput',
      ]),
    );
  }

  @override
  String get kind => isInitial ? 'tool_call' : 'tool_call_update';

  /// Tool-call identifier.
  final String toolCallId;

  /// Whether this update creates the tool call.
  final bool isInitial;

  /// Optional title replacement.
  final String? title;

  /// Optional tool kind replacement.
  final AcpToolKind? toolKind;

  /// Optional status replacement.
  final AcpToolStatus? status;

  /// Optional complete content replacement.
  final List<AcpToolContent>? content;

  /// Optional complete location replacement.
  final List<AcpToolLocation>? locations;

  /// Opaque raw tool input.
  final Object? rawInput;

  /// Opaque raw tool output.
  final Object? rawOutput;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Input metadata for an available slash command.
final class AcpCommandInput implements AcpExtensible {
  /// Creates slash-command input metadata.
  const AcpCommandInput({
    this.type = 'unstructured',
    this.hint,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses slash-command input metadata.
  factory AcpCommandInput.fromJson(AcpJsonMap json) => AcpCommandInput(
    type: AcpJson.string(json, 'type') ?? 'unstructured',
    hint: AcpJson.string(json, 'hint'),
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const ['type', 'hint']),
  );

  /// Input discriminator.
  final String type;

  /// Placeholder hint.
  final String? hint;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// An available ACP slash command.
final class AcpAvailableCommand implements AcpExtensible {
  /// Creates an available command.
  const AcpAvailableCommand({
    required this.name,
    required this.description,
    this.input,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses an available command.
  factory AcpAvailableCommand.fromJson(AcpJsonMap json) {
    final input = AcpJson.objectField(json, 'input');
    return AcpAvailableCommand(
      name: AcpJson.string(json, 'name') ?? '',
      description: AcpJson.string(json, 'description') ?? '',
      input: input == null ? null : AcpCommandInput.fromJson(input),
      meta: AcpJson.meta(json),
      extensions: AcpJson.extensions(json, const [
        'name',
        'description',
        'input',
      ]),
    );
  }

  /// Command name without a slash.
  final String name;

  /// Command description.
  final String description;

  /// Optional command input metadata.
  final AcpCommandInput? input;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Complete replacement of available commands.
final class AcpAvailableCommandsUpdate extends AcpSessionUpdate {
  /// Creates an available-commands update.
  const AcpAvailableCommandsUpdate({
    this.commands = const <AcpAvailableCommand>[],
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses an available-commands update.
  factory AcpAvailableCommandsUpdate.fromJson(AcpJsonMap json) =>
      AcpAvailableCommandsUpdate(
        commands: AcpJson.objectList(
          json['availableCommands'],
          AcpAvailableCommand.fromJson,
        ),
        meta: AcpJson.meta(json),
        extensions: AcpJson.extensions(json, const [
          'sessionUpdate',
          'availableCommands',
        ]),
      );

  @override
  String get kind => 'available_commands_update';

  /// Currently available commands.
  final List<AcpAvailableCommand> commands;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Notification that the legacy session mode changed.
final class AcpCurrentModeUpdate extends AcpSessionUpdate {
  /// Creates a mode update.
  const AcpCurrentModeUpdate({
    required this.modeId,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses a mode update.
  factory AcpCurrentModeUpdate.fromJson(AcpJsonMap json) =>
      AcpCurrentModeUpdate(
        modeId:
            AcpJson.identifier(json, 'currentModeId') ??
            AcpJson.identifier(json, 'modeId') ??
            '',
        meta: AcpJson.meta(json),
        extensions: AcpJson.extensions(json, const [
          'sessionUpdate',
          'currentModeId',
          'modeId',
        ]),
      );

  @override
  String get kind => 'current_mode_update';

  /// Active mode identifier.
  final String modeId;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Provider extension indicating that the legacy model changed.
final class AcpCurrentModelUpdate extends AcpSessionUpdate {
  /// Creates a model update.
  const AcpCurrentModelUpdate({
    required this.modelId,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses a model update.
  factory AcpCurrentModelUpdate.fromJson(AcpJsonMap json) =>
      AcpCurrentModelUpdate(
        modelId:
            AcpJson.identifier(json, 'currentModelId') ??
            AcpJson.identifier(json, 'modelId') ??
            '',
        meta: AcpJson.meta(json),
        extensions: AcpJson.extensions(json, const [
          'sessionUpdate',
          'currentModelId',
          'modelId',
        ]),
      );

  @override
  String get kind => 'current_model_update';

  /// Active model identifier.
  final String modelId;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Complete replacement of generic session configuration.
final class AcpConfigOptionsUpdate extends AcpSessionUpdate {
  /// Creates a configuration update.
  const AcpConfigOptionsUpdate({
    this.options = const <AcpSessionConfigOption>[],
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses a configuration update.
  factory AcpConfigOptionsUpdate.fromJson(AcpJsonMap json) =>
      AcpConfigOptionsUpdate(
        options: AcpJson.objectList(
          json['configOptions'],
          AcpSessionConfigOption.fromJson,
        ),
        meta: AcpJson.meta(json),
        extensions: AcpJson.extensions(json, const [
          'sessionUpdate',
          'configOptions',
        ]),
      );

  @override
  String get kind => 'config_option_update';

  /// Complete configuration state.
  final List<AcpSessionConfigOption> options;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Partial session metadata update.
final class AcpSessionInfoUpdate extends AcpSessionUpdate {
  /// Creates a session information update.
  const AcpSessionInfoUpdate({
    this.title,
    this.hasTitle = false,
    this.updatedAt,
    this.hasUpdatedAt = false,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses a session information update while preserving explicit `null`.
  factory AcpSessionInfoUpdate.fromJson(AcpJsonMap json) =>
      AcpSessionInfoUpdate(
        title: AcpJson.string(json, 'title'),
        hasTitle: json.containsKey('title'),
        updatedAt: AcpJson.string(json, 'updatedAt'),
        hasUpdatedAt: json.containsKey('updatedAt'),
        meta: AcpJson.meta(json),
        extensions: AcpJson.extensions(json, const [
          'sessionUpdate',
          'title',
          'updatedAt',
        ]),
      );

  @override
  String get kind => 'session_info_update';

  /// New title, or `null` when clearing it.
  final String? title;

  /// Whether the update contained the title field.
  final bool hasTitle;

  /// New ISO-8601 timestamp, or `null` when clearing it.
  final String? updatedAt;

  /// Whether the update contained the timestamp field.
  final bool hasUpdatedAt;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Cumulative monetary cost reported by an agent.
final class AcpCost implements AcpExtensible {
  /// Creates cost information.
  const AcpCost({
    required this.amount,
    required this.currency,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses cost information.
  factory AcpCost.fromJson(AcpJsonMap json) => AcpCost(
    amount: AcpJson.number(json, 'amount') ?? 0,
    currency: AcpJson.string(json, 'currency') ?? '',
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const ['amount', 'currency']),
  );

  /// Cumulative amount.
  final num amount;

  /// ISO 4217 currency code.
  final String currency;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Context-window and cost update.
final class AcpUsageUpdate extends AcpSessionUpdate {
  /// Creates a usage update.
  const AcpUsageUpdate({
    required this.used,
    required this.size,
    this.cost,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses a usage update.
  factory AcpUsageUpdate.fromJson(AcpJsonMap json) {
    final cost = AcpJson.objectField(json, 'cost');
    return AcpUsageUpdate(
      used: AcpJson.integer(json, 'used') ?? 0,
      size: AcpJson.integer(json, 'size') ?? 0,
      cost: cost == null ? null : AcpCost.fromJson(cost),
      meta: AcpJson.meta(json),
      extensions: AcpJson.extensions(json, const [
        'sessionUpdate',
        'used',
        'size',
        'cost',
      ]),
    );
  }

  @override
  String get kind => 'usage_update';

  /// Tokens currently in context.
  final int used;

  /// Total context-window tokens.
  final int size;

  /// Optional cumulative cost.
  final AcpCost? cost;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Unknown update retained for future protocol versions.
final class AcpUnknownSessionUpdate extends AcpSessionUpdate {
  /// Creates an unknown session update.
  const AcpUnknownSessionUpdate({
    required this.kind,
    required this.raw,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses an unknown session update.
  factory AcpUnknownSessionUpdate.fromJson(AcpJsonMap json) =>
      AcpUnknownSessionUpdate(
        kind: AcpJson.string(json, 'sessionUpdate') ?? 'unknown',
        raw: AcpJson.immutableObject(json),
        meta: AcpJson.meta(json),
        extensions: AcpJson.extensions(json, const ['sessionUpdate']),
      );

  @override
  final String kind;

  /// Complete unrecognized update.
  final AcpJsonMap raw;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// A typed `session/update` notification.
final class AcpSessionNotification implements AcpExtensible {
  /// Creates a session notification.
  const AcpSessionNotification({
    required this.sessionId,
    required this.update,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses a session notification.
  factory AcpSessionNotification.fromJson(AcpJsonMap json) {
    final update =
        AcpJson.objectField(json, 'update') ??
        const <String, Object?>{'sessionUpdate': 'unknown'};
    return AcpSessionNotification(
      sessionId: AcpJson.identifier(json, 'sessionId') ?? '',
      update: AcpSessionUpdate.fromJson(update),
      meta: AcpJson.meta(json),
      extensions: AcpJson.extensions(json, const ['sessionId', 'update']),
    );
  }

  /// Session receiving the update.
  final String sessionId;

  /// Parsed update.
  final AcpSessionUpdate update;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Forward-compatible permission-option kind.
extension type const AcpPermissionOptionKind(String value) {
  /// Allow this operation once.
  static const allowOnce = AcpPermissionOptionKind('allow_once');

  /// Always allow matching operations.
  static const allowAlways = AcpPermissionOptionKind('allow_always');

  /// Reject this operation once.
  static const rejectOnce = AcpPermissionOptionKind('reject_once');

  /// Always reject matching operations.
  static const rejectAlways = AcpPermissionOptionKind('reject_always');
}

/// A user-selectable answer to a permission request.
final class AcpPermissionOption implements AcpExtensible {
  /// Creates a permission option.
  const AcpPermissionOption({
    required this.id,
    required this.name,
    required this.kind,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses a permission option.
  factory AcpPermissionOption.fromJson(AcpJsonMap json) => AcpPermissionOption(
    id: AcpJson.identifier(json, 'optionId') ?? '',
    name: AcpJson.string(json, 'name') ?? '',
    kind: AcpPermissionOptionKind(
      AcpJson.string(json, 'kind') ?? 'reject_once',
    ),
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const ['optionId', 'name', 'kind']),
  );

  /// Option identifier.
  final String id;

  /// Display name.
  final String name;

  /// Permission behavior.
  final AcpPermissionOptionKind kind;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Parameters of `session/request_permission`.
final class AcpPermissionRequest implements AcpExtensible {
  /// Creates permission-request parameters.
  const AcpPermissionRequest({
    required this.sessionId,
    required this.toolCall,
    this.options = const <AcpPermissionOption>[],
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses permission-request parameters.
  factory AcpPermissionRequest.fromJson(AcpJsonMap json) {
    final toolCall =
        AcpJson.objectField(json, 'toolCall') ??
        const <String, Object?>{'toolCallId': ''};
    return AcpPermissionRequest(
      sessionId: AcpJson.identifier(json, 'sessionId') ?? '',
      toolCall: AcpToolCallUpdate.fromJson(toolCall),
      options: AcpJson.objectList(
        json['options'],
        AcpPermissionOption.fromJson,
      ),
      meta: AcpJson.meta(json),
      extensions: AcpJson.extensions(json, const [
        'sessionId',
        'toolCall',
        'options',
      ]),
    );
  }

  /// Session requesting permission.
  final String sessionId;

  /// Tool call awaiting permission.
  final AcpToolCallUpdate toolCall;

  /// Choices offered to the user.
  final List<AcpPermissionOption> options;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;
}

/// Outcome returned for an ACP permission request.
sealed class AcpPermissionOutcome {
  const AcpPermissionOutcome();

  /// Encodes this outcome.
  AcpJsonMap toJson();
}

/// The user selected a permission option.
final class AcpSelectedPermissionOutcome extends AcpPermissionOutcome {
  /// Creates a selected permission outcome.
  const AcpSelectedPermissionOutcome(this.optionId);

  /// Selected option identifier.
  final String optionId;

  @override
  AcpJsonMap toJson() => <String, Object?>{
    'outcome': 'selected',
    'optionId': optionId,
  };
}

/// The permission request was cancelled before selection.
final class AcpCancelledPermissionOutcome extends AcpPermissionOutcome {
  /// Creates a cancelled permission outcome.
  const AcpCancelledPermissionOutcome();

  @override
  AcpJsonMap toJson() => const <String, Object?>{'outcome': 'cancelled'};
}
