import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../broadcast_picker_button.dart';

/// 配信状態の表示と、iOS の Broadcast Picker / 切断ボタンをまとめたセクション。
///
/// 旧 client_screen.dart の private `_BroadcastSection` を移設し、ハードコード色を
/// [AppStatusColors] トークンへ置き換えた。
class BroadcastSection extends StatelessWidget {
  final bool isIOS;
  final bool isConnected;
  final bool broadcastingActive;
  final int packetCount;
  final String? captureError;
  final String preferredExtensionId;

  /// 手動接続中の接続先(`ip:port`)。null なら自動探索モード。
  final String? manualTarget;
  final VoidCallback onStop;

  const BroadcastSection({
    super.key,
    required this.isIOS,
    required this.isConnected,
    required this.broadcastingActive,
    required this.packetCount,
    required this.captureError,
    required this.preferredExtensionId,
    required this.manualTarget,
    required this.onStop,
  });

  String get _searchingLabel => manualTarget == null
      ? 'ローカルネットワーク内の Hub を探しています...'
      : '$manualTarget へ接続を試みています...';

  @override
  Widget build(BuildContext context) {
    final colors = context.statusColors;
    final theme = Theme.of(context);
    final subtle = theme.colorScheme.onSurfaceVariant;

    if (isIOS) {
      return Column(
        children: [
          if (!isConnected)
            Text(
              _searchingLabel,
              textAlign: TextAlign.center,
              style: TextStyle(color: subtle),
            )
          else
            Text(
              broadcastingActive
                  ? 'ブロードキャスト中  パケット: $packetCount'
                  : 'Hub に接続済み。下のボタンからブロードキャストを開始してください。',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: broadcastingActive ? colors.connected : colors.warning,
              ),
            ),
          AppSpacing.gapM,
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.cell_tower, size: 28, color: theme.colorScheme.primary),
              AppSpacing.gapS,
              BroadcastPickerButton(
                preferredExtensionBundleId: preferredExtensionId,
                size: 60,
              ),
              AppSpacing.gapS,
              Text(
                'タップして配信開始',
                style: TextStyle(fontSize: 13, color: subtle),
              ),
            ],
          ),
          if (captureError != null) ...[
            AppSpacing.gapS,
            Text(
              'エラー: $captureError',
              style: TextStyle(fontSize: 12, color: colors.disconnected),
              textAlign: TextAlign.center,
            ),
          ],
          if (isConnected) ...[
            AppSpacing.gapM,
            _StopButton(onStop: onStop),
          ],
        ],
      );
    }

    // 非 iOS(Android / macOS / Windows)
    return Column(
      children: [
        if (!isConnected)
          Text(
            _searchingLabel,
            textAlign: TextAlign.center,
            style: TextStyle(color: subtle),
          )
        else
          Text(
            'ブロードキャスト中  パケット: $packetCount',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.connected),
          ),
        if (captureError != null) ...[
          AppSpacing.gapS,
          Text(
            'エラー: $captureError',
            style: TextStyle(fontSize: 12, color: colors.disconnected),
            textAlign: TextAlign.center,
          ),
        ],
        if (isConnected) ...[
          AppSpacing.gapM,
          _StopButton(onStop: onStop),
        ],
      ],
    );
  }
}

class _StopButton extends StatelessWidget {
  final VoidCallback onStop;
  const _StopButton({required this.onStop});

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      icon: const Icon(Icons.stop_circle),
      label: const Text('Hub から切断'),
      style: FilledButton.styleFrom(
        backgroundColor: context.statusColors.disconnected,
        foregroundColor: Colors.white,
      ),
      onPressed: onStop,
    );
  }
}
