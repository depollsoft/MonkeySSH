import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../domain/models/terminal_theme.dart';

/// Theme configuration for the Flutty app.
/// Inspired by Termius with a modern hacker aesthetic.
abstract final class FluttyTheme {
  // Core palette - deep space with accents sampled from the app icon.
  static const _accentTeal = Color(0xFF14756C);
  static const _accentTealSoft = Color(0xFF58A38C);
  static const _backgroundDark = Color(0xFF0D0D12);
  static const _surfaceDark = Color(0xFF16161D);
  static const _cardDark = Color(0xFF1C1C26);
  static const _borderDark = Color(0xFF2A2A3A);
  static const _textPrimary = Color(0xFFF0F0F5);
  static const _textSecondary = Color(0xFF8A8A9A);
  static const _errorColor = Color(0xFFFF4757);
  static const _warningColor = Color(0xFFFFBE00);

  // Light theme equivalents
  static const _backgroundLight = Color(0xFFF8F9FC);
  static const _surfaceLight = Color(0xFFFFFFFF);
  static const _cardLight = Color(0xFFFFFFFF);
  static const _borderLight = Color(0xFFE8E8EF);

  /// Standard spacing constants for consistent layout.
  static const double spacingXs = 4;

  /// Small spacing.
  static const double spacingSm = 8;

  /// Medium spacing.
  static const double spacingMd = 16;

  /// Large spacing.
  static const double spacingLg = 24;

  /// Extra-large spacing.
  static const double spacingXl = 32;

  /// Standard border radius for cards and containers.
  static const double radiusSm = 8;

  /// Medium border radius.
  static const double radiusMd = 12;

  /// Large border radius.
  static const double radiusLg = 16;

  /// Light theme.
  static ThemeData get light => _buildTheme(Brightness.light);

  /// Dark theme.
  static ThemeData get dark => _buildTheme(Brightness.dark);

  /// Uses system text styles instead of bundled fonts when true.
  ///
  /// This is intended for tests that instantiate theme data without a bundled
  /// font asset bundle.
  @visibleForTesting
  static bool debugUseSystemFonts = false;

  /// Builds an app theme using colors from a terminal theme palette.
  static ThemeData fromTerminalTheme(
    TerminalThemeData terminalTheme, {
    required Brightness brightness,
  }) => _buildTheme(brightness, terminalTheme: terminalTheme);

  static ThemeData _buildTheme(
    Brightness brightness, {
    TerminalThemeData? terminalTheme,
  }) {
    final isDark = brightness == Brightness.dark;
    final background =
        terminalTheme?.background ??
        (isDark ? _backgroundDark : _backgroundLight);
    final textPrimary =
        terminalTheme?.foreground ?? (isDark ? _textPrimary : Colors.black87);
    final textSecondary = terminalTheme == null
        ? (isDark ? _textSecondary : Colors.black54)
        : _blend(background, textPrimary, isDark ? 0.62 : 0.84);
    final surface =
        terminalTheme?.background ?? (isDark ? _surfaceDark : _surfaceLight);
    final card = terminalTheme == null
        ? (isDark ? _cardDark : _cardLight)
        : _blend(background, textPrimary, isDark ? 0.07 : 0.025);
    final border = terminalTheme == null
        ? (isDark ? _borderDark : _borderLight)
        : _blend(background, textPrimary, isDark ? 0.18 : 0.16);
    final primary = terminalTheme == null
        ? _accentTeal
        : _resolveTerminalAccent(terminalTheme);
    final primarySoft = terminalTheme == null
        ? _accentTealSoft
        : _blend(background, primary, isDark ? 0.55 : 0.28);
    final error = terminalTheme?.red ?? _errorColor;
    final warning = terminalTheme?.yellow ?? _warningColor;
    final inputFill = terminalTheme == null
        ? (isDark ? _cardDark : Colors.grey.shade50)
        : _blend(background, textPrimary, isDark ? 0.08 : 0.018);
    final inputHover = terminalTheme == null
        ? (isDark ? _borderDark : Colors.grey.shade100)
        : _blend(background, textPrimary, isDark ? 0.12 : 0.045);
    final overlayBackground = terminalTheme?.black ?? Colors.grey.shade900;
    final snackBarBackground = isDark ? card : overlayBackground;
    final snackBarForeground = _readableTextColor(snackBarBackground);
    final tooltipBackground = isDark ? card : overlayBackground;
    final tooltipForeground = _readableTextColor(tooltipBackground);
    final onPrimary = terminalTheme == null
        ? Colors.white
        : _readableTextColor(primary);
    final onTertiary = terminalTheme == null
        ? Colors.black
        : _readableTextColor(warning);
    final onError = terminalTheme == null
        ? Colors.white
        : _readableTextColor(error);

    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: primary,
      onPrimary: onPrimary,
      secondary: card,
      onSecondary: textPrimary,
      tertiary: warning,
      onTertiary: onTertiary,
      error: error,
      onError: onError,
      surface: surface,
      onSurface: textPrimary,
      surfaceContainerHighest: card,
      outline: border,
      outlineVariant: border.withAlpha(isDark ? 128 : 180),
    );

