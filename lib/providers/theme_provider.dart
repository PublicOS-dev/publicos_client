import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:publicos_client/theme/glass_theme.dart';

class ThemeProvider with ChangeNotifier {
  static const String _themeKey = 'theme_mode';
  bool _isDarkMode = true;

  // ============================================
  // Civic Modernism Color Palette
  // ============================================

  // Slate/Concrete range - maturity and structure
  static const Color slateDarkest = Color(0xFF1e2328);
  static const Color slateDark = Color(0xFF2d3339);
  static const Color slateMid = Color(0xFF4a5568);
  static const Color slateLight = Color(0xFF718096);
  static const Color slateLighter = Color(0xFFa0aec0);
  static const Color slateLightest = Color(0xFFf4f6f8);

  // International Teal - primary action, trustworthy
  static const Color tealPrimary = Color(0xFF0f766e);
  static const Color tealLight = Color(0xFF14b8a6);
  static const Color tealDark = Color(0xFF0d6b63);

  // Warm Amber - secondary accent, human connection
  static const Color amberAccent = Color(0xFFd97706);
  static const Color amberLight = Color(0xFFf59e0b);
  static const Color amberDark = Color(0xFFb45309);

  // Alabaster/Paper - off-white backgrounds
  static const Color paperWhite = Color(0xFFfafbfc);
  static const Color paperLight = Color(0xFFf5f6f7);
  static const Color paperMid = Color(0xFFedf2f7);

  // Semantic colors (not overridden by accent)
  static const Color errorLight = Color(0xFFdc2626);
  static const Color errorDark = Color(0xFFf87171);
  static const Color successLight = Color(0xFF16a34a);
  static const Color successDark = Color(0xFF4ade80);
  static const Color warningLight = Color(0xFFea580c);
  static const Color warningDark = Color(0xFFfb923c);

  ThemeProvider() {
    loadThemePreference();
  }

  bool get isDarkMode => _isDarkMode;
  ThemeMode get themeMode => _isDarkMode ? ThemeMode.dark : ThemeMode.light;

  Future<void> loadThemePreference() async {
    final prefs = await SharedPreferences.getInstance();
    _isDarkMode = prefs.getBool(_themeKey) ?? true;
    notifyListeners();
  }

  Future<void> toggleTheme() async {
    _isDarkMode = !_isDarkMode;
    notifyListeners();
    _saveThemePreference();
  }

  Future<void> _saveThemePreference() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_themeKey, _isDarkMode);
  }

  // ============================================
  // Info semantic color (for informational badges, links, etc.)
  // ============================================
  static const Color infoLight = Color(0xFF0284c7);
  static const Color infoDark = Color(0xFF38bdf8);


  ThemeData getLightTheme() => GlassTheme.lightTheme;
  ThemeData getDarkTheme() => GlassTheme.darkTheme;
}

// ============================================
// Phigital Design System Tokens & Helpers
// ============================================

class PhigitalStyle {
  PhigitalStyle._();

  // ── Canonical border radii ──
  static const double radiusSheet = 20.0;
  static const double radiusCard = 14.0;
  static const double radiusButton = 8.0;
  /// Icon/avatar radius as 18% of size
  static double radiusIcon(double size) => size * 0.18;

  // ── Surface colors ──
  static const Color cardBackgroundDark = Color(0xFF2a3038);
  static const Color cardBackgroundLight = Color(0xFFF8F9FB);
  static const Color cardBorderDark = Color(0xFF3d454f);
  static const Color cardBorderLight = Color(0xFFE8EAED);

  /// Deeper surface for heavy containers (e.g. select account screen)
  static const Color surfaceDeepDark = Color(0xFF15181c);

  /// Deep teal for teal-heavy containers
  static const Color tealDeep = Color(0xFF0a524c);

  static Color cardBackground(bool isDark) =>
      isDark ? cardBackgroundDark : cardBackgroundLight;

  static Color cardBorder(bool isDark) =>
      isDark ? cardBorderDark : cardBorderLight;

  // ── Hard shadows (blurRadius: 0 always) ──
  static List<BoxShadow> cardShadow(bool isDark) => [
        BoxShadow(
          color: isDark
              ? Colors.black.withValues(alpha: 0.4)
              : const Color(0xFF1e2328).withValues(alpha: 0.06),
          offset: const Offset(0, 3),
          blurRadius: 0,
        ),
      ];

  static List<BoxShadow> smallShadow(bool isDark) => [
        BoxShadow(
          color: isDark
              ? Colors.black.withValues(alpha: 0.8)
              : const Color(0xFF1e2328).withValues(alpha: 0.12),
          offset: const Offset(0, 2),
          blurRadius: 0,
        ),
      ];

  static List<BoxShadow> sheetShadow(bool isDark) => [
        BoxShadow(
          color: isDark
              ? Colors.black.withValues(alpha: 0.5)
              : const Color(0xFF1e2328).withValues(alpha: 0.08),
          offset: const Offset(0, -4),
          blurRadius: 0,
        ),
      ];

  static List<BoxShadow> iconShadow(bool isDark) => [
        BoxShadow(
          color: isDark
              ? Colors.black.withValues(alpha: 0.4)
              : const Color(0xFF1e2328).withValues(alpha: 0.08),
          offset: const Offset(0, 4),
          blurRadius: 0,
        ),
      ];

