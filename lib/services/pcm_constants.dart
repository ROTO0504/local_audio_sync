/// PCM16 ステレオ 48kHz / 20ms フレーム前提の共通定数とユーティリティ。
///
/// すべてのキャプチャ経路(iOS Broadcast Extension、Android MediaProjection、
/// macOS ScreenCaptureKit、Windows WASAPI loopback)で同じフォーマットへ
/// 揃えるための統一値。
library;

import 'dart:typed_data';

/// サンプリングレート(Hz)。
const int kSampleRate = 48000;

/// チャンネル数。ステレオ固定。
const int kChannels = 2;

/// 1 フレームあたりのサンプル数(チャンネルごと)。20 ms 相当。
const int kFramesPerChunk = 960;

/// 1 フレームあたりのバイト数。
/// 960 サンプル × 2 ch × 2 byte = 3840 byte。
const int kBytesPerChunk = kFramesPerChunk * kChannels * 2;

/// PCM16 バイト列から RMS レベル(0.0〜1.0)を計算する。
/// VU メーター描画に使う。サンプル数が 0 の場合は 0.0 を返す。
double computePcm16RmsLevel(Uint8List pcm16) {
  if (pcm16.isEmpty) return 0.0;
  final samples = pcm16.buffer.asInt16List(
    pcm16.offsetInBytes,
    pcm16.lengthInBytes ~/ 2,
  );
  if (samples.isEmpty) return 0.0;
  double sumSq = 0;
  for (final s in samples) {
    final n = s / 32768.0;
    sumSq += n * n;
  }
  final mean = sumSq / samples.length;
  if (mean.isNaN || mean.isInfinite) return 0.0;
  return mean.clamp(0.0, 1.0).toDouble();
}
