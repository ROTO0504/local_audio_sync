/// PCM16 ステレオ 48kHz / 20ms フレーム前提の共通定数とユーティリティ。
///
/// すべてのキャプチャ経路(iOS Broadcast Extension、Android MediaProjection、
/// macOS ScreenCaptureKit、Windows WASAPI loopback)で同じフォーマットへ
/// 揃えるための統一値。
library;

import 'dart:math' as math;
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
///
/// 旧実装は `sumSq / N` の二乗平均(分散)を返しており、
/// 振幅 0.5 の信号で 0.25 にしかならなかった。これだと音楽信号(平均振幅
/// 0.2 前後)で 0.04 ≒ 4% 表示となり、ユーザーの「VU が 5% しか動かない」
/// 報告につながっていた。本実装では平方根を取って真の RMS を返す。
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
  if (mean.isNaN || mean.isInfinite || mean <= 0) return 0.0;
  return math.sqrt(mean).clamp(0.0, 1.0).toDouble();
}
