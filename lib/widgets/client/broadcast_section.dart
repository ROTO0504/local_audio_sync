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

  /// iOS の Broadcast Extension 診断テキスト(無ければ null)。
  final String? diagnostics;

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
    this.diagnostics,
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
          BroadcastPickerButton(
            preferredExtensionBundleId: preferredExtensionId,
            broadcasting: broadcastingActive,
          ),
          if (!broadcastingActive) ...[
            AppSpacing.gapS,
            Text(
              'ボタンを押すと配信先の選択シートが開きます。'
              '「Local Audio Sync」を選んで「ブロードキャストを開始」してください。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: subtle),
            ),
          ],
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
          if (diagnostics != null) ...[
            AppSpacing.gapM,
            _DiagnosticsBox(text: diagnostics!),
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

/// Broadcast Extension の診断テキストを等幅で小さく表示する箱。
/// 音声が届かないときの原因切り分け(Extension 起動/音声到達/送信状況)用。
class _DiagnosticsBox extends StatelessWidget {
  final String text;
  const _DiagnosticsBox({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '配信診断',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            text,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              height: 1.4,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
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
