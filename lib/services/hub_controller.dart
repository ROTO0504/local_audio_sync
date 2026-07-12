import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/audio_packet.dart';
import '../models/client_info.dart';
import '../models/control_messages.dart';
import '../providers/hub_state_provider.dart';
import 'audio_mixer_service.dart';
import 'discovery_service.dart';
import 'udp_receiver_service.dart';

/// Hub(集約・再生側)のコアロジック。
///
/// 旧実装ではこの処理一式が hub_screen.dart(UI の State)に直書きされて
/// おり、テストも他画面からの再利用もできなかった。本クラスに集約し、
/// UI は start / stop の呼び出しと hubStateProvider の購読だけを行う。
///
/// 役割:
///   - UDP 受信(HELLO / PING / BYE / 音声)のハンドリング
///   - uuid ←→ セッション内 clientId(uint16)の対応管理
///   - ミキサーへのクライアント登録・音量反映・パケット投入
///   - ビーコン送信の開始・停止
///   - PING が途絶えたクライアントの inactive 化(stale 監視)
class HubController {
  HubController(
    this._ref, {
    UdpReceiverService? receiver,
    AudioMixerService? mixer,
    HubBeaconSender? beacon,
    Duration staleCheckInterval = const Duration(seconds: 10),
    Duration staleTimeout = const Duration(seconds: 10),
  })  : _receiver = receiver ?? UdpReceiverService(),
        _mixer = mixer ?? AudioMixerService(),
        _beacon = beacon ?? HubBeaconSender(),
        _staleCheckInterval = staleCheckInterval,
        _staleTimeout = staleTimeout;

  final Ref _ref;
  final UdpReceiverService _receiver;
  final AudioMixerService _mixer;
  final HubBeaconSender _beacon;
  final Duration _staleCheckInterval;
  final Duration _staleTimeout;

  final Map<String, int> _uuidToClientId = {};
  int _nextClientId = 1;
  Timer? _staleTimer;
  bool _running = false;

  bool get isRunning => _running;

  /// テスト・デバッグ用: uuid に割り当てたセッション内 clientId を返す。
  int? clientIdOf(String uuid) => _uuidToClientId[uuid];

  Future<void> start(String hubName) async {
    if (_running) return;
    _running = true;

    AudioMixerService.initFfi();

    _receiver.onClientHello = _handleHello;
    _receiver.onClientPing = _handlePing;
    _receiver.onClientBye = _handleBye;
    _receiver.onAudioPacket = _handleAudioPacket;

    await _receiver.start();
    await _beacon.start(hubName);

    _staleTimer = Timer.periodic(_staleCheckInterval, (_) => _checkStale());
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;

    // コールバックを先に外し、処理中の UDP イベントが破棄済みの
    // Riverpod 状態やミキサーへ触れないようにする。
    _receiver.onClientHello = null;
    _receiver.onClientPing = null;
    _receiver.onClientBye = null;
    _receiver.onAudioPacket = null;

    _staleTimer?.cancel();
    _staleTimer = null;
    _beacon.stop();
    _receiver.stop();
    _mixer.removeAllClients(); // ネイティブ Opus デコーダを全て解放
    AudioMixerService.destroyFfi();
  }

  // ---- 受信ハンドラ ----

  void _handleHello(ClientHello hello, String ip, int port) {
    final existingId = _uuidToClientId[hello.uuid];
    final id = existingId ?? _nextClientId++;
    _uuidToClientId[hello.uuid] = id;
    _receiver.sendAckHello(ip, port, id);

    final existing = _ref.read(hubStateProvider)[hello.uuid];

    // 新クライアントは HELLO2 と v1 HELLO を併送してくる(旧 Hub 互換)。
    // 到着順は保証されないため、v1 HELLO が後から届いても platform や
    // protocolVersion を「unknown / 1」へ退行させない。
    var platform = hello.platform;
    var protocolVersion = hello.protocolVersion;
    if (existing != null && hello.protocolVersion < existing.protocolVersion) {
      platform = existing.platform;
      protocolVersion = existing.protocolVersion;
    }

    final client = ClientInfo(
      id: hello.uuid,
      name: hello.name,
      ip: ip,
      port: port,
      platform: platform,
      protocolVersion: max(protocolVersion, existing?.protocolVersion ?? 1),
      volume: existing?.volume ?? 1.0,
      isMuted: existing?.isMuted ?? false,
      lastSeen: DateTime.now(),
    );
    _ref.read(hubStateProvider.notifier).addOrUpdateClient(client);

    // 同一 UUID の再接続(BYE なし)の場合は、古いデコーダ/ジッター
    // バッファを先に破棄してからクリーンな状態で登録し直す。
    if (existing != null) {
      _mixer.removeClient(id);
    }
    // JitterBuffer が seq 断絶を検出したら送信側に RESYNC を返す。
    // ip/port はコールバック発火時点の値を Provider から読む(クライアントが
    // ポートを切り替えても追従できるように)。
    _mixer.addClient(
      id,
      onResync: () {
        final current = _ref.read(hubStateProvider)[hello.uuid];
        if (current != null) {
          _receiver.sendResync(current.ip, current.port, id);
        }
      },
    );
  }

  void _handlePing(int clientId) {
    final uuid = _uuidOf(clientId);
    if (uuid != null) {
      _ref.read(hubStateProvider.notifier).updateLastSeen(uuid);
    }
  }

  void _handleBye(int clientId) {
    final uuid = _uuidOf(clientId);
    if (uuid != null) {
      _ref.read(hubStateProvider.notifier).removeClient(uuid);
      _uuidToClientId.remove(uuid);
      _mixer.removeClient(clientId);
    }
  }

  void _handleAudioPacket(AudioPacket packet, String ip) {
    // Provider の状態から音量・ミュートを反映してミキサーへ流す。
    final uuid = _uuidOf(packet.clientId);
    double volume = 1.0;
    if (uuid != null) {
      final client = _ref.read(hubStateProvider)[uuid];
      if (client != null) {
        volume = client.isMuted ? 0.0 : client.volume;
      }
    }
    _mixer.setVolume(packet.clientId, volume);
    _mixer.pushEncodedPacket(packet.clientId, packet.sequence, packet.opusBytes);
  }

  // ---- stale 監視 ----

  void _checkStale() {
    final clients = _ref.read(hubStateProvider);
    final now = DateTime.now();
    for (final entry in clients.entries) {
      if (!entry.value.isActive) continue;
      if (now.difference(entry.value.lastSeen) > _staleTimeout) {
        _ref.read(hubStateProvider.notifier).markInactive(entry.key);
        // ネイティブミキサーのスロットも解放し、音声コールバックが死んだ
        // クライアントのリングバッファを走査し続けないようにする。
        final clientId = _uuidToClientId[entry.key];
        if (clientId != null) {
          _mixer.removeClient(clientId);
          // UUID → clientId の対応は残す。再接続時に同じ番号を再利用し、
          // addClient が状態をクリーンに初期化する。
        }
      }
    }
  }

  String? _uuidOf(int clientId) {
    for (final entry in _uuidToClientId.entries) {
      if (entry.value == clientId) return entry.key;
    }
    return null;
  }
}

/// HubController のシングルトン Provider。
/// 画面側は `ref.read(hubControllerProvider)` で取得して start / stop を呼ぶ。
final hubControllerProvider = Provider<HubController>((ref) {
  final controller = HubController(ref);
  ref.onDispose(() {
    controller.stop();
  });
  return controller;
});
