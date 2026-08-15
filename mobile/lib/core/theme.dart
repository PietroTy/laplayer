import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppThemePalette {
  purplish("Purplish", Color(0xFFBB86FC), Color(0xFF7B2CBF), Color(0xFF120E24)),
  spotifake("Spotifake", Color(0xFF1ED760), Color(0xFF158A3E), Color(0xFF090909)),
  stargaze("Stargaze", Color(0xFFFFD700), Color(0xFFFFA000), Color(0xFF0E1428)),
  burntSienna("Burnt Sienna", Color(0xFFE07A5F), Color(0xFFB04A33), Color(0xFF1E120E)),
  oceanBreeze("Ocean Breeze", Color(0xFF00F5FF), Color(0xFF00868B), Color(0xFF091C28)),
  sakuraPink("Sakura Pink", Color(0xFFFF80AB), Color(0xFFC51162), Color(0xFF220E18)),
  dracula("Dracula", Color(0xFFFF5555), Color(0xFFBD2022), Color(0xFF282A36)),
  omni("Omni", Color(0xFF00E5C3), Color(0xFF0097A7), Color(0xFF0F1B22)),
  noir("Noir", Color(0xFFE8E8E8), Color(0xFF9E9E9E), Color(0xFF000000)),
  ultraviolet("Ultraviolet", Color(0xFFD500FF), Color(0xFF8B00C7), Color(0xFF1A0730));

  final String name;
  final Color accent;
  final Color accentDim;
  final Color bg;

  const AppThemePalette(this.name, this.accent, this.accentDim, this.bg);

  /// Cor de fundo do círculo do logo (padrão: accent do tema)
  Color get logoCircleBg => this == AppThemePalette.noir ? Colors.black : accent;

  /// Cor do símbolo dentro do círculo do logo
  Color get logoSymbol => this == AppThemePalette.noir ? Colors.white : Colors.black;

  /// Cores para fundo dégradé suave do tema
  List<Color>? get bgGradientColors {
    switch (this) {
      case AppThemePalette.purplish:
        return const [Color(0xFF241442), Color(0xFF140D28), Color(0xFF080512)];
      case AppThemePalette.stargaze:
        return const [Color(0xFF1A284D), Color(0xFF0E1528), Color(0xFF060914)];
      case AppThemePalette.oceanBreeze:
        return const [Color(0xFF0E3850), Color(0xFF091C28), Color(0xFF040E14)];
      case AppThemePalette.sakuraPink:
        return const [Color(0xFF42162F), Color(0xFF220E18), Color(0xFF0F050B)];
      case AppThemePalette.omni:
        return const [Color(0xFF163444), Color(0xFF0F1B22), Color(0xFF070D11)];
      case AppThemePalette.burntSienna:
        return const [Color(0xFF351C16), Color(0xFF1E120E), Color(0xFF0C0705)];
      case AppThemePalette.ultraviolet:
        return const [Color(0xFF33094E), Color(0xFF1A0730), Color(0xFF0B0215)];
      default:
        return null;
    }
  }

  LinearGradient? get bgGradient {
    final colors = bgGradientColors;
    if (colors == null) return null;
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: colors,
    );
  }
}

/// Paleta de cores do Localify (valores mutáveis para suportar temas dinâmicos)
abstract class AppColors {
  // ── Backgrounds ────────────────────────────────────────────────────────
  static Color bg           = const Color(0xFF0D0B18);  // Purplish por padrão
  static LinearGradient? bgGradient;                     // Fundo dégradé se ativado
  static const Color surface      = Color(0xFF141414);  // Cards e bottom sheets
  static const Color surfaceHigh  = Color(0xFF1E1E1E);  // Elementos elevados
  static const Color border = Color(0xFF2A2A2A);

  // ── Acento primário ───────────────────────────────────────────────────
  static Color accent       = const Color(0xFFBB86FC);  // Purplish por padrão
  static Color accentDim    = const Color(0xFF7B2CBF);  // Purplish por padrão

  // ── Texto ─────────────────────────────────────────────────────────────
  static const Color textPrimary  = Color(0xFFFFFFFF);
  static const Color textSecond   = Color(0xFFB3B3B3);
  static const Color textMuted    = Color(0xFF6B6B6B);

  // ── Extras ────────────────────────────────────────────────────────────
  static const Color error        = Color(0xFFFF4444);
  static const Color warning      = Color(0xFFFFB800);

