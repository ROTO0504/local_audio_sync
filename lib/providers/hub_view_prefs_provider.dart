import 'package:flutter_riverpod/flutter_riverpod.dart';

/// クライアント一覧のソートキー。
enum HubSortKey { name, volume, lossRate, lastSeen, platform }

/// クライアント一覧のフィルタ条件。
enum HubFilter { all, active, paused, muted, disconnected }

/// 一覧の表示設定(ソート・フィルタ・検索)。イミュータブル。
class HubViewPrefs {
  final HubSortKey sortKey;
  final bool ascending;
  final HubFilter filter;
  final String query;

  const HubViewPrefs({
    this.sortKey = HubSortKey.name,
    this.ascending = true,
    this.filter = HubFilter.all,
    this.query = '',
  });

  HubViewPrefs copyWith({
    HubSortKey? sortKey,
    bool? ascending,
    HubFilter? filter,
    String? query,
  }) {
    return HubViewPrefs(
      sortKey: sortKey ?? this.sortKey,
      ascending: ascending ?? this.ascending,
      filter: filter ?? this.filter,
      query: query ?? this.query,
    );
  }
}

/// 一覧の表示設定を保持する。UI(ツールバー)から各 setter で更新する。
class HubViewPrefsNotifier extends Notifier<HubViewPrefs> {
  @override
  HubViewPrefs build() => const HubViewPrefs();

  void setSortKey(HubSortKey key) {
    state = state.copyWith(sortKey: key);
  }

  void toggleAscending() {
    state = state.copyWith(ascending: !state.ascending);
  }

  void setFilter(HubFilter filter) {
    state = state.copyWith(filter: filter);
  }

  void setQuery(String query) {
    state = state.copyWith(query: query);
  }
}

final hubViewPrefsProvider =
    NotifierProvider<HubViewPrefsNotifier, HubViewPrefs>(
  HubViewPrefsNotifier.new,
);
