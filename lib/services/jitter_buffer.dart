import 'dart:collection';
import 'dart:typed_data';

/// ジッターバッファの遅延プリセット。
///
/// 1 フレーム = 20ms。LAN はレイテンシ優先(目標 40ms)、
/// WAN / VPN 経由はジッタ・パケロス耐性優先(目標 200ms)。
enum JitterBufferPreset {
  lan(
    targetDelayFrames: 2,
    maxBufferFrames: 5,
    label: 'LAN(低遅延)',
  ),
  wan(
    targetDelayFrames: 10,
    maxBufferFrames: 25,
    label: 'WAN / VPN(安定重視)',
  );

  const JitterBufferPreset({
    required this.targetDelayFrames,
    required this.maxBufferFrames,
    required this.label,
  });

  final int targetDelayFrames;
  final int maxBufferFrames;

  /// UI 表示用ラベル。
  final String label;

  /// 永続化された name から復元する(不明値は lan)。
  static JitterBufferPreset fromName(String? name) {
    for (final preset in JitterBufferPreset.values) {
      if (preset.name == name) return preset;
    }
    return JitterBufferPreset.lan;
  }
}

/// Opus 音声パケット用の固定遅延ジッターバッファ。
///
/// 主な責務:
/// 1. パケットの順序復元(順不同で届いた seq を昇順に並べ直す)
/// 2. 起動時の初期遅延確保(targetDelayFrames 分溜まるまで再生開始しない)
/// 3. パケットロス時に PLC(Packet Loss Concealment)用に null を返す
/// 4. **シーケンス断絶検出と自動再同期**(本コミットで追加)
///
/// 旧実装の弱点:
///   - reset() を呼ばない限り、一度同期外れすると永遠に古いパケットとして
///     棄却され続け、復帰しなかった
///   - 送信側がアプリ再起動などで seq を 0 から振り直したとき追従できなかった
///
/// 本実装では `resyncThresholdFrames`(既定 100 = 約 2 秒)以上 seq が乖離した
/// 場合、内部状態を新しい seq に合わせてリセットして再同期する。
/// その際、外部から接続経路にも合わせて再同期トークンを通知できるよう
/// `onResyncDetected` コールバックを呼び出す(送信側に RESYNC を送る等の用途)。
class JitterBuffer {
  /// 再生開始までに溜める最低フレーム数。
  final int targetDelayFrames;

  /// バッファに溜めて良い最大フレーム数。これを超えたら古い順に捨てる。
  final int maxBufferFrames;

  /// この値以上 seq が乖離(過去でも未来でも)したら強制リセットする閾値。
  /// 32bit seq の半分以下に収まる必要がある。
  final int resyncThresholdFrames;

  /// 自動再同期が発火したときに呼ばれるコールバック(任意)。
  /// 引数は新しい先頭 seq。
  final void Function(int newSeq)? onResyncDetected;

  final SplayTreeMap<int, Uint8List> _buffer = SplayTreeMap();
  int? _nextExpectedSeq;
  bool _playbackStarted = false;
  int _totalReceived = 0;
  int _totalDropped = 0;
  int _totalResynced = 0;

  JitterBuffer({
    this.targetDelayFrames = 2,
    this.maxBufferFrames = 5,
    this.resyncThresholdFrames = 100,
    this.onResyncDetected,
  })  : assert(targetDelayFrames >= 1),
        assert(maxBufferFrames >= targetDelayFrames),
        assert(resyncThresholdFrames > 1 &&
            resyncThresholdFrames < 0x7FFFFFFF);

  /// 新しい Opus パケットを差し込む。受け入れたら true、拒否(古すぎる等)で false。
  bool push(int sequence, Uint8List opusBytes) {
    _totalReceived++;

    if (_nextExpectedSeq == null) {
      // 初パケットは無条件採用
      _nextExpectedSeq = sequence;
    } else {
      final expected = _nextExpectedSeq!;
      final forwardDistance = (sequence - expected) & 0xFFFFFFFF;
      final backwardDistance = (expected - sequence) & 0xFFFFFFFF;

      // 期待 seq から大きく離れすぎていたら再同期(送信側リセット等)
      if (forwardDistance >= resyncThresholdFrames &&
          backwardDistance >= resyncThresholdFrames) {
        _resyncTo(sequence);
      } else if (_isOlderThan(sequence, expected)) {
        // 既に再生済み区間と判定 → 棄却
        _totalDropped++;
        return false;
      }
    }

    _buffer[sequence] = opusBytes;

    // 溢れたら古い順から落とす
    while (_buffer.length > maxBufferFrames) {
      _buffer.remove(_buffer.firstKey());
      _totalDropped++;
    }
    return true;
  }

  /// 次フレームを取り出す。null = まだ準備未完 or パケットロス(PLC を呼ぶこと)。
  /// 20ms ごとに呼び出すこと(再生コールバックや FFI ミキサーから)。
  Uint8List? pop() {
    if (_nextExpectedSeq == null) return null;

    if (!_playbackStarted && _buffer.length < targetDelayFrames) {
      return null;
    }

    final seq = _nextExpectedSeq!;
    _nextExpectedSeq = _wrappedIncrement(seq);
    _playbackStarted = true;

    return _buffer.remove(seq); // null = 紛失 → 呼び出し側が PLC 適用
  }

  /// 描画/取り出し前の判定。再生開始前は targetDelayFrames まで貯まったか確認。
  bool get hasData {
    if (_nextExpectedSeq == null) return false;
    if (!_playbackStarted) return _buffer.length >= targetDelayFrames;
    return _buffer.isNotEmpty;
  }

  int get bufferedCount => _buffer.length;
  int get totalReceived => _totalReceived;
  int get totalDropped => _totalDropped;
  int get totalResynced => _totalResynced;
  int? get nextExpectedSeq => _nextExpectedSeq;

  /// 完全初期化(切断時や手動再同期時)。
  void reset() {
    _buffer.clear();
    _nextExpectedSeq = null;
    _playbackStarted = false;
    _totalReceived = 0;
    _totalDropped = 0;
    _totalResynced = 0;
  }

  /// 内部の seq 状態だけ新しい seq に切り替える(統計はクリアしない)。
  /// 再生中の状態は保ちつつ追従させる。
  void _resyncTo(int newSeq) {
    _buffer.clear();
    _nextExpectedSeq = newSeq;
    _playbackStarted = false;
    _totalResynced++;
    onResyncDetected?.call(newSeq);
  }

  static int _wrappedIncrement(int seq) => (seq + 1) & 0xFFFFFFFF;

  /// 32bit ラップを考慮した「より古い」判定。
  static bool _isOlderThan(int seq, int reference) {
    final diff = (seq - reference) & 0xFFFFFFFF;
    return diff > 0x7FFFFFFF;
  }
}
