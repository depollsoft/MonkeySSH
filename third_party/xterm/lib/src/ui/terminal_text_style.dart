import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

const _kDefaultFontSize = 13.0;

const _kDefaultHeight = 1.2;

const _kDefaultFontFamily = 'monospace';

const _kDefaultFontFamilyFallback = [
  'Menlo',
  'Monaco',
  'Consolas',
  'Liberation Mono',
  'Courier New',
  'Noto Sans Mono CJK SC',
  'Noto Sans Mono CJK TC',
  'Noto Sans Mono CJK KR',
  'Noto Sans Mono CJK JP',
  'Noto Sans Mono CJK HK',
  'Noto Color Emoji',
  'Noto Sans Symbols',
  'monospace',
  'sans-serif',
];

/// Colour emoji font families, the first that exists on the platform first.
const terminalEmojiFontFamilies = [
  'Apple Color Emoji',
  'Noto Color Emoji',
  'Segoe UI Emoji',
];

/// Whether a cell's grapheme cluster asks for emoji presentation: the code
/// points after its base ([CellData.graphemeExtras]) include VS16.
bool requestsEmojiPresentation(List<int> graphemeExtras) =>
    graphemeExtras.contains(0xFE0F);

/// [style] with the colour emoji fonts ahead of its own families, for a
/// cluster that [requestsEmojiPresentation]. Font fallback otherwise only
/// reaches an emoji font for a code point the terminal font lacks, so a
/// terminal font with a text heart draws `♥️` as that heart.
TextStyle withEmojiPresentation(TextStyle style) => style.copyWith(
      fontFamily: terminalEmojiFontFamilies.first,
      fontFamilyFallback: [
        ...terminalEmojiFontFamilies.skip(1),
        if (style.fontFamily != null) style.fontFamily!,
        ...?style.fontFamilyFallback,
      ],
    );

class TerminalStyle {
  const TerminalStyle({
    this.fontSize = _kDefaultFontSize,
    this.height = _kDefaultHeight,
    this.fontFamily = _kDefaultFontFamily,
    this.fontFamilyFallback = _kDefaultFontFamilyFallback,
  });

  factory TerminalStyle.fromTextStyle(TextStyle textStyle) {
    return TerminalStyle(
      fontSize: textStyle.fontSize ?? _kDefaultFontSize,
      height: textStyle.height ?? _kDefaultHeight,
      fontFamily: textStyle.fontFamily ??
          textStyle.fontFamilyFallback?.first ??
          _kDefaultFontFamily,
      fontFamilyFallback:
          textStyle.fontFamilyFallback ?? _kDefaultFontFamilyFallback,
    );
  }

  final double fontSize;

  final double height;

  final String fontFamily;

  final List<String> fontFamilyFallback;

  TextStyle toTextStyle({
    Color? color,
    Color? backgroundColor,
    bool bold = false,
    bool italic = false,
    bool underline = false,
    bool strikethrough = false,
    bool overline = false,
    TextDecorationStyle underlineStyle = TextDecorationStyle.solid,
    Color? decorationColor,
  }) {
    final decorations = <TextDecoration>[
      if (underline) TextDecoration.underline,
      if (overline) TextDecoration.overline,
      if (strikethrough) TextDecoration.lineThrough,
    ];
    return TextStyle(
      fontSize: fontSize,
      height: height,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      color: color,
      backgroundColor: backgroundColor,
      fontWeight: bold ? FontWeight.bold : FontWeight.normal,
      fontStyle: italic ? FontStyle.italic : FontStyle.normal,
      decoration: decorations.isEmpty
          ? TextDecoration.none
          : TextDecoration.combine(decorations),
      // Flutter applies a single decoration style/color to all lines at once,
      // so the underline style/color also governs any overline/strikethrough.
      decorationStyle: decorations.isEmpty ? null : underlineStyle,
      decorationColor: decorations.isEmpty ? null : decorationColor,
    );
  }

  TerminalStyle copyWith({
    double? fontSize,
    double? height,
    String? fontFamily,
    List<String>? fontFamilyFallback,
  }) {
    return TerminalStyle(
      fontSize: fontSize ?? this.fontSize,
      height: height ?? this.height,
      fontFamily: fontFamily ?? this.fontFamily,
      fontFamilyFallback: fontFamilyFallback ?? this.fontFamilyFallback,
    );
  }

  // Value equality lets a render object skip its cache-clearing style setter
  // when a widget rebuild hands it an equivalent but freshly built style.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalStyle &&
          other.fontSize == fontSize &&
          other.height == height &&
          other.fontFamily == fontFamily &&
          listEquals(other.fontFamilyFallback, fontFamilyFallback);

  @override
  int get hashCode => Object.hash(
      fontSize, height, fontFamily, Object.hashAll(fontFamilyFallback));
}
