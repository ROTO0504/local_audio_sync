import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Hub(集約・再生)モード中に OS へバックグラウンド動作の継続を要求する。
///
/// - Android: mediaPlayback 種別のフォアグラウンドサービス(HubPlaybackService)
///   を起動し、通知 + WakeLock + MulticastLock で受信・再生を維持する
/// - iOS: AVAudioSession を .playback で activate し、
///   UIBackgroundModes: audio によりバックグラウンド再生を維持する
/// - Windows / macOS: 何もしない(デスクトップはバックグラウンド制限がない)
///
/// プラットフォームチャネルが未実装の環境(テスト等)では例外を握って続行する。
class HubBackgroundKeeper {
  static const MethodChannel _androidChannel =
      MethodChannel('com.example.local_audio_sync/broadcast');
  static const MethodChannel _iosChannel =
      MethodChannel('com.example.local_audio_sync/hubPlayback');

  Future<void> start() async {
    try {
      if (Platform.isAndroid) {
        await _androidChannel.invokeMethod('startHubPlayback');
      } else if (Platform.isIOS) {
        await _iosChannel.invokeMethod('start');
      }
    } catch (e) {
      debugPrint('[HubBackgroundKeeper] start 失敗(前面での動作は継続): $e');
    }
  }

  Future<void> stop() async {
    try {
      if (Platform.isAndroid) {
        await _androidChannel.invokeMethod('stopHubPlayback');
      } else if (Platform.isIOS) {
        await _iosChannel.invokeMethod('stop');
      }
    } catch (e) {
      debugPrint('[HubBackgroundKeeper] stop 失敗: $e');
    }
  }
}