  // ── Decoration helpers ──
  static BoxDecoration cardDecoration(bool isDark) => BoxDecoration(
        color: cardBackground(isDark),
        borderRadius: BorderRadius.circular(radiusCard),
        border: Border.all(color: cardBorder(isDark), width: 1),
        boxShadow: cardShadow(isDark),
      );

  static BoxDecoration sheetDecoration(bool isDark) => BoxDecoration(
        color: cardBackground(isDark),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(radiusSheet)),
        border: Border.all(color: cardBorder(isDark), width: 1),
        boxShadow: sheetShadow(isDark),
      );

  // ── Subtle surface tints for nested elements ──
  static Color subtleTint(bool isDark) => isDark
      ? Colors.black.withValues(alpha: 0.15)
      : const Color(0xFF1e2328).withValues(alpha: 0.03);

  static Color subtleBorder(bool isDark) => isDark
      ? Colors.white.withValues(alpha: 0.08)
      : const Color(0xFF1e2328).withValues(alpha: 0.06);

  // ── User-selectable accent color presets ──
  //
  // The chat bubble paints this record at FULL OPACITY (`message_widget.dart`
  // `_bubbleFill`), so the swatch the user taps is literally the bubble they
  // get. Do not paint it as an alpha tint over `tokens.background`: a
  // `withValues(alpha: 0.22)` tint caps bubble luminance at ~24%, turns white
  // into grey, and flattens every dark tone to the same near-black smudge.
  //
  // What DOES constrain this list:
  //
  //  1. Foreground. `_bubbleFg` picks pure black or pure white by whichever
  //     contrasts more (crossover at relative luminance 0.179). That is
  //     >= 4.5:1 against *any* fill, so no color can fail WCAG AA — but only
  //     because the pick is max-contrast. A naive `luminance < 0.5` midpoint
  //     would fail 23 of these. Don't "simplify" _bubbleFg.
  //  2. Distinctness. Every pair here is >= 11 CIELAB dE apart, so the picker
  //     never offers two colors the eye can't separate. Full opacity means the
  //     bubbles are now exactly as distinct as the swatches.
  //  3. Distance from the page background (rgb 6,6,10). Nothing here is within
  //     dE 18 of it, so no bubble dissolves into the scaffold.
  //
  // Deduping to (2) cost most of `rose` (a duplicate of `red`), plus a handful
  // of 900/100 tones that collided with their neighbours. The same list feeds
  // `xmtp_contact_settings.dart` and the full-opacity profile text-card fill in
  // `create_record_page.dart`, both of which want exactly these semantics.
  //
  // Legacy values still render — they're just stored ints. They're only gone
  // from the picker.
  //
  // Ordered by hue family, each family stepping dark -> light, neutrals last,
  // so the edge-to-edge strip in the Account app reads as a gradient sweep.
  static const List<Color> colorPresets = [
    // Hue sweep, snaked: families run red -> rose, and every other one is
    // listed light -> dark so the brightness carries across the boundary
    // instead of resetting, so the strip reads like a rainbow.
    // Red (dark -> light)
    Color(0xFF7f1d1d), Color(0xFFef4444), Color(0xFFfca5a5), Color(0xFFfee2e2),
    // Orange (light -> dark)
    Color(0xFFffedd5), Color(0xFFfdba74), Color(0xFFf97316), Color(0xFF7c2d12),
    // Amber (dark -> light)
    Color(0xFFf59e0b), Color(0xFFfcd34d),
    // Lime (light -> dark)
    Color(0xFFecfccb), Color(0xFFbef264), Color(0xFF84cc16), Color(0xFF365314),
    // Green (dark -> light)
    Color(0xFF14532d), Color(0xFF22c55e), Color(0xFF86efac), Color(0xFFdcfce7),
    // Teal (light -> dark)
    Color(0xFF5eead4), Color(0xFF14b8a6), Color(0xFF134e4a),
    // Cyan (dark -> light)
    Color(0xFF164e63), Color(0xFF06b6d4), Color(0xFF67e8f9), Color(0xFFcffafe),
    // Blue (light -> dark)
    Color(0xFFdbeafe), Color(0xFF93c5fd), Color(0xFF3b82f6), Color(0xFF1e3a8a),
    // Indigo (dark -> light)
    Color(0xFF6366f1), Color(0xFFa5b4fc),
    // Violet (light -> dark)
    Color(0xFF8b5cf6), Color(0xFF4c1d95),
    // Fuchsia (dark -> light)
    Color(0xFF701a75), Color(0xFFd946ef), Color(0xFFf0abfc), Color(0xFFfae8ff),
    // Pink (light -> dark)
    Color(0xFFf9a8d4), Color(0xFFec4899), Color(0xFF831843),
    // Rose (dark -> light)
    Color(0xFFf43f5e),
    // Neutrals, dim -> bright
    Color(0xFF1e293b), Color(0xFF475569), Color(0xFF64748b),
    Color(0xFF94a3b8), Color(0xFFf8fafc),
  ];

  // ── Handle bar widget for bottom sheets ──
  static Widget handleBar(bool isDark) => Center(
        child: Container(
          width: 36,
          height: 4,
          margin: const EdgeInsets.only(top: 10, bottom: 8),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.2)
                : const Color(0xFF1e2328).withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );
}