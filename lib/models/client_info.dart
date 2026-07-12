class ClientInfo {
  final String id;
  final String name;
  final String ip;
  final int port;

  /// `ios` / `android` / `macos` / `windows` / `linux` / `unknown`。
  final String platform;

  /// クライアントが話すプロトコルバージョン(v1 HELLO なら 1)。
  final int protocolVersion;

  final double volume; // 0.0 - 1.0
  final bool isMuted;
  final bool isActive;

  /// Hub からのリモート制御(PAUSE)で配信を一時停止中かどうか。
  final bool isPaused;
  final DateTime lastSeen;

  /// 受信音声の RMS レベル(0.0〜1.0)。Hub 側の VU メーター表示用。
  final double vuLevel;

  const ClientInfo({
    required this.id,
    required this.name,
    required this.ip,
    required this.port,
    this.platform = 'unknown',
    this.protocolVersion = 1,
    this.volume = 1.0,
    this.isMuted = false,
    this.isActive = true,
    this.isPaused = false,
    required this.lastSeen,
    this.vuLevel = 0.0,
  });

  ClientInfo copyWith({
    String? id,
    String? name,
    String? ip,
    int? port,
    String? platform,
    int? protocolVersion,
    double? volume,
    bool? isMuted,
    bool? isActive,
    bool? isPaused,
    DateTime? lastSeen,
    double? vuLevel,
  }) {
    return ClientInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      ip: ip ?? this.ip,
      port: port ?? this.port,
      platform: platform ?? this.platform,
      protocolVersion: protocolVersion ?? this.protocolVersion,
      volume: volume ?? this.volume,
      isMuted: isMuted ?? this.isMuted,
      isActive: isActive ?? this.isActive,
      isPaused: isPaused ?? this.isPaused,
      lastSeen: lastSeen ?? this.lastSeen,
      vuLevel: vuLevel ?? this.vuLevel,
    );
  }
}
