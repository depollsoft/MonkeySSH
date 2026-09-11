import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/paragraph_cache.dart';

void main() {
  test('clear releases native paragraphs and allows reuse', () {
    final cache = ParagraphCache(2);
    addTearDown(cache.clear);
    final first = cache.performAndCacheLayout(
      'a',
      const TextStyle(),
      TextScaler.noScaling,
      1,
    );
    final second = cache.performAndCacheLayout(
      'b',
      const TextStyle(),
      TextScaler.noScaling,
      2,
    );
    expect(first.debugDisposed, isFalse);
    expect(cache.getLayoutFromCache(1), same(first));

    cache.clear();
    expect(first.debugDisposed, isTrue);
    expect(second.debugDisposed, isTrue);
    expect(cache.length, 0);
    expect(cache.getLayoutFromCache(1), isNull);
    expect(cache.clear, returnsNormally);

    final replacement = cache.performAndCacheLayout(
      'c',
      const TextStyle(),
      TextScaler.noScaling,
      1,
    );
    expect(replacement.debugDisposed, isFalse);
    expect(cache.getLayoutFromCache(1), same(replacement));
  });

  test('replacing a key releases only its old paragraph', () {
    final cache = ParagraphCache(2);
    addTearDown(cache.clear);
    final old = cache.performAndCacheLayout(
      'a',
      const TextStyle(),
      TextScaler.noScaling,
      1,
    );
    final other = cache.performAndCacheLayout(
      'b',
      const TextStyle(),
      TextScaler.noScaling,
      2,
    );
    final replacement = cache.performAndCacheLayout(
      'c',
      const TextStyle(),
      TextScaler.noScaling,
      1,
    );

    expect(old.debugDisposed, isTrue);
    expect(other.debugDisposed, isFalse);
    expect(replacement.debugDisposed, isFalse);
    expect(cache.length, 2);
    expect(cache.getLayoutFromCache(1), same(replacement));
    expect(cache.getLayoutFromCache(2), same(other));
  });

  test('requires positive capacity so returned paragraphs stay owned', () {
    for (final size in [0, -1]) {
      expect(() => ParagraphCache(size), throwsArgumentError);
    }
  });

  test('replacement promotes the key and cache misses preserve recency', () {
    final cache = ParagraphCache(2);
    addTearDown(cache.clear);
    final old = cache.performAndCacheLayout(
      'old',
      const TextStyle(),
      TextScaler.noScaling,
      1,
    );
    final lru = cache.performAndCacheLayout(
      'lru',
      const TextStyle(),
      TextScaler.noScaling,
      2,
    );
    final replacement = cache.performAndCacheLayout(
      'new',
      const TextStyle(),
      TextScaler.noScaling,
      1,
    );
    expect(old.debugDisposed, isTrue);
    expect(lru.debugDisposed, isFalse);
    expect(cache.getLayoutFromCache(99), isNull);
    final newest = cache.performAndCacheLayout(
      'newest',
      const TextStyle(),
      TextScaler.noScaling,
      3,
    );
    expect(lru.debugDisposed, isTrue);
    expect(replacement.debugDisposed, isFalse);
    expect(newest.debugDisposed, isFalse);
    expect(cache.length, 2);
  });

  test('capacity-one churn disposes each evicted paragraph', () {
    final cache = ParagraphCache(1);
    addTearDown(cache.clear);
    var previous = cache.performAndCacheLayout(
      '0',
      const TextStyle(),
      TextScaler.noScaling,
      0,
    );
    for (var key = 1; key <= 20; key++) {
      final next = cache.performAndCacheLayout(
        '$key',
        const TextStyle(),
        TextScaler.noScaling,
        key,
      );
      expect(previous.debugDisposed, isTrue);
      expect(next.debugDisposed, isFalse);
      expect(cache.length, 1);
      previous = next;
    }
    cache.clear();
    expect(previous.debugDisposed, isTrue);
  });

  test('cache hits still promote the least recently used entry', () {
    final cache = ParagraphCache(2);
    addTearDown(cache.clear);
    final first = cache.performAndCacheLayout(
      'a',
      const TextStyle(),
      TextScaler.noScaling,
      1,
    );
    final evicted = cache.performAndCacheLayout(
      'b',
      const TextStyle(),
      TextScaler.noScaling,
      2,
    );
    expect(cache.getLayoutFromCache(1), same(first));
    final third = cache.performAndCacheLayout(
      'c',
      const TextStyle(),
      TextScaler.noScaling,
      3,
    );
    expect(evicted.debugDisposed, isTrue);
    expect(first.debugDisposed, isFalse);
    expect(third.debugDisposed, isFalse);
    expect(cache.length, 2);
    expect(cache.getLayoutFromCache(2), isNull);
    expect(cache.getLayoutFromCache(1), same(first));
    expect(cache.getLayoutFromCache(3), same(third));
  });
}
