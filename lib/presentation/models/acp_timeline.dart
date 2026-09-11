/// Presentation-level view models for rendering an Agent Client Protocol (ACP)
/// conversation.
///
/// These models are intentionally decoupled from the ACP wire protocol: they
/// describe *what to draw*, not how the bytes arrived. A controller layer is
/// responsible for mapping ACP notifications onto these immutable models
/// (including merging streamed `tool_call`/`tool_call_update` events by ID).
///
/// Every type here is immutable and value-comparable so that the rendering
/// widgets can rebuild cheaply and in isolation as a conversation streams.
library;

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';

/// Streaming lifecycle of a piece of assistant content.
enum AcpStreamStatus {
  /// Content is still being appended by the agent.
  streaming,

  /// Content is final; no further chunks are expected.
  complete,
}

/// Severity of a [AcpStatusEntry].
enum AcpStatusSeverity {
  /// Neutral, informational status (e.g. a stop reason).
  info,

  /// A recoverable warning (e.g. an unsupported capability degraded).
  warning,

  /// A failure or error condition.
  error,
}

/// A single, ordered item in a rendered ACP conversation timeline.
///
/// The [id] is a stable identifier assigned by the controller layer so that
/// list rendering can key entries and merge streamed updates.
@immutable
sealed class AcpTimelineEntry extends Equatable {
  /// Creates a timeline entry with a stable [id].
  const AcpTimelineEntry({required this.id, this.parentToolCallId});

  /// Stable identifier for this entry within its conversation.
  final String id;

  /// Launching tool call for nested subagent output, when present.
  final String? parentToolCallId;
}

/// A user prompt made up of ordered content parts.
///
/// Part order is significant and must be preserved when rendering: a user may
/// interleave text, images, and file references in a specific sequence.
final class AcpUserPromptEntry extends AcpTimelineEntry {
  /// Creates a user prompt entry from ordered [parts].
  ///
  /// [parts] is defensively wrapped in an unmodifiable list.
  AcpUserPromptEntry({
    required super.id,
    required List<AcpPromptPart> parts,
    this.queued = false,
  }) : parts = List.unmodifiable(parts);

  /// Whether this prompt is waiting behind an active turn.
  final bool queued;

  /// The ordered content parts of the prompt.
  final List<AcpPromptPart> parts;

  @override
  List<Object?> get props => [id, parts, queued];
}

/// A chunk of assistant Markdown text.
final class AcpAssistantMessageEntry extends AcpTimelineEntry {
  /// Creates an assistant message entry.
  const AcpAssistantMessageEntry({
    required super.id,
    required this.markdown,
    super.parentToolCallId,
    this.status = AcpStreamStatus.complete,
  });

  /// The raw Markdown produced by the assistant.
  final String markdown;

  /// Whether more Markdown is still streaming into this entry.
  final AcpStreamStatus status;

  @override
  List<Object?> get props => [id, parentToolCallId, markdown, status];
}

/// A thought / reasoning group emitted by the assistant.
///
/// Thoughts are rendered collapsed by default.
final class AcpThoughtEntry extends AcpTimelineEntry {
  /// Creates a thought entry.
  const AcpThoughtEntry({
    required super.id,
    required this.markdown,
    super.parentToolCallId,
    this.status = AcpStreamStatus.complete,
    this.title,
  });

  /// The reasoning content as Markdown.
  final String markdown;

  /// Whether the thought is still streaming.
  final AcpStreamStatus status;

  /// Optional short label for the thought group (e.g. `Planning`).
  final String? title;

  @override
  List<Object?> get props => [id, parentToolCallId, markdown, status, title];
}

/// A nested transcript emitted by a subagent launched from a tool call.
final class AcpSubagentTranscriptEntry extends AcpTimelineEntry {
  /// Creates a nested transcript related to [launchToolCallId].
  AcpSubagentTranscriptEntry({
    required super.id,
    required this.launchToolCallId,
    required List<AcpTimelineEntry> entries,
  }) : entries = List.unmodifiable(entries);

  /// Tool call that launched the subagent.
  final String launchToolCallId;

  /// Ordered nested assistant/thought/tool updates.
  final List<AcpTimelineEntry> entries;

  @override
  List<Object?> get props => [id, launchToolCallId, entries];
}

/// A plan / task list emitted by the assistant.

