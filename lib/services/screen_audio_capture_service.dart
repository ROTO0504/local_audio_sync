import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'pcm_chunker.dart';
import 'windows_loopback_service.dart';

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
///     ScreenCaptureKit + SCStream(capturesAudio = true)。
///     初回起動時に「画面録画」許可ダイアログが OS から出る。
/// - Windows:
///     WASAPI loopback。`audio_mixer_plugin.dll` 内の loopback API を FFI で叩く。
///     [WindowsLoopbackService] を内部で起動し、polling で取得する。
class ScreenAudioCaptureService {
  static const _methodChannel =
      MethodChannel('com.example.local_audio_sync/broadcast');
  static const _eventChannel =
      EventChannel('com.example.local_audio_sync/screenAudio');

  StreamSubscription? _sub;
  StreamSubscription? _windowsSub;
  WindowsLoopbackService? _windowsLoopback;
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
  /// Android / macOS では即座にキャプチャ開始。
  /// Windows では FFI 経由で audio_mixer_plugin.dll の loopback API を起動。
  Future<void> start() async {
    if (_isCapturing) return;

    if (Platform.isWindows) {
      try {
        final loop = WindowsLoopbackService();
        await loop.start();
        _windowsLoopback = loop;

        // Windows loopback はすでに 20ms チャンクで来るが、一応 chunker を通す
        final chunker = PcmChunker();
        _windowsSub = loop.pcmStream.listen(
          (raw) {
            for (final chunk in chunker.add(raw)) {
              _pcmController.add(chunk);
            }
          },
          onError: (Object err, StackTrace st) {
            debugPrint(
                '[ScreenAudioCaptureService] Windows loopback error: $err\n$st');
            _pcmController.addError(err);
          },
        );
        _isCapturing = true;
      } catch (e) {
        _pcmController.addError(
          ScreenAudioStartException(
            code: 'WINDOWS_LOOPBACK_FAILED',
            message: '$e',
          ),
        );
      }
      return;
    }

    // iOS / macOS / Android(MethodChannel + EventChannel 経路)
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

    if (Platform.isWindows) {
      await _windowsSub?.cancel();
      _windowsSub = null;
      await _windowsLoopback?.stop();
      _windowsLoopback = null;
      return;
    }

    await _sub?.cancel();
    _sub = null;
    try {
      if (Platform.isIOS) {
        await _methodChannel.invokeMethod<void>('stopBroadcastReceiver');
      } else {
        await _methodChannel.invokeMethod<void>('stopScreenCapture');
      }
    } catch (e) {
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
    _windowsLoopback?.dispose();
    _windowsLoopback = null;
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
