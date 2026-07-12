import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/client_info.dart';
import '../services/hub_controller.dart';
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
    final active = client.isActive;
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
              // プラットフォームアイコン + 接続状態ドット
              Stack(
                alignment: Alignment.bottomRight,
                children: [
                  Icon(
                    platformIcon(client.platform),
                    size: 28,
                    color: active ? Colors.blueGrey : Colors.grey,
                  ),
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: active ? Colors.green : Colors.grey,
                      border: Border.all(color: Colors.white, width: 1.5),
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
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade300,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text(
                              '切断',
                              style: TextStyle(fontSize: 10),
                            ),
                          ),
                        ] else if (client.isPaused) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.orange.shade100,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text(
                              '一時停止中',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.deepOrange,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    Text(
                      '${client.ip}  ·  ID: $shortId',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade600,
                      ),
                    ),
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
                    color: client.isMuted ? Colors.red : Colors.black87,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),

              // Mute button
              IconButton(
                icon: Icon(
                  client.isMuted ? Icons.volume_off : Icons.volume_up,
                  size: 20,
                  color: client.isMuted ? Colors.red : Colors.black54,
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
                    color:
                        client.isPaused ? Colors.deepOrange : Colors.black54,
                  ),
                  tooltip: client.isPaused ? '配信を再開させる' : '配信を一時停止させる',
                  onPressed: () => client.isPaused
                      ? controller.resumeClient(client.id)
                      : controller.pauseClient(client.id),
                ),

              // 切断済みクライアントの削除ボタン(設定は保持される)
              if (!active)
                IconButton(
                  icon: const Icon(Icons.close, size: 20, color: Colors.grey),
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
