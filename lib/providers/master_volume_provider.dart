import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// マスター音量キー。HubController と共有する(値の実体は同一)。
const kMasterVolumeKey = 'hub_master_volume';

/// マスター音量(0.0〜1.0)の UI 単一ソース。
///
/// 実効音量の適用(各クライアントの volume * master をミキサーへ反映)は
/// HubController が担う。この provider は UI の表示・入力値を保持し永続化する
/// 役割で、UI 側は set 時に `HubController.setMasterVolume` も併せて呼ぶ。
/// キー `hub_master_volume` は HubController と共有し、双方から同じ値を書く。
class MasterVolumeNotifier extends Notifier<double> {
  @override
  double build() => 1.0;

  Future<void> setMasterVolume(double volume) async {
    state = volume.clamp(0.0, 1.0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(kMasterVolumeKey, state);
  }

  Future<double> restore() async {
    final prefs = await SharedPreferences.getInstance();
    state = (prefs.getDouble(kMasterVolumeKey) ?? 1.0).clamp(0.0, 1.0);
    return state;
  }
}

final masterVolumeProvider =
    NotifierProvider<MasterVolumeNotifier, double>(
  MasterVolumeNotifier.new,
);
