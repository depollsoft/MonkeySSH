/// Lets a containing shell trigger native chat actions that the embedded
/// conversation has no app bar of its own to offer.
library;

import 'package:flutter/foundation.dart';

/// Forwards transcript actions to the currently mounted native chat.
///
/// The terminal shell owns one of these and passes it to its embedded
/// conversation; its overflow menu calls [openSearch] and [exportTranscript].
/// Calls are ignored while no conversation is attached.
class AcpChatActionsController {
  Object? _owner;
  VoidCallback? _openSearch;
  VoidCallback? _exportTranscript;

  /// Whether a conversation is attached to receive actions.
  bool get isAttached => _owner != null;

  /// Opens the find bar over the transcript.
  void openSearch() => _openSearch?.call();

  /// Opens the Markdown export preview for the loaded transcript.
  void exportTranscript() => _exportTranscript?.call();

  /// Routes actions to [owner] until it detaches.
  void attach(
    Object owner, {
    required VoidCallback openSearch,
    required VoidCallback exportTranscript,
  }) {
    _owner = owner;
    _openSearch = openSearch;
    _exportTranscript = exportTranscript;
  }

  /// Stops routing actions to [owner], if it is still the attached one.
  void detach(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _openSearch = null;
    _exportTranscript = null;
  }
}
