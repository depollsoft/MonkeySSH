/// Models for keeping an unsent native chat draft across app restarts.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'acp_attachment.dart';
import 'acp_session_keys.dart';

/// Format version written into every saved draft.
///
/// Version 1 came from this feature's first preview builds: pasted text was
/// inline, attachments had no `addedAt`, and local files no modification
/// time. It is still read; see [AcpSavedComposerDraft.tryFromJson].
const int kAcpSavedComposerDraftVersion = 2;

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

  /// This draft with [later] appended: text separated by a blank line and
  /// attachments after this draft's, up to [maxAttachments]. The caret ends
  /// up at the end.
  AcpComposerDraftSnapshot followedBy(
    AcpComposerDraftSnapshot later, {
    int? maxAttachments,
  }) {
    final String merged;
    if (later.text.trim().isEmpty) {
      merged = text;
    } else if (text.trim().isEmpty) {
      merged = later.text;
    } else {
      merged = '$text\n\n${later.text}';
    }
    final attachments = [...this.attachments, ...later.attachments];
    return AcpComposerDraftSnapshot(
      text: merged,
      caret: merged.length,
      attachments: maxAttachments == null
          ? attachments
          : attachments.take(maxAttachments),
    );
  }
}

/// Tells the user the composer holds a draft kept from an earlier run of the
/// app that has not been sent.
@immutable
class AcpRestoredDraftNotice {
  /// Creates a restored-draft notice.
  const AcpRestoredDraftNotice({this.unavailableAttachmentCount = 0});

  /// Saved attachments that could not be restored and were removed.
  final int unavailableAttachmentCount;

  @override
  bool operator ==(Object other) =>
      other is AcpRestoredDraftNotice &&
      other.unavailableAttachmentCount == unavailableAttachmentCount;

  @override
  int get hashCode => unavailableAttachmentCount.hashCode;
}

/// Size and modification time of a picked local file, used to tell whether a
/// saved reference still points at the same file.
@immutable
final class AcpDraftFileStamp {
  /// Creates a file stamp.
  const AcpDraftFileStamp({required this.sizeBytes, required this.modifiedMs});

  /// File size in bytes.
  final int sizeBytes;

  /// Last modification time, in milliseconds since the epoch.
  final int modifiedMs;

  @override
  bool operator ==(Object other) =>
      other is AcpDraftFileStamp &&
      other.sizeBytes == sizeBytes &&
      other.modifiedMs == modifiedMs;

  @override
  int get hashCode => Object.hash(sizeBytes, modifiedMs);
}

/// One attachment reference kept in a saved draft.
@immutable
sealed class AcpSavedDraftAttachment {
  const AcpSavedDraftAttachment({
    required this.name,
    required this.fallback,
    required this.addedAt,
  });

  /// User-visible file name.
  final String name;

  /// Behaviour when the attachment cannot be embedded inline.
  final AcpAttachmentFallback fallback;

  /// When the attachment was first saved with the draft, in UTC.
  final DateTime addedAt;

  /// JSON form of this reference.
  Map<String, Object?> toJson();

  Map<String, Object?> _common(String kind) => <String, Object?>{
    'kind': kind,
    'name': name,
    'addedAt': addedAt.millisecondsSinceEpoch,
    if (fallback != AcpAttachmentFallback.reject) 'fallback': fallback.name,
  };

