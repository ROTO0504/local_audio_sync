import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// 端末を一意に識別する永続 UUID を管理する。
///
/// 旧実装はクライアント画面の State 生成毎に UUID v4 を発行していたため、
/// アプリを再起動すると Hub からは別デバイスに見え、音量などの設定を
/// 引き継げなかった。本サービスは初回に生成した ID を shared_preferences に
/// 保存し、以降は常に同じ値を返す。
///
/// Hub 役として動くときのビーコン識別用 ID(hubId)も同じ仕組みで
/// 別キーに保持する(クライアント側の「前回接続した Hub」判定に使う)。
class DeviceIdentityService {
  static const String _kClientUuidKey = 'device_identity_client_uuid';
  static const String _kHubIdKey = 'device_identity_hub_id';

  static String? _cachedClientUuid;
  static String? _cachedHubId;

  /// クライアント(送信側)としての永続 UUID。
  Future<String> getClientUuid() async {
    return _cachedClientUuid ??= await _getOrCreate(_kClientUuidKey);
  }

  /// Hub(集約・再生側)としての永続 ID。
  Future<String> getHubId() async {
    return _cachedHubId ??= await _getOrCreate(_kHubIdKey);
  }

  Future<String> _getOrCreate(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(key);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = const Uuid().v4();
    await prefs.setString(key, id);
    return id;
  }

  /// テスト用: メモリキャッシュを破棄する(shared_preferences は触らない)。
  static void resetCache() {
    _cachedClientUuid = null;
    _cachedHubId = null;
  }
}
