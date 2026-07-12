import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/client_info.dart';

class HubStateNotifier extends Notifier<Map<String, ClientInfo>> {
  @override
  Map<String, ClientInfo> build() => {};

  void addOrUpdateClient(ClientInfo client) {
    state = {...state, client.id: client};
  }

  void removeClient(String clientId) {
    final updated = Map<String, ClientInfo>.from(state);
    updated.remove(clientId);
    state = updated;
  }

  void setVolume(String clientId, double volume) {
    final client = state[clientId];
    if (client == null) return;
    state = {
      ...state,
      clientId: client.copyWith(volume: volume.clamp(0.0, 1.0)),
    };
  }

  void setMuted(String clientId, {required bool muted}) {
    final client = state[clientId];
    if (client == null) return;
    state = {
      ...state,
      clientId: client.copyWith(isMuted: muted),
    };
  }

  void markInactive(String clientId) {
    final client = state[clientId];
    if (client == null) return;
    state = {
      ...state,
      clientId: client.copyWith(isActive: false),
    };
  }

  void updateLastSeen(String clientId) {
    final client = state[clientId];
    if (client == null) return;
    state = {
      ...state,
      clientId: client.copyWith(lastSeen: DateTime.now(), isActive: true),
    };
  }

  void updateVuLevel(String clientId, double level) {
    final client = state[clientId];
    if (client == null) return;
    state = {
      ...state,
      clientId: client.copyWith(vuLevel: level.clamp(0.0, 1.0)),
    };
  }

  void setMasterVolumeAll(double volume) {
    state = {
      for (final entry in state.entries)
        entry.key: entry.value.copyWith(volume: volume.clamp(0.0, 1.0)),
    };
  }
}

final hubStateProvider =
    NotifierProvider<HubStateNotifier, Map<String, ClientInfo>>(
  HubStateNotifier.new,
);
