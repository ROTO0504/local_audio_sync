import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'dart:typed_data';
import 'jitter_buffer.dart';
import 'opus_decoder_service.dart';

/// Dart-side orchestrator for the Windows audio mixer FFI plugin.
/// On non-Windows platforms this is a no-op stub.
class AudioMixerService {
  static DynamicLibrary? _lib;
  static late final _MixerInit _mixerInit;
  static late final _MixerPushFrames _mixerPushFrames;
  static late final _MixerSetVolume _mixerSetVolume;
  static late final _MixerRemoveClient _mixerRemoveClient;
  static late final _MixerDestroy _mixerDestroy;

  static bool _initialized = false;

  // Per-client state
  final Map<int, JitterBuffer> _jitterBuffers = {};
  final Map<int, OpusDecoderService> _decoders = {};

  static void initFfi() {
    if (_initialized || !Platform.isWindows) return;
    try {
      _lib = DynamicLibrary.open('audio_mixer_plugin.dll');
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

      _mixerInit();
      _initialized = true;
    } catch (e) {
      // FFI not available — playback will be silent on Windows until DLL is built
    }
  }

  void addClient(int clientId) {
    // Dispose any existing decoder before overwriting (handles reconnect without BYE)
    _decoders[clientId]?.dispose();
    _jitterBuffers[clientId] = JitterBuffer();
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
      if (pcm == null || !_initialized) continue;
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
