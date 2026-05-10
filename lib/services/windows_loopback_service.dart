import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'pcm_constants.dart';

/// Windows でデフォルト出力デバイスの音声を WASAPI loopback でキャプチャし、
/// PCM16 ステレオ 48kHz の 20ms チャンクとしてストリームに流すサービス。
///
/// 実装は `audio_mixer_plugin.dll` 内の `loopback_*` C API を FFI 経由で叩く。
/// DLL 側がリングバッファを持っていて、こちらは 20ms 周期で polling する。
class WindowsLoopbackService {
  static DynamicLibrary? _lib;
  static late final _LoopbackStart _loopbackStart;
  static late final _LoopbackStop _loopbackStop;
  static late final _LoopbackReadPcm16 _loopbackReadPcm16;
  static late final _LoopbackPendingFrames _loopbackPendingFrames;
  static late final _LoopbackIsRunning _loopbackIsRunning;
  static bool _ffiReady = false;

  Timer? _pollTimer;
  bool _running = false;
  Pointer<Int16>? _readBuf;
  static const int _readFramesPerPoll = kFramesPerChunk; // 20ms 相当

  final StreamController<Uint8List> _pcmController =
      StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get pcmStream => _pcmController.stream;

  bool get isRunning => _running;

  /// FFI ロード。Windows 以外、または DLL が見つからないときは無効化される。
  static void initFfi() {
    if (_ffiReady || !Platform.isWindows) return;
    try {
      _lib = DynamicLibrary.open('audio_mixer_plugin.dll');
      _loopbackStart = _lib!
          .lookupFunction<Int32 Function(), int Function()>('loopback_start');
      _loopbackStop = _lib!
          .lookupFunction<Void Function(), void Function()>('loopback_stop');
      _loopbackReadPcm16 = _lib!.lookupFunction<
          Int32 Function(Pointer<Int16>, Int32),
          int Function(Pointer<Int16>, int)>('loopback_read_pcm16');
      _loopbackPendingFrames = _lib!.lookupFunction<Int32 Function(),
          int Function()>('loopback_pending_frames');
      _loopbackIsRunning = _lib!
          .lookupFunction<Int32 Function(), int Function()>('loopback_is_running');
      _ffiReady = true;
    } catch (e) {
      debugPrint('[WindowsLoopbackService] DLL ロード失敗: $e');
    }
  }

  /// loopback デバイスを起動し、20ms 周期で polling を開始する。
  /// 失敗したら例外を投げる。
  Future<void> start() async {
    if (_running) return;
    initFfi();
    if (!_ffiReady) {
      throw const WindowsLoopbackException(
        'audio_mixer_plugin.dll が読み込めません。flutter build windows を実行してください',
      );
    }

    final code = _loopbackStart();
    if (code == 1) {
      // 既に起動中。リカバーとして 1 度 stop してから再起動を試みる。
      _loopbackStop();
      final code2 = _loopbackStart();
      if (code2 != 0) {
        throw WindowsLoopbackException('loopback_start 失敗 code=$code2');
      }
    } else if (code != 0) {
      throw WindowsLoopbackException('loopback_start 失敗 code=$code');
    }

    _readBuf ??= calloc<Int16>(_readFramesPerPoll * kChannels);
    _running = true;

    _pollTimer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      _pollOnce();
    });
  }

  void _pollOnce() {
    if (!_ffiReady || !_running) return;
    final buf = _readBuf;
    if (buf == null) return;

    int totalReadFrames = 0;
    // 1 ティックで複数回読みきる(遅延した場合の追いつき)
    while (true) {
      final framesRead = _loopbackReadPcm16(buf, _readFramesPerPoll);
      if (framesRead <= 0) break;
      totalReadFrames += framesRead;

      // PCM16 を Uint8List にコピー
      final byteCount = framesRead * kChannels * 2;
      final out = Uint8List(byteCount);
      // ポインタ → typed list を直接コピー
      final src = buf.asTypedList(framesRead * kChannels);
      final outInt16 = out.buffer.asInt16List();
      for (int i = 0; i < framesRead * kChannels; i++) {
        outInt16[i] = src[i];
      }

      // 20ms ぴったり(=kBytesPerChunk)で切り出す。framesRead < _readFramesPerPoll の
      // 端数は次回ティックで自然に追いつく。kBytesPerChunk と一致するときだけ流す。
      if (out.length == kBytesPerChunk) {
        _pcmController.add(out);
      } else if (out.isNotEmpty) {
        // 端数も後段(ScreenAudioCaptureService の PcmChunker)で揃えてもらう。
        _pcmController.add(out);
      }

      // ringbuffer がだいぶ溜まっているときは追加で読む
      if (framesRead < _readFramesPerPoll) break;
      if (totalReadFrames >= _readFramesPerPoll * 4) break; // 安全弁
    }
  }

  Future<void> stop() async {
    if (!_running && _ffiReady && _loopbackIsRunning() == 0) return;
    _running = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    if (_ffiReady) {
      _loopbackStop();
    }
  }

  void dispose() {
    stop();
    if (_readBuf != null) {
      calloc.free(_readBuf!);
      _readBuf = null;
    }
    _pcmController.close();
  }

  /// テスト用: pending frames 取得(Windows 以外は 0)。
  int pendingFrames() {
    if (!_ffiReady) return 0;
    return _loopbackPendingFrames();
  }
}

class WindowsLoopbackException implements Exception {
  final String message;
  const WindowsLoopbackException(this.message);
  @override
  String toString() => 'WindowsLoopbackException: $message';
}

// FFI typedefs
typedef _LoopbackStart = int Function();
typedef _LoopbackStop = void Function();
typedef _LoopbackReadPcm16 = int Function(Pointer<Int16> buf, int maxFrames);
typedef _LoopbackPendingFrames = int Function();
typedef _LoopbackIsRunning = int Function();