final class AcpPlanEntry extends AcpTimelineEntry {
  /// Creates a plan entry.
  const AcpPlanEntry({required super.id, required this.plan});

  /// The plan to render.
  final AcpPlan plan;

  @override
  List<Object?> get props => [id, plan];
}

/// A tool call and its (possibly merged) updates.
final class AcpToolCallEntry extends AcpTimelineEntry {
  /// Creates a tool call entry.
  const AcpToolCallEntry({
    required super.id,
    required this.toolCall,
    super.parentToolCallId,
    this.isSubagent = false,
  });

  /// The merged state of the tool call.
  final AcpToolCall toolCall;

  /// Whether this tool launches a nested subagent transcript.
  final bool isSubagent;

  @override
  List<Object?> get props => [id, parentToolCallId, toolCall, isSubagent];
}

/// A usage / context-window update.
final class AcpUsageEntry extends AcpTimelineEntry {
  /// Creates a usage entry.
  const AcpUsageEntry({required super.id, required this.usage});

  /// The usage metrics to render.
  final AcpUsage usage;

  @override
  List<Object?> get props => [id, usage];
}

/// A status, stop-reason, or error entry.
final class AcpStatusEntry extends AcpTimelineEntry {
  /// Creates a status entry.
  const AcpStatusEntry({
    required super.id,
    required this.message,
    this.severity = AcpStatusSeverity.info,
    this.detail,
  });

  /// A short, human-readable status message.
  final String message;

  /// The severity of the status.
  final AcpStatusSeverity severity;

  /// Optional secondary detail line.
  final String? detail;

  @override
  List<Object?> get props => [id, message, severity, detail];
}

/// A single, ordered part of a user prompt.
@immutable
sealed class AcpPromptPart extends Equatable {
  /// Const base constructor.
  const AcpPromptPart();
}

/// A plain-text part of a user prompt.
final class AcpTextPart extends AcpPromptPart {
  /// Creates a text part.
  const AcpTextPart(this.text);

  /// The literal text.
  final String text;

  @override
  List<Object?> get props => [text];
}

/// An image part of a user prompt, shown inline.
final class AcpImagePart extends AcpPromptPart {
  /// Creates an image part.
  const AcpImagePart(this.image);

  /// The image to render.
  final AcpImageContent image;

  @override
  List<Object?> get props => [image];
}

/// A file / resource-link part of a user prompt, shown as a chip.
final class AcpResourcePart extends AcpPromptPart {
  /// Creates a resource part.
  const AcpResourcePart(this.resource);

  /// The resource reference to render.
  final AcpResourceRef resource;

  @override
  List<Object?> get props => [resource];
}

/// How an [AcpImageContent] should be resolved to displayable bytes.
enum AcpImageSourceKind {
  /// The image bytes are already in memory.
  bytes,

  /// The image is a `data:` URI.
  dataUri,

  /// The image is a `file:` URI on the device/remote.
  fileUri,

  /// The image is an `http`/`https` URI that requires an explicit resolver.
  networkUri,
}

/// An image referenced by a prompt or embedded in assistant Markdown.
///
/// An image carries at least one of [bytes], [dataUri], or [uri]. Network URIs
/// are never fetched automatically; callers must provide a resolver.
@immutable
class AcpImageContent extends Equatable {
  /// Creates image content from in-memory [bytes], encoded [dataUri], or a [uri].
  ///
  /// [bytes], when provided, is defensively cloned and stored privately so the
  /// model's published state cannot be mutated by the caller after
  /// construction. The public [bytes] getter returns an unmodifiable view.
  AcpImageContent({
    Uint8List? bytes,
    this.uri,
    this.dataUri,
    this.mimeType,
    this.label,
    this.decodeWidth,
    this.decodeHeight,
  }) : _bytes = bytes == null ? null : Uint8List.fromList(bytes),
       assert(
         bytes != null || dataUri != null || uri != null,
         'AcpImageContent requires bytes, a data URI, or a URI',
       );

  // Privately owned clone; never handed out directly.
  final Uint8List? _bytes;

  /// The raw, already-decoded image bytes, when available in memory.
  ///
  /// Returns an unmodifiable view: attempts to mutate it (e.g. `bytes[0] = x`)
  /// throw, so published state stays immutable.
  Uint8List? get bytes => _bytes?.asUnmodifiableView();

