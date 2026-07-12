import 'package:flutter/widgets.dart';

/// アプリ全体で使う間隔(余白/ギャップ)の定数。
///
/// 従来は各画面に `SizedBox(height: 8/12/24)` や `EdgeInsets.all(16/24/32)` が
/// 直書きで散在していた。ここへ集約し、画面間で一貫した間隔リズムを保つ。
abstract final class AppSpacing {
  static const double xs = 4;
  static const double s = 8;
  static const double m = 16;
  static const double l = 24;
  static const double xl = 32;

  // よく使う組み合わせのショートカット。
  static const EdgeInsets screenPadding = EdgeInsets.all(m);
  static const EdgeInsets cardPadding = EdgeInsets.all(m);
  static const SizedBox gapXs = SizedBox(height: xs, width: xs);
  static const SizedBox gapS = SizedBox(height: s, width: s);
  static const SizedBox gapM = SizedBox(height: m, width: m);
  static const SizedBox gapL = SizedBox(height: l, width: l);
}

/// 角丸半径の定数。
abstract final class AppRadius {
  static const double s = 8;
  static const double m = 12;
  static const double l = 20;

  static const BorderRadius allS = BorderRadius.all(Radius.circular(s));
  static const BorderRadius allM = BorderRadius.all(Radius.circular(m));
  static const BorderRadius allL = BorderRadius.all(Radius.circular(l));
}
