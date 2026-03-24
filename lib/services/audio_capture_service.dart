import 'dart:async';
import 'dart:typed_data';
import 'package:record/record.dart';

const int kSampleRate = 48000;
const int kChannels = 2; // stereo
const int kFramesPerChunk = 960; // 20ms at 48kHz
const int kBytesPerChunk = kFramesPerChunk * kChannels * 2; // 16-bit

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

    // Buffer incoming bytes into exact kBytesPerChunk chunks
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

  /// Compute RMS level 0.0–1.0 for VU meter from a PCM16 chunk.
  static double computeRmsLevel(Uint8List pcm16) {
    final samples = pcm16.buffer.asInt16List();
    if (samples.isEmpty) return 0.0;
    double sumSq = 0;
    for (final s in samples) {
      sumSq += (s / 32768.0) * (s / 32768.0);
    }
    return (sumSq / samples.length).clamp(0.0, 1.0);
  }
}
