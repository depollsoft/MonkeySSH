import 'package:flutter/foundation.dart';

/// Maximum image payload that the ACP timeline can safely display.
const int kAcpAttachmentImageDisplayMaxBytes = 10 * 1024 * 1024;

/// Maximum decoded audio payload sent inline or retained for playback.
///
/// Matches the image ceiling: a clip at this size encodes to roughly 13.4 MiB
/// of base64, which stays inside the 20 MiB ACP JSON-RPC frame with headroom
/// for the rest of the prompt.
const int kAcpAttachmentAudioMaxBytes = 10 * 1024 * 1024;

/// Normalizes common non-canonical audio MIME aliases.
///
/// File-name and magic-number detection report legacy `x-` aliases (for
/// example `audio/x-wav`). Agents generally expect the registered names, so
/// inline audio is labelled with them. Non-audio and unknown audio types are
/// returned lower-cased and trimmed but otherwise unchanged.
String normalizeAcpAudioMimeType(String mimeType) {
  final normalized = mimeType.trim().toLowerCase();
  return switch (normalized) {
    'audio/x-wav' || 'audio/wave' || 'audio/vnd.wave' => 'audio/wav',
    'audio/mp3' || 'audio/x-mp3' || 'audio/mpeg3' => 'audio/mpeg',
    'audio/x-flac' => 'audio/flac',
    'audio/x-m4a' || 'audio/m4a' => 'audio/mp4',
    'audio/x-aiff' => 'audio/aiff',
    'audio/weba' => 'audio/webm',
    'audio/x-aac' => 'audio/aac',
    _ => normalized,
  };
}

/// Returns a conventional file extension for an audio [mimeType].
///
/// Native players (notably AVFoundation) pick a demuxer from the extension,
/// so decoded clips are written with one. Unknown types fall back to `audio`.
String acpAudioFileExtension(String? mimeType) =>
    switch (normalizeAcpAudioMimeType(mimeType ?? '')) {
      'audio/mpeg' => 'mp3',
      'audio/wav' => 'wav',
      'audio/mp4' => 'm4a',
      'audio/aac' => 'aac',
      'audio/ogg' || 'audio/opus' => 'ogg',
      'audio/flac' => 'flac',
      'audio/webm' => 'webm',
      'audio/aiff' => 'aiff',
      'audio/x-caf' => 'caf',
      'audio/amr' => 'amr',
      'audio/3gpp' => '3gp',
      _ => 'audio',
    };

/// Internal MIME marker for text collapsed into a composer paste chip.
///
/// It is converted back to ordinary ACP text before leaving the app.
const String kAcpPastedTextMimeType =
    'application/x-monkeyssh-composer-pasted-text';

/// Opens a fresh byte stream for a local attachment.
typedef AcpAttachmentStreamFactory = Stream<List<int>> Function();

/// The source category of an attachment candidate.
enum AcpAttachmentSourceKind {
  /// Bytes already held in volatile memory.
  memory,

  /// A local file that is read only when a prompt is prepared.
  localFile,

  /// A remote file selected through SFTP.
  remoteFile,
}

/// A possible attachment selected by the user.
@immutable
sealed class AcpAttachmentCandidate {
  const AcpAttachmentCandidate({
    required this.name,
    required this.sizeBytes,
    required this.mimeType,
  });

  /// Creates an attachment backed by volatile in-memory bytes.
  factory AcpAttachmentCandidate.memory({
    required String name,
    required Uint8List bytes,
    String? mimeType,
  }) = AcpMemoryAttachmentCandidate;

  /// Creates a lazily read local-file attachment.
  const factory AcpAttachmentCandidate.localFile({
    required String name,
    required AcpAttachmentStreamFactory openRead,
    int? sizeBytes,
    String? mimeType,
    String? localPath,
  }) = AcpLocalFileAttachmentCandidate;

  /// Creates a remote SFTP attachment that is never downloaded.
  const factory AcpAttachmentCandidate.remoteFile({
    required String name,
    required String remotePath,
    int? sizeBytes,
    String? mimeType,
  }) = AcpRemoteFileAttachmentCandidate;

  /// User-visible file name.
  final String name;

  /// File size when known.
  final int? sizeBytes;

  /// Picker-provided MIME type when known.
  final String? mimeType;

  /// Whether this candidate represents collapsed composer text.
  bool get isPastedText => mimeType == kAcpPastedTextMimeType;

  /// Attachment source category.
  AcpAttachmentSourceKind get sourceKind;
}

/// An attachment backed by volatile in-memory bytes.
@immutable
final class AcpMemoryAttachmentCandidate extends AcpAttachmentCandidate {
  /// Creates an in-memory attachment, defensively copying [bytes].
  AcpMemoryAttachmentCandidate({
    required super.name,
    required Uint8List bytes,
    super.mimeType,
  }) : _bytes = Uint8List.fromList(bytes).asUnmodifiableView(),
       super(sizeBytes: bytes.length);

  final Uint8List _bytes;

  /// Read-only attachment bytes.
  Uint8List get bytes => _bytes;

  @override
  AcpAttachmentSourceKind get sourceKind => AcpAttachmentSourceKind.memory;
}

/// A lazily read local-file attachment.
@immutable
final class AcpLocalFileAttachmentCandidate extends AcpAttachmentCandidate {
  /// Creates a local-file attachment.
  const AcpLocalFileAttachmentCandidate({
    required super.name,
    required this.openRead,
    super.sizeBytes,
    super.mimeType,
    this.localPath,
  });

  /// Opens the file byte stream.
  ///
  /// The preparation service invokes this at most once per preparation.
  final AcpAttachmentStreamFactory openRead;

  /// Path of the picked file on this device, when the picker reported one.
  ///
  /// A saved composer draft keeps this reference so the attachment can be
  /// offered again after the app restarts. It is never sent to the agent.
  final String? localPath;

