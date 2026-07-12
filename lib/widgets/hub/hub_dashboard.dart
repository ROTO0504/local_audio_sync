import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/hub_controller.dart';
import '../../providers/hub_state_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';

/// デスクトップ Hub 左ペインの情報集約ダッシュボード。
///
/// [hubStateProvider] を watch して接続台数・平均音量・ミュート数・
/// 一時停止数・稼働時間・プロトコル別内訳をカードで集約表示する。
/// 稼働時間は [HubController.startedAt] から算出し、1秒ごとに更新する。
class HubDashboard extends ConsumerStatefulWidget {
  const HubDashboard({super.key});

  @override
  ConsumerState<HubDashboard> createState() => _HubDashboardState();
}

class _HubDashboardState extends ConsumerState<HubDashboard> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // 稼働時間の表示を毎秒更新する。
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clients = ref.watch(hubStateProvider);
    final controller = ref.read(hubControllerProvider);
    final scheme = Theme.of(context).colorScheme;
    final colors = context.statusColors;

    final all = clients.values.toList();
    final active = all.where((c) => c.isActive).toList();
    final mutedCount = all.where((c) => c.isMuted).length;
    final pausedCount = active.where((c) => c.isPaused).length;

    // 平均音量はアクティブなクライアントのみを対象に(ミュートは 0 扱い)。
    final avgVolume = active.isEmpty
        ? 0.0
        : active
                .map((c) => c.isMuted ? 0.0 : c.volume)
                .reduce((a, b) => a + b) /
            active.length;

    // プロトコル別内訳(platform 単位で集計)。
    final byPlatform = <String, int>{};
    for (final c in all) {
      byPlatform[c.platform] = (byPlatform[c.platform] ?? 0) + 1;
    }

    return ListView(
      padding: AppSpacing.screenPadding,
      children: [
        Text(
          'ダッシュボード',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        AppSpacing.gapM,
        _StatCard(
          icon: Icons.groups,
          label: '接続中 / 総数',
          value: '${active.length} / ${all.length}',
          accent: active.isEmpty ? scheme.outline : colors.connected,
        ),
        AppSpacing.gapS,
        _StatCard(
          icon: Icons.timer_outlined,
          label: '稼働時間',
          value: _uptimeLabel(controller.startedAt),
          accent: scheme.primary,
        ),
        AppSpacing.gapS,
        _StatCard(
          icon: Icons.speaker_group,
          label: '平均音量',
          value: '${(avgVolume * 100).round()}%',
          accent: scheme.primary,
        ),
        AppSpacing.gapS,
        Row(
          children: [
            Expanded(
              child: _StatCard(
                icon: Icons.volume_off,
                label: 'ミュート',
                value: '$mutedCount',
                accent: mutedCount == 0 ? scheme.outline : colors.disconnected,
              ),
            ),
            AppSpacing.gapS,
            Expanded(
              child: _StatCard(
                icon: Icons.pause_circle_outline,
                label: '一時停止',
                value: '$pausedCount',
                accent: pausedCount == 0 ? scheme.outline : colors.paused,
              ),
            ),
          ],
        ),
        AppSpacing.gapM,
        if (byPlatform.isNotEmpty) ...[
          Text(
            'プラットフォーム別内訳',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          AppSpacing.gapS,
          _PlatformBreakdown(byPlatform: byPlatform),
        ],
      ],
    );
  }

  static String _uptimeLabel(DateTime? startedAt) {
    if (startedAt == null) return '-';
    final d = DateTime.now().difference(startedAt);
    if (d.isNegative) return '0:00';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }
}

/// 見出し + 数値の集約カード1枚。
class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color accent;

  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: AppSpacing.cardPadding,
        child: Row(
          children: [
            Icon(icon, size: 22, color: accent),
            AppSpacing.gapM,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// プラットフォーム別の台数を横並びのチップで示す。
class _PlatformBreakdown extends StatelessWidget {
  final Map<String, int> byPlatform;

  const _PlatformBreakdown({required this.byPlatform});

  @override
  Widget build(BuildContext context) {
    final entries = byPlatform.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Wrap(
      spacing: AppSpacing.s,
      runSpacing: AppSpacing.s,
      children: [
        for (final e in entries)
          Chip(
            visualDensity: VisualDensity.compact,
            avatar: Icon(_platformIcon(e.key), size: 16),
            label: Text('${_platformLabel(e.key)} ${e.value}'),
          ),
      ],
    );
  }

  static IconData _platformIcon(String platform) => switch (platform) {
        'ios' => Icons.phone_iphone,
        'android' => Icons.android,
        'macos' => Icons.laptop_mac,
        'windows' => Icons.desktop_windows,
        'linux' => Icons.computer,
        _ => Icons.device_unknown,
      };

  static String _platformLabel(String platform) => switch (platform) {
        'ios' => 'iOS',
        'android' => 'Android',
        'macos' => 'macOS',
        'windows' => 'Windows',
        'linux' => 'Linux',
        _ => '不明',
      };
}
