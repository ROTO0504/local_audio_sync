import 'package:flutter_riverpod/flutter_riverpod.dart';

enum ClientConnectionStatus { searching, connecting, connected, disconnected }

class ClientState {
  final ClientConnectionStatus status;
  final String? hubIp;
  final int hubPort;

  /// 接続(試行)中の Hub の表示名。
  final String? hubName;
  final String? assignedClientId;
  final double vuLevel; // 0.0 - 1.0, for VU meter
  final bool isBroadcasting;

  const ClientState({
    this.status = ClientConnectionStatus.searching,
    this.hubIp,
    this.hubPort = 7777,
    this.hubName,
    this.assignedClientId,
    this.vuLevel = 0.0,
    this.isBroadcasting = false,
  });

  ClientState copyWith({
    ClientConnectionStatus? status,
    String? hubIp,
    int? hubPort,
    String? hubName,
    String? assignedClientId,
    double? vuLevel,
    bool? isBroadcasting,
  }) {
    return ClientState(
      status: status ?? this.status,
      hubIp: hubIp ?? this.hubIp,
      hubPort: hubPort ?? this.hubPort,
      hubName: hubName ?? this.hubName,
      assignedClientId: assignedClientId ?? this.assignedClientId,
      vuLevel: vuLevel ?? this.vuLevel,
      isBroadcasting: isBroadcasting ?? this.isBroadcasting,
    );
  }
}

class ClientStateNotifier extends Notifier<ClientState> {
  @override
  ClientState build() => const ClientState();

  void setSearching() {
    state = const ClientState(status: ClientConnectionStatus.searching);
  }

  void setConnecting(String hubIp, int hubPort, {String? hubName}) {
    state = state.copyWith(
      status: ClientConnectionStatus.connecting,
      hubIp: hubIp,
      hubPort: hubPort,
      hubName: hubName,
    );
  }

  void setConnected(String assignedClientId) {
    state = state.copyWith(
      status: ClientConnectionStatus.connected,
      assignedClientId: assignedClientId,
      isBroadcasting: true,
    );
  }

  void setDisconnected() {
    state = state.copyWith(
      status: ClientConnectionStatus.disconnected,
      isBroadcasting: false,
    );
  }

  void updateVuLevel(double level) {
    state = state.copyWith(vuLevel: level.clamp(0.0, 1.0));
  }
}

final clientStateProvider =
    NotifierProvider<ClientStateNotifier, ClientState>(
  ClientStateNotifier.new,
);
