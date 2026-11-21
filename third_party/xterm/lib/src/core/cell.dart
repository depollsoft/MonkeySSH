class CellData {
  CellData({
    required this.foreground,
    required this.background,
    required this.flags,
    required this.content,
    this.underlineColor = 0,
    this.graphemeExtras = const [],
  });

  factory CellData.empty() {
    return CellData(
      foreground: 0,
      background: 0,
      flags: 0,
      content: 0,
      underlineColor: 0,
    );
  }

  int foreground;

  int background;

  int flags;

  int content;

  /// Underline color, encoded like [foreground]/[background] (a [CellColor]
  /// type plus value). `0` means "use the text color".
  int underlineColor;

  /// The code points the cell's grapheme cluster holds after the one in
  /// [content], such as combining marks, a ZWJ sequence's later emoji or a
  /// variation selector. Empty unless [content] has
  /// [CellContent.graphemeFlag]. The list is shared with the line and must
  /// not be changed.
  List<int> graphemeExtras;

  /// Everything about the cell its painted glyph depends on, compared by
  /// value, for keying a cache of laid-out glyphs. Unlike [getHash], two
  /// different cells never share a key.
  Object get paintKey => (
        foreground,
        background,
        flags,
        content,
        underlineColor,
        graphemeExtras.isEmpty ? null : String.fromCharCodes(graphemeExtras),
      );

  int getHash() {
    final hash =
        Object.hash(foreground, background, flags, content, underlineColor);
    if (graphemeExtras.isEmpty) return hash;
    return Object.hash(hash, Object.hashAll(graphemeExtras));
  }

  @override
  String toString() {
    return 'CellData{foreground: $foreground, background: $background, '
        'flags: $flags, content: $content, underlineColor: $underlineColor, '
        'graphemeExtras: $graphemeExtras}';
  }
}

abstract class CellAttr {
  static const bold = 1 << 0;
  static const faint = 1 << 1;
  static const italic = 1 << 2;
  static const underline = 1 << 3;
  static const blink = 1 << 4;
  static const inverse = 1 << 5;
  static const invisible = 1 << 6;
  static const strikethrough = 1 << 7;

  // Underline style occupies bits 8..10 and holds an [UnderlineStyle] index.
  static const underlineStyleShift = 8;
  static const underlineStyleMask = 7 << underlineStyleShift;

  static const overline = 1 << 11;
}

/// Visual style of an underline, matching the values used by the `CSI 4 : x m`
/// SGR sub-parameter in xterm.js.
enum UnderlineStyle {
  none,
  single,
  double,
  curly,
  dotted,
  dashed,
}

abstract class CellColor {
  static const valueMask = 0xFFFFFF;

  static const typeShift = 25;
  static const typeMask = 3 << typeShift;

  static const normal = 0 << typeShift;
  static const named = 1 << typeShift;
  static const palette = 2 << typeShift;
  static const rgb = 3 << typeShift;
}

/// What shell integration (OSC 133 semantic prompts) says a cell holds: the
/// prompt, the user's input, or anything else, which counts as command output.
/// A cell takes the kind in force when it is written; an erased cell is
/// output again.
abstract class SemanticContent {
  static const output = 0;
  static const input = 1;
  static const prompt = 2;
}

abstract class CellContent {
  static const codepointMask = 0x1fffff;

  /// Set when the cell holds code points after its base, which
  /// [BufferLine.getGraphemeExtras] returns: the rest of a grapheme cluster
  /// (DEC mode 2027), or the marks legacy mode joins to a glyph. It sits
  /// between the code point and the width, so `content & codepointMask` and
  /// `content >> widthShift` read the same with it set.
  static const graphemeFlag = 1 << 21;

  static const widthShift = 22;
  // static const widthMask = 3 << widthShift;
}
