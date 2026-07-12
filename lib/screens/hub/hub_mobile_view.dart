import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/hub_state_provider.dart';
import '../../providers/visible_clients_provider.dart';
import '../../theme/app_spacing.dart';
import '../../widgets/client_tile.dart';
import '../../widgets/hub/client_toolbar.dart';

/// 狭幅(モバイル/縦持ち)向けの Hub 表示。
///
/// 上部に接続サマリと検索/フィルタの [ClientToolbar]、その下に
/// [visibleClientsProvider] を購読した縦リストを並べる。
class HubMobileView extends ConsumerWidget {
  const HubMobileView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(hubStateProvider);
    final visible = ref.watch(visibleClientsProvider);
    final activeCount = all.values.where((c) => c.isActive).length;

    return Column(
      children: [
        // 接続サマリ
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.m,
            vertical: AppSpacing.s,
          ),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Text(
            all.isEmpty
                ? 'クライアント待機中'
                : '接続中 $activeCount / ${all.length} 台',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        // 検索/フィルタ(モバイルは一括操作バーも表示)
        const ClientToolbar(),
        Expanded(
          child: all.isEmpty
              ? const _EmptyState()
              : visible.isEmpty
                  ? const _NoMatchState()
                  : ListView(
                      children: [
                        for (final c in visible) ClientTile(client: c),
                        const SizedBox(height: AppSpacing.m),
                      ],
                    ),
        ),
      ],
    );
  }
}

/// まだ誰も接続していないときの案内。
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
          Padding(
            padding: AppSpacing.screenPadding,
            child: Text(
              '他のデバイスでアプリを起動し、「クライアント」を選択してください',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

/// 接続はあるが検索/フィルタに一致するクライアントがいないとき。
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
