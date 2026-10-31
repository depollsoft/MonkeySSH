import 'package:xterm/src/utils/unicode_grapheme.dart';
import 'package:xterm/src/utils/unicode_v11.dart';

/// Variation selector 15, which asks for text (narrow) presentation.
const textPresentationSelector = 0xFE0E;

/// Variation selector 16, which asks for emoji (wide) presentation.
const emojiPresentationSelector = 0xFE0F;

/// The context [graphemeBreak] carries from one code point pair to the next.
///
/// The MonkeyMux screen model ports the same rules
/// (remote/monkeymux/grapheme.go); both run the Unicode break tests.
class GraphemeBreakState {
  /// What the code points before the pair end with, for GB9c: nothing that
  /// counts, an Indic consonant and any extends, or one of those followed by
  /// a linker and any further linkers and extends.
  int _incb = _incbNone;

  /// The sequence the pair is inside, for GB11 to GB13.
  int _base = _baseDefault;

  void reset() {
    _incb = _incbNone;
    _base = _baseDefault;
  }

  /// Copies [other] into this state.
  void copyFrom(GraphemeBreakState other) {
    _incb = other._incb;
    _base = other._base;
  }

  static const _incbNone = 0;
  static const _incbConsonant = 1;
  static const _incbLinker = 2;

  static const _baseDefault = 0;
  static const _basePictographic = 1;
  static const _baseRegionalIndicator = 2;
}

/// Whether [codePoint] can continue a grapheme cluster, which keeps the rest
/// of Latin-1, and so ASCII, off the slower path. Up to U+00FF only the
/// Extended_Pictographic © and ® can, after a ZWJ. Anything can follow a
/// prepended concatenation mark (GB9b); like Ghostty, a terminal ignores that
/// for Latin-1.
bool mayContinueGrapheme(int codePoint) =>
    codePoint > 0xFF || codePoint == 0xA9 || codePoint == 0xAE;

/// The [GraphemeClass] of [codePoint].
int graphemeClassOf(int codePoint) => graphemeProperty(codePoint) & _classMask;

/// Whether a grapheme cluster ends between [cp1] and [cp2], updating [state].
/// Call it for every consecutive pair, starting from a fresh state at the
/// cluster's first code point.
///
/// These are Ghostty's rules (its uucode library's no-control variant):
/// UAX #29 with an emoji modifier joining only an emoji modifier base, as
/// UTS #51 has it. Unlike uucode, GB9c joins a consonant only after a linker
/// that itself follows a consonant, as UAX #29 says. Controls never reach a
/// terminal's print path and count as other.
bool graphemeBreak(int cp1, int cp2, GraphemeBreakState state) {
  final gb1 = graphemeProperty(cp1) & _classMask;
  final gb2 = graphemeProperty(cp2) & _classMask;

  if (gb1 == GraphemeClass.incbConsonant) {
    state._incb = GraphemeBreakState._incbConsonant;
  } else if (gb1 == GraphemeClass.incbLinkerExtend ||
      gb1 == GraphemeClass.incbLinkerOther) {
    if (state._incb != GraphemeBreakState._incbNone) {
      state._incb = GraphemeBreakState._incbLinker;
    }
  } else if (gb1 != GraphemeClass.incbExtend && gb1 != GraphemeClass.zwj) {
    state._incb = GraphemeBreakState._incbNone;
  }

  switch (state._base) {
    case GraphemeBreakState._baseRegionalIndicator:
      if (gb1 != GraphemeClass.regionalIndicator ||
          gb2 != GraphemeClass.regionalIndicator) {
        state._base = GraphemeBreakState._baseDefault;
      }
    case GraphemeBreakState._basePictographic:
      if (!_continuesEmoji(gb1) || !_continuesEmoji(gb2)) {
        state._base = GraphemeBreakState._baseDefault;
      }
  }

  // GB6, GB7, GB8: Hangul syllable sequences.
  if (gb1 == GraphemeClass.l &&
      (gb2 == GraphemeClass.l ||
          gb2 == GraphemeClass.v ||
          gb2 == GraphemeClass.lv ||
          gb2 == GraphemeClass.lvt)) {
    return false;
  }
  if ((gb1 == GraphemeClass.lv || gb1 == GraphemeClass.v) &&
      (gb2 == GraphemeClass.v || gb2 == GraphemeClass.t)) {
    return false;
  }
  if ((gb1 == GraphemeClass.lvt || gb1 == GraphemeClass.t) &&
      gb2 == GraphemeClass.t) {
    return false;
  }

  // GB9a, GB9b.
  if (gb2 == GraphemeClass.spacingMark || gb1 == GraphemeClass.prepend) {
    return false;
  }

  // GB9c: consonant, then linkers and extends with at least one linker,
  // then a consonant.
  if (state._incb == GraphemeBreakState._incbLinker &&
      gb2 == GraphemeClass.incbConsonant) {
    state._base = GraphemeBreakState._baseDefault;
    return false;
  }

  // GB11: emoji ZWJ sequences, and emoji modifier sequences.
  if (_isPictographic(gb1)) {
    if (_isExtend(gb2) || gb2 == GraphemeClass.zwj) {
      state._base = GraphemeBreakState._basePictographic;
      return false;
    }
    if (gb1 == GraphemeClass.emojiModifierBase &&
        gb2 == GraphemeClass.emojiModifier) {
      state._base = GraphemeBreakState._basePictographic;
      return false;
    }
  } else if (state._base == GraphemeBreakState._basePictographic) {
    if ((_isExtend(gb1) || gb1 == GraphemeClass.emojiModifier) &&
        (_isExtend(gb2) || gb2 == GraphemeClass.zwj)) {
      return false;
    }
    state._base = GraphemeBreakState._baseDefault;
    if (gb1 == GraphemeClass.zwj && _isPictographic(gb2)) {
      return false;
    }
  }

  // GB12, GB13: regional indicators pair up.
  if (gb1 == GraphemeClass.regionalIndicator &&
      gb2 == GraphemeClass.regionalIndicator) {
    if (state._base == GraphemeBreakState._baseDefault) {
      state._base = GraphemeBreakState._baseRegionalIndicator;
      return false;
    }
    state._base = GraphemeBreakState._baseDefault;
    return true;
  }

  // GB9, then GB999.
  return !(_isExtend(gb2) || gb2 == GraphemeClass.zwj);
}

