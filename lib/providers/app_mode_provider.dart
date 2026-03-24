import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_mode.dart';

const _kModeKey = 'app_mode';
const _kNameKey = 'device_name';

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
