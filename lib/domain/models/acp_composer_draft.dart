/// Models for keeping an unsent native chat draft across app restarts.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'acp_attachment.dart';
import 'acp_session_keys.dart';

/// Format version written into every saved draft.
const int kAcpSavedComposerDraftVersion = 1;

/// The session a composer draft belongs to.
///
/// The remote bridge is left out on purpose: a resumed session can come back
/// on a new bridge with the same ACP session id, and its draft follows it.
@immutable
final class AcpComposerDraftIdentity {
  /// Creates a draft identity from raw identifiers.
  const AcpComposerDraftIdentity({
    required this.hostId,
    required this.providerId,
    required this.acpSessionId,
  });

  /// The draft identity of the session behind [key].
  factory AcpComposerDraftIdentity.of(AcpSessionKey key) =>
      AcpComposerDraftIdentity(
        hostId: key.hostId,
        providerId: key.providerId,
        acpSessionId: key.acpSessionId,
      );

  /// Saved host identifier.
  final int hostId;

  /// ACP provider identifier.
  final String providerId;

  /// Remote ACP session identifier.
  final String acpSessionId;

  /// Canonical, content-free string form.
  String get value => jsonEncode(<Object?>[hostId, providerId, acpSessionId]);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpComposerDraftIdentity &&
          other.hostId == hostId &&
          other.providerId == providerId &&
          other.acpSessionId == acpSessionId;

  @override
  int get hashCode => Object.hash(hostId, providerId, acpSessionId);

  @override
  String toString() => 'AcpComposerDraftIdentity(host: $hostId)';
}

/// The live contents of a composer: text, caret and ordered attachments.
@immutable
final class AcpComposerDraftSnapshot {
  /// Creates a snapshot, copying [attachments].
  AcpComposerDraftSnapshot({
    required this.text,
    this.caret = 0,
    Iterable<AcpAttachmentDraft> attachments = const <AcpAttachmentDraft>[],
  }) : attachments = List<AcpAttachmentDraft>.unmodifiable(attachments);

  /// Composer text.
  final String text;

  /// Caret offset within [text].
  final int caret;

  /// Ordered attachments with the user's fallback choice.
  final List<AcpAttachmentDraft> attachments;

  /// Whether there is nothing worth keeping.
  bool get isEmpty => text.trim().isEmpty && attachments.isEmpty;
}

/// One attachment reference kept in a saved draft.
@immutable
sealed class AcpSavedDraftAttachment {
  const AcpSavedDraftAttachment({required this.name, required this.fallback});

  /// User-visible file name.
  final String name;

  /// Behaviour when the attachment cannot be embedded inline.
  final AcpAttachmentFallback fallback;

  /// JSON form of this reference.
  Map<String, Object?> toJson();

  /// Parses a reference written by [toJson], or returns `null`.
  static AcpSavedDraftAttachment? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    if (name is! String || name.isEmpty) return null;
    final fallback = json['fallback'] == AcpAttachmentFallback.remoteUpload.name
        ? AcpAttachmentFallback.remoteUpload
        : AcpAttachmentFallback.reject;
    final sizeBytes = json['size'];
    final size = sizeBytes is int && sizeBytes >= 0 ? sizeBytes : null;
    final mimeType = json['mime'];
    final mime = mimeType is String && mimeType.isNotEmpty ? mimeType : null;
    switch (json['kind']) {
      case AcpSavedPastedText.kind:
        final text = json['text'];
        if (text is! String || text.isEmpty) return null;
        return AcpSavedPastedText(name: name, text: text);
      case AcpSavedLocalFile.kind:
        final path = json['path'];
        if (path is! String || path.isEmpty) return null;
        return AcpSavedLocalFile(
          name: name,
          path: path,
          sizeBytes: size,
          mimeType: mime,
          fallback: fallback,
        );
      case AcpSavedRemoteFile.kind:
        final remotePath = json['remotePath'];
        if (remotePath is! String || remotePath.isEmpty) return null;
        return AcpSavedRemoteFile(
          name: name,
          remotePath: remotePath,
          sizeBytes: size,
          mimeType: mime,
          fallback: fallback,
        );
    }
    return null;
  }
}

/// A large paste the composer collapsed into a chip. Its text is kept.
final class AcpSavedPastedText extends AcpSavedDraftAttachment {
  /// Creates a saved pasted-text chip.
  const AcpSavedPastedText({required super.name, required this.text})
    : super(fallback: AcpAttachmentFallback.reject);

  /// Storage tag.
  static const kind = 'pastedText';

  /// The pasted text.
  final String text;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'name': name,
    'text': text,
  };
}

/// A reference to a file picked on this device.
final class AcpSavedLocalFile extends AcpSavedDraftAttachment {
  /// Creates a saved local-file reference.
  const AcpSavedLocalFile({
    required super.name,
    required this.path,
    required super.fallback,
    this.sizeBytes,
    this.mimeType,
  });

  /// Storage tag.
  static const kind = 'localFile';

  /// Local file path reported by the picker.
  final String path;

  /// File size when the draft was saved.
  final int? sizeBytes;

  /// Picker-provided MIME type.
  final String? mimeType;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'name': name,
    'path': path,
    'size': ?sizeBytes,
    'mime': ?mimeType,
    'fallback': fallback.name,
  };
}

/// A reference to a file selected on the remote host.
final class AcpSavedRemoteFile extends AcpSavedDraftAttachment {
  /// Creates a saved remote-file reference.
  const AcpSavedRemoteFile({
    required super.name,
    required this.remotePath,
    required super.fallback,
    this.sizeBytes,
    this.mimeType,
  });

  /// Storage tag.
  static const kind = 'remoteFile';

  /// Absolute remote path reported by SFTP.
  final String remotePath;

