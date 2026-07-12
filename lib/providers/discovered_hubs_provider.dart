import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/discovery_service.dart';

/// 発見済みの Hub 集合(キー `hubId ?? 'ip:port'`)を保持する Notifier。
///
/// 旧実装は「最初に見つかった Hub に繋ぐ(first-wins)」だけで複数 Hub を
/// 同時に扱えなかった。ここでは UDP ビーコン / mDNS 両経路のヒットを
/// [upsert] で集約し、[pruneStale] で古くなったものを落とすことで、
/// ピッカーが「今生きている Hub 一覧」を購読できるようにする。
class DiscoveredHubsNotifier extends Notifier<Map<String, DiscoveredHub>> {
  /// キーごとの最終受信時刻。pruneStale で古い Hub を除去するために使う。
  final Map<String, DateTime> _lastSeen = {};

  @override
  Map<String, DiscoveredHub> build() => const {};

  /// Hub のキー(`hubId ?? 'ip:port'`)。
  static String keyOf(DiscoveredHub hub) => ClientDiscoveryListener.keyOf(hub);

  /// Hub を集合へ追加 / 更新する。
  ///
  /// v1 / v2 ビーコンが交互に届くと、同じ物理 Hub でも v1 は `ip:port`、
  /// v2 は `hubId` と別キーになり得る。二重表示を避けるため、hubId 付きを
  /// 受け取ったら同一 `ip:port` の v1 エントリを畳み、逆に hubId なしを
  /// 受け取ったときは既に hubId 付きの同一 `ip:port` があればそちらを優先する。
  void upsert(DiscoveredHub hub) {
    final key = keyOf(hub);
    final ipPortKey = '${hub.ip}:${hub.port}';
    final next = Map<String, DiscoveredHub>.from(state);

    if (hub.hubId != null) {
      // v2: 同一 ip:port の v1 エントリがあれば畳む
      if (next.remove(ipPortKey) != null) {
        _lastSeen.remove(ipPortKey);
      }
    } else {
      // v1: 既に同一 ip:port の hubId 付きエントリがあれば、そちらを維持
      final hasV2 = next.entries.any(
        (e) => e.value.hubId != null && '${e.value.ip}:${e.value.port}' == ipPortKey,
      );
      if (hasV2) {
        return;
      }
    }

    _lastSeen[key] = DateTime.now();
    next[key] = hub;
    state = next;
  }

  /// [maxAge] より古い最終受信の Hub を集合から取り除く。
  void pruneStale(Duration maxAge) {
    final now = DateTime.now();
    final next = Map<String, DiscoveredHub>.from(state);
    var changed = false;
    for (final key in state.keys.toList()) {
      final seen = _lastSeen[key];
      if (seen == null || now.difference(seen) > maxAge) {
        next.remove(key);
        _lastSeen.remove(key);
        changed = true;
      }
    }
    if (changed) state = next;
  }

  /// 指定キーの Hub を明示的に取り除く。
  void remove(String key) {
    if (!state.containsKey(key)) return;
    final next = Map<String, DiscoveredHub>.from(state)..remove(key);
    _lastSeen.remove(key);
    state = next;
  }

  /// 集合をすべてクリアする(自動探索の再スタート時など)。
  void clear() {
    _lastSeen.clear();
    state = const {};
  }
}

final discoveredHubsProvider =
    NotifierProvider<DiscoveredHubsNotifier, Map<String, DiscoveredHub>>(
  DiscoveredHubsNotifier.new,
);
