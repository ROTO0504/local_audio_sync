import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';

/// 切断 / 接続失敗時に「次にどうするか」を明示するアクション行。
///
/// 旧実装は状態が消える SnackBar だけで導線が無かった。ここでは
/// 「再試行」「別の Hub を選ぶ(ピッカーを開く)」「自動探索へ戻る」を
/// 常時提示し、ユーザーが迷わず次の操作へ進めるようにする。
class ActionBanner extends StatelessWidget {
  /// 直近の接続先へ再試行する。再試行先が無ければ null(ボタン非表示)。
  final VoidCallback? onRetry;

  /// Hub ピッカーを開く。
  final VoidCallback onOpenPicker;

  /// 手動接続中に自動探索へ戻す。手動モードでなければ null(ボタン非表示)。
  final VoidCallback? onReturnToAuto;

  const ActionBanner({
    super.key,
    this.onRetry,
    required this.onOpenPicker,
    this.onReturnToAuto,
  });

  @override
  Widget build(BuildContext context) {
    final color = context.statusColors.disconnected;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.m),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: AppRadius.allM,
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, size: 18, color: color),
              AppSpacing.gapS,
              Expanded(
                child: Text(
                  'Hub に接続していません',
                  style: TextStyle(color: color, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          AppSpacing.gapS,
          Wrap(
            spacing: AppSpacing.s,
            runSpacing: AppSpacing.s,
            children: [
              if (onRetry != null)
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('再試行'),
                  onPressed: onRetry,
                ),
              FilledButton.icon(
                icon: const Icon(Icons.list, size: 18),
                label: const Text('別の Hub を選ぶ'),
                onPressed: onOpenPicker,
              ),
              if (onReturnToAuto != null)
                TextButton.icon(
                  icon: const Icon(Icons.autorenew, size: 18),
                  label: const Text('自動探索へ戻る'),
                  onPressed: onReturnToAuto,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
