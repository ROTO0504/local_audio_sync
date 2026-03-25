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
  // True once we have committed to playing back (enough frames have buffered).
  // Before this flag is set, hasData returns false when the buffer is below
  // targetDelayFrames so that _drainJitterBuffer exits the while-loop instead
  // of spinning forever on a pop() call that returns null without consuming.
  bool _playbackStarted = false;
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

    // During the initial buffering phase wait until we have enough frames so
    // that _drainJitterBuffer's while(hasData) loop cannot spin forever.
    if (!_playbackStarted && _buffer.length < targetDelayFrames) return null;

    final seq = _nextExpectedSeq!;
    _nextExpectedSeq = _wrappedIncrement(seq);
    // Once we commit to advancing the sequence we are in playback mode,
    // regardless of whether this frame was a real packet or a PLC slot.
    _playbackStarted = true;

    final frame = _buffer.remove(seq);
    return frame; // null = lost packet → caller should use PLC
  }

  /// True when there is data worth draining right now.
  /// Before playback starts we require at least [targetDelayFrames] packets so
  /// that pop() never returns null-without-consuming (which would infinite-loop
  /// _drainJitterBuffer on Windows when FFI is active).
  bool get hasData {
    if (_nextExpectedSeq == null) return false;
    if (!_playbackStarted) return _buffer.length >= targetDelayFrames;
    return _buffer.isNotEmpty;
  }
  int get bufferedCount => _buffer.length;
  int get totalReceived => _totalReceived;
  int get totalDropped => _totalDropped;

  void reset() {
    _buffer.clear();
    _nextExpectedSeq = null;
    _playbackStarted = false;
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
