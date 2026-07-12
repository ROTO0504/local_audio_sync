import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hub 側で覚えておくクライアントごとの設定。
@immutable
class ClientSettings {
  final double volume;
  final bool isMuted;

  const ClientSettings({this.volume = 1.0, this.isMuted = false});

  Map<String, dynamic> toJson() => {'volume': volume, 'isMuted': isMuted};

  static ClientSettings? fromJson(Map<String, dynamic> json) {
    final volume = (json['volume'] as num?)?.toDouble();
    final isMuted = json['isMuted'] as bool?;
    if (volume == null && isMuted == null) return null;
    return ClientSettings(
      volume: (volume ?? 1.0).clamp(0.0, 1.0),
      isMuted: isMuted ?? false,
    );
  }
}

/// クライアント設定(音量 / ミュート)を永続デバイス UUID キーで保存する。
///
/// クライアントが再接続してきたとき(HELLO 受信時)にここから復元することで、
/// アプリや Hub を再起動しても「あのデバイスは音量 30%」が引き継がれる。
class ClientSettingsStore {
  static const String _kKeyPrefix = 'client_settings_';

  Future<ClientSettings?> load(String uuid) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_kKeyPrefix$uuid');
    if (raw == null) return null;
    try {
      return ClientSettings.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (e) {
      debugPrint('[ClientSettingsStore] 破損した設定を無視します ($uuid): $e');
      return null;
    }
  }

  Future<void> save(String uuid, ClientSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_kKeyPrefix$uuid',
      jsonEncode(settings.toJson()),
    );
  }

  Future<void> remove(String uuid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_kKeyPrefix$uuid');
  }
}
