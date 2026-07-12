import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/control_messages.dart';
import '../providers/app_mode_provider.dart';
import '../providers/hub_state_provider.dart';
import '../services/discovery_service.dart';
import '../services/hub_controller.dart';
import '../services/jitter_buffer.dart';
import '../widgets/client_tile.dart';

/// Hub(集約・再生側)の画面。
/// コアロジックは [HubController] に集約されており、ここでは
/// start / stop の呼び出しと状態の表示だけを行う。
class HubScreen extends ConsumerStatefulWidget {
  const HubScreen({super.key});

  @override
  ConsumerState<HubScreen> createState() => _HubScreenState();
}

class _HubScreenState extends ConsumerState<HubScreen> {
  late final HubController _controller;
  String? _localIp;
  double _masterVolume = 1.0;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(hubControllerProvider);
    _controller.onCommandDeliveryFailed = _onCommandDeliveryFailed;
    _controller.start(ref.read(deviceNameProvider));
    getLocalIpv4().then((ip) {
      if (mounted) setState(() => _localIp = ip);
    });
  }

  @override
  void dispose() {
    _controller.onCommandDeliveryFailed = null;
    _controller.stop();
    super.dispose();
  }

  void _onCommandDeliveryFailed(String uuid, RemoteCommandAction action) {
    if (!mounted) return;
    final client = ref.read(hubStateProvider)[uuid];
    final name = client?.name ?? uuid;
    final label = switch (action) {
      RemoteCommandAction.pause => '一時停止',
      RemoteCommandAction.resume => '再開',
      RemoteCommandAction.stop => '停止',
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$name への$label指示が届きませんでした')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final clients = ref.watch(hubStateProvider);
    final name = ref.watch(deviceNameProvider);
    final activeCount = clients.values.where((c) => c.isActive).length;

    return Scaffold(
      appBar: AppBar(
        title: Text('Hub — $name'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: '設定',
            onPressed: _showSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          _HubHeader(
            localIp: _localIp,
            port: kAudioPort,
            activeCount: activeCount,
            totalCount: clients.length,
            masterVolume: _masterVolume,
            onMasterVolumeChanged: (v) {
              setState(() => _masterVolume = v);
              _controller.setMasterVolume(v);
            },
            onPauseAll:
                activeCount == 0 ? null : () => _controller.pauseAll(),
            onResumeAll:
                clients.values.any((c) => c.isActive && c.isPaused)
                    ? () => _controller.resumeAll()
                    : null,
          ),
          Expanded(
            child: clients.isEmpty
                ? const _EmptyState()
                : ListView(
                    children: [
                      ...clients.values.map((c) => ClientTile(client: c)),
                      const SizedBox(height: 12),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  void _showSettings() {
    showDialog<void>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Hub 設定'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  leading: const Icon(Icons.volume_up),
                  title: const Text('すべての音量を 100% にする'),
                  onTap: () {
                    setState(() => _masterVolume = 1.0);
                    _controller.setMasterVolume(1.0);
                    Navigator.of(context).pop();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.volume_mute),
                  title: const Text('すべてミュート'),
                  onTap: () {
                    final clients = ref.read(hubStateProvider);
                    for (final id in clients.keys) {
                      _controller.setClientMuted(id, muted: true);
                    }
                    Navigator.of(context).pop();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.swap_horiz),
                  title: const Text('クライアントモードへ切替'),
                  onTap: () async {
                    Navigator.of(context).pop();
                    await ref.read(appModeProvider.notifier).reset();
                    if (mounted) context.mounted;
                  },
                ),
                const Divider(),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(
                    '受信バッファ(遅延と安定のバランス)',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                ),
                RadioGroup<JitterBufferPreset>(
                  groupValue: _controller.jitterPreset,
                  onChanged: (value) async {
                    if (value == null) return;
                    await _controller.setJitterPreset(value);
                    setDialogState(() {});
                  },
                  child: Column(
                    children: [
                      for (final preset in JitterBufferPreset.values)
                        RadioListTile<JitterBufferPreset>(
                          dense: true,
                          title: Text(preset.label,
                              style: const TextStyle(fontSize: 14)),
                          subtitle: Text(
                            '目標遅延 約${preset.targetDelayFrames * 20}ms',
                            style: const TextStyle(fontSize: 11),
                          ),
                          value: preset,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('閉じる'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 自 IP・接続数・マスター音量・一括操作をまとめたヘッダ。
class _HubHeader extends StatelessWidget {
  final String? localIp;
  final int port;
  final int activeCount;
  final int totalCount;
  final double masterVolume;
  final ValueChanged<double> onMasterVolumeChanged;
  final VoidCallback? onPauseAll;
  final VoidCallback? onResumeAll;

  const _HubHeader({
    required this.localIp,
    required this.port,
    required this.activeCount,
    required this.totalCount,
    required this.masterVolume,
    required this.onMasterVolumeChanged,
    required this.onPauseAll,
    required this.onResumeAll,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lan, size: 16, color: Colors.grey),
              const SizedBox(width: 6),
              Text(
                localIp == null ? 'IP 取得中...' : '$localIp:$port',
                style: const TextStyle(fontSize: 13, color: Colors.black87),
              ),
              const Spacer(),
              Text(
                totalCount == 0
                    ? 'クライアント待機中'
                    : '接続中 $activeCount / $totalCount 台',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.pause_circle_outline, size: 20),
                tooltip: '全員の配信を一時停止',
                visualDensity: VisualDensity.compact,
                onPressed: onPauseAll,
              ),
              IconButton(
                icon: const Icon(Icons.play_circle_outline, size: 20),
                tooltip: '全員の配信を再開',
                visualDensity: VisualDensity.compact,
                onPressed: onResumeAll,
              ),
            ],
          ),
          Row(
            children: [
              const Icon(Icons.speaker_group, size: 16, color: Colors.grey),
              const SizedBox(width: 6),
              const Text('マスター音量', style: TextStyle(fontSize: 12)),
              Expanded(
                child: Slider(
                  value: masterVolume,
                  min: 0,
                  max: 1,
                  onChanged: onMasterVolumeChanged,
                ),
              ),
              SizedBox(
                width: 40,
                child: Text(
                  '${(masterVolume * 100).round()}%',
                  style: const TextStyle(fontSize: 12),
                  textAlign: TextAlign.end,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.wifi_find, size: 64, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          Text(
            'クライアントを待っています...',
            style: TextStyle(fontSize: 18, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 8),
          Text(
            '他のデバイスでアプリを起動し、「クライアント」を選択してください',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
