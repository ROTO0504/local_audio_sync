import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_mode_provider.dart';
import '../providers/hub_state_provider.dart';
import '../services/hub_controller.dart';
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

  @override
  void initState() {
    super.initState();
    _controller = ref.read(hubControllerProvider);
    _controller.start(ref.read(deviceNameProvider));
  }

  @override
  void dispose() {
    _controller.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clients = ref.watch(hubStateProvider);
    final name = ref.watch(deviceNameProvider);

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
      body: clients.isEmpty
          ? const _EmptyState()
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    '${clients.length} 台のクライアントが接続中',
                    style: const TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ),
                ...clients.values.map((c) => ClientTile(client: c)),
              ],
            ),
    );
  }

  void _showSettings() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Hub 設定'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.volume_up),
              title: const Text('すべての音量を 100% にする'),
              onTap: () {
                ref.read(hubStateProvider.notifier).setMasterVolumeAll(1.0);
                Navigator.of(context).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.volume_mute),
              title: const Text('すべてミュート'),
              onTap: () {
                final clients = ref.read(hubStateProvider);
                for (final id in clients.keys) {
                  ref.read(hubStateProvider.notifier).setMuted(id, muted: true);
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
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('閉じる'),
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
