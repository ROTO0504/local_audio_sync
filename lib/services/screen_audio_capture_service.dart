import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'audio_capture_service.dart'; // kBytesPerChunk

/// Captures system/screen audio on Android (MediaProjection) and iOS
/// (RPScreenRecorder) and exposes the same [pcmStream] interface as
/// [AudioCaptureService] so the rest of the app can treat both sources
/// identically.
///
/// On Android the caller must invoke [requestPermission] first and await
/// `true` before calling [start].  On iOS the OS shows its own screen-
/// recording prompt automatically when [start] is called.
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

  /// Android only: show the MediaProjection system dialog and wait for the
  /// user to accept or deny.  Returns `true` on success.
  /// On iOS this always returns `true` (the dialog appears on [start]).
  Future<bool> requestPermission() async {
    if (Platform.isAndroid) {
      try {
        final ok =
            await _methodChannel.invokeMethod<bool>('requestMediaProjection');
        return ok ?? false;
      } catch (_) {
        return false;
      }
    }
    return true;
  }

  /// Start capturing screen audio and feeding [pcmStream].
  Future<void> start() async {
    if (_isCapturing) return;

    await _methodChannel.invokeMethod<void>('startScreenCapture');

    // Buffer incoming raw bytes into exact kBytesPerChunk (3840 byte) chunks,
    // matching the frame size used by AudioCaptureService / OpusEncoderService.
    var carry = <int>[];
    _sub = _eventChannel.receiveBroadcastStream().listen(
      (dynamic raw) {
        if (raw is! Uint8List) return;
        carry.addAll(raw);
        while (carry.length >= kBytesPerChunk) {
          _pcmController
              .add(Uint8List.fromList(carry.sublist(0, kBytesPerChunk)));
          carry = carry.sublist(kBytesPerChunk);
        }
      },
      onError: (Object err) => _pcmController.addError(err),
    );

    _isCapturing = true;
  }

  /// Stop capturing and release native resources.
  Future<void> stop() async {
    if (!_isCapturing) return;
    _isCapturing = false;
    await _sub?.cancel();
    _sub = null;
    try {
      await _methodChannel.invokeMethod<void>('stopScreenCapture');
    } catch (_) {
      // Ignore errors on stop (e.g., if native side already cleaned up)
    }
  }

  void dispose() {
    stop();
    _pcmController.close();
  }
}
