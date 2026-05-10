import 'dart:async';
import 'dart:typed_data';
import 'package:record/record.dart';
import 'pcm_constants.dart';

// 旧来の場所から定数を読みたいコードのために再エクスポート。
// フェーズ5でマイク経路と一緒に消す予定。
export 'pcm_constants.dart' show kSampleRate, kChannels, kFramesPerChunk, kBytesPerChunk;

/// マイク音声キャプチャ。**現在は新方針(内部音声のみ)で利用していない**。
///
/// docs/PLAN.md フェーズ5 でこのファイル全体を削除予定。
/// 既存テストの後方互換のため一時的に残置。
@Deprecated('Use ScreenAudioCaptureService. Mic capture path will be removed in phase 5.')
class AudioCaptureService {
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  final StreamController<Uint8List> _pcmController =
      StreamController<Uint8List>.broadcast();

  Stream<Uint8List> get pcmStream => _pcmController.stream;
  bool _isRecording = false;

  bool get isRecording => _isRecording;

  Future<bool> requestPermission() async {
    return _recorder.hasPermission();
  }

  Future<void> start() async {
    if (_isRecording) return;

    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: kSampleRate,
        numChannels: kChannels,
        bitRate: 0,
      ),
    );

    _isRecording = true;

    var carry = <int>[];
    _sub = stream.listen(
      (data) {
        carry.addAll(data);
        while (carry.length >= kBytesPerChunk) {
          final chunk = Uint8List.fromList(carry.sublist(0, kBytesPerChunk));
          carry = carry.sublist(kBytesPerChunk);
          _pcmController.add(chunk);
        }
      },
      onError: (Object err) => _pcmController.addError(err),
    );
  }

  Future<void> stop() async {
    if (!_isRecording) return;
    await _sub?.cancel();
    _sub = null;
    await _recorder.stop();
    _isRecording = false;
  }

  void dispose() {
    stop();
    _pcmController.close();
    _recorder.dispose();
  }

  /// PCM16 チャンクから RMS(VU メーター用)レベルを計算する委譲。
  /// 新コードは [computePcm16RmsLevel] を直接使うこと。
  static double computeRmsLevel(Uint8List pcm16) => computePcm16RmsLevel(pcm16);
}
