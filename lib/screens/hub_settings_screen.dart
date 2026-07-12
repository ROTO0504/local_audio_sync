import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_mode_provider.dart';
import '../providers/hub_state_provider.dart';
import '../providers/master_volume_provider.dart';
import '../providers/theme_mode_provider.dart';
import '../services/hub_controller.dart';
import '../services/jitter_buffer.dart';
import '../theme/app_spacing.dart';

/// Hub の各種設定を1画面へ集約したもの。
///
/// 旧実装では hub_screen.dart の `_showSettings` ダイアログに詰め込まれていた
/// 内容(名前変更・ジッタープリセット・テーマ・マスター音量・一括操作・
/// 役割切替)を、独立した画面として整理した。
class HubSettingsScreen extends ConsumerStatefulWidget {
  const HubSettingsScreen({super.key});

  @override
  ConsumerState<HubSettingsScreen> createState() => _HubSettingsScreenState();
}

class _HubSettingsScreenState extends ConsumerState<HubSettingsScreen> {
  late final TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _nameController =
        TextEditingController(text: ref.read(deviceNameProvider));
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(hubControllerProvider);
    final themeMode = ref.watch(themeModeProvider);
    final masterVolume = ref.watch(masterVolumeProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Hub 設定')),
      body: ListView(
        padding: AppSpacing.screenPadding,
        children: [
          // ---- Hub 名 ----
          _SectionTitle('Hub 名'),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              hintText: 'この Hub の表示名',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (v) {
              final name = v.trim();
              if (name.isNotEmpty) {
                ref.read(deviceNameProvider.notifier).setName(name);
              }
            },
          ),
          AppSpacing.gapS,
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () {
                final name = _nameController.text.trim();
                if (name.isNotEmpty) {
                  ref.read(deviceNameProvider.notifier).setName(name);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('名前を保存しました')),
                  );
                }
              },
              child: const Text('保存'),
            ),
          ),

          const Divider(height: AppSpacing.xl),

          // ---- マスター音量 ----
          _SectionTitle('マスター音量'),
          Row(
            children: [
              const Icon(Icons.speaker_group, size: 20),
              Expanded(
                child: Slider(
                  value: masterVolume,
                  min: 0,
                  max: 1,
                  label: '${(masterVolume * 100).round()}%',
                  divisions: 20,
                  onChanged: (v) {
                    // Provider(表示・永続)とコントローラ(実効音量)の両方へ。
                    ref.read(masterVolumeProvider.notifier).setMasterVolume(v);
                    controller.setMasterVolume(v);
                  },
                ),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  '${(masterVolume * 100).round()}%',
                  textAlign: TextAlign.end,
                ),
              ),
            ],
          ),

          const Divider(height: AppSpacing.xl),

          // ---- 一括操作 ----
          _SectionTitle('一括操作'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.volume_up),
            title: const Text('すべての音量を 100% にする'),
            onTap: () {
              ref.read(masterVolumeProvider.notifier).setMasterVolume(1.0);
              controller.setMasterVolume(1.0);
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.volume_off),
            title: const Text('すべてミュート'),
            onTap: () {
              final ids = ref.read(hubStateProvider).keys.toSet();
              controller.muteSelected(ids, true);
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.volume_mute),
            title: const Text('すべてのミュートを解除'),
            onTap: controller.unmuteAll,
          ),

          const Divider(height: AppSpacing.xl),

          // ---- 受信バッファ(ジッタープリセット) ----
          _SectionTitle('受信バッファ(遅延と安定のバランス)'),
          RadioGroup<JitterBufferPreset>(
            groupValue: controller.jitterPreset,
            onChanged: (value) async {
              if (value == null) return;
              await controller.setJitterPreset(value);
              if (mounted) setState(() {});
            },
            child: Column(
              children: [
                for (final preset in JitterBufferPreset.values)
                  RadioListTile<JitterBufferPreset>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(preset.label),
                    subtitle: Text(
                      '目標遅延 約${preset.targetDelayFrames * 20}ms',
                      style: const TextStyle(fontSize: 11),
                    ),
                    value: preset,
                  ),
              ],
            ),
          ),

          const Divider(height: AppSpacing.xl),

          // ---- テーマ ----
          _SectionTitle('テーマ'),
          RadioGroup<ThemeMode>(
            groupValue: themeMode,
            onChanged: (mode) {
              if (mode != null) {
                ref.read(themeModeProvider.notifier).setThemeMode(mode);
              }
            },
            child: Column(
              children: const [
                RadioListTile<ThemeMode>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('システムに合わせる'),
                  value: ThemeMode.system,
                ),
                RadioListTile<ThemeMode>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('ライト'),
                  value: ThemeMode.light,
                ),
                RadioListTile<ThemeMode>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('ダーク'),
                  value: ThemeMode.dark,
                ),
              ],
            ),
          ),

          const Divider(height: AppSpacing.xl),

          // ---- 役割切替 ----
          _SectionTitle('役割'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.swap_horiz),
            title: const Text('クライアントモードへ切替'),
            subtitle: const Text('現在の Hub を終了して役割を選び直します'),
            onTap: () async {
              await ref.read(appModeProvider.notifier).reset();
            },
          ),
        ],
      ),
    );
  }
}

/// セクション見出し。
class _SectionTitle extends StatelessWidget {
  final String title;

  const _SectionTitle(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
