import 'dart:typed_data';

class ClientInfo {
  final String id;
  final String name;
  final String ip;
  final int port;
  final double volume; // 0.0 - 1.0
  final bool isMuted;
  final bool isActive;
  final DateTime lastSeen;
  final Float32List? lastPcmChunk; // for VU meter on hub

  const ClientInfo({
    required this.id,
    required this.name,
    required this.ip,
    required this.port,
    this.volume = 1.0,
    this.isMuted = false,
    this.isActive = true,
    required this.lastSeen,
    this.lastPcmChunk,
  });

  ClientInfo copyWith({
    String? id,
    String? name,
    String? ip,
    int? port,
    double? volume,
    bool? isMuted,
    bool? isActive,
    DateTime? lastSeen,
    Float32List? lastPcmChunk,
  }) {
    return ClientInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      ip: ip ?? this.ip,
      port: port ?? this.port,
      volume: volume ?? this.volume,
      isMuted: isMuted ?? this.isMuted,
      isActive: isActive ?? this.isActive,
      lastSeen: lastSeen ?? this.lastSeen,
      lastPcmChunk: lastPcmChunk ?? this.lastPcmChunk,
    );
  }
}
