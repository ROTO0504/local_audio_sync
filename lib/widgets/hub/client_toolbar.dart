import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/hub_selection_provider.dart';
import '../../providers/hub_view_prefs_provider.dart';
import '../../providers/visible_clients_provider.dart';
import '../../services/hub_controller.dart';
import '../../theme/app_spacing.dart';

/// 検索・ソート・フィルタ・一括操作をまとめたツールバー。
///
/// モバイル/デスクトップ双方のリスト上部で共有する。
/// 検索/ソート/フィルタは [hubViewPrefsProvider] を、
/// 一括操作は [hubSelectionProvider] と [HubController] の *Selected 系を使う。
class ClientToolbar extends ConsumerStatefulWidget {
  /// 一括操作バーを表示するか(デスクトップでは true、モバイルは省略可)。
  final bool showBulkActions;

  const ClientToolbar({super.key, this.showBulkActions = true});

  @override
  ConsumerState<ClientToolbar> createState() => _ClientToolbarState();
}

class _ClientToolbarState extends ConsumerState<ClientToolbar> {
  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _searchController =
        TextEditingController(text: ref.read(hubViewPrefsProvider).query);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(hubViewPrefsProvider);
    final prefsNotifier = ref.read(hubViewPrefsProvider.notifier);
    final selection = ref.watch(hubSelectionProvider);

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.m,
        vertical: AppSpacing.s,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 検索 + ソート
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    hintText: '名前 / IP で検索',
                    suffixIcon: prefs.query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              prefsNotifier.setQuery('');
                            },
                          ),
                  ),
                  onChanged: prefsNotifier.setQuery,
                ),
              ),
              AppSpacing.gapS,
              _SortControl(
                sortKey: prefs.sortKey,
                ascending: prefs.ascending,
                onSortKeyChanged: prefsNotifier.setSortKey,
                onToggleAscending: prefsNotifier.toggleAscending,
              ),
            ],
          ),
          AppSpacing.gapS,
          // フィルタ
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<HubFilter>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: HubFilter.all, label: Text('すべて')),
                ButtonSegment(value: HubFilter.active, label: Text('接続中')),
                ButtonSegment(value: HubFilter.paused, label: Text('一時停止')),
                ButtonSegment(value: HubFilter.muted, label: Text('ミュート')),
                ButtonSegment(
                    value: HubFilter.disconnected, label: Text('切断')),
              ],
              selected: {prefs.filter},
              onSelectionChanged: (s) => prefsNotifier.setFilter(s.first),
            ),
          ),
          // 選択中のみ現れる一括操作バー
          if (widget.showBulkActions && selection.isNotEmpty) ...[
            AppSpacing.gapS,
            _BulkActionBar(selection: selection),
          ],
        ],
      ),
    );
  }
}

/// ソートキーのドロップダウン + 昇降トグル。
class _SortControl extends StatelessWidget {
  final HubSortKey sortKey;
  final bool ascending;
  final ValueChanged<HubSortKey> onSortKeyChanged;
  final VoidCallback onToggleAscending;

  const _SortControl({
    required this.sortKey,
    required this.ascending,
    required this.onSortKeyChanged,
    required this.onToggleAscending,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DropdownButton<HubSortKey>(
          value: sortKey,
          underline: const SizedBox.shrink(),
          items: [
            for (final key in HubSortKey.values)
              DropdownMenuItem(value: key, child: Text(_sortLabel(key))),
          ],
          onChanged: (v) {
            if (v != null) onSortKeyChanged(v);
          },
        ),
        IconButton(
          icon: Icon(ascending ? Icons.arrow_upward : Icons.arrow_downward,
              size: 20),
          tooltip: ascending ? '昇順' : '降順',
          visualDensity: VisualDensity.compact,
          onPressed: onToggleAscending,
        ),
      ],
    );
  }

  static String _sortLabel(HubSortKey key) => switch (key) {
        HubSortKey.name => '名前',
        HubSortKey.volume => '音量',
        HubSortKey.lossRate => 'ロス率',
        HubSortKey.lastSeen => '最終受信',
        HubSortKey.platform => '種別',
      };
}

/// 選択集合への一括操作バー(全選択/解除/pause/resume/stop/mute/unmute/音量)。
class _BulkActionBar extends ConsumerWidget {
  final Set<String> selection;

  const _BulkActionBar({required this.selection});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(hubControllerProvider);
    final selectionNotifier = ref.read(hubSelectionProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: AppRadius.allM,
      ),
      child: Row(
        children: [
          Text(
            '${selection.length} 台選択中',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: scheme.onSecondaryContainer,
            ),
          ),
          AppSpacing.gapS,
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.select_all, size: 18),
                    label: const Text('全選択'),
                    onPressed: () {
                      final ids = ref
                          .read(visibleClientsProvider)
                          .map((c) => c.id);
                      selectionNotifier.selectAll(ids);
                    },
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.deselect, size: 18),
                    label: const Text('解除'),
                    onPressed: selectionNotifier.clear,
                  ),
                  const _Sep(),
                  _ActionButton(
                    icon: Icons.pause_circle_outline,
                    tooltip: '一括で一時停止',
                    onPressed: () => controller.pauseSelected(selection),
                  ),
                  _ActionButton(
                    icon: Icons.play_circle_outline,
                    tooltip: '一括で再開',
                    onPressed: () => controller.resumeSelected(selection),
                  ),
                  _ActionButton(
                    icon: Icons.stop_circle_outlined,
                    tooltip: '一括で停止',
                    onPressed: () => controller.stopSelected(selection),
                  ),
                  const _Sep(),
                  _ActionButton(
                    icon: Icons.volume_off,
                    tooltip: '一括でミュート',
                    onPressed: () => controller.muteSelected(selection, true),
                  ),
                  _ActionButton(
                    icon: Icons.volume_up,
                    tooltip: '一括でミュート解除',
                    onPressed: () => controller.muteSelected(selection, false),
                  ),
                  const _Sep(),
                  SizedBox(
                    width: 140,
                    child: _BulkVolumeSlider(selection: selection),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 選択集合の音量を一括設定するスライダ。
class _BulkVolumeSlider extends ConsumerStatefulWidget {
  final Set<String> selection;

  const _BulkVolumeSlider({required this.selection});

  @override
  ConsumerState<_BulkVolumeSlider> createState() => _BulkVolumeSliderState();
}

class _BulkVolumeSliderState extends ConsumerState<_BulkVolumeSlider> {
  double _value = 1.0;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.tune, size: 18),
        Expanded(
          child: Slider(
            value: _value,
            min: 0,
            max: 1,
            onChanged: (v) => setState(() => _value = v),
            onChangeEnd: (v) => ref
                .read(hubControllerProvider)
                .setSelectedVolume(widget.selection, v),
          ),
        ),
      ],
    );
  }
}

/// 一括操作用の小さなアイコンボタン。
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _ActionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 20),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
    );
  }
}

/// 区切りの縦線。
class _Sep extends StatelessWidget {
  const _Sep();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: SizedBox(
        height: 20,
        child: VerticalDivider(
          width: 1,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
    );
  }
}