  /// Encoded inline image data, decoded by the image widget off the UI isolate
  /// for large payloads. [uri] remains available as a fallback.
  final String? dataUri;

  /// The image URI (`data:`, `file:`, `http:`/`https:`), when not in memory.
  final String? uri;

  /// The MIME type, if known (e.g. `image/png`).
  final String? mimeType;

  /// An accessible label describing the image, used for semantics.
  final String? label;

  /// Optional decode-width hint (in pixels) to bound memory usage.
  final int? decodeWidth;

  /// Optional decode-height hint (in pixels) to bound memory usage.
  final int? decodeHeight;

  /// Classifies how this image must be resolved for display.
  AcpImageSourceKind get sourceKind {
    if (_bytes != null) {
      return AcpImageSourceKind.bytes;
    }
    final value = dataUri ?? uri ?? '';
    if (value.startsWith('data:')) {
      return AcpImageSourceKind.dataUri;
    }
    if (value.startsWith('file:')) {
      return AcpImageSourceKind.fileUri;
    }
    return AcpImageSourceKind.networkUri;
  }

  @override
  List<Object?> get props => [
    _bytes,
    dataUri,
    uri,
    mimeType,
    label,
    decodeWidth,
    decodeHeight,
  ];
}

/// A reference to a file or resource, rendered as a chip.
@immutable
class AcpResourceRef extends Equatable {
  /// Creates a resource reference.
  const AcpResourceRef({
    required this.uri,
    this.name,
    this.mimeType,
    this.sizeBytes,
  });

  /// The resource URI or path.
  final String uri;

  /// Optional display name; falls back to the URI's final segment.
  final String? name;

  /// The MIME type, if known.
  final String? mimeType;

  /// The size in bytes, if known.
  final int? sizeBytes;

  /// The name to display for this resource.
  String get displayName {
    final explicit = name;
    if (explicit != null && explicit.isNotEmpty) {
      return explicit;
    }
    final trimmed = uri.endsWith('/') ? uri.substring(0, uri.length - 1) : uri;
    final slash = trimmed.lastIndexOf('/');
    final segment = slash >= 0 ? trimmed.substring(slash + 1) : trimmed;
    return segment.isEmpty ? uri : segment;
  }

  @override
  List<Object?> get props => [uri, name, mimeType, sizeBytes];
}

/// Lifecycle status of an ACP tool call.
enum AcpToolStatus {
  /// The tool call has been requested but not started.
  pending,

  /// The tool call is currently executing.
  running,

  /// The tool call finished successfully.
  completed,

  /// The tool call finished with an error.
  failed,

  /// The tool call was cancelled.
  cancelled,
}

/// Coarse category of a tool call, used to pick an icon.
enum AcpToolKind {
  /// Reads a file or resource.
  read,

  /// Edits or writes a file.
  edit,

  /// Deletes a file or resource.
  delete,

  /// Moves or renames a file.
  move,

  /// Searches content.
  search,

  /// Executes a command or process.
  execute,

  /// Fetches remote content.
  fetch,

  /// Reasons or thinks.
  think,

  /// Any other or unknown tool.
  other,
}

/// A file location referenced by a tool call.
@immutable
class AcpToolLocation extends Equatable {
  /// Creates a tool location.
  const AcpToolLocation({required this.path, this.line});

  /// The file path.
  final String path;

  /// The optional 1-based line number.
  final int? line;

  @override
  List<Object?> get props => [path, line];
}

/// A unified-diff produced by a tool call.
@immutable
class AcpDiff extends Equatable {
  /// Creates a diff.
  const AcpDiff({
    required this.path,
    required this.unifiedDiff,
    this.oldText,
    this.newText,
  });

  /// The path the diff applies to.
  final String path;

  /// The pre-formatted unified diff text (with `+`/`-`/context lines).
  final String unifiedDiff;

  /// The original text, when available.
  final String? oldText;

  /// The updated text, when available.
  final String? newText;

  @override
  List<Object?> get props => [path, unifiedDiff, oldText, newText];
}