  // ── Efeitos (Glassmorfismo) ───────────────────────────────────────────
  static Color get glassSurface => surface.withValues(alpha: 0.6);
  static Color get glassSurfaceHigh => surfaceHigh.withValues(alpha: 0.75);
  
  // Sombra elegante padrão
  static List<BoxShadow> get premiumShadow => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.3),
          blurRadius: 20,
          offset: const Offset(0, 10),
        )
      ];
}

final themePaletteProvider = StateNotifierProvider<ThemePaletteNotifier, AppThemePalette>((ref) {
  return ThemePaletteNotifier();
});

class ThemePaletteNotifier extends StateNotifier<AppThemePalette> {
  // Aceita um palette inicial (passado pelo main.dart após pré-carregamento)
  ThemePaletteNotifier([AppThemePalette initial = AppThemePalette.purplish])
      : super(initial);

  Future<void> setTheme(AppThemePalette palette) async {
    state = palette;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('theme_palette_index', palette.index);
    _updateAppColors(palette);
  }

  void _updateAppColors(AppThemePalette palette) {
    AppColors.bg = palette.bg;
    AppColors.bgGradient = palette.bgGradient;
    AppColors.accent = palette.accent;
    AppColors.accentDim = palette.accentDim;
  }
}

class AppBackground extends StatelessWidget {
  final Widget child;
  const AppBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final gradient = AppColors.bgGradient;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.bg,
        gradient: gradient,
      ),
      child: child,
    );
  }
}

class AppTheme {
  static ThemeData dark(AppThemePalette palette) {
    final base = ThemeData.dark(useMaterial3: true);

    return base.copyWith(
      scaffoldBackgroundColor: palette.bg,
      colorScheme: ColorScheme.dark(
        primary:        palette.accent,
        secondary:      palette.accentDim,
        surface:        AppColors.surface,
        error:          AppColors.error,
        onPrimary:      Colors.black,
        onSecondary:    Colors.white,
        onSurface:      AppColors.textPrimary,
        onError:        Colors.white,
      ),
      textTheme: GoogleFonts.dmSansTextTheme(base.textTheme).copyWith(
        displayLarge: GoogleFonts.dmSans(
          color: AppColors.textPrimary, fontSize: 32, fontWeight: FontWeight.w700, letterSpacing: -1.0,
        ),
        displayMedium: GoogleFonts.dmSans(
          color: AppColors.textPrimary, fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: -0.5,
        ),
        headlineMedium: GoogleFonts.dmSans(
          color: AppColors.textPrimary, fontSize: 20, fontWeight: FontWeight.w600,
        ),
        titleLarge: GoogleFonts.dmSans(
          color: AppColors.textPrimary, fontSize: 17, fontWeight: FontWeight.w600,
        ),
        titleMedium: GoogleFonts.dmSans(
          color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w500,
        ),
        bodyLarge: GoogleFonts.dmSans(
          color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w400,
        ),
        bodyMedium: GoogleFonts.dmSans(
          color: AppColors.textSecond, fontSize: 13, fontWeight: FontWeight.w400,
        ),
        bodySmall: GoogleFonts.dmSans(
          color: AppColors.textMuted, fontSize: 11, fontWeight: FontWeight.w400,
        ),
        labelLarge: GoogleFonts.dmSans(
          color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 0.5,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: palette.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: GoogleFonts.dmSans(
          color: AppColors.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: AppColors.surface,
        selectedItemColor: palette.accent,
        unselectedItemColor: AppColors.textMuted,
        type: BottomNavigationBarType.fixed,
        showSelectedLabels: true,
        showUnselectedLabels: true,
        elevation: 0,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: palette.accent,
        inactiveTrackColor: AppColors.surfaceHigh,
        thumbColor: palette.accent,
        overlayColor: palette.accent.withValues(alpha: 0.15),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        trackHeight: 3,
      ),
      cardTheme: const CardThemeData(
        color: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.border,
        thickness: 1,
        space: 1,
      ),
      iconTheme: const IconThemeData(color: AppColors.textSecond, size: 22),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: palette.accent,
          foregroundColor: Colors.black,
          textStyle: GoogleFonts.dmSans(fontSize: 14, fontWeight: FontWeight.w700),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(50)),
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
          elevation: 0,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: palette.accent),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceHigh,
        hintStyle: GoogleFonts.dmSans(color: AppColors.textMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    );
  }

  static InputDecoration inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      filled: true,
      fillColor: AppColors.surfaceHigh,
      hintStyle: GoogleFonts.dmSans(color: AppColors.textMuted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    );
  }
}
