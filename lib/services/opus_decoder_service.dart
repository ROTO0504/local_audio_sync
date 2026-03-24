import 'dart:typed_data';
import 'package:opus_dart/opus_dart.dart';

/// Wraps opus_dart v3 SimpleOpusDecoder.
/// Input: Opus bytes
/// Output: float32 PCM stereo
///
/// Call [init] after initOpus() has been called in main().
class OpusDecoderService {
  SimpleOpusDecoder? _decoder;

  void init() {
    _decoder ??= SimpleOpusDecoder(
      sampleRate: 48000,
      channels: 2,
    );
  }

  /// Decode Opus bytes to float32 PCM stereo.
  /// Returns null on decode error.
  Float32List? decode(Uint8List opusBytes) {
    final dec = _decoder;
    if (dec == null) return null;
    try {
      return dec.decodeFloat(input: opusBytes);
    } catch (_) {
      return null;
    }
  }

  /// Packet loss concealment: decode with null input.
  Float32List? decodePLC() {
    final dec = _decoder;
    if (dec == null) return null;
    try {
      // null input = PLC in opus_dart v3
      return dec.decodeFloat(input: null);
    } catch (_) {
      return Float32List(960 * 2); // silence fallback
    }
  }

  void dispose() {
    _decoder?.destroy();
    _decoder = null;
  }
}
