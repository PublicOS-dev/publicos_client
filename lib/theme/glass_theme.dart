import 'package:flutter/material.dart';

/// Theme extension holding glass-specific color tokens.
///
/// Read via `GlassTokens.of(context)` inside a `build` method.
/// Dark mode is the original "glass" aesthetic; light mode is a near-white
/// mirror that keeps the same structural tokens so widgets don't need to
/// branch on brightness.
class GlassTokens extends ThemeExtension<GlassTokens> {
  final Color background;
  final Color surfaceDeep;
  final Color surfaceElevated;
  final Color starkWhite;
  final Color neonAccent;
  final Color borderSubtle;
  final Color borderMedium;
  final Color textDim;
  final Color glassFill;
  final Color glassFillHover;
  final Color glassShadow;
  final Color connectedAccent;
  final Color fallbackAccent;

  /// Soft "remove / destructive" red — chip X badges, remove affordances.
  /// Deliberately muted (never the theme errorColor) so it reads as a quiet
  /// control, not an alarm.
  final Color softDanger;

  const GlassTokens({
    required this.background,
    required this.surfaceDeep,
    required this.surfaceElevated,
    required this.starkWhite,
    required this.neonAccent,
    required this.borderSubtle,
    required this.borderMedium,
    required this.textDim,
    required this.glassFill,
    required this.glassFillHover,
    required this.glassShadow,
    required this.connectedAccent,
    required this.fallbackAccent,
    required this.softDanger,
  });

  static const GlassTokens dark = GlassTokens(
    background: Color.fromARGB(255, 22, 22, 22),
    surfaceDeep: Color(0xFF0A0A0A),
    surfaceElevated: Color(0xFF141414),
    starkWhite: Color(0xFFFFFFFF),
    neonAccent: Color(0xFFFFFFFF),
    // EXPERIMENT: halfway between the old 10% white and the background.
    // borderSubtle: Color(0x1AFFFFFF),
    borderSubtle: Color(0x0DFFFFFF),
    borderMedium: Color(0x33FFFFFF),
    textDim: Color(0x99FFFFFF),
    glassFill: Color(0x0AFFFFFF),
    glassFillHover: Color(0x14FFFFFF),
    glassShadow: Color(0x80000000),
    connectedAccent: Color(0xFF64FFDA),
    fallbackAccent: Color(0xFFFFAB40),
    softDanger: Color(0xFFD25C5C),
  );

  static const GlassTokens light = GlassTokens(
    background: Color(0xFFF5F6F8),
    surfaceDeep: Color(0xFFEEEFF2),
    surfaceElevated: Color(0xFFE3E5EA),
    starkWhite: Color(0xFF0A0A0A),
    neonAccent: Color(0xFF0A0A0A),
    borderSubtle: Color(0x14000000),
    borderMedium: Color(0x29000000),
    textDim: Color(0x99000000),
    glassFill: Color(0x0A000000),
    glassFillHover: Color(0x14000000),
    glassShadow: Color(0x29000000),
    connectedAccent: Color(0xFF00796B),
    fallbackAccent: Color(0xFFBF5F00),
    softDanger: Color(0xFFB54747),
  );

  static GlassTokens of(BuildContext context) =>
      Theme.of(context).extension<GlassTokens>() ?? dark;

  @override
  GlassTokens copyWith({
    Color? background,
    Color? surfaceDeep,
    Color? surfaceElevated,
    Color? starkWhite,
    Color? neonAccent,
    Color? borderSubtle,
    Color? borderMedium,
    Color? textDim,
    Color? glassFill,
    Color? glassFillHover,
    Color? glassShadow,
    Color? connectedAccent,
    Color? fallbackAccent,
    Color? softDanger,
  }) {
    return GlassTokens(
      background: background ?? this.background,
      surfaceDeep: surfaceDeep ?? this.surfaceDeep,
      surfaceElevated: surfaceElevated ?? this.surfaceElevated,
      starkWhite: starkWhite ?? this.starkWhite,
      neonAccent: neonAccent ?? this.neonAccent,
      borderSubtle: borderSubtle ?? this.borderSubtle,
      borderMedium: borderMedium ?? this.borderMedium,
      textDim: textDim ?? this.textDim,
      glassFill: glassFill ?? this.glassFill,
      glassFillHover: glassFillHover ?? this.glassFillHover,
      glassShadow: glassShadow ?? this.glassShadow,
      connectedAccent: connectedAccent ?? this.connectedAccent,
      fallbackAccent: fallbackAccent ?? this.fallbackAccent,
      softDanger: softDanger ?? this.softDanger,
    );
  }

