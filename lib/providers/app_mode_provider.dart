import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/app_mode.dart';

const _kModeKey = 'app_mode';
const _kNameKey = 'device_name';
const _kClientUuidKey = 'client_uuid';

class AppModeNotifier extends Notifier<AppMode?> {
  @override
  AppMode? build() => null; // null = not yet chosen

  Future<void> setMode(AppMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kModeKey, mode.name);
  }

  Future<AppMode?> restoreMode() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kModeKey);
    if (raw == null) return null;
    final mode = AppMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => AppMode.client,
    );
    state = mode;
    return mode;
  }

  Future<void> reset() async {
    state = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kModeKey);
  }
}

final appModeProvider = NotifierProvider<AppModeNotifier, AppMode?>(
  AppModeNotifier.new,
);

// Device name (used by both hub and client)
class DeviceNameNotifier extends Notifier<String> {
  @override
  String build() => 'Device';

  Future<void> setName(String name) async {
    state = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kNameKey, name);
  }

  Future<void> restoreName() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getString(_kNameKey) ?? 'Device';
  }
}

final deviceNameProvider = NotifierProvider<DeviceNameNotifier, String>(
  DeviceNameNotifier.new,
);

/// クライアントを一意に識別する UUID(Hub 側で client_id を割り当てる際の鍵)。
///
/// 旧実装は `Uuid().v4()` を起動毎に生成していたため、Hub から見ると同じ
/// 物理デバイスでも毎回別クライアントとして扱われ、Hub の `_nextClientId` が
/// 単調増加して miniaudio ミキサーの MAX_CLIENTS=16 を食い潰し、最終的に
/// 音が再生されなくなる不具合があった。本プロバイダで永続化する。
class ClientUuidNotifier extends Notifier<String> {
  @override
  String build() => '';

  /// 起動時に SharedPreferences から復元、なければ新規生成して永続化。
  Future<String> restoreOrCreate() async {
    final prefs = await SharedPreferences.getInstance();
    var uuid = prefs.getString(_kClientUuidKey);
    if (uuid == null || uuid.isEmpty) {
      uuid = const Uuid().v4();
      await prefs.setString(_kClientUuidKey, uuid);
    }
    state = uuid;
    return uuid;
  }
}

final clientUuidProvider = NotifierProvider<ClientUuidNotifier, String>(
  ClientUuidNotifier.new,
);
