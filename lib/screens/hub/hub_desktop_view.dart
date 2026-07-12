import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/client_info.dart';
import '../../providers/hub_state_provider.dart';
import '../../providers/hub_selection_provider.dart';
import '../../providers/visible_clients_provider.dart';
import '../../theme/app_spacing.dart';
import '../../widgets/hub/client_row.dart';
import '../../widgets/hub/client_toolbar.dart';
import '../../widgets/hub/diagnostics_chip.dart';
import '../../widgets/hub/hub_dashboard.dart';
import '../../widgets/vu_meter.dart';

/// 広幅(デスクトップ)向けの Hub 表示。
///
/// 3ペイン構成:
///   左  = [HubDashboard](固定幅・情報集約)
///   中  = [ClientToolbar] + クライアントテーブル([ClientRow] 列挙)
///   右  = 選択が1件のときだけ詳細 + 診断([_ClientDetailPane])
class HubDesktopView extends ConsumerStatefulWidget {
  const HubDesktopView({super.key});

  @override
  ConsumerState<HubDesktopView> createState() => _HubDesktopViewState();
}

class _HubDesktopViewState extends ConsumerState<HubDesktopView> {
  /// 右ペインに詳細表示するクライアント(テーブル行タップで設定)。
  String? _detailUuid;

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(hubStateProvider);
    final visible = ref.watch(visibleClientsProvider);
    final scheme = Theme.of(context).colorScheme;

    // 詳細対象がいなくなった(切断・削除)場合はペインを閉じる。
    final detail = _detailUuid == null ? null : all[_detailUuid];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 左: ダッシュボード(固定幅)
        const SizedBox(
          width: 280,
          child: HubDashboard(),
        ),
        VerticalDivider(width: 1, color: scheme.outlineVariant),
        // 中: ツールバー + テーブル
        Expanded(
          child: Column(
            children: [
              const ClientToolbar(),
              ClientRowHeader(
                visibleIds: [for (final c in visible) c.id],
              ),
              Expanded(
                child: all.isEmpty
                    ? const _EmptyState()
                    : visible.isEmpty
                        ? const _NoMatchState()
                        : ListView.builder(
                            itemCount: visible.length,
                            itemBuilder: (context, i) {
                              final c = visible[i];
                              return ClientRow(
                                client: c,
                                highlighted: c.id == _detailUuid,
                                onTap: () => setState(
                                  () => _detailUuid =
                                      c.id == _detailUuid ? null : c.id,
                                ),
                              );
                            },
                          ),
              ),
            ],
          ),
        ),
        // 右: 選択1件の詳細 + 診断
        if (detail != null) ...[
          VerticalDivider(width: 1, color: scheme.outlineVariant),
          SizedBox(
            width: 300,
            child: _ClientDetailPane(
              client: detail,
              onClose: () => setState(() => _detailUuid = null),
            ),
          ),
        ],
      ],
    );
  }
}

/// 右ペイン: 選択中クライアント1件の詳細と診断。
class _ClientDetailPane extends ConsumerWidget {
  final ClientInfo client;
  final VoidCallback onClose;

  const _ClientDetailPane({required this.client, required this.onClose});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final selected = ref.watch(
      hubSelectionProvider.select((s) => s.contains(client.id)),
    );

    return ListView(
      padding: AppSpacing.screenPadding,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                client.name,
                style: Theme.of(context).textTheme.titleMedium,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              tooltip: '詳細を閉じる',
              visualDensity: VisualDensity.compact,
              onPressed: onClose,
            ),
          ],
        ),
        AppSpacing.gapS,
        _DetailRow(label: 'IP', value: '${client.ip}:${client.port}'),
        _DetailRow(label: 'デバイス ID', value: client.id),
        _DetailRow(
          label: 'プロトコル',
          value: 'v${client.protocolVersion}',
        ),
        _DetailRow(
          label: '状態',
          value: !client.isActive
              ? '切断'
              : client.isPaused
                  ? '一時停止中'
                  : '接続中',
        ),
        AppSpacing.gapM,
        Row(
          children: [
            Text('レベル', style: TextStyle(color: scheme.onSurfaceVariant)),
            AppSpacing.gapM,
            VuMeter(
              level: client.isActive ? client.vuLevel : 0.0,
              height: 60,
            ),
          ],
        ),
        AppSpacing.gapM,
        Text('接続品質', style: Theme.of(context).textTheme.labelLarge),
        AppSpacing.gapS,
        DiagnosticsChip(uuid: client.id),
        AppSpacing.gapM,
        // 選択集合への追加/除外(一括操作の対象にする)
        FilledButton.tonalIcon(
          icon: Icon(selected ? Icons.check_box : Icons.check_box_outline_blank,
              size: 18),
          label: Text(selected ? '選択を解除' : '一括操作の対象に追加'),
          onPressed: () =>
              ref.read(hubSelectionProvider.notifier).toggle(client.id),
        ),
      ],
    );
  }
}

/// ラベル + 値の詳細1行。
class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

/// クライアント未接続時の案内。
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.wifi_find, size: 64, color: scheme.outline),
          AppSpacing.gapM,
          Text(
            'クライアントを待っています...',
            style: TextStyle(fontSize: 18, color: scheme.onSurfaceVariant),
          ),
          AppSpacing.gapS,
          Text(
            '他のデバイスでアプリを起動し、「クライアント」を選択してください',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// 検索/フィルタに一致しないとき。
class _NoMatchState extends StatelessWidget {
  const _NoMatchState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.filter_alt_off, size: 48, color: scheme.outline),
          AppSpacing.gapS,
          Text(
            '条件に一致するクライアントがいません',
            style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