    // Use JetBrains Mono for that terminal feel, Inter for UI
    final baseTextTheme = isDark
        ? ThemeData.dark().textTheme
        : ThemeData.light().textTheme;

    final textTheme = _interTextTheme(baseTextTheme).copyWith(
      // Headings with more weight
      headlineLarge: _inter(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        color: textPrimary,
        letterSpacing: -0.5,
      ),
      headlineMedium: _inter(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: textPrimary,
        letterSpacing: -0.3,
      ),
      headlineSmall: _inter(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: textPrimary,
      ),
      titleLarge: _inter(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: textPrimary,
      ),
      titleMedium: _inter(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: textPrimary,
      ),
      bodyLarge: _inter(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: textPrimary,
      ),
      bodyMedium: _inter(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: textSecondary,
      ),
      bodySmall: _inter(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: textSecondary,
      ),
      labelLarge: _inter(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: textPrimary,
      ),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      textTheme: textTheme,
      scaffoldBackgroundColor: background,
      pageTransitionsTheme: _buildPageTransitionsTheme(background),

      // App bar with subtle blur effect vibe
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: _mono(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: textPrimary,
          letterSpacing: -0.5,
        ),
      ),

      // Cards with subtle glow on dark theme
      cardTheme: CardThemeData(
        color: card,
        elevation: isDark ? 0 : 1,
        shadowColor: isDark ? primary.withAlpha(20) : Colors.black12,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: border),
        ),
        margin: EdgeInsets.zero,
      ),

      // Glowing FAB
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        elevation: isDark ? 8 : 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),

      // Modern input fields
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: inputFill,
        hoverColor: inputHover,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: error),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        labelStyle: TextStyle(color: textSecondary),
        hintStyle: TextStyle(color: textSecondary.withAlpha(150)),
        prefixIconColor: textSecondary,
      ),

      // Buttons with glow
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: _inter(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          elevation: isDark ? 4 : 2,
          shadowColor: isDark ? primary.withAlpha(80) : Colors.black26,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: _inter(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          side: BorderSide(color: border, width: 1.5),
          textStyle: _inter(fontSize: 15, fontWeight: FontWeight.w500),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colorScheme.primary,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          textStyle: _inter(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),

      // Segmented buttons
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return colorScheme.primary;
            }
            return card;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return colorScheme.onPrimary;
            }
            return textPrimary;
          }),
          side: WidgetStateProperty.all(BorderSide(color: border)),
        ),
      ),

      // Chips
      chipTheme: ChipThemeData(
        backgroundColor: card,
        selectedColor: primarySoft,
        labelStyle: _inter(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          // Material 3 InputChip leaves the label transparent if labelStyle
          // is supplied without a color, so pin one here.
          color: textPrimary,
        ),
        side: BorderSide(color: border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),

      // Dividers
      dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),

      // List tiles
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        tileColor: Colors.transparent,
        selectedTileColor: primary.withAlpha(isDark ? 20 : 30),
        iconColor: textSecondary,
      ),

      // Bottom sheet
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),

      // Dialog
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titleTextStyle: _inter(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
      ),

      // Snackbar
      snackBarTheme: SnackBarThemeData(
        backgroundColor: snackBarBackground,
        contentTextStyle: _inter(color: snackBarForeground),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
      ),

      // Tab bar
      tabBarTheme: TabBarThemeData(
        labelColor: colorScheme.primary,
        unselectedLabelColor: textSecondary,
        indicatorColor: colorScheme.primary,
        indicatorSize: TabBarIndicatorSize.label,
        labelStyle: _inter(fontSize: 14, fontWeight: FontWeight.w600),
        unselectedLabelStyle: _inter(fontSize: 14, fontWeight: FontWeight.w500),
      ),

      // Progress indicators
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colorScheme.primary,
        linearTrackColor: border,
        circularTrackColor: border,
      ),

      // Icons
      iconTheme: IconThemeData(color: textSecondary, size: 24),

      // Popup menu
      popupMenuTheme: PopupMenuThemeData(
        color: card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: border),
        ),
        textStyle: _inter(fontSize: 14, color: textPrimary),
      ),

      // Expansion tile
      expansionTileTheme: ExpansionTileThemeData(
        iconColor: textSecondary,
        collapsedIconColor: textSecondary,
        textColor: textPrimary,
        collapsedTextColor: textPrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        collapsedShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),

      // Navigation bar (mobile bottom nav)
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        indicatorColor: colorScheme.primary.withAlpha(isDark ? 35 : 30),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return _inter(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? colorScheme.primary : textSecondary,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 22,
            color: selected ? colorScheme.primary : textSecondary,
          );
        }),
        elevation: isDark ? 0 : 1,
        surfaceTintColor: Colors.transparent,
      ),

      // Tooltips
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: tooltipBackground,
          borderRadius: BorderRadius.circular(8),
          border: terminalTheme == null && !isDark
              ? null
              : Border.all(color: border),
        ),
        textStyle: _inter(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: tooltipForeground,
        ),
        waitDuration: const Duration(milliseconds: 500),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),

      // Switch
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.onPrimary;
          }
          return textSecondary;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary;
          }
          return border;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return Colors.transparent;
          }
          return border.withAlpha(isDark ? 100 : 180);
        }),
      ),
    );
  }

  static PageTransitionsTheme _buildPageTransitionsTheme(Color background) =>
      PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(
            fallbackColor: background,
          ),
          TargetPlatform.iOS: const CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: const CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: ZoomPageTransitionsBuilder(
            backgroundColor: background,
          ),
          TargetPlatform.linux: ZoomPageTransitionsBuilder(
            backgroundColor: background,
          ),
        },
      );

  static TextTheme _interTextTheme(TextTheme textTheme) =>
      debugUseSystemFonts ? textTheme : textTheme.apply(fontFamily: 'Inter');

  static TextStyle _inter({
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
    double? letterSpacing,
  }) {
    if (debugUseSystemFonts) {
      return TextStyle(
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color,
        letterSpacing: letterSpacing,
      );
    }

    // Flutter 3.41+ maps fontWeight to the variable font's wght axis.
    return TextStyle(
      fontFamily: 'Inter',
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      letterSpacing: letterSpacing,
    );
  }

  static TextStyle _mono({
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
    double? letterSpacing,
  }) {
    if (debugUseSystemFonts) {
      return TextStyle(
        fontFamily: 'monospace',
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color,
        letterSpacing: letterSpacing,
      );
    }

    return TextStyle(
      fontFamily: 'JetBrains Mono',
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      letterSpacing: letterSpacing,
    );
  }

  static Color _blend(Color background, Color foreground, double amount) =>
      Color.lerp(background, foreground, amount)!;
  static Color _resolveTerminalAccent(TerminalThemeData theme) {
    // Prefer the theme's cursor color when its designer chose a strongly
    // saturated, sufficiently contrasty value. Themes that use a near-neutral
    // cursor (e.g. white-on-black) fall through to the candidate-scoring
    // fallback below so we still pick a vivid accent.
    final cursorHsl = HSLColor.fromColor(theme.cursor);
    if (cursorHsl.saturation >= 0.45 &&
        _contrastRatio(theme.cursor, theme.background) >= 2.5) {
      return theme.cursor;
    }

    final candidates = [
      theme.blue,
      theme.cyan,
      theme.magenta,
      theme.green,
      theme.brightBlue,
      theme.brightCyan,
      theme.brightMagenta,
      theme.cursor,
      theme.yellow,
      theme.red,
    ];
    var bestColor = candidates.first;
    var bestScore = double.negativeInfinity;

    for (final candidate in candidates) {
      final hsl = HSLColor.fromColor(candidate);
      final balance = 1 - (hsl.lightness - 0.5).abs();
      final score =
          _contrastRatio(candidate, theme.background) +
          (hsl.saturation * 2) +
          balance;
      if (score > bestScore) {
        bestColor = candidate;
        bestScore = score;
      }
    }

    return bestColor;
  }

  static Color _readableTextColor(Color background) =>
      _contrastRatio(Colors.white, background) >
          _contrastRatio(Colors.black, background)
      ? Colors.white
      : Colors.black;

  static double _contrastRatio(Color a, Color b) {
    final luminanceA = a.computeLuminance();
    final luminanceB = b.computeLuminance();
    final lighter = luminanceA > luminanceB ? luminanceA : luminanceB;
    final darker = luminanceA > luminanceB ? luminanceB : luminanceA;
    return (lighter + 0.05) / (darker + 0.05);
  }

  /// Monospace text style for terminal/code content.
  static TextStyle get monoStyle =>
      _mono(fontSize: 13, fontWeight: FontWeight.w400);

  /// Monospace **display** text style: the brand/identity voice for screen
  /// titles, host names, numerals, and status badges.
  ///
  /// JetBrains Mono at title scale is the signature of the design system; use
  /// this where a surface announces what it is. Keep dense, explanatory body
  /// text in the Inter-based [TextTheme] styles instead.
  static TextStyle displayMono({
    double fontSize = 20,
    FontWeight fontWeight = FontWeight.w600,
    Color? color,
    double letterSpacing = -0.5,
  }) => _mono(
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
    letterSpacing: letterSpacing,
  );
}
