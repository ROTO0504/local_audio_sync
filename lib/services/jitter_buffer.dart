import 'dart:collection';
import 'dart:typed_data';

/// Fixed-delay jitter buffer for Opus audio packets.
/// Holds [targetDelayFrames] frames before starting playback.
/// Sequence numbers are uint32 and wrap around at 0xFFFFFFFF.
class JitterBuffer {
  final int targetDelayFrames;
  final int maxBufferFrames;

  final SplayTreeMap<int, Uint8List> _buffer = SplayTreeMap();
  int? _nextExpectedSeq;
  int _totalReceived = 0;
  int _totalDropped = 0;

  JitterBuffer({
    this.targetDelayFrames = 2,
    this.maxBufferFrames = 5,
  });

  /// Push an incoming Opus packet. Returns true if accepted.
  bool push(int sequence, Uint8List opusBytes) {
    _totalReceived++;

    // Initialize expected sequence on first packet
    _nextExpectedSeq ??= sequence;

    // Drop significantly out-of-order packets (already played)
    final expected = _nextExpectedSeq!;
    if (_isOlderThan(sequence, expected)) {
      _totalDropped++;
      return false;
    }

    _buffer[sequence] = opusBytes;

    // Overflow: drop oldest if buffer too full
    while (_buffer.length > maxBufferFrames) {
      _buffer.remove(_buffer.firstKey());
      _totalDropped++;
    }

    return true;
  }

  /// Pop the next frame. Returns null if not yet ready or packet lost (PLC needed).
  /// Call this every 20ms (one Opus frame interval).
  Uint8List? pop() {
    if (_nextExpectedSeq == null) return null;

    // Not enough buffered yet
    if (_buffer.length < targetDelayFrames && _nextExpectedSeq == _buffer.firstKey()) {
      return null;
    }

    final seq = _nextExpectedSeq!;
    _nextExpectedSeq = _wrappedIncrement(seq);

    final frame = _buffer.remove(seq);
    return frame; // null = lost packet → caller should use PLC
  }

  bool get hasData => _buffer.isNotEmpty;
  int get bufferedCount => _buffer.length;
  int get totalReceived => _totalReceived;
  int get totalDropped => _totalDropped;

  void reset() {
    _buffer.clear();
    _nextExpectedSeq = null;
    _totalReceived = 0;
    _totalDropped = 0;
  }

  static int _wrappedIncrement(int seq) => (seq + 1) & 0xFFFFFFFF;

  /// Returns true if [seq] is older than [reference] (accounting for wrap-around).
  static bool _isOlderThan(int seq, int reference) {
    final diff = (seq - reference) & 0xFFFFFFFF;
    return diff > 0x7FFFFFFF; // More than half the range behind = older
  }
}
