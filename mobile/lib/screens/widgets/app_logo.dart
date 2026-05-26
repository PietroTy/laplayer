import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme.dart';

/// Logo do لاplayer com cor dinâmica baseada no tema atual.
/// O círculo usa a cor accent do tema; o símbolo (لا) é exibido em branco.
class AppLogo extends ConsumerWidget {
  final double size;
  final bool showText;
  final double? fontSize;
  final Color? circleColor;   // override manual opcional
  final Color? symbolColor;   // override manual opcional
  final double textGap;
  final double? textFontSize;
  final bool hasBorder;

  const AppLogo({
    super.key,
    this.size = 24.0,
    this.showText = false,
    this.fontSize,
    this.circleColor,
    this.symbolColor,
    this.textGap = 8.0,
    this.textFontSize,
    this.hasBorder = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ref.watch(themePaletteProvider);
    final bgColor     = circleColor ?? palette.logoCircleBg;
    final glyphColor  = symbolColor ?? palette.logoSymbol;

    // Ícone: círculo colorido com o símbolo branco por cima
    final logoWidget = Container(
      width:  size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: bgColor,
        border: hasBorder
            ? Border.all(color: bgColor.withOpacity(0.35), width: size * 0.04)
            : null,
      ),
      child: Center(
        child: Image.asset(
          'assets/app_logo_glyph.png',
          width:  size * 0.58,
          height: size * 0.58,
          color:  glyphColor,
          fit: BoxFit.contain,
        ),
      ),
    );

    if (!showText) return logoWidget;

    final glyphHeight = textFontSize ?? (size * 0.85);
    final glyphWidth  = glyphHeight * (123.0 / 176.0);

    // Glyph لا ao lado do texto "player" — usa accent do tema
    final textGlyphWidget = Image.asset(
      'assets/app_logo_glyph.png',
      width:  glyphWidth,
      height: glyphHeight,
      color:  palette.accent,
      fit: BoxFit.contain,
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        logoWidget,
        SizedBox(width: textGap),
        textGlyphWidget,
        const SizedBox(width: 2.0),
        Text(
          'player',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: textFontSize ?? (size * 0.85),
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
      ],
    );
  }
}
