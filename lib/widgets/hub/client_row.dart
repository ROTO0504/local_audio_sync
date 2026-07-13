import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/client_info.dart';
import '../../providers/hub_selection_provider.dart';
import '../../services/hub_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../client_tile.dart' show platformIcon;
import '../vu_meter.dart';
import 'diagnostics_chip.dart';

/// デスクトップ Hub テーブルの列幅定義。ヘッダと行で共有する。
///
/// 固定列の合計は名前(Expanded)を除いて狭めに取り、中ペインが 600px 程度でも
/// オーバーフローしないようにしている(以前は合計 668px で 667px ペインに
/// 収まらず RenderFlex overflow が出ていた)。
class ClientRowLayout {
  static const double checkbox = 44;
  static const double platform = 36;
  static const double ip = 108;
  static const double vu = 8;
  static const double volume = 96;
  static const double volumeLabel = 44;
  static const double actions = 152;
  static const double diagnostics = 60;
}

/// テーブルのヘッダ行(全選択チェックボックス + 列見出し)。
class ClientRowHeader extends ConsumerWidget {
  /// 現在ヘッダのチェックボックスで全選択の対象になる可視クライアント id 群。
  final List<String> visibleIds;

  const ClientRowHeader({super.key, required this.visibleIds});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(hubSelectionProvider);
    final notifier = ref.read(hubSelectionProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    final allSelected = visibleIds.isNotEmpty &&
        visibleIds.every((id) => selection.contains(id));
    final someSelected =
        visibleIds.any((id) => selection.contains(id)) && !allSelected;

    final headerStyle = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: scheme.onSurfaceVariant,
    );

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: ClientRowLayout.checkbox,
            child: Checkbox(
              value: allSelected ? true : (someSelected ? null : false),
              tristate: true,
              onChanged: (_) {
                if (allSelected) {
                  notifier.clear();
                } else {
                  notifier.selectAll(visibleIds);
                }
              },
            ),
          ),
          SizedBox(width: ClientRowLayout.platform),
          Expanded(child: Text('名前', style: headerStyle)),
          SizedBox(
            width: ClientRowLayout.ip,
            child: Text('IP', style: headerStyle),
          ),
          SizedBox(width: ClientRowLayout.vu),
          const SizedBox(width: AppSpacing.s),
          SizedBox(
            width: ClientRowLayout.volume,
            child: Text('音量', style: headerStyle),
          ),
          SizedBox(width: ClientRowLayout.volumeLabel),
          SizedBox(
            width: ClientRowLayout.actions,
            child: Text('操作', style: headerStyle, textAlign: TextAlign.center),
          ),
          SizedBox(
            width: ClientRowLayout.diagnostics,
            child: Text('品質', style: headerStyle),
          ),
        ],
      ),
    );
  }
}

/// デスクトップのテーブル行1つ。DataRow ではなく自前 Row で構築する。
class ClientRow extends ConsumerWidget {
  final ClientInfo client;

  /// タップで詳細ペインに表示するための選択(行ハイライト用)。
  final bool highlighted;
  final VoidCallback? onTap;

