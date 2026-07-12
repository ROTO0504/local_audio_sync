import 'package:flutter/material.dart';

/// M3 の `ColorScheme` に存在しない「状態色」をまとめた ThemeExtension。
///
/// 接続状態(検索中/接続中/接続済み/切断/一時停止)や VU メーターの色を、
/// 各ウィジェットにハードコードするのではなくテーマ経由で解決するために使う。
/// `Theme.of(context).extension<AppStatusColors>()!` で参照する。
@immutable
class AppStatusColors extends ThemeExtension<AppStatusColors> {
  /// 検索中(Hub を探索している)。
  final Color searching;

  /// 接続処理中 / 再接続試行中。
  final Color connecting;

  /// 接続済み(正常)。
  final Color connected;

  /// 切断 / 接続失敗。
  final Color disconnected;

  /// 一時停止中(Hub からの pause など)。
  final Color paused;

  /// 注意喚起(品質劣化など致命的ではない警告)。
  final Color warning;

  /// VU レベル低(通常音量)。
  final Color vuLow;

  /// VU レベル中(やや大きい)。
  final Color vuMid;

  /// VU レベル高(クリップ寸前)。
  final Color vuHigh;

  /// VU メーターの背景トラック。
  final Color vuTrack;

  const AppStatusColors({
    required this.searching,
    required this.connecting,
    required this.connected,
    required this.disconnected,
    required this.paused,
    required this.warning,
    required this.vuLow,
    required this.vuMid,
    required this.vuHigh,
    required this.vuTrack,
  });

  static const light = AppStatusColors(
    searching: Color(0xFFF59E0B),
    connecting: Color(0xFF2563EB),
    connected: Color(0xFF16A34A),
    disconnected: Color(0xFFDC2626),
    paused: Color(0xFFEA580C),
    warning: Color(0xFFD97706),
    vuLow: Color(0xFF22C55E),
    vuMid: Color(0xFFF59E0B),
    vuHigh: Color(0xFFEF4444),
    vuTrack: Color(0xFFE2E8F0),
  );

  static const dark = AppStatusColors(
    searching: Color(0xFFFBBF24),
    connecting: Color(0xFF60A5FA),
    connected: Color(0xFF4ADE80),
    disconnected: Color(0xFFF87171),
    paused: Color(0xFFFB923C),
    warning: Color(0xFFFBBF24),
    vuLow: Color(0xFF4ADE80),
    vuMid: Color(0xFFFBBF24),
    vuHigh: Color(0xFFF87171),
    vuTrack: Color(0xFF334155),
  );

  @override
  AppStatusColors copyWith({
    Color? searching,
    Color? connecting,
    Color? connected,
    Color? disconnected,
    Color? paused,
    Color? warning,
    Color? vuLow,
    Color? vuMid,
    Color? vuHigh,
    Color? vuTrack,
  }) {
    return AppStatusColors(
      searching: searching ?? this.searching,
      connecting: connecting ?? this.connecting,
      connected: connected ?? this.connected,
      disconnected: disconnected ?? this.disconnected,
      paused: paused ?? this.paused,
      warning: warning ?? this.warning,
      vuLow: vuLow ?? this.vuLow,
      vuMid: vuMid ?? this.vuMid,
      vuHigh: vuHigh ?? this.vuHigh,
      vuTrack: vuTrack ?? this.vuTrack,
    );
  }

  @override
  AppStatusColors lerp(ThemeExtension<AppStatusColors>? other, double t) {
    if (other is! AppStatusColors) return this;
    return AppStatusColors(
      searching: Color.lerp(searching, other.searching, t)!,
      connecting: Color.lerp(connecting, other.connecting, t)!,
      connected: Color.lerp(connected, other.connected, t)!,
      disconnected: Color.lerp(disconnected, other.disconnected, t)!,
      paused: Color.lerp(paused, other.paused, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      vuLow: Color.lerp(vuLow, other.vuLow, t)!,
      vuMid: Color.lerp(vuMid, other.vuMid, t)!,
      vuHigh: Color.lerp(vuHigh, other.vuHigh, t)!,
      vuTrack: Color.lerp(vuTrack, other.vuTrack, t)!,
    );
  }
}

/// `BuildContext` から状態色へ手短にアクセスするための拡張。
extension AppStatusColorsX on BuildContext {
  AppStatusColors get statusColors =>
      Theme.of(this).extension<AppStatusColors>() ?? AppStatusColors.light;
}
