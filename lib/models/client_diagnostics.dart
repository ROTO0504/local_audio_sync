/// クライアント1台分の接続品質診断スナップショット。
///
/// 値の出所:
///   - totalReceived / totalDropped / totalResynced / bufferedFrames は
///     ミキサー内部の [JitterBuffer] 集計を [AudioMixerService.statsOf] 経由で読む。
///   - lastSeen はミキサーが持たないため、HubController 側で
///     ClientInfo.lastSeen を補完する(ミキサー直読み時は null)。
///
/// UI(診断チップ・ダッシュボード)はこの値だけを見れば描画できる。
class ClientDiagnostics {
  /// ジッターバッファが受理した総パケット数。
  final int totalReceived;

  /// 順序外れ・溢れで棄却した総パケット数。
  final int totalDropped;

  /// シーケンス断絶で再同期した回数。
  final int totalResynced;

  /// 現在バッファに滞留しているフレーム数(バッファ深)。
  final int bufferedFrames;

  /// 最終受信時刻(stale 判定・経過表示用)。ミキサー直読みでは null。
  final DateTime? lastSeen;

  /// ネイティブ再生リングの現在の深さ(フレーム)。再生バッファ実測。
  final int ringFrames;

  /// ネイティブ再生リングのアンダーラン累計(フレーム)。枯渇=無音埋めの量。
  final int underrunFrames;

  /// ネイティブ再生リングのオーバーラン累計(フレーム)。満杯=破棄の量。
  final int overrunFrames;

  const ClientDiagnostics({
    this.totalReceived = 0,
    this.totalDropped = 0,
    this.totalResynced = 0,
    this.bufferedFrames = 0,
    this.lastSeen,
    this.ringFrames = 0,
    this.underrunFrames = 0,
    this.overrunFrames = 0,
  });

  /// パケットロス率(0.0〜1.0)。受信ゼロなら 0。
  double get lossRate => totalReceived == 0 ? 0 : totalDropped / totalReceived;

  /// 再生リングの滞留時間(ms)。48kHz なので 48 フレーム = 1ms。
  double get ringMs => ringFrames / 48.0;

  ClientDiagnostics copyWith({
    int? totalReceived,
    int? totalDropped,
    int? totalResynced,
    int? bufferedFrames,
    DateTime? lastSeen,
    int? ringFrames,
    int? underrunFrames,
    int? overrunFrames,
  }) {
    return ClientDiagnostics(
      totalReceived: totalReceived ?? this.totalReceived,
      totalDropped: totalDropped ?? this.totalDropped,
      totalResynced: totalResynced ?? this.totalResynced,
      bufferedFrames: bufferedFrames ?? this.bufferedFrames,
      lastSeen: lastSeen ?? this.lastSeen,
      ringFrames: ringFrames ?? this.ringFrames,
      underrunFrames: underrunFrames ?? this.underrunFrames,
      overrunFrames: overrunFrames ?? this.overrunFrames,
    );
  }
}