  const ClientRow({
    super.key,
    required this.client,
    this.highlighted = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(hubControllerProvider);
    final selected = ref.watch(
      hubSelectionProvider.select((s) => s.contains(client.id)),
    );
    final scheme = Theme.of(context).colorScheme;
    final colors = context.statusColors;
    final active = client.isActive;

    return Material(
      color: highlighted
          ? scheme.primaryContainer.withValues(alpha: 0.4)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Opacity(
          opacity: active ? 1.0 : 0.55,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s,
              vertical: AppSpacing.xs,
            ),
            child: Row(
              children: [
                // 選択チェックボックス
                SizedBox(
                  width: ClientRowLayout.checkbox,
                  child: Checkbox(
                    value: selected,
                    onChanged: (_) => ref
                        .read(hubSelectionProvider.notifier)
                        .toggle(client.id),
                  ),
                ),
                // プラットフォーム + 接続ドット
                SizedBox(
                  width: ClientRowLayout.platform,
                  child: Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      Icon(
                        platformIcon(client.platform),
                        size: 26,
                        color:
                            active ? scheme.onSurfaceVariant : scheme.outline,
                      ),
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: active ? colors.connected : scheme.outline,
                          border: Border.all(
                            color: scheme.surface,
                            width: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // 名前 + 状態ピル
                Expanded(
                  child: Row(
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
                        const SizedBox(width: AppSpacing.xs),
                        _Pill(
                          label: '切断',
                          background: scheme.surfaceContainerHighest,
                          foreground: scheme.onSurfaceVariant,
                        ),
                      ] else if (client.isPaused) ...[
                        const SizedBox(width: AppSpacing.xs),
                        _Pill(
                          label: '一時停止中',
                          background: colors.paused.withValues(alpha: 0.18),
                          foreground: colors.paused,
                        ),
                      ],
                    ],
                  ),
                ),
                // IP
                SizedBox(
                  width: ClientRowLayout.ip,
                  child: Text(
                    client.ip,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                // VU メーター(ヘッダの vu 列幅と揃える)
                SizedBox(
                  width: ClientRowLayout.vu,
                  child: VuMeter(
                    level: active ? client.vuLevel : 0.0,
                    width: ClientRowLayout.vu,
                    height: 28,
                  ),
                ),
                const SizedBox(width: AppSpacing.s),
                // 音量スライダ
                SizedBox(
                  width: ClientRowLayout.volume,
                  child: Slider(
                    value: client.isMuted ? 0 : client.volume,
                    min: 0,
                    max: 1,
                    onChanged: client.isMuted
                        ? null
                        : (v) => controller.setClientVolume(client.id, v),
                  ),
                ),
                // 音量 % / ミュート表示
                SizedBox(
                  width: ClientRowLayout.volumeLabel,
                  child: Text(
                    client.isMuted
                        ? 'ミュート'
                        : '${(client.volume * 100).round()}%',
                    style: TextStyle(
                      fontSize: 11,
                      color: client.isMuted
                          ? colors.disconnected
                          : scheme.onSurface,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                // 操作(ミュート / pause-resume / 停止 / 削除)
                SizedBox(
                  width: ClientRowLayout.actions,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: Icon(
                          client.isMuted ? Icons.volume_off : Icons.volume_up,
                          size: 20,
                          color: client.isMuted
                              ? colors.disconnected
                              : scheme.onSurfaceVariant,
                        ),
                        tooltip: client.isMuted ? 'ミュート解除' : 'ミュート',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => controller.setClientMuted(
                          client.id,
                          muted: !client.isMuted,
                        ),
                      ),
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
                          visualDensity: VisualDensity.compact,
                          onPressed: () => client.isPaused
                              ? controller.resumeClient(client.id)
                              : controller.pauseClient(client.id),
                        ),
                      // 停止(stopClient) — 接続中かつ v2 のみ
                      if (active && client.protocolVersion >= 2)
                        IconButton(
                          icon: Icon(
                            Icons.stop_circle_outlined,
                            size: 20,
                            color: colors.disconnected,
                          ),
                          tooltip: '配信を停止させる',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => controller.stopClient(client.id),
                        ),
                      // 切断済みは一覧から削除
                      if (!active)
                        IconButton(
                          icon: Icon(Icons.close,
                              size: 20, color: scheme.outline),
                          tooltip: '一覧から削除(音量設定は保持)',
                          visualDensity: VisualDensity.compact,
                          onPressed: () =>
                              controller.removeClientEntry(client.id),
                        ),
                    ],
                  ),
                ),
                // 診断チップ(コンパクト)
                SizedBox(
                  width: ClientRowLayout.diagnostics,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: DiagnosticsChip(uuid: client.id, compact: true),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 状態を表す小さなピル型ラベル。
class _Pill extends StatelessWidget {
  final String label;
  final Color background;
  final Color foreground;

  const _Pill({
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
        borderRadius: AppRadius.allS,
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, color: foreground),
      ),
    );
  }
}
