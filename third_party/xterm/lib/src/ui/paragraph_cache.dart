import 'dart:ui';

import 'package:flutter/widgets.dart';

/// A cache of laid out [Paragraph]s. This is used to avoid laying out the same
/// text multiple times, which is expensive.
///
/// The cache owns its paragraphs. Callers must not retain them after [clear]
/// or eviction/replacement, or dispose them themselves.
class ParagraphCache {
  /// Creates an owning cache with a positive capacity.
  ParagraphCache(this._maximumSize) {
    if (_maximumSize <= 0) {
      throw ArgumentError.value(
          _maximumSize, 'maximumSize', 'must be positive');
    }
  }

  final int _maximumSize;
  // Insertion order is LRU to MRU. Removing/reinserting on a hit promotes it,
  // and keys.first finds the eviction candidate without scanning the cache.
  final _cache = <int, Paragraph>{};

  /// Returns a [Paragraph] for the given [key]. [key] is the same as the
  /// key argument to [performAndCacheLayout].
  Paragraph? getLayoutFromCache(int key) {
    final paragraph = _cache.remove(key);
    if (paragraph != null) {
      _cache[key] = paragraph;
    }
    return paragraph;
  }

  /// Applies [style] and [textScaler] to [text] and lays it out to create
  /// a [Paragraph]. The [Paragraph] is cached and can be retrieved with the
  /// same [key] by calling [getLayoutFromCache].
  Paragraph performAndCacheLayout(
    String text,
    TextStyle style,
    TextScaler textScaler,
    int key,
  ) {
    final builder = ParagraphBuilder(style.getParagraphStyle());
    builder.pushStyle(style.getTextStyle(textScaler: textScaler));
    builder.addText(text);

    final paragraph = builder.build();
    paragraph.layout(ParagraphConstraints(width: double.infinity));

    _cache.remove(key)?.dispose();
    if (_cache.length == _maximumSize) {
      _cache.remove(_cache.keys.first)!.dispose();
    }
    _cache[key] = paragraph;
    return paragraph;
  }

  /// Releases all cached paragraphs. This should be called when the same text
  /// and style pair no longer produces the same layout, or the owner is disposed.
  void clear() {
    for (final paragraph in _cache.values) {
      paragraph.dispose();
    }
    _cache.clear();
  }

  /// Returns the number of [Paragraph]s in the cache.
  int get length {
    return _cache.length;
  }
}