  @override
  GlassTokens lerp(ThemeExtension<GlassTokens>? other, double t) {
    if (other is! GlassTokens) return this;
    return GlassTokens(
      background: Color.lerp(background, other.background, t)!,
      surfaceDeep: Color.lerp(surfaceDeep, other.surfaceDeep, t)!,
      surfaceElevated: Color.lerp(surfaceElevated, other.surfaceElevated, t)!,
      starkWhite: Color.lerp(starkWhite, other.starkWhite, t)!,
      neonAccent: Color.lerp(neonAccent, other.neonAccent, t)!,
      borderSubtle: Color.lerp(borderSubtle, other.borderSubtle, t)!,
      borderMedium: Color.lerp(borderMedium, other.borderMedium, t)!,
      textDim: Color.lerp(textDim, other.textDim, t)!,
      glassFill: Color.lerp(glassFill, other.glassFill, t)!,
      glassFillHover: Color.lerp(glassFillHover, other.glassFillHover, t)!,
      glassShadow: Color.lerp(glassShadow, other.glassShadow, t)!,
      connectedAccent: Color.lerp(connectedAccent, other.connectedAccent, t)!,
      fallbackAccent: Color.lerp(fallbackAccent, other.fallbackAccent, t)!,
      softDanger: Color.lerp(softDanger, other.softDanger, t)!,
    );
  }
}

const _fontFamily = 'SpaceGrotesk';

/// Theme builders + reusable glass decorations.
///
/// `GlassTheme.darkTheme` / `GlassTheme.lightTheme` return fully-configured
/// `ThemeData` including the `GlassTokens` extension for each mode.
/// `GlassTheme.glassBox(context)` and `.glassBoxHover(context)` return the
/// shared glass-card decoration used across the app.
class GlassTheme {
  GlassTheme._();

  static ThemeData get darkTheme => _build(
        brightness: Brightness.dark,
        tokens: GlassTokens.dark,
        base: Typography.material2021().white,
        errorColor: const Color(0xFFFF453A),
      );

  static ThemeData get lightTheme => _build(
        brightness: Brightness.light,
        tokens: GlassTokens.light,
        base: Typography.material2021().black,
        errorColor: const Color(0xFFD70015),
      );

  static ThemeData _build({
    required Brightness brightness,
    required GlassTokens tokens,
    required TextTheme base,
    required Color errorColor,
  }) {
    final textTheme = base
        .apply(
          fontFamily: _fontFamily,
          bodyColor: tokens.starkWhite,
          displayColor: tokens.starkWhite,
        );

    final colorScheme = brightness == Brightness.dark
        ? ColorScheme.dark(
            primary: tokens.neonAccent,
            secondary: tokens.neonAccent,
            surface: tokens.surfaceDeep,
            error: errorColor,
            onPrimary: tokens.background,
            onSecondary: tokens.background,
            onSurface: tokens.starkWhite,
            onError: tokens.starkWhite,
          )
        : ColorScheme.light(
            primary: tokens.neonAccent,
            secondary: tokens.neonAccent,
            surface: tokens.surfaceDeep,
            error: errorColor,
            onPrimary: tokens.background,
            onSecondary: tokens.background,
            onSurface: tokens.starkWhite,
            onError: tokens.background,
          );

    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: tokens.background,
      primaryColor: tokens.neonAccent,
      colorScheme: colorScheme,
      textTheme: textTheme,
      extensions: [tokens],
      cardTheme: CardThemeData(
        color: tokens.surfaceElevated,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: tokens.borderSubtle, width: 1),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: tokens.starkWhite),
        titleTextStyle: TextStyle(
          fontFamily: _fontFamily,
          color: tokens.starkWhite,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: tokens.surfaceElevated,
        contentTextStyle: TextStyle(
          fontFamily: _fontFamily,
          color: tokens.starkWhite,
          fontSize: 13,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.3,
        ),
        actionTextColor: tokens.starkWhite,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: tokens.borderSubtle, width: 1),
        ),
        insetPadding: const EdgeInsets.symmetric(
          horizontal: 48,
          vertical: 24,
        ),
      ),
    );
  }

  static BoxDecoration glassBox(BuildContext context) {
    final tokens = GlassTokens.of(context);
    return BoxDecoration(
      color: tokens.glassFill,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: tokens.borderSubtle, width: 1),
      boxShadow: [
        BoxShadow(
          color: tokens.glassShadow,
          offset: const Offset(0, 4),
          blurRadius: 12,
        ),
      ],
    );
  }

  static BoxDecoration glassBoxHover(BuildContext context) {
    final tokens = GlassTokens.of(context);
    return BoxDecoration(
      color: tokens.glassFillHover,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: tokens.borderMedium, width: 1.5),
      boxShadow: [
        BoxShadow(
          color: tokens.neonAccent.withValues(alpha: 0.15),
          offset: const Offset(0, 4),
          blurRadius: 16,
        ),
      ],
    );
  }
}

/// Dialog widths. Every one is a MAX
/// width; narrow screens shrink it. S confirm · M form / picker / reveal ·
/// L settings / readers · XL editors / managers · W a window inside the window.
class DialogWidth {
  static const double s = 400;
  static const double m = 480;
  static const double l = 560;
  static const double xl = 720;
  static const double w = 900;

  /// Flutter's own floor for a dialog (`BoxConstraints(minWidth: 280)`).
  /// Setting `constraints:` on an AlertDialog replaces that default, so the
  /// AlertDialog sites pass it back alongside their max.
  static const double min = 280;
}
