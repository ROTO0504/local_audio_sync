import 'dart:typed_data';
import 'package:opus_dart/opus_dart.dart';

const int kOpusSampleRate = 48000;
const int kOpusChannels = 2;

/// Wraps opus_dart v3 SimpleOpusEncoder.
/// Input: 16-bit PCM stereo, 960 samples/channel (= 20ms at 48kHz)
///   → Int16List length = 960 × 2 = 1920 samples
/// Output: Opus-compressed bytes
///
/// Call [init] after initOpus() has been called in main().
class OpusEncoderService {
  SimpleOpusEncoder? _encoder;

  void init() {
    _encoder ??= SimpleOpusEncoder(
      sampleRate: kOpusSampleRate,
      channels: kOpusChannels,
      application: Application.audio, // music quality
    );
  }

  /// Encode a PCM16 chunk (1920 × 2 bytes = 3840 bytes for stereo 20ms).
  /// Returns Opus bytes or null on error.
  Uint8List? encode(Uint8List pcm16Bytes) {
    final enc = _encoder;
    if (enc == null) return null;
    try {
      final pcm16 = pcm16Bytes.buffer.asInt16List(
        pcm16Bytes.offsetInBytes,
        pcm16Bytes.lengthInBytes ~/ 2,
      );
      return enc.encode(input: pcm16);
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    _encoder?.destroy();
    _encoder = null;
  }
}
