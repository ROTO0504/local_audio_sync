import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_audio_sync/services/pcm_constants.dart';

void main() {
  group('PCM 定数', () {
    test('48kHz / ステレオ / 20ms フレームの一貫性', () {
      expect(kSampleRate, 48000);
      expect(kChannels, 2);
      expect(kFramesPerChunk, 960);
      expect(kBytesPerChunk, 3840); // 960 × 2 × 2
    });
  });

  group('computePcm16RmsLevel', () {
    test('空入力は 0.0', () {
      expect(computePcm16RmsLevel(Uint8List(0)), 0.0);
    });

    test('全 0 サンプルは 0.0', () {
      final pcm = Uint8List(8); // 4 サンプル分の 0
      expect(computePcm16RmsLevel(pcm), 0.0);
    });

    test('最大正サンプルだけだと約 1.0', () {
      // Int16 32767 が連続。
      final samples = Int16List(64);
      for (int i = 0; i < samples.length; i++) {
        samples[i] = 32767;
      }
      final pcm = samples.buffer.asUint8List();
      final level = computePcm16RmsLevel(pcm);
      expect(level, greaterThan(0.99));
      expect(level, lessThanOrEqualTo(1.0));
    });

    test('最大負サンプルだけでも約 1.0(2 乗するので符号無関係)', () {
      final samples = Int16List(64);
      for (int i = 0; i < samples.length; i++) {
        samples[i] = -32768;
      }
      final pcm = samples.buffer.asUint8List();
      final level = computePcm16RmsLevel(pcm);
      expect(level, greaterThan(0.99));
    });

    test('半分の振幅は約 0.25(RMS なので二乗平均)', () {
      final samples = Int16List(64);
      for (int i = 0; i < samples.length; i++) {
        samples[i] = 16384; // ≈ 32768/2
      }
      final pcm = samples.buffer.asUint8List();
      final level = computePcm16RmsLevel(pcm);
      // (0.5)^2 = 0.25 付近
      expect(level, greaterThan(0.24));
      expect(level, lessThan(0.26));
    });
  });
}
