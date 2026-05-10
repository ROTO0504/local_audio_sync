import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'pcm_chunker.dart';

/// 内部音声(他アプリの再生音)をキャプチャしてくれる各 OS のネイティブ実装の
/// 共通ファサード。すべて同じ PCM16 ステレオ 48kHz / 20ms チャンクで吐く。
///
/// プラットフォームごとの実体:
///
/// - iOS / iPadOS:
///     Broadcast Upload Extension が他アプリの音を取り込み、UNIX Domain
///     Socket(App Group コンテナ内)経由でメインアプリへ。メインアプリの
///     `BroadcastReceiverPlugin` が EventChannel に流す。
///     `requestPermission` は `RPSystemBroadcastPickerView` をユーザーが
///     タップして配信を始めることが前提なので、自動許可は出さない。
/// - Android:
///     `MediaProjection` + `AudioPlaybackCaptureConfiguration` で、対象アプリが
///     `allowAudioPlaybackCapture` 許可しているもののみキャプチャ。
///     `requestPermission` でシステムダイアログを表示する。
/// - macOS:
///     ScreenCaptureKit ベースの内部音声キャプチャ(フェーズ3で実装予定)。
/// - Windows:
///     WASAPI loopback ベースのキャプチャ(フェーズ4で実装予定)。
class ScreenAudioCaptureService {
  static const _methodChannel =
      MethodChannel('com.example.local_audio_sync/broadcast');
  static const _eventChannel =
      EventChannel('com.example.local_audio_sync/screenAudio');

  StreamSubscription? _sub;
  final StreamController<Uint8List> _pcmController =
      StreamController<Uint8List>.broadcast();

  Stream<Uint8List> get pcmStream => _pcmController.stream;

  bool _isCapturing = false;
  bool get isCapturing => _isCapturing;

  /// Android のみ: MediaProjection 同意ダイアログを出して許可を取る。
  /// iOS は Picker タップを前提とするため常に true(実際の開始は別経路)。
  /// macOS / Windows / その他は将来実装、現状は true を返す。
  Future<bool> requestPermission() async {
    if (Platform.isAndroid) {
      try {
        final ok =
            await _methodChannel.invokeMethod<bool>('requestMediaProjection');
        return ok ?? false;
      } catch (e, st) {
        debugPrint('[ScreenAudioCaptureService] '
            'requestMediaProjection 失敗: $e\n$st');
        return false;
      }
    }
    return true;
  }

  /// iOS では UDS リスナを起動するだけで、実際に PCM が来始めるのは
  /// ユーザーが Broadcast Picker でブロードキャストを開始した後。
  /// Android では MediaProjection が既に許可済み前提でキャプチャを開始する。
  Future<void> start() async {
    if (_isCapturing) return;

    try {
      if (Platform.isIOS) {
        await _methodChannel.invokeMethod<void>('startBroadcastReceiver');
      } else {
        await _methodChannel.invokeMethod<void>('startScreenCapture');
      }
    } on PlatformException catch (e) {
      _pcmController.addError(
        ScreenAudioStartException(
          code: e.code,
          message: e.message ?? '内部音声キャプチャの開始に失敗しました',
        ),
      );
      return;
    } catch (e) {
      _pcmController.addError(
        ScreenAudioStartException(
          code: 'UNKNOWN',
          message: '内部音声キャプチャ開始時に予期しないエラー: $e',
        ),
      );
      return;
    }

    // 受信した生バイトを 20ms チャンク(kBytesPerChunk = 3840 byte)に揃える。
    // 一度の Event で複数チャンクが届くこともあれば、端数だけのこともある。
    // 端数は PcmChunker が次回まで保持してくれる。
    final chunker = PcmChunker();
    _sub = _eventChannel.receiveBroadcastStream().listen(
      (dynamic raw) {
        if (raw is! Uint8List) return;
        for (final chunk in chunker.add(raw)) {
          _pcmController.add(chunk);
        }
      },
      onError: (Object err, StackTrace st) {
        debugPrint('[ScreenAudioCaptureService] EventChannel error: $err\n$st');
        _pcmController.addError(err);
      },
      cancelOnError: false,
    );

    _isCapturing = true;
  }

  /// iOS の場合、停止しても Broadcast 自体はユーザーが Picker で再度
  /// 「停止」しない限り続く。受信側だけを止めるイメージ。
  Future<void> stop() async {
    if (!_isCapturing) return;
    _isCapturing = false;
    await _sub?.cancel();
    _sub = null;
    try {
      if (Platform.isIOS) {
        await _methodChannel.invokeMethod<void>('stopBroadcastReceiver');
      } else {
        await _methodChannel.invokeMethod<void>('stopScreenCapture');
      }
    } catch (e) {
      // 停止時のエラーは黙って飲み込む(既に止まっている可能性が高い)
      debugPrint('[ScreenAudioCaptureService] stop 中の例外を無視: $e');
    }
  }

  /// iOS のみ: メインアプリ側で「直近 1.5 秒以内に Extension から PCM が
  /// 届いているか」を問い合わせる。Picker 起動後にユーザーが配信を始めたか
  /// を UI に反映するために使う。
  Future<bool> isBroadcastingActive() async {
    if (!Platform.isIOS) return _isCapturing;
    try {
      final res = await _methodChannel.invokeMethod<bool>('isBroadcasting');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    stop();
    _pcmController.close();
  }
}

/// 内部音声キャプチャ開始時に発生する例外。UI でユーザーに表示する想定。
class ScreenAudioStartException implements Exception {
  final String code;
  final String message;
  const ScreenAudioStartException({required this.code, required this.message});

  @override
  String toString() => 'ScreenAudioStartException($code): $message';
}
