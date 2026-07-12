import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'app_spacing.dart';

/// アプリのライト/ダークテーマを一元的に組み立てる。
///
/// 従来は `app.dart` にインラインで `ColorScheme.fromSeed(blueAccent)` のみを
/// 持っていた。ここへ移し、両モードのカラースキーム・状態色 ThemeExtension・
/// コンポーネントテーマ(AppBar/Card/Slider/Chip/FilledButton)を集約する。
abstract final class AppTheme {
  /// ブランドのシード色。ライト/ダーク双方の ColorScheme をここから生成する。
  static const Color brandSeed = Color(0xFF3D5AFE);

  static ThemeData light() => _build(Brightness.light, AppStatusColors.light);
  static ThemeData dark() => _build(Brightness.dark, AppStatusColors.dark);

  static ThemeData _build(Brightness brightness, AppStatusColors statusColors) {
    final scheme = ColorScheme.fromSeed(
      seedColor: brandSeed,
      brightness: brightness,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      extensions: [statusColors],
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 2,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        margin: EdgeInsets.zero,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.allM),
        clipBehavior: Clip.antiAlias,
      ),
      chipTheme: ChipThemeData(
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.allL),
        side: BorderSide.none,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s),
      ),
      sliderTheme: const SliderThemeData(
        trackHeight: 3,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.allS),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.l,
            vertical: AppSpacing.s + 2,
          ),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: AppSpacing.m,
      ),
    );
  }
}
