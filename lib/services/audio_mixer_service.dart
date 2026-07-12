import 'dart:ffi';
import 'package:audio_mixer_ffi/audio_mixer_ffi.dart';
import 'package:ffi/ffi.dart';
import 'dart:typed_data';
import '../models/client_diagnostics.dart';
import 'jitter_buffer.dart';
import 'opus_decoder_service.dart';
import 'pcm_constants.dart';

/// Dart-side orchestrator for the audio mixer FFI plugin.
///
/// miniaudio ベースのネイティブミキサー(packages/audio_mixer_ffi)を叩く。
/// Windows / Android / iOS / macOS すべてで動作し、ネイティブライブラリを
/// ロードできない環境(テスト等)では no-op になる。
class AudioMixerService {
  static DynamicLibrary? _lib;
  static late final _MixerInit _mixerInit;
  static late final _MixerPushFrames _mixerPushFrames;
  static late final _MixerSetVolume _mixerSetVolume;
  static late final _MixerRemoveClient _mixerRemoveClient;
  static late final _MixerDestroy _mixerDestroy;
  static late final _MixerStats _mixerStats;
  static late final _MixerSetTargetLatency _mixerSetTargetLatency;

  static bool _initialized = false;

  // Per-client state
  final Map<int, JitterBuffer> _jitterBuffers = {};
  final Map<int, OpusDecoderService> _decoders = {};

  /// デコード済み音声の RMS レベル通知(Hub の VU メーター用)。
  /// 20ms フレームごとに呼ばれるため、UI へ反映する側でスロットリングすること。
  void Function(int clientId, double level)? onClientLevel;

  /// 以後の addClient に適用するジッターバッファの遅延プリセット。
  /// 既存クライアントへ適用するには remove → add で作り直す
  /// (HubController.setJitterPreset 参照)。
  JitterBufferPreset jitterPreset = JitterBufferPreset.lan;

  static void initFfi() {
    if (_initialized) return;
    try {
      _lib = openAudioMixerLibrary();
      _mixerInit = _lib!
          .lookupFunction<Void Function(), void Function()>('mixer_init');
      _mixerPushFrames = _lib!.lookupFunction<
          Void Function(Uint16, Pointer<Float>, Int32),
          void Function(int, Pointer<Float>, int)>('mixer_push_frames');
      _mixerSetVolume = _lib!.lookupFunction<
          Void Function(Uint16, Float),
          void Function(int, double)>('mixer_set_volume');
      _mixerRemoveClient = _lib!.lookupFunction<Void Function(Uint16),
          void Function(int)>('mixer_remove_client');
      _mixerDestroy = _lib!
          .lookupFunction<Void Function(), void Function()>('mixer_destroy');
      _mixerStats = _lib!.lookupFunction<
          Void Function(Uint16, Pointer<Int64>, Int32),
          void Function(int, Pointer<Int64>, int)>('mixer_stats');
      _mixerSetTargetLatency = _lib!.lookupFunction<
          Void Function(Int32),
          void Function(int)>('mixer_set_target_latency_ms');

      _mixerInit();
      _initialized = true;
    } catch (e) {
      // FFI not available — playback will be silent on Windows until DLL is built
    }
  }

  /// クライアントを登録する。
  ///
  /// [onResync] は JitterBuffer がシーケンス断絶を検出したときに呼ばれ、
  /// Hub 側から送信側へ RESYNC 制御メッセージを送るために使う。
  /// null の場合は内部リセットのみで送信側通知は行わない。
  void addClient(int clientId, {void Function()? onResync}) {
    // Dispose any existing decoder before overwriting (handles reconnect without BYE)
    _decoders[clientId]?.dispose();
    _jitterBuffers[clientId] = JitterBuffer(
      targetDelayFrames: jitterPreset.targetDelayFrames,
      maxBufferFrames: jitterPreset.maxBufferFrames,
      onResyncDetected: onResync == null ? null : (_) => onResync(),
    );
    final dec = OpusDecoderService()..init();
    _decoders[clientId] = dec;
    if (_initialized) {
      _mixerSetVolume(clientId, 1.0);
    }
  }

  void removeClient(int clientId) {
    _jitterBuffers.remove(clientId);
    _decoders[clientId]?.dispose();
    _decoders.remove(clientId);
    if (_initialized) _mixerRemoveClient(clientId);
  }

