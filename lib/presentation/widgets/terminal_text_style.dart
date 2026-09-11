import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Resolves the platform-specific system monospace family.
String resolveMonospaceFontFamily(TargetPlatform platform) =>
    switch (platform) {
      TargetPlatform.iOS || TargetPlatform.macOS => 'Menlo',
      _ => 'monospace',
    };

/// Resolves fallback families for the shared monospace stack.
List<String> resolveMonospaceFontFallback(TargetPlatform platform) =>
    switch (platform) {
      TargetPlatform.iOS ||
      TargetPlatform.macOS => const ['Courier', 'Courier New', 'monospace'],
      TargetPlatform.windows => const ['Consolas', 'Courier New', 'monospace'],
      _ => const ['monospace'],
    };

/// Resolves an optional configured monospace [TextStyle].
///
/// Returns null for the system monospace option so callers can decide whether
/// to fall back to a plain [TextStyle] or a different default.
TextStyle? resolveConfiguredMonospaceTextStyle(
  String fontFamily, {
  double? fontSize,
}) {
  final textStyle = switch (fontFamily) {
    'JetBrains Mono' => const TextStyle(fontFamily: 'JetBrains Mono'),
    'Fira Code' => GoogleFonts.firaCode(),
    'Source Code Pro' => GoogleFonts.sourceCodePro(),
    'Ubuntu Mono' => GoogleFonts.ubuntuMono(),
    'Roboto Mono' => GoogleFonts.robotoMono(),
    'IBM Plex Mono' => GoogleFonts.ibmPlexMono(),
    'Inconsolata' => GoogleFonts.inconsolata(),
    'Anonymous Pro' => GoogleFonts.anonymousPro(),
    'Cousine' => GoogleFonts.cousine(),
    'PT Mono' => GoogleFonts.ptMono(),
    'Space Mono' => GoogleFonts.spaceMono(),
    'VT323' => GoogleFonts.vt323(),
    'Share Tech Mono' => GoogleFonts.shareTechMono(),
    'Overpass Mono' => GoogleFonts.overpassMono(),
    'Oxygen Mono' => GoogleFonts.oxygenMono(),
    _ => null,
  };
  if (textStyle == null || fontSize == null) {
    return textStyle;
  }
  return textStyle.copyWith(fontSize: fontSize);
}

/// Resolves the monospace [TextStyle] used for terminal and editor content.
TextStyle resolveMonospaceTextStyle(
  String fontFamily, {
  TargetPlatform? platform,
  double? fontSize,
}) {
  final configuredStyle = resolveConfiguredMonospaceTextStyle(
    fontFamily,
    fontSize: fontSize,
  );
  if (configuredStyle != null) {
    return configuredStyle;
  }

  final textStyle = fontFamily == 'monospace'
      ? TextStyle(
          fontFamily: platform == null
              ? 'monospace'
              : resolveMonospaceFontFamily(platform),
          fontFamilyFallback: platform == null
              ? null
              : resolveMonospaceFontFallback(platform),
        )
      : TextStyle(
          fontFamily: fontFamily,
          fontFamilyFallback: platform == null
              ? null
              : resolveMonospaceFontFallback(platform),
        );
  if (fontSize == null) {
    return textStyle;
  }
  return textStyle.copyWith(fontSize: fontSize);
}
