import 'package:flutter/material.dart';

import '../../providers/client_state_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../vu_meter.dart';

/// クライアントの接続状態を常時提示する恒常ステータスカード。
///
/// 旧実装は状態を数秒で消える SnackBar に頼っていたため、後から状態が
/// 分からなかった。このカードは searching / connecting / connected /
/// disconnected(手動モードでは reconnecting)を大きく表示し、接続先 Hub 名・
/// IP・自デバイス ID・VU メーター・リンク品質を一箇所に集約する。
class ConnectionCard extends StatelessWidget {
  final ClientState state;

  const ConnectionCard({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final colors = context.statusColors;
    final theme = Theme.of(context);
    final subtle = theme.colorScheme.onSurfaceVariant;

    // 手動モードで再接続を試みている間は「再接続中」と表示する。
    final isReconnecting =
        state.status == ClientConnectionStatus.connecting && state.isManualMode;

    final (label, color, icon) = switch (state.status) {
      ClientConnectionStatus.searching => ('Hub を探索中', colors.searching, Icons.search),
      ClientConnectionStatus.connecting => (
          isReconnecting ? '再接続中' : '接続中',
          colors.connecting,
          Icons.sync,
        ),
      ClientConnectionStatus.connected => ('接続済み', colors.connected, Icons.check_circle),
      ClientConnectionStatus.disconnected => ('切断', colors.disconnected, Icons.link_off),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: color, size: 28),
                AppSpacing.gapS,
                Text(
                  label,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (state.isManualMode) ...[
                  AppSpacing.gapS,
                  const _ManualBadge(),
                ],
              ],
            ),
            AppSpacing.gapM,
            VuMeter(level: state.vuLevel, width: 220, height: 14),
            AppSpacing.gapM,
            if (state.hubIp != null)
              _InfoRow(
                icon: Icons.dns,
                label: '接続先',
                value: state.hubName == null
                    ? '${state.hubIp}:${state.hubPort}'
                    : '${state.hubName}(${state.hubIp}:${state.hubPort})',
              ),
            if (state.deviceId != null)
              _InfoRow(
                icon: Icons.badge,
                label: 'このデバイス',
                value: state.deviceId!.length >= 8
                    ? state.deviceId!.substring(0, 8)
                    : state.deviceId!,
              ),
            if (state.linkStats != null && state.status == ClientConnectionStatus.connected)
              _InfoRow(
                icon: Icons.network_check,
                label: 'リンク',
                value: _linkSummary(state),
              ),
            if (state.status == ClientConnectionStatus.searching)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.s),
                child: Text(
                  'ローカルネットワーク内の Hub を探しています...',
                  style: TextStyle(fontSize: 12, color: subtle),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _linkSummary(ClientState state) {
    final stats = state.linkStats!;
    final parts = <String>['送出 ${stats.sentPackets}'];
    final since = stats.sincePong;
    if (since != null) {
      parts.add('PONG ${since.inSeconds}s 前');
    }
    if (stats.consecutiveFailures > 0) {
      parts.add('失敗 ${stats.consecutiveFailures}');
    }
    return parts.join(' / ');
  }
}

class _ManualBadge extends StatelessWidget {
  const _ManualBadge();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.tertiary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: AppRadius.allS,
      ),
      child: Text(
        '手動',
        style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final subtle = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: subtle),
          AppSpacing.gapS,
          Text('$label: ', style: TextStyle(fontSize: 12, color: subtle)),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
