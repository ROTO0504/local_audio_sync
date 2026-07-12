import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/client_controller_provider.dart';
import '../../providers/client_state_provider.dart';
import '../../providers/discovered_hubs_provider.dart';
import '../../services/discovery_service.dart';
import '../../services/last_hub_store.dart';
import '../../services/manual_hub_store.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';

/// 発見済み Hub の一覧と手動 IP 入力を内包した接続先ピッカー。
///
/// 発見タブは [discoveredHubsProvider] を watch し、名前 / IP / v2 バッジ /
/// 前回接続マーク付きで一覧表示する。手動タブは旧 `_showManualConnectDialog`
/// を移設・改装したもの。選択で [ClientController] の接続メソッドを呼ぶ。
class HubPicker extends ConsumerStatefulWidget {
  const HubPicker({super.key});

  /// bottom sheet として表示する。
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const HubPicker(),
    );
  }

  @override
  ConsumerState<HubPicker> createState() => _HubPickerState();
}

class _HubPickerState extends ConsumerState<HubPicker> {
  final _ipController = TextEditingController();
  final _portController = TextEditingController(text: '$kAudioPort');
  final _manualStore = ManualHubStore();
  List<String> _history = const [];
  String? _lastHubKey;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _loadLastHub();
    _loadDefaultPort();
  }

  Future<void> _loadHistory() async {
    final history = await ref.read(clientControllerProvider).loadManualHistory();
    if (mounted) setState(() => _history = history);
  }

  Future<void> _loadDefaultPort() async {
    final port = await _manualStore.loadDefaultPort();
    if (mounted) _portController.text = '$port';
  }

  Future<void> _loadLastHub() async {
    final last = await LastHubStore().loadLastHub();
    if (mounted && last != null) {
      setState(() => _lastHubKey = ClientDiscoveryListener.keyOf(last));
    }
  }

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return DefaultTabController(
      length: 2,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const TabBar(
                tabs: [
                  Tab(text: '発見した Hub'),
                  Tab(text: '手動接続'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _DiscoveredTab(lastHubKey: _lastHubKey),
                    _buildManualTab(context),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildManualTab(BuildContext context) {
    final subtle = Theme.of(context).colorScheme.onSurfaceVariant;
    final isManual = ref.watch(
      clientStateProvider.select((s) => s.isManualMode),
    );
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.m),
      children: [
        Text(
          'ブロードキャストが届かないネットワーク(別セグメントや VPN 経由)では、'
          'Hub 画面に表示される IP:ポート を直接入力してください。',
          style: TextStyle(fontSize: 12, color: subtle),
        ),
        AppSpacing.gapM,
        TextField(
          controller: _ipController,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Hub の IP アドレス',
            hintText: '例: 192.168.1.10',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        AppSpacing.gapS,
        TextField(
          controller: _portController,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'ポート',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        AppSpacing.gapM,
        FilledButton.icon(
          icon: const Icon(Icons.link),
          label: const Text('接続'),
          onPressed: () => _connectManual(context),
        ),
        if (isManual) ...[
          AppSpacing.gapS,
          TextButton.icon(
            icon: const Icon(Icons.autorenew),
            label: const Text('自動探索へ戻る'),
            onPressed: () {
              Navigator.of(context).pop();
              ref.read(clientControllerProvider).returnToAutoDiscovery();
            },
          ),
        ],
        if (_history.isNotEmpty) ...[
          AppSpacing.gapM,
          Text('最近の接続先', style: TextStyle(fontSize: 12, color: subtle)),
          ..._history.map(
            (entry) => ListTile(
              dense: true,
              leading: const Icon(Icons.history, size: 18),
              title: Text(entry, style: const TextStyle(fontSize: 13)),
              onTap: () {
                final parsed = ManualHubStore.parse(entry);
                if (parsed == null) return;
                Navigator.of(context).pop();
                ref
                    .read(clientControllerProvider)
                    .connectManually(parsed.ip, parsed.port);
              },
            ),
          ),
        ],
      ],
    );
  }

  void _connectManual(BuildContext context) {
    final ip = _ipController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    if (ip.isEmpty || port == null || port < 1 || port > 65535) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('IP アドレスとポートを確認してください')),
      );
      return;
    }
    Navigator.of(context).pop();
    ref.read(clientControllerProvider).connectManually(ip, port);
  }
}

class _DiscoveredTab extends ConsumerWidget {
  final String? lastHubKey;

  const _DiscoveredTab({required this.lastHubKey});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hubs = ref.watch(discoveredHubsProvider);
    final connectedKey =
        ref.watch(clientStateProvider.select((s) => s.connectedHubId));
    final subtle = Theme.of(context).colorScheme.onSurfaceVariant;

    if (hubs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.wifi_find, size: 40, color: subtle),
              AppSpacing.gapM,
              Text(
                'Hub を探しています...\n同じ Wi-Fi に Hub がいることを確認してください。',
                textAlign: TextAlign.center,
                style: TextStyle(color: subtle),
              ),
            ],
          ),
        ),
      );
    }

    final entries = hubs.entries.toList();
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final key = entries[index].key;
        final hub = entries[index].value;
        final isConnected = key == connectedKey;
        final isLast = key == lastHubKey;
        return ListTile(
          leading: Icon(
            isConnected ? Icons.cast_connected : Icons.cast,
            color: isConnected ? context.statusColors.connected : null,
          ),
          title: Row(
            children: [
              Flexible(child: Text(hub.name, overflow: TextOverflow.ellipsis)),
              if (hub.protocolVersion >= 2) ...[
                AppSpacing.gapS,
                const _Badge(label: 'v2'),
              ],
              if (isLast) ...[
                AppSpacing.gapS,
                const _Badge(label: '前回'),
              ],
            ],
          ),
          subtitle: Text('${hub.ip}:${hub.port}'),
          trailing: isConnected
              ? Text('接続中',
                  style: TextStyle(
                      fontSize: 12, color: context.statusColors.connected))
              : const Icon(Icons.chevron_right),
          onTap: isConnected
              ? null
              : () {
                  Navigator.of(context).pop();
                  ref.read(clientControllerProvider).connectTo(hub);
                },
        );
      },
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  const _Badge({required this.label});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: AppRadius.allS,
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}
