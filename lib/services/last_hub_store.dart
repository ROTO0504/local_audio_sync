import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/control_messages.dart';
import 'discovery_service.dart';

/// 前回接続した Hub を 1 件だけ JSON で保存する。
///
/// [ManualHubStore] が `ip:port` の履歴(手動接続用)を持つのに対し、
/// こちらは hubId を含む「前回つないだ Hub」を覚えておき、次回起動時に
/// 発見集合へ同じ hubId が現れたら自動再接続するために使う。
class LastHubStore {
  static const String _kKey = 'last_connected_hub';

  /// 前回接続した Hub を保存する(上書き)。
  Future<void> saveLastHub(DiscoveredHub hub) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode({
      'ip': hub.ip,
      'port': hub.port,
      'name': hub.name,
      'hubId': hub.hubId,
      'proto': hub.protocolVersion,
    });
    await prefs.setString(_kKey, json);
  }

  /// 保存済みの前回 Hub を復元する。無ければ / 壊れていれば null。
  Future<DiscoveredHub?> loadLastHub() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final ip = map['ip'] as String?;
      final port = map['port'] as int?;
      final name = map['name'] as String?;
      if (ip == null || port == null || name == null) return null;
      return DiscoveredHub(
        ip: ip,
        port: port,
        name: name,
        hubId: map['hubId'] as String?,
        protocolVersion: (map['proto'] as int?) ?? kProtocolVersionLegacy,
      );
    } catch (_) {
      return null;
    }
  }

  /// 記憶している前回 Hub を消す(設定画面の「記憶 Hub 管理」用)。
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kKey);
  }
}
