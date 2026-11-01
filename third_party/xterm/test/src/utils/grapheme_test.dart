import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:xterm/src/utils/grapheme.dart';
import 'package:xterm/src/utils/unicode_grapheme.dart';

void main() {
  // remote/monkeymux/grapheme_table.go is generated from the same table and
  // checked against the same digest, so the client and the MonkeyMux screen
  // model join code points into the same clusters.
  test('graphemeProperty matches the shared grapheme table digest', () {
    final digest = <String, String>{};
    for (final line in File('../../scripts/unicode_grapheme_table.crc32')
        .readAsLinesSync()) {
      final fields = line.trim().split(' ');
      if (fields.length == 2 && !line.startsWith('#')) {
        digest[fields[0]] = fields[1];
      }
    }
    final values = Uint8List(0x110000);
    for (var codePoint = 0; codePoint < values.length; codePoint++) {
      values[codePoint] = graphemeProperty(codePoint);
    }
    expect(digest['unicode'], unicodeGraphemeVersion);
    expect(
      digest['crc32'],
      getCrc32(values).toRadixString(16).padLeft(8, '0'),
      reason: 'rerun scripts/generate_unicode_grapheme_tables.py',
    );
  });

  // The Unicode break tests, which the MonkeyMux screen model runs through
  // its port of the same rules. Tests with controls are skipped: terminals
  // never print them. Ghostty's tailoring breaks before an emoji modifier
  // that does not follow an emoji modifier base, and without GB9c a
  // consonant joins only a prepended mark.
  test('graphemeBreak passes the Unicode grapheme break tests', () {
    final failures = <String>[];
    var tested = 0;
    for (final line
        in File('../../remote/monkeymux/testdata/grapheme_break_test.txt')
            .readAsLinesSync()) {
      if (line.startsWith('#') || line.trim().isEmpty) continue;
      final parts = line.trim().split(' ');
      final codePoints = [
        for (var i = 1; i < parts.length; i += 2)
          int.parse(parts[i], radix: 16),
      ];
      if (codePoints.any((codePoint) => codePoint < 0x20)) continue;
      tested++;
      final state = GraphemeBreakState();
      for (var i = 0; i + 1 < codePoints.length; i++) {
        var want = parts[2 * i + 2] == '÷';
        if (graphemeProperty(codePoints[i + 1]) & 0x1F ==
                GraphemeClass.emojiModifier &&
            graphemeProperty(codePoints[i]) & 0x1F !=
                GraphemeClass.emojiModifierBase) {
          want = true;
        }
        if (graphemeProperty(codePoints[i + 1]) & 0x1F ==
                GraphemeClass.incbConsonant &&
            graphemeProperty(codePoints[i]) & 0x1F != GraphemeClass.prepend) {
          want = true;
        }
        if (graphemeBreak(codePoints[i], codePoints[i + 1], state) != want) {
          failures.add(line);
          break;
        }
      }
    }
    expect(tested, greaterThan(500));
    expect(failures, isEmpty);
  });

  test('variation selectors size the clusters they apply to', () {
    expect(
      graphemeWidthEffect(0x2665, emojiPresentationSelector),
      GraphemeWidthEffect.wide,
    );
    expect(
      graphemeWidthEffect(0x231A, textPresentationSelector),
      GraphemeWidthEffect.narrow,
    );
    expect(
      graphemeWidthEffect(0x31, emojiPresentationSelector),
      GraphemeWidthEffect.wide,
    );
    expect(
      graphemeWidthEffect(0x61, emojiPresentationSelector),
      GraphemeWidthEffect.ignore,
    );
  });

  test('code points with a width of their own widen a cluster', () {
    // A regional indicator pairs into a flag; a spacing mark has a column.
    expect(graphemeWidthEffect(0x1F1FA, 0x1F1F8), GraphemeWidthEffect.wide);
    expect(graphemeWidthEffect(0x0915, 0x093F), GraphemeWidthEffect.wide);
    // Marks, joiners, modifiers and Hangul vowels and finals add nothing.
    for (final codePoint in [0x0301, 0x200D, 0x1F3FD, 0x1161, 0x11A8]) {
      expect(
        graphemeWidthEffect(0x1F468, codePoint),
        GraphemeWidthEffect.noChange,
        reason: codePoint.toRadixString(16),
      );
    }
  });

  test('an emoji modifier on its own takes two columns', () {
    expect(graphemeStartWidth(0x1F3FD), 2);
    expect(graphemeStartWidth(0x41), 1);
    expect(graphemeStartWidth(0x0301), 0);
  });
}
