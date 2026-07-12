/// クライアント → Hub のリンク品質スナップショット。
///
/// [UdpSenderService] の内部カウンタ(PONG からの経過・連続失敗回数・
/// 送出パケット数)を定期ポーリングして載せ、クライアント画面の
/// 接続カードで「接続の健全さ」を恒常表示するために使う。
class ClientLinkStats {
  /// 直近の PONG 受信からの経過時間。まだ一度も PONG を受けていない
  /// (旧 Hub 相手 / 接続直後)場合は null。
  final Duration? sincePong;

  /// 連続した接続失敗回数(ソケット再生成やタイムアウトの累積)。
  final int consecutiveFailures;

  /// このセッションで送出した音声パケットの累計。
  final int sentPackets;

  const ClientLinkStats({
    this.sincePong,
    this.consecutiveFailures = 0,
    this.sentPackets = 0,
  });

  @override
  bool operator ==(Object other) =>
      other is ClientLinkStats &&
      sincePong == other.sincePong &&
      consecutiveFailures == other.consecutiveFailures &&
      sentPackets == other.sentPackets;

  @override
  int get hashCode => Object.hash(sincePong, consecutiveFailures, sentPackets);

  @override
  String toString() =>
      'ClientLinkStats(sincePong=$sincePong, '
      'consecutiveFailures=$consecutiveFailures, sentPackets=$sentPackets)';
}