  /// Remove all clients and release their native resources.
  /// Call this on Hub teardown before destroyFfi().
  void removeAllClients() {
    for (final id in _decoders.keys.toList()) {
      removeClient(id);
    }
  }

  void pushEncodedPacket(int clientId, int sequence, Uint8List opusBytes) {
    final jb = _jitterBuffers[clientId];
    if (jb == null) return;
    jb.push(sequence, opusBytes);
    _drainJitterBuffer(clientId);
  }

  void setVolume(int clientId, double volume) {
    if (_initialized) _mixerSetVolume(clientId, volume.clamp(0.0, 1.0));
  }

  /// 再生プリバッファ(目標遅延)を ms 単位で設定する。大きいほどジッタ耐性が
  /// 上がる代わりに遅延が増える。ネイティブ側で [20, 500]ms にクランプされる。
  void setTargetLatencyMs(int ms) {
    if (_initialized) _mixerSetTargetLatency(ms);
  }

  /// 指定クライアントのジッターバッファ統計スナップショットを返す。
  /// 未登録なら null。lastSeen はミキサーが持たないため常に null で、
  /// HubController 側で ClientInfo.lastSeen を補完する。
  ClientDiagnostics? statsOf(int clientId) {
    final jb = _jitterBuffers[clientId];
    if (jb == null) return null;
    // ネイティブ再生リングの実測(深さ・アンダー/オーバーラン)を併せて読む。
    final native = _readNativeStats(clientId);
    return ClientDiagnostics(
      totalReceived: jb.totalReceived,
      totalDropped: jb.totalDropped,
      totalResynced: jb.totalResynced,
      bufferedFrames: jb.bufferedCount,
      ringFrames: native?[0] ?? 0,
      underrunFrames: native?[1] ?? 0,
      overrunFrames: native?[2] ?? 0,
    );
  }

  /// ネイティブミキサーの診断スロットを読む。FFI 無効環境では null。
  /// out[0]=リング深さ(frames), [1]=underrun累計, [2]=overrun累計, [3]=active。
  List<int>? _readNativeStats(int clientId) {
    if (!_initialized) return null;
    const slots = 4;
    final ptr = calloc<Int64>(slots);
    try {
      _mixerStats(clientId, ptr, slots);
      final view = ptr.asTypedList(slots);
      return List<int>.from(view);
    } finally {
      calloc.free(ptr);
    }
  }

  void _drainJitterBuffer(int clientId) {
    final jb = _jitterBuffers[clientId];
    final dec = _decoders[clientId];
    if (jb == null || dec == null) return;

    while (jb.hasData) {
      final opusBytes = jb.pop();
      Float32List? pcm;
      if (opusBytes != null) {
        pcm = dec.decode(opusBytes);
      } else {
        pcm = dec.decodePLC();
      }
      if (pcm == null) continue;
      // ネイティブミキサーが無効(未対応環境)でも VU レベルは通知する
      onClientLevel?.call(clientId, computeFloat32RmsLevel(pcm));
      if (!_initialized) continue;
      _pushToFfi(clientId, pcm);
    }
  }

  void _pushToFfi(int clientId, Float32List pcm) {
    if (!_initialized) return;
    final ptr = calloc<Float>(pcm.length);
    try {
      final nativeList = ptr.asTypedList(pcm.length);
      nativeList.setAll(0, pcm);
      _mixerPushFrames(clientId, ptr, pcm.length ~/ 2); // frameCount = samples / channels
    } finally {
      calloc.free(ptr);
    }
  }

  static void destroyFfi() {
    if (_initialized) {
      _mixerDestroy();
      _initialized = false;
    }
  }
}

// FFI typedefs
typedef _MixerInit = void Function();
typedef _MixerPushFrames = void Function(int clientId, Pointer<Float> pcm, int frameCount);
typedef _MixerSetVolume = void Function(int clientId, double volume);
typedef _MixerRemoveClient = void Function(int clientId);
typedef _MixerDestroy = void Function();
typedef _MixerStats = void Function(int clientId, Pointer<Int64> out, int outLen);
typedef _MixerSetTargetLatency = void Function(int ms);
