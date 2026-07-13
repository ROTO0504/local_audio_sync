import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/client_link_stats.dart';

enum ClientConnectionStatus { searching, connecting, connected, disconnected }

/// nullable フィールドを copyWith で「変更しない」と「null に戻す」の
/// 両方を表現するためのセンチネル。デフォルト値をこれにしておき、
/// 呼び出し側が明示的に値(null を含む)を渡したときだけ差し替える。
const Object _unset = Object();

class ClientState {
  final ClientConnectionStatus status;
  final String? hubIp;
  final int hubPort;

  /// 接続(試行)中の Hub の表示名。
  final String? hubName;
  final String? assignedClientId;
  final double vuLevel; // 0.0 - 1.0, for VU meter
  final bool isBroadcasting;

  /// Hub からのリモート制御(PAUSE / STOP)で配信を止められているか。
  final bool isPausedByHub;

  /// このセッションで送出した音声パケット数(UI 表示用)。
  final int packetCount;

  /// キャプチャ開始/継続時のエラーメッセージ(なければ null)。
  final String? captureError;

  /// iOS の Broadcast Extension が実際に配信中か(iOS 専用の状態)。
  final bool broadcastingActive;

  /// このデバイスの永続 UUID。接続状態遷移をまたいで保持する。
  final String? deviceId;

  /// 接続中(または接続先として選択中)の Hub のキー。
  /// `hubId ?? 'ip:port'`。ピッカーで前回接続マークを付ける等に使う。
  final String? connectedHubId;

  /// IP 直接指定の手動接続モードか。
  final bool isManualMode;

  /// リンク品質のスナップショット(未計測時は null)。
  final ClientLinkStats? linkStats;

  /// iOS の Broadcast Extension が App Group へ書き出した診断テキスト
  /// (コンテナ取得可否・.audioApp バッファ数・実サンプルレート・送信バイト等)。
  /// 音声が届かないときの切り分け表示に使う。iOS 以外や未配信時は null。
  final String? broadcastDiagnostics;

  const ClientState({
    this.status = ClientConnectionStatus.searching,
    this.hubIp,
    this.hubPort = 7777,
    this.hubName,
    this.assignedClientId,
    this.vuLevel = 0.0,
    this.isBroadcasting = false,
    this.isPausedByHub = false,
    this.packetCount = 0,
    this.captureError,
    this.broadcastingActive = false,
    this.deviceId,
    this.connectedHubId,
    this.isManualMode = false,
    this.linkStats,
    this.broadcastDiagnostics,
  });

  ClientState copyWith({
    ClientConnectionStatus? status,
    Object? hubIp = _unset,
    int? hubPort,
    Object? hubName = _unset,
    Object? assignedClientId = _unset,
    double? vuLevel,
    bool? isBroadcasting,
    bool? isPausedByHub,
    int? packetCount,
    Object? captureError = _unset,
    bool? broadcastingActive,
    Object? deviceId = _unset,
    Object? connectedHubId = _unset,
    bool? isManualMode,
    Object? linkStats = _unset,
    Object? broadcastDiagnostics = _unset,
  }) {
    return ClientState(
      status: status ?? this.status,
      hubIp: hubIp == _unset ? this.hubIp : hubIp as String?,
      hubPort: hubPort ?? this.hubPort,
      hubName: hubName == _unset ? this.hubName : hubName as String?,
      assignedClientId: assignedClientId == _unset
          ? this.assignedClientId
          : assignedClientId as String?,
      vuLevel: vuLevel ?? this.vuLevel,
      isBroadcasting: isBroadcasting ?? this.isBroadcasting,
      isPausedByHub: isPausedByHub ?? this.isPausedByHub,
      packetCount: packetCount ?? this.packetCount,
      captureError:
          captureError == _unset ? this.captureError : captureError as String?,
      broadcastingActive: broadcastingActive ?? this.broadcastingActive,
      deviceId: deviceId == _unset ? this.deviceId : deviceId as String?,
      connectedHubId: connectedHubId == _unset
          ? this.connectedHubId
          : connectedHubId as String?,
      isManualMode: isManualMode ?? this.isManualMode,
      linkStats:
          linkStats == _unset ? this.linkStats : linkStats as ClientLinkStats?,
      broadcastDiagnostics: broadcastDiagnostics == _unset
          ? this.broadcastDiagnostics
          : broadcastDiagnostics as String?,
    );
  }
}

class ClientStateNotifier extends Notifier<ClientState> {
  @override
  ClientState build() => const ClientState();

  /// 探索状態へ戻す。deviceId は端末固有の識別子なので接続状態遷移を
  /// またいで保持する(他の接続系フィールドはリセットしてよい)。
  void setSearching() {
    state = ClientState(
      status: ClientConnectionStatus.searching,
      deviceId: state.deviceId,
      isManualMode: state.isManualMode,
    );
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

  void setPausedByHub(bool paused) {
    state = state.copyWith(isPausedByHub: paused, vuLevel: paused ? 0.0 : null);
  }

  // ---- v2 で追加したフィールドの setter 群 ----

  void setDeviceId(String? deviceId) {
    state = state.copyWith(deviceId: deviceId);
  }

  /// 送出パケット数を「値」で更新する(増分ではない)。
  void setPacketCount(int count) {
    state = state.copyWith(packetCount: count);
  }

  void setCaptureError(String? error) {
    state = state.copyWith(captureError: error);
  }

  void setBroadcasting(bool active) {
    state = state.copyWith(broadcastingActive: active);
  }

  void setManualMode(bool manual) {
    state = state.copyWith(isManualMode: manual);
  }

  void setConnectedHubId(String? hubId) {
    state = state.copyWith(connectedHubId: hubId);
  }

  void setLinkStats(ClientLinkStats? stats) {
    state = state.copyWith(linkStats: stats);
  }

  void setBroadcastDiagnostics(String? diagnostics) {
    state = state.copyWith(broadcastDiagnostics: diagnostics);
  }
}

final clientStateProvider =
    NotifierProvider<ClientStateNotifier, ClientState>(
  ClientStateNotifier.new,
);
