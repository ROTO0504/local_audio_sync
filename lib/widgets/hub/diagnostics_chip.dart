import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/client_diagnostics.dart';
import '../../providers/hub_diagnostics_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';

/// クライアント1台の接続品質診断を小さくまとめて表示するチップ。
///
/// [hubDiagnosticsProvider] から uuid で [ClientDiagnostics] を引き、
///   - ロス率(緑 <1% / 橙 <5% / 赤)
///   - 再同期回数
///   - バッファ深(フレーム数)
///   - 最終受信からの経過(10秒超で警告色)
/// を横並びで示す。診断が無ければ何も描画しない。
class DiagnosticsChip extends ConsumerWidget {
  final String uuid;

  /// 省スペース表示(テーブル行など)向け。ロス率のみを最小限で出す。
  final bool compact;

  const DiagnosticsChip({
    super.key,
    required this.uuid,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diag = ref.watch(hubDiagnosticsProvider)[uuid];
    if (diag == null) return const SizedBox.shrink();

    final colors = context.statusColors;
    final scheme = Theme.of(context).colorScheme;

    // ロス率の色分け(緑 <1% / 橙 <5% / 赤)。
    final loss = diag.lossRate;
    final lossColor = loss < 0.01
        ? colors.connected
        : loss < 0.05
            ? colors.warning
            : colors.disconnected;

    // 最終受信からの経過。10秒超で警告色。
    final lastSeen = diag.lastSeen;
    final staleColor = lastSeen != null &&
            DateTime.now().difference(lastSeen) > const Duration(seconds: 10)
        ? colors.disconnected
        : scheme.onSurfaceVariant;

    if (compact) {
      // テーブル行向け: ロス率だけを小さな丸バッジで。
      return Tooltip(
        message: _tooltipText(diag),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: lossColor.withValues(alpha: 0.15),
            borderRadius: AppRadius.allS,
          ),
          child: Text(
            _lossLabel(loss),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: lossColor,
            ),
          ),
        ),
      );
    }

    return Wrap(
      spacing: AppSpacing.s,
      runSpacing: AppSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _Metric(
          icon: Icons.percent,
          label: 'ロス ${_lossLabel(loss)}',
          color: lossColor,
        ),
        _Metric(
          icon: Icons.sync,
          label: '再同期 ${diag.totalResynced}',
          color: scheme.onSurfaceVariant,
        ),
        _Metric(
          icon: Icons.layers,
          label: 'バッファ ${diag.bufferedFrames}',
          color: scheme.onSurfaceVariant,
        ),
        _Metric(
          icon: Icons.speaker,
          label: '再生 ${diag.ringMs.toStringAsFixed(0)}ms',
          color: scheme.onSurfaceVariant,
        ),
        _Metric(
          icon: Icons.warning_amber,
          label: '欠 ${diag.underrunFrames}',
          color: diag.underrunFrames > 0
              ? colors.warning
              : scheme.onSurfaceVariant,
        ),
        if (lastSeen != null)
          _Metric(
            icon: Icons.schedule,
            label: _elapsedLabel(DateTime.now().difference(lastSeen)),
            color: staleColor,
          ),
      ],
    );
  }

  static String _lossLabel(double loss) =>
      '${(loss * 100).toStringAsFixed(loss < 0.1 ? 1 : 0)}%';

  static String _elapsedLabel(Duration d) {
    if (d.inSeconds < 1) return '受信中';
    if (d.inSeconds < 60) return '${d.inSeconds}秒前';
    return '${d.inMinutes}分前';
  }

  static String _tooltipText(ClientDiagnostics d) {
    final last = d.lastSeen;
    final elapsed = last == null ? '-' : _elapsedLabel(DateTime.now().difference(last));
    return 'ロス率 ${_lossLabel(d.lossRate)}\n'
        '受信 ${d.totalReceived} / 欠落 ${d.totalDropped}\n'
        '再同期 ${d.totalResynced} 回\n'
        'ジッタバッファ ${d.bufferedFrames} フレーム\n'
        '再生バッファ ${d.ringMs.toStringAsFixed(0)}ms(${d.ringFrames}フレーム)\n'
        'アンダーラン ${d.underrunFrames} / オーバーラン ${d.overrunFrames} フレーム\n'
        '最終受信 $elapsed';
  }
}

/// アイコン + ラベルの小さな指標1つ。
class _Metric extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _Metric({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 2),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: color),
        ),
      ],
    );
  }
}