/// How appending a code point to a grapheme cluster changes its width.
enum GraphemeWidthEffect {
  /// Leave the code point out of the cluster, and the break state as it was
  /// before it: an emoji variation selector after a code point it does not
  /// apply to.
  ignore,

  /// Append it; the width stays.
  noChange,

  /// Append it; the cluster takes two columns.
  wide,

  /// Append it; the cluster takes one column.
  narrow,
}

/// The effect of appending [codePoint] to a cluster whose last code point is
/// [previous], once [graphemeBreak] has found no break between them. As in
/// Ghostty, a code point that has a width of its own makes the cluster wide.
GraphemeWidthEffect graphemeWidthEffect(int previous, int codePoint) {
  if (codePoint == emojiPresentationSelector ||
      codePoint == textPresentationSelector) {
    if (graphemeProperty(previous) & graphemeVSBase == 0) {
      return GraphemeWidthEffect.ignore;
    }
    return codePoint == emojiPresentationSelector
        ? GraphemeWidthEffect.wide
        : GraphemeWidthEffect.narrow;
  }
  if (!isZeroWidthInGrapheme(codePoint)) return GraphemeWidthEffect.wide;
  return GraphemeWidthEffect.noChange;
}

/// Whether [codePoint] adds no width to the cluster it joins: anything of
/// width 0, emoji modifiers, Hangul medial vowels and final consonants, and
/// prepended concatenation marks.
bool isZeroWidthInGrapheme(int codePoint) {
  if (unicodeV11.wcwidth(codePoint) == 0) return true;
  final gb = graphemeProperty(codePoint) & _classMask;
  return gb == GraphemeClass.emojiModifier ||
      gb == GraphemeClass.v ||
      gb == GraphemeClass.t ||
      gb == GraphemeClass.prepend;
}

/// The columns [codePoint] takes when it starts a cluster with clustering
/// on: its width, except that an emoji modifier on its own is shown as a
/// two-column color swatch, as in Ghostty.
int graphemeStartWidth(int codePoint) {
  if (graphemeProperty(codePoint) & _classMask == GraphemeClass.emojiModifier) {
    return 2;
  }
  return unicodeV11.wcwidth(codePoint);
}

/// Whether [codePoint] is an emoji variation selector, which in legacy mode
/// only attaches after an extended pictographic code point.
bool isEmojiVariationSelector(int codePoint) =>
    codePoint == emojiPresentationSelector ||
    codePoint == textPresentationSelector;

/// Whether [codePoint] is Extended_Pictographic.
bool isExtendedPictographic(int codePoint) =>
    _isPictographic(graphemeProperty(codePoint) & _classMask);

const _classMask = graphemeVSBase - 1;

bool _isExtend(int gb) =>
    gb == GraphemeClass.zwnj ||
    gb == GraphemeClass.incbExtend ||
    gb == GraphemeClass.incbLinkerExtend;

bool _isPictographic(int gb) =>
    gb == GraphemeClass.extendedPictographic ||
    gb == GraphemeClass.emojiModifierBase;

bool _continuesEmoji(int gb) =>
    gb == GraphemeClass.incbExtend ||
    gb == GraphemeClass.incbLinkerExtend ||
    gb == GraphemeClass.zwnj ||
    gb == GraphemeClass.zwj ||
    gb == GraphemeClass.extendedPictographic ||
    gb == GraphemeClass.emojiModifierBase ||
    gb == GraphemeClass.emojiModifier;