/// A tool call and its merged state.
@immutable
class AcpToolCall extends Equatable {
  /// Creates a tool call.
  ///
  /// [locations] and [diffs] are defensively wrapped in unmodifiable lists.
  AcpToolCall({
    required this.id,
    required this.title,
    this.kind = AcpToolKind.other,
    this.status = AcpToolStatus.pending,
    this.rawInput,
    this.rawOutput,
    this.rawOutputIsStructured = false,
    List<AcpToolLocation> locations = const [],
    List<AcpDiff> diffs = const [],
    List<AcpImageContent> images = const [],
  }) : locations = List.unmodifiable(locations),
       diffs = List.unmodifiable(diffs),
       images = List.unmodifiable(images);

  /// The tool-call identifier used to merge updates.
  final String id;

  /// A short, human-readable title (e.g. `Read pubspec.yaml`).
  final String title;

  /// The category of tool.
  final AcpToolKind kind;

  /// The current lifecycle status.
  final AcpToolStatus status;

  /// The tool input, pre-formatted for display (never logged).
  final String? rawInput;

  /// The tool output, pre-formatted for display (never logged).
  final String? rawOutput;

  /// Whether [rawOutput] is structured YAML-like data rather than Markdown.
  final bool rawOutputIsStructured;

  /// File locations touched by the tool call.
  final List<AcpToolLocation> locations;

  /// Diffs produced by the tool call.
  final List<AcpDiff> diffs;

  /// Images produced by the tool call.
  final List<AcpImageContent> images;

  @override
  List<Object?> get props => [
    id,
    title,
    kind,
    status,
    rawInput,
    rawOutput,
    rawOutputIsStructured,
    locations,
    diffs,
    images,
  ];
}

/// Status of a single plan item.
enum AcpPlanItemStatus {
  /// Not yet started.
  pending,

  /// Currently in progress.
  inProgress,

  /// Completed.
  completed,
}

/// Priority of a single plan item.
enum AcpPlanPriority {
  /// Low priority.
  low,

  /// Medium priority.
  medium,

  /// High priority.
  high,
}

/// A single item within an [AcpPlan].
@immutable
class AcpPlanItem extends Equatable {
  /// Creates a plan item.
  const AcpPlanItem({
    required this.title,
    this.status = AcpPlanItemStatus.pending,
    this.priority,
  });

  /// The item description.
  final String title;

  /// The item status.
  final AcpPlanItemStatus status;

  /// The optional priority.
  final AcpPlanPriority? priority;

  @override
  List<Object?> get props => [title, status, priority];
}

/// A plan / task list with derived progress.
@immutable
class AcpPlan extends Equatable {
  /// Creates a plan from ordered [items].
  ///
  /// [items] is defensively wrapped in an unmodifiable list.
  AcpPlan({List<AcpPlanItem> items = const []})
    : items = List.unmodifiable(items);

  /// The ordered plan items.
  final List<AcpPlanItem> items;

  /// The number of completed items.
  int get completedCount =>
      items.where((i) => i.status == AcpPlanItemStatus.completed).length;

  /// The total number of items.
  int get totalCount => items.length;

  /// Completion fraction in the range `0.0`–`1.0`.
  double get progress => totalCount == 0 ? 0 : completedCount / totalCount;

  @override
  List<Object?> get props => [items];
}

/// Token usage / context-window metrics for a session.
@immutable
class AcpUsage extends Equatable {
  /// Creates usage metrics.
  const AcpUsage({
    this.inputTokens,
    this.outputTokens,
    this.totalTokens,
    this.contextWindow,
    this.contextUsedTokens,
  });

  /// Prompt (input) tokens, if reported.
  final int? inputTokens;

  /// Completion (output) tokens, if reported.
  final int? outputTokens;

  /// Total tokens, if reported.
  final int? totalTokens;

  /// The model context window size in tokens, if reported.
  final int? contextWindow;

  /// Tokens currently occupying the context window, if reported.
  final int? contextUsedTokens;

  /// Fraction of the context window in use (`0.0`–`1.0`), when derivable.
  double? get contextFraction {
    final window = contextWindow;
    final used = contextUsedTokens;
    if (window == null || window <= 0 || used == null) {
      return null;
    }
    return (used / window).clamp(0.0, 1.0);
  }

  /// Whether any metric is available to render.
  bool get hasData =>
      inputTokens != null ||
      outputTokens != null ||
      totalTokens != null ||
      contextWindow != null ||
      contextUsedTokens != null;

  @override
  List<Object?> get props => [
    inputTokens,
    outputTokens,
    totalTokens,
    contextWindow,
    contextUsedTokens,
  ];
}
