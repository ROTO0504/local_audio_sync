import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_mode_provider.dart';
import '../providers/client_controller_provider.dart';
import '../services/discovery_service.dart';
import '../services/last_hub_store.dart';
import '../services/manual_hub_store.dart';
import '../theme/app_spacing.dart';
import '../providers/theme_mode_provider.dart';

/// クライアントの設定画面。
///
/// デバイス名 / 既定ポート / テーマ / 記憶 Hub の管理 / 役割切替を 1 画面に集約する。
/// go_router ルートに依存せず `Navigator.push` で開く(ルート登録は app.dart 側)。
class ClientSettingsScreen extends ConsumerStatefulWidget {
  const ClientSettingsScreen({super.key});

  @override
  ConsumerState<ClientSettingsScreen> createState() =>
      _ClientSettingsScreenState();
}

class _ClientSettingsScreenState extends ConsumerState<ClientSettingsScreen> {
  final _manualStore = ManualHubStore();
  final _lastHubStore = LastHubStore();

  List<String> _history = const [];
  DiscoveredHub? _lastHub;
  int _defaultPort = kAudioPort;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final history = await _manualStore.loadHistory();
    final last = await _lastHubStore.loadLastHub();
    final port = await _manualStore.loadDefaultPort();
    if (mounted) {
      setState(() {
        _history = history;
        _lastHub = last;
        _defaultPort = port;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);
    final deviceName = ref.watch(deviceNameProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('クライアント設定')),
      body: ListView(
        children: [
          const _SectionHeader('デバイス'),
          ListTile(
            leading: const Icon(Icons.badge),
            title: const Text('デバイス名'),
            subtitle: Text(deviceName),
            trailing: const Icon(Icons.edit),
            onTap: () => _editDeviceName(deviceName),
          ),
          ListTile(
            leading: const Icon(Icons.settings_ethernet),
            title: const Text('既定ポート'),
            subtitle: Text('手動接続時の初期ポート: $_defaultPort'),
            trailing: const Icon(Icons.edit),
            onTap: _editDefaultPort,
          ),
          const Divider(height: 1),
          const _SectionHeader('表示'),
          ListTile(
            leading: const Icon(Icons.brightness_6),
            title: const Text('テーマ'),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s),
              child: SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('自動')),
                  ButtonSegment(value: ThemeMode.light, label: Text('ライト')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('ダーク')),
                ],
                selected: {themeMode},
                onSelectionChanged: (set) {
                  ref.read(themeModeProvider.notifier).setThemeMode(set.first);
                },
              ),
            ),
          ),
          const Divider(height: 1),
          const _SectionHeader('記憶している Hub'),
          if (_lastHub != null)
            ListTile(
              leading: const Icon(Icons.star),
              title: Text(_lastHub!.name),
              subtitle: Text('${_lastHub!.ip}:${_lastHub!.port}'
                  '${_lastHub!.hubId != null ? '  (前回接続先)' : ''}'),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: '前回接続先を忘れる',
                onPressed: () async {
                  await _lastHubStore.clear();
                  await _reload();
                },
              ),
            )
          else
            const ListTile(
              leading: Icon(Icons.star_border),
              title: Text('前回接続先はありません'),
            ),
          if (_history.isNotEmpty) ...[
            const _SectionHeader('手動接続の履歴'),
            ..._history.map(
              (entry) => ListTile(
                leading: const Icon(Icons.history),
                title: Text(entry),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    await _manualStore.remove(entry);
                    await _reload();
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.m),
              child: TextButton.icon(
                icon: const Icon(Icons.clear_all),
                label: const Text('履歴をすべて消す'),
                onPressed: () async {
                  await _manualStore.clearHistory();
                  await _reload();
                },
              ),
            ),
          ],
          const Divider(height: 1),
          const _SectionHeader('役割'),
          ListTile(
            leading: const Icon(Icons.swap_horiz),
            title: const Text('役割を切り替える'),
            subtitle: const Text('Hub / クライアントの選択画面に戻ります'),
            onTap: _switchRole,
          ),
        ],
      ),
    );
  }

  Future<void> _editDeviceName(String current) async {
    final controller = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('デバイス名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'このデバイスの表示名',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      await ref.read(deviceNameProvider.notifier).setName(result);
    }
  }

  Future<void> _editDefaultPort() async {
    final controller = TextEditingController(text: '$_defaultPort');
    final result = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('既定ポート'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            hintText: '例: 7777',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () {
              final port = int.tryParse(controller.text.trim());
              Navigator.of(dialogContext).pop(port);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result != null && result >= 1 && result <= 65535) {
      await _manualStore.saveDefaultPort(result);
      await _reload();
    }
  }

  Future<void> _switchRole() async {
    await ref.read(clientControllerProvider).stop();
    await ref.read(appModeProvider.notifier).reset();
    if (mounted) {
      // 役割リセットで redirect が /setup へ誘導する。設定画面を閉じておく。
      Navigator.of(context).pop();
    }
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.m,
        AppSpacing.m,
        AppSpacing.m,
        AppSpacing.xs,
      ),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