  /// Parses a reference written by [toJson], or returns `null`.
  ///
  /// [legacyAddedAt] stands in for `addedAt` in a version 1 row, which did
  /// not record it.
  static AcpSavedDraftAttachment? tryFromJson(
    Object? json, {
    DateTime? legacyAddedAt,
  }) {
    if (json is! Map) return null;
    final name = json['name'];
    final addedAtMs = json['addedAt'];
    if (name is! String || name.isEmpty) return null;
    final addedAt = addedAtMs is int
        ? _utcFromMillis(addedAtMs)
        : legacyAddedAt;
    if (addedAt == null) return null;
    final fallback = json['fallback'] == AcpAttachmentFallback.remoteUpload.name
        ? AcpAttachmentFallback.remoteUpload
        : AcpAttachmentFallback.reject;
    final sizeBytes = json['size'];
    final size = sizeBytes is int && sizeBytes >= 0 ? sizeBytes : null;
    final mimeType = json['mime'];
    final mime = mimeType is String && mimeType.isNotEmpty ? mimeType : null;
    switch (json['kind']) {
      case AcpSavedPastedText.kind:
        final chip = json['chip'];
        if (chip is int && chip >= 0) {
          return AcpSavedPastedText(name: name, chip: chip, addedAt: addedAt);
        }
        // Version 1 kept the pasted text inline.
        final text = json['text'];
        if (legacyAddedAt == null || text is! String || text.isEmpty) {
          return null;
        }
        return AcpSavedPastedText.legacy(
          name: name,
          text: text,
          addedAt: addedAt,
        );
      case AcpSavedLocalFile.kind:
        final path = json['path'];
        final modified = json['modified'];
        if (path is! String || path.isEmpty) return null;
        if (size == null || modified is! int) return null;
        return AcpSavedLocalFile(
          name: name,
          path: path,
          stamp: AcpDraftFileStamp(sizeBytes: size, modifiedMs: modified),
          mimeType: mime,
          fallback: fallback,
          addedAt: addedAt,
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
          addedAt: addedAt,
        );
    }
    return null;
  }
}

/// A large paste the composer collapsed into a chip. Its text lives in the
/// draft's chips row at index [chip].
final class AcpSavedPastedText extends AcpSavedDraftAttachment {
  /// Creates a saved pasted-text chip.
  const AcpSavedPastedText({
    required super.name,
    required int this.chip,
    required super.addedAt,
  }) : legacyText = null,
       super(fallback: AcpAttachmentFallback.reject);

  /// A chip read from a version 1 row, which kept its text inline.
  const AcpSavedPastedText.legacy({
    required super.name,
    required String text,
    required super.addedAt,
  }) : chip = null,
       legacyText = text,
       super(fallback: AcpAttachmentFallback.reject);

  /// Storage tag.
  static const kind = 'pastedText';

  /// Index of the text in the draft's chips row.
  final int? chip;

  /// The text of a chip from a version 1 row.
  final String? legacyText;

  /// The chip's text, given the draft's chips row.
  String? textFrom(List<String> chips) {
    final index = chip;
    if (index == null) return legacyText;
    return index < chips.length ? chips[index] : null;
  }

  @override
  Map<String, Object?> toJson() => {..._common(kind), 'chip': chip};
}

/// A reference to a file picked on this device.
final class AcpSavedLocalFile extends AcpSavedDraftAttachment {
  /// Creates a saved local-file reference.
  const AcpSavedLocalFile({
    required super.name,
    required this.path,
    required this.stamp,
    required super.fallback,
    required super.addedAt,
    this.mimeType,
  });

  /// Storage tag.
  static const kind = 'localFile';

  /// Local file path reported by the picker.
  final String path;

  /// Size and modification time when the reference was first saved.
  final AcpDraftFileStamp stamp;

  /// Picker-provided MIME type.
  final String? mimeType;

  @override
  Map<String, Object?> toJson() => {
    ..._common(kind),
    'path': path,
    'size': stamp.sizeBytes,
    'modified': stamp.modifiedMs,
    'mime': ?mimeType,
  };
}

