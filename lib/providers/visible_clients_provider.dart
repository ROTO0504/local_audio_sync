import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/client_info.dart';
import 'hub_diagnostics_provider.dart';
import 'hub_state_provider.dart';
import 'hub_view_prefs_provider.dart';

/// フィルタ・検索・ソートを適用済みの表示用クライアント一覧。
///
/// `hubStateProvider`(生データ)+ `hubViewPrefsProvider`(表示設定)+
/// `hubDiagnosticsProvider`(ロス率などの派生値)を合成する派生 provider。
/// モバイル/デスクトップ両ビューがこれを watch して描画する。
///
/// 適用順序: filter → query(name/ip 部分一致・大文字小文字無視)→ sort。
final visibleClientsProvider = Provider<List<ClientInfo>>((ref) {
  final clients = ref.watch(hubStateProvider);
  final prefs = ref.watch(hubViewPrefsProvider);
  final diagnostics = ref.watch(hubDiagnosticsProvider);

  // 1. フィルタ
  Iterable<ClientInfo> list = clients.values.where((c) {
    switch (prefs.filter) {
      case HubFilter.all:
        return true;
      case HubFilter.active:
        return c.isActive;
      case HubFilter.paused:
        return c.isPaused;
      case HubFilter.muted:
        return c.isMuted;
      case HubFilter.disconnected:
        return !c.isActive;
    }
  });

  // 2. 検索クエリ(name / ip の部分一致、大文字小文字を無視)
  final query = prefs.query.trim().toLowerCase();
  if (query.isNotEmpty) {
    list = list.where((c) =>
        c.name.toLowerCase().contains(query) ||
        c.ip.toLowerCase().contains(query));
  }

  // 3. ソート
  final result = list.toList();
  int cmp(ClientInfo a, ClientInfo b) {
    switch (prefs.sortKey) {
      case HubSortKey.name:
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case HubSortKey.volume:
        return a.volume.compareTo(b.volume);
      case HubSortKey.lossRate:
        final la = diagnostics[a.id]?.lossRate ?? 0.0;
        final lb = diagnostics[b.id]?.lossRate ?? 0.0;
        return la.compareTo(lb);
      case HubSortKey.lastSeen:
        return a.lastSeen.compareTo(b.lastSeen);
      case HubSortKey.platform:
        return a.platform.compareTo(b.platform);
    }
  }

  result.sort((a, b) => prefs.ascending ? cmp(a, b) : cmp(b, a));
  return result;
});
