import 'package:shared_preferences/shared_preferences.dart';

import 'discovery_service.dart' show kAudioPort;

/// 手動接続した Hub(`ip:port`)の履歴を保存する。
///
/// ブロードキャスト / mDNS が届かないネットワーク(別セグメント、VPN、
/// WAN)では自動探索で Hub が見つからないため、ユーザーが IP:ポートを
/// 直接入力して接続する。よく使う接続先をすぐ選べるよう直近 5 件を残す。
class ManualHubStore {
  static const String _kHistoryKey = 'manual_hub_history';
  static const String _kDefaultPortKey = 'client_default_port';
  static const int _kMaxEntries = 5;

  /// 手動接続時の既定ポート(設定画面で変更可能)。未設定なら [kAudioPort]。
  Future<int> loadDefaultPort() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_kDefaultPortKey) ?? kAudioPort;
  }

  Future<void> saveDefaultPort(int port) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kDefaultPortKey, port);
  }

  /// 直近の接続先(新しい順)。各要素は `ip:port` 形式。
  Future<List<String>> loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_kHistoryKey) ?? const [];
  }

  /// 接続先を履歴の先頭に記録する(重複は先頭へ移動、最大 5 件)。
  Future<void> add(String ip, int port) async {
    final entry = '$ip:$port';
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList(_kHistoryKey) ?? [];
    history.remove(entry);
    history.insert(0, entry);
    if (history.length > _kMaxEntries) {
      history.removeRange(_kMaxEntries, history.length);
    }
    await prefs.setStringList(_kHistoryKey, history);
  }

  /// 履歴から 1 件を削除する(設定画面の記憶 Hub 管理用)。
  Future<void> remove(String entry) async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList(_kHistoryKey) ?? [];
    if (history.remove(entry)) {
      await prefs.setStringList(_kHistoryKey, history);
    }
  }

  /// 履歴をすべて消す。
  Future<void> clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kHistoryKey);
  }

  /// `ip:port` 文字列をパースする。不正なら null。
  static ({String ip, int port})? parse(String entry) {
    final index = entry.lastIndexOf(':');
    if (index <= 0) return null;
    final ip = entry.substring(0, index);
    final port = int.tryParse(entry.substring(index + 1));
    if (port == null || port < 1 || port > 65535) return null;
    return (ip: ip, port: port);
  }
}