/// A reference to a file selected on the remote host. It is sent as a link
/// to the remote path, so the agent always reads the file as it is then.
final class AcpSavedRemoteFile extends AcpSavedDraftAttachment {
  /// Creates a saved remote-file reference.
  const AcpSavedRemoteFile({
    required super.name,
    required this.remotePath,
    required super.fallback,
    required super.addedAt,
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
  Map<String, Object?> toJson() => {
    ..._common(kind),
    'remotePath': remotePath,
    'size': ?sizeBytes,
    'mime': ?mimeType,
  };
}

/// The stored form of an unsent composer draft.
///
/// Text is kept verbatim and pasted-text chips by index into a separate
/// chips row. Picked files are kept as references only. Attachments that
/// exist only in memory (a pasted image) are counted in
/// [unsavedAttachmentCount] rather than stored.
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
    this.version = kAcpSavedComposerDraftVersion,
  }) : attachments = List<AcpSavedDraftAttachment>.unmodifiable(attachments);

  /// Composer text.
  final String text;

  /// Caret offset within [text].
  final int caret;

  /// When the draft was last saved, in UTC.
  final DateTime savedAt;

  /// Ordered attachment references.
  final List<AcpSavedDraftAttachment> attachments;

  /// Attachments that could not be stored (in-memory images, pasted text
  /// beyond the size budget, or files that were already gone).
  final int unsavedAttachmentCount;

  /// Format version this draft was read from.
  final int version;

  /// Whether this draft was read from an older format and should be
  /// rewritten in the current one.
  bool get isLegacy => version < kAcpSavedComposerDraftVersion;

  /// JSON form. `savedAt` comes first so pruning can read it from a prefix.
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
  ///
  /// Version 1 rows are read too. Their text and pasted-text chips are kept
  /// and their remote files dated by the save time. Their local files are
  /// counted as unavailable, since version 1 did not record the modification
  /// time the file check needs.
  static AcpSavedComposerDraft? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final version = json['v'];
    if (version is! int || version < 1 || version > 2) return null;
    final savedAtMs = json['savedAt'];
    final text = json['text'];
    final rawAttachments = json['attachments'];
    if (savedAtMs is! int || text is! String || rawAttachments is! List) {
      return null;
    }
    final savedAt = _utcFromMillis(savedAtMs);
    if (savedAt == null) return null;
    final caret = json['caret'];
    final unsaved = json['unsaved'];
    final attachments = <AcpSavedDraftAttachment>[];
    var unreadable = 0;
    for (final item in rawAttachments) {
      final attachment = AcpSavedDraftAttachment.tryFromJson(
        item,
        legacyAddedAt: version == 1 ? savedAt : null,
      );
      if (attachment == null) {
        unreadable++;
      } else {
        attachments.add(attachment);
      }
    }
    return AcpSavedComposerDraft(
      text: text,
      caret: caret is int ? caret.clamp(0, text.length) : text.length,
      savedAt: savedAt,
      attachments: attachments,
      unsavedAttachmentCount:
          (unsaved is int && unsaved > 0 ? unsaved : 0) + unreadable,
      version: version,
    );
  }

  /// Reads only the save time from the start of an encoded draft, or returns
  /// `null` when it is not where [toJson] puts it.
  static DateTime? peekSavedAt(String encoded) {
    final match = _savedAtPrefix.matchAsPrefix(encoded);
    final millis = match == null ? null : int.tryParse(match.group(1)!);
    return millis == null ? null : _utcFromMillis(millis);
  }

  /// Characters of an encoded draft that [peekSavedAt] needs.
  static const peekLength = 32;

  static final _savedAtPrefix = RegExp(r'\{"savedAt":(-?\d{1,16})[,}]');

  /// Encodes the texts of a draft's pasted-text chips for the chips row.
  static String encodeChips(List<String> chips) => jsonEncode(chips);

  /// Decodes a chips row, or returns `null` when it is malformed.
  static List<String>? decodeChips(String encoded) {
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List) return null;
      final chips = <String>[];
      for (final chip in decoded) {
        if (chip is! String) return null;
        chips.add(chip);
      }
      return chips;
    } on FormatException {
      return null;
    }
  }
}

/// The UTC time [millis] after the epoch, or `null` when it is outside the
/// range `DateTime` can represent.
DateTime? _utcFromMillis(int millis) => millis.abs() <= 8640000000000000
    ? DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true)
    : null;