  @override
  AcpAttachmentSourceKind get sourceKind => AcpAttachmentSourceKind.localFile;
}

/// A remote SFTP file attachment.
@immutable
final class AcpRemoteFileAttachmentCandidate extends AcpAttachmentCandidate {
  /// Creates a remote-file attachment.
  const AcpRemoteFileAttachmentCandidate({
    required super.name,
    required this.remotePath,
    super.sizeBytes,
    super.mimeType,
  });

  /// Absolute remote path reported by SFTP.
  final String remotePath;

  @override
  AcpAttachmentSourceKind get sourceKind => AcpAttachmentSourceKind.remoteFile;
}

/// Explicit fallback selected for a local attachment.
enum AcpAttachmentFallback {
  /// Reject content that cannot be embedded.
  reject,

  /// Upload content to the private MonkeySSH remote upload directory.
  remoteUpload,
}

/// One ordered item in an ACP prompt draft.
@immutable
sealed class AcpPromptDraftItem {
  const AcpPromptDraftItem();
}

/// Ordered prompt text.
@immutable
final class AcpPromptTextDraft extends AcpPromptDraftItem {
  /// Creates a text prompt item.
  const AcpPromptTextDraft(this.text);

  /// Prompt text.
  final String text;
}

/// Ordered attachment plus the user's explicit fallback choice.
@immutable
final class AcpAttachmentDraft extends AcpPromptDraftItem {
  /// Creates an attachment draft.
  const AcpAttachmentDraft({
    required this.candidate,
    this.fallback = AcpAttachmentFallback.reject,
  });

  /// Selected attachment.
  final AcpAttachmentCandidate candidate;

  /// Behavior when the attachment cannot be embedded.
  final AcpAttachmentFallback fallback;
}

/// An immutable, ordered ACP prompt draft.
@immutable
final class AcpPromptDraft {
  /// Creates a prompt draft and snapshots its ordered [items].
  AcpPromptDraft(Iterable<AcpPromptDraftItem> items)
    : items = List<AcpPromptDraftItem>.unmodifiable(items);

  /// Ordered prompt text and attachments.
  final List<AcpPromptDraftItem> items;
}

/// Attachment safety and resource limits.
@immutable
final class AcpAttachmentLimits {
  /// Creates attachment limits.
  const AcpAttachmentLimits({
    this.maxCount = 10,
    this.maxFileBytes = 50 * 1024 * 1024,
    this.maxTotalBytes = 100 * 1024 * 1024,
    this.maxEmbeddedBytes = 5 * 1024 * 1024,
    this.maxImageBytes = kAcpAttachmentImageDisplayMaxBytes,
    this.maxAudioBytes = kAcpAttachmentAudioMaxBytes,
    this.maxFileNameBytes = 255,
    this.maxMimeTypeBytes = 127,
    this.mimeSniffBytes = 512,
  }) : assert(maxCount > 0),
       assert(maxFileBytes > 0),
       assert(maxTotalBytes > 0),
       assert(maxEmbeddedBytes > 0),
       assert(maxImageBytes > 0),
       assert(maxImageBytes <= kAcpAttachmentImageDisplayMaxBytes),
       assert(maxAudioBytes > 0),
       assert(maxAudioBytes <= kAcpAttachmentAudioMaxBytes),
       assert(maxFileNameBytes > 0),
       assert(maxMimeTypeBytes > 0),
       assert(mimeSniffBytes > 0);

  /// Maximum attachments per prompt.
  final int maxCount;

  /// Maximum bytes for one attachment, including upload fallbacks.
  final int maxFileBytes;

  /// Maximum known or read attachment bytes across the prompt.
  final int maxTotalBytes;

  /// Maximum bytes embedded as a text or blob resource.
  final int maxEmbeddedBytes;

  /// Maximum bytes embedded as an ACP image.
  final int maxImageBytes;

  /// Maximum bytes embedded as ACP audio.
  final int maxAudioBytes;

  /// Maximum UTF-8 bytes in a file name.
  final int maxFileNameBytes;

  /// Maximum UTF-8 bytes in a MIME type.
  final int maxMimeTypeBytes;

  /// Maximum prefix bytes used for MIME detection.
  final int mimeSniffBytes;
}

/// Attachment preparation failure category.
enum AcpAttachmentFailure {
  /// Too many attachments were selected.
  countLimit,

  /// One attachment exceeds the per-file limit.
  fileSizeLimit,

  /// Prompt attachments exceed the total byte limit.
  totalSizeLimit,

  /// An image exceeds the safe display limit.
  imageSizeLimit,

  /// An audio clip exceeds the inline audio limit.
  audioSizeLimit,

  /// A file name is empty, unsafe, or too long.
  invalidFileName,

  /// A MIME type is malformed or too long.
  invalidMimeType,

  /// A local file cannot be read.
  unreadable,

  /// Text resource bytes are not valid UTF-8.
  invalidUtf8,

  /// The agent cannot accept the attachment inline.
  unsupportedCapability,

  /// The attachment is too large to embed and upload was not selected.
  inlineSizeLimit,

  /// Remote upload was selected but no uploader is available.
  uploadUnavailable,

  /// Remote upload failed.
  uploadFailed,

  /// Preparation was cancelled.
  cancelled,
}

/// Safe attachment preparation exception.
final class AcpAttachmentException implements Exception {
  /// Creates an attachment exception with no file names, paths, or content.
  const AcpAttachmentException(this.failure, this.message);

  /// Failure category.
  final AcpAttachmentFailure failure;

  /// User-facing, content-free explanation.
  final String message;

  @override
  String toString() => 'AcpAttachmentException(${failure.name}): $message';
}
