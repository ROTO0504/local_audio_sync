import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/client_info.dart';
import '../providers/hub_selection_provider.dart';
import '../services/hub_controller.dart';
import '../theme/app_colors.dart';
import 'hub/diagnostics_chip.dart';
import 'vu_meter.dart';

/// プラットフォーム識別子に対応するアイコン。
IconData platformIcon(String platform) => switch (platform) {
      'ios' => Icons.phone_iphone,
      'android' => Icons.android,
      'macos' => Icons.laptop_mac,
      'windows' => Icons.desktop_windows,
      'linux' => Icons.computer,
      _ => Icons.device_unknown,
    };

class ClientTile extends ConsumerWidget {
  final ClientInfo client;

  const ClientTile({super.key, required this.client});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(hubControllerProvider);
    final scheme = Theme.of(context).colorScheme;
    final colors = context.statusColors;
    final active = client.isActive;
    final selected = ref.watch(
      hubSelectionProvider.select((s) => s.contains(client.id)),
    );
    final shortId =
        client.id.length > 8 ? client.id.substring(0, 8) : client.id;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Opacity(
        opacity: active ? 1.0 : 0.55,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              // 選択チェックボックス(一括操作の対象)
              Checkbox(
                value: selected,
                visualDensity: VisualDensity.compact,
                onChanged: (_) =>
                    ref.read(hubSelectionProvider.notifier).toggle(client.id),
              ),

              // プラットフォームアイコン + 接続状態ドット
              Stack(
                alignment: Alignment.bottomRight,
                children: [
                  Icon(
                    platformIcon(client.platform),
                    size: 28,
                    color: active ? scheme.onSurfaceVariant : scheme.outline,
                  ),
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: active ? colors.connected : scheme.outline,
                      border: Border.all(
                        color: scheme.surfaceContainerLow,
                        width: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 10),

              // 名前 + IP + デバイス ID(短縮)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            client.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        if (!active) ...[
                          const SizedBox(width: 6),
                          _StatusPill(
                            label: '切断',
                            background: scheme.surfaceContainerHighest,
                            foreground: scheme.onSurfaceVariant,
                          ),
                        ] else if (client.isPaused) ...[
                          const SizedBox(width: 6),
                          _StatusPill(
                            label: '一時停止中',
                            background: colors.paused.withValues(alpha: 0.18),
                            foreground: colors.paused,
                          ),
                        ],
                      ],
                    ),
                    Text(
                      '${client.ip}  ·  ID: $shortId',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    // 接続品質診断(ロス率などがあれば小さく表示)
                    DiagnosticsChip(uuid: client.id, compact: true),
                  ],
                ),
              ),

              // VU meter(受信音声の実レベル)
              VuMeter(
                level: active ? client.vuLevel : 0.0,
                height: 32,
              ),
              const SizedBox(width: 12),

              // Volume slider
              SizedBox(
                width: 100,
                child: Slider(
                  value: client.isMuted ? 0 : client.volume,
                  min: 0,
                  max: 1,
                  onChanged: client.isMuted
                      ? null
                      : (v) => controller.setClientVolume(client.id, v),
                ),
              ),

              // Volume % label
              SizedBox(
                width: 48,
                child: Text(
                  client.isMuted ? 'ミュート' : '${(client.volume * 100).round()}%',
                  style: TextStyle(
                    fontSize: 11,
                    color: client.isMuted
                        ? colors.disconnected
                        : scheme.onSurface,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),

              // Mute button
              IconButton(
                icon: Icon(
                  client.isMuted ? Icons.volume_off : Icons.volume_up,
                  size: 20,
                  color: client.isMuted
                      ? colors.disconnected
                      : scheme.onSurfaceVariant,
                ),
                tooltip: client.isMuted ? 'ミュート解除' : 'ミュート',
                onPressed: () => controller.setClientMuted(
                  client.id,
                  muted: !client.isMuted,
                ),
              ),

              // リモート一時停止 / 再開(v2 クライアント + 接続中のみ)
              if (active && client.protocolVersion >= 2)
                IconButton(
                  icon: Icon(
                    client.isPaused
                        ? Icons.play_circle_outline
                        : Icons.pause_circle_outline,
                    size: 20,
                    color: client.isPaused
                        ? colors.paused
                        : scheme.onSurfaceVariant,
                  ),
                  tooltip: client.isPaused ? '配信を再開させる' : '配信を一時停止させる',
                  onPressed: () => client.isPaused
                      ? controller.resumeClient(client.id)
                      : controller.pauseClient(client.id),
                ),

              // 配信停止(stopClient) — v2 クライアント + 接続中のみ
              if (active && client.protocolVersion >= 2)
                IconButton(
                  icon: Icon(
                    Icons.stop_circle_outlined,
                    size: 20,
                    color: colors.disconnected,
                  ),
                  tooltip: '配信を停止させる',
                  onPressed: () => controller.stopClient(client.id),
                ),

              // 切断済みクライアントの削除ボタン(設定は保持される)
              if (!active)
                IconButton(
                  icon: Icon(Icons.close, size: 20, color: scheme.outline),
                  tooltip: '一覧から削除(音量設定は保持)',
                  onPressed: () => controller.removeClientEntry(client.id),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 状態を表す小さなピル型ラベル(切断/一時停止中など)。
class _StatusPill extends StatelessWidget {
  final String label;
  final Color background;
  final Color foreground;

  const _StatusPill({
    required this.label,
    required this.background,
    required this.foreground,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, color: foreground),
      ),
    );
  }
}