  /// File size when selected.
  final int? sizeBytes;

  /// MIME type when known.
  final String? mimeType;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'name': name,
    'remotePath': remotePath,
    'size': ?sizeBytes,
    'mime': ?mimeType,
    'fallback': fallback.name,
  };
}

/// The stored form of an unsent composer draft.
///
/// Text and pasted-text chips are kept verbatim. Picked files are kept as
/// references only, and attachments that exist only in memory (a pasted
/// image) are counted in [unsavedAttachmentCount] rather than stored.
@immutable
final class AcpSavedComposerDraft {
  /// Creates a saved draft.
  AcpSavedComposerDraft({
    required this.text,
    required this.caret,
    required this.savedAt,
    Iterable<AcpSavedDraftAttachment> attachments =
        const <AcpSavedDraftAttachment>[],
    this.unsavedAttachmentCount = 0,
  }) : attachments = List<AcpSavedDraftAttachment>.unmodifiable(attachments);

  /// Captures [snapshot] for storage.
  ///
  /// Pasted-text chips are kept while their combined length stays within
  /// [pastedTextBudget] UTF-16 code units; the rest count as unsaved.
  factory AcpSavedComposerDraft.capture(
    AcpComposerDraftSnapshot snapshot, {
    required DateTime savedAt,
    required int pastedTextBudget,
  }) {
    final attachments = <AcpSavedDraftAttachment>[];
    var unsaved = 0;
    var budget = pastedTextBudget;
    for (final draft in snapshot.attachments) {
      final saved = switch (draft.candidate) {
        final AcpMemoryAttachmentCandidate memory when memory.isPastedText =>
          _pastedText(memory, budget),
        AcpMemoryAttachmentCandidate() => null,
        AcpLocalFileAttachmentCandidate(:final localPath?, :final name) =>
          AcpSavedLocalFile(
            name: name,
            path: localPath,
            sizeBytes: draft.candidate.sizeBytes,
            mimeType: draft.candidate.mimeType,
            fallback: draft.fallback,
          ),
        AcpLocalFileAttachmentCandidate() => null,
        AcpRemoteFileAttachmentCandidate(:final remotePath, :final name) =>
          AcpSavedRemoteFile(
            name: name,
            remotePath: remotePath,
            sizeBytes: draft.candidate.sizeBytes,
            mimeType: draft.candidate.mimeType,
            fallback: draft.fallback,
          ),
      };
      if (saved == null) {
        unsaved++;
        continue;
      }
      if (saved is AcpSavedPastedText) budget -= saved.text.length;
      attachments.add(saved);
    }
    return AcpSavedComposerDraft(
      text: snapshot.text,
      caret: snapshot.caret.clamp(0, snapshot.text.length),
      savedAt: savedAt.toUtc(),
      attachments: attachments,
      unsavedAttachmentCount: unsaved,
    );
  }

  static AcpSavedPastedText? _pastedText(
    AcpMemoryAttachmentCandidate candidate,
    int budget,
  ) {
    final String text;
    try {
      text = utf8.decode(candidate.bytes);
    } on FormatException {
      return null;
    }
    if (text.isEmpty || text.length > budget) return null;
    return AcpSavedPastedText(name: candidate.name, text: text);
  }

  /// Composer text.
  final String text;

  /// Caret offset within [text].
  final int caret;

  /// When the draft was last saved, in UTC.
  final DateTime savedAt;

  /// Ordered attachment references.
  final List<AcpSavedDraftAttachment> attachments;

  /// Attachments that could not be stored (in-memory images, or pasted text
  /// beyond the size budget).
  final int unsavedAttachmentCount;

  /// JSON form. `savedAt` comes first so pruning can read it cheaply.
  Map<String, Object?> toJson() => <String, Object?>{
    'savedAt': savedAt.millisecondsSinceEpoch,
    'v': kAcpSavedComposerDraftVersion,
    'text': text,
    'caret': caret,
    'attachments': [for (final attachment in attachments) attachment.toJson()],
    if (unsavedAttachmentCount > 0) 'unsaved': unsavedAttachmentCount,
  };

  /// Parses a draft written by [toJson], or returns `null` when [json] is
  /// malformed or from an unknown format version.
  static AcpSavedComposerDraft? tryFromJson(Object? json) {
    if (json is! Map) return null;
    if (json['v'] != kAcpSavedComposerDraftVersion) return null;
    final savedAt = json['savedAt'];
    final text = json['text'];
    if (savedAt is! int || text is! String) return null;
    final caret = json['caret'];
    final unsaved = json['unsaved'];
    final rawAttachments = json['attachments'];
    final attachments = <AcpSavedDraftAttachment>[];
    var unreadable = 0;
    if (rawAttachments is List) {
      for (final item in rawAttachments) {
        final attachment = AcpSavedDraftAttachment.tryFromJson(item);
        if (attachment == null) {
          unreadable++;
        } else {
          attachments.add(attachment);
        }
      }
    }
    return AcpSavedComposerDraft(
      text: text,
      caret: caret is int ? caret.clamp(0, text.length) : text.length,
      savedAt: DateTime.fromMillisecondsSinceEpoch(savedAt, isUtc: true),
      attachments: attachments,
      unsavedAttachmentCount:
          (unsaved is int && unsaved > 0 ? unsaved : 0) + unreadable,
    );
  }

  /// Reads only the save time from an encoded draft, without decoding the
  /// rest, or returns `null` when it is not where [toJson] puts it.
  static DateTime? peekSavedAt(String encoded) {
    final match = _savedAtPrefix.matchAsPrefix(encoded);
    final millis = match == null ? null : int.tryParse(match.group(1)!);
    return millis == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }

  static final _savedAtPrefix = RegExp(r'\{"savedAt":(-?\d{1,16})[,}]');
}
