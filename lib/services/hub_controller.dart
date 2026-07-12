import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/audio_packet.dart';
import '../models/client_diagnostics.dart';
import '../models/client_info.dart';
import '../models/control_messages.dart';
import '../providers/hub_diagnostics_provider.dart';
import '../providers/hub_state_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_mixer_service.dart';
import 'client_settings_store.dart';
import 'device_identity_service.dart';
import 'discovery_service.dart';
import 'hub_background_keeper.dart';
import 'jitter_buffer.dart';
import 'mdns_discovery_service.dart';
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
    HubMdnsAdvertiser? mdnsAdvertiser,
    HubBackgroundKeeper? backgroundKeeper,
    DeviceIdentityService? identity,
    ClientSettingsStore? settingsStore,
    Duration staleCheckInterval = const Duration(seconds: 10),
    Duration staleTimeout = const Duration(seconds: 10),
    Duration vuUpdateInterval = const Duration(milliseconds: 150),
    Duration diagnosticsInterval = const Duration(seconds: 1),
  })  : _receiver = receiver ?? UdpReceiverService(),
        _mixer = mixer ?? AudioMixerService(),
        _beacon = beacon ?? HubBeaconSender(),
        _mdnsAdvertiser = mdnsAdvertiser ?? HubMdnsAdvertiser(),
        _backgroundKeeper = backgroundKeeper ?? HubBackgroundKeeper(),
        _identity = identity ?? DeviceIdentityService(),
        _settingsStore = settingsStore ?? ClientSettingsStore(),
        _staleCheckInterval = staleCheckInterval,
        _staleTimeout = staleTimeout,
        _vuUpdateInterval = vuUpdateInterval,
        _diagnosticsInterval = diagnosticsInterval;

  final Ref _ref;
  final UdpReceiverService _receiver;
  final AudioMixerService _mixer;
  final HubBeaconSender _beacon;
  final HubMdnsAdvertiser _mdnsAdvertiser;
  final HubBackgroundKeeper _backgroundKeeper;
  final DeviceIdentityService _identity;
  final ClientSettingsStore _settingsStore;
  final Duration _staleCheckInterval;
  final Duration _staleTimeout;
  final Duration _vuUpdateInterval;
  final Duration _diagnosticsInterval;

  final Map<String, int> _uuidToClientId = {};
  final Map<String, DateTime> _lastVuUpdate = {};
  int _nextClientId = 1;
  Timer? _staleTimer;
  Timer? _diagnosticsTimer;
  bool _running = false;

  /// マスター音量(0.0〜1.0)。各クライアントの個別音量には乗算で効く。
  /// クライアントの volume は破壊せず、実効音量のみをミキサーへ反映する。
  double _masterVolume = 1.0;

  /// start した時刻(ダッシュボードの稼働時間表示用)。stop で null に戻す。
  DateTime? _startedAt;

  static const String _kJitterPresetKey = 'hub_jitter_preset';
  static const String _kMasterVolumeKey = 'hub_master_volume';

  bool get isRunning => _running;

  /// 現在のマスター音量(0.0〜1.0)。
  double get masterVolume => _masterVolume;

  /// start した時刻(未起動なら null)。ダッシュボードの稼働時間表示用。
  DateTime? get startedAt => _startedAt;

  /// 現在のジッターバッファ遅延プリセット。
  JitterBufferPreset get jitterPreset => _mixer.jitterPreset;

  /// CMD を最大回数再送しても届かなかったときに UI へ通知する。
  /// (uuid, 失敗したコマンド)を渡す。
  void Function(String uuid, RemoteCommandAction action)? onCommandDeliveryFailed;

  /// テスト・デバッグ用: uuid に割り当てたセッション内 clientId を返す。
  int? clientIdOf(String uuid) => _uuidToClientId[uuid];

  Future<void> start(String hubName) async {
    if (_running) return;
    _running = true;
    _startedAt = DateTime.now();

    AudioMixerService.initFfi();

    _receiver.onClientHello = _handleHello;
    _receiver.onClientPing = _handlePing;
    _receiver.onClientBye = _handleBye;
    _receiver.onAudioPacket = _handleAudioPacket;
    _receiver.onCommandFailed = _handleCommandFailed;
    _mixer.onClientLevel = _handleClientLevel;

    // 保存済みのジッターバッファプリセットとマスター音量を復元
    final prefs = await SharedPreferences.getInstance();
    _mixer.jitterPreset =
        JitterBufferPreset.fromName(prefs.getString(_kJitterPresetKey));
    _masterVolume = (prefs.getDouble(_kMasterVolumeKey) ?? 1.0).clamp(0.0, 1.0);

    final hubId = await _identity.getHubId();
    await _receiver.start();
    // UDP ビーコン(v1/v2 併送)と mDNS 公開のデュアルスタック。
    // iOS はブロードキャスト送信不可のため mDNS が唯一の被発見手段になる。
    await _beacon.start(hubName, hubId: hubId);
    await _mdnsAdvertiser.start(hubName: hubName, hubId: hubId);
    // Android FGS / iOS AVAudioSession によるバックグラウンド維持
    await _backgroundKeeper.start();

    _staleTimer = Timer.periodic(_staleCheckInterval, (_) => _checkStale());
    // 診断ポーリング: 全 clientId のミキサー統計を集約して provider へ流す。
    _diagnosticsTimer =
        Timer.periodic(_diagnosticsInterval, (_) => _pollDiagnostics());
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
    _receiver.onCommandFailed = null;
    _mixer.onClientLevel = null;

    _staleTimer?.cancel();
    _staleTimer = null;
    _diagnosticsTimer?.cancel();
    _diagnosticsTimer = null;
    _startedAt = null;
    _beacon.stop();
    await _mdnsAdvertiser.stop();
    await _backgroundKeeper.stop();
    _receiver.stop();
    _mixer.removeAllClients(); // ネイティブ Opus デコーダを全て解放
    AudioMixerService.destroyFfi();
  }

  // ---- 受信ハンドラ ----

  Future<void> _handleHello(ClientHello hello, String ip, int port) async {
    final existingId = _uuidToClientId[hello.uuid];
    final id = existingId ?? _nextClientId++;
    _uuidToClientId[hello.uuid] = id;
    _receiver.sendAckHello(ip, port, id);

    final existing = _ref.read(hubStateProvider)[hello.uuid];

    // 音量 / ミュートの復元優先順位:
    //   セッション中の状態(existing)> 永続ストア > デフォルト
    // ストアを読むのは新規参加(再起動後の再接続を含む)のときだけ。
    ClientSettings? stored;
    if (existing == null) {
      stored = await _settingsStore.load(hello.uuid);
    }
    if (!_running) return; // await 中に stop() された場合は何もしない

    // 新クライアントは HELLO2 と v1 HELLO を併送してくる(旧 Hub 互換)。
    // 到着順は保証されないため、v1 HELLO が後から届いても platform や
    // protocolVersion を「unknown / 1」へ退行させない。
    var platform = hello.platform;
    var protocolVersion = hello.protocolVersion;
    if (existing != null && hello.protocolVersion < existing.protocolVersion) {
      platform = existing.platform;
      protocolVersion = existing.protocolVersion;
    }

    final volume = existing?.volume ?? stored?.volume ?? 1.0;
    final isMuted = existing?.isMuted ?? stored?.isMuted ?? false;

    final client = ClientInfo(
      id: hello.uuid,
      name: hello.name,
      ip: ip,
      port: port,
      platform: platform,
      protocolVersion: max(protocolVersion, existing?.protocolVersion ?? 1),
      volume: volume,
      isMuted: isMuted,
      lastSeen: DateTime.now(),
      // 初回接続時刻。再接続(existing あり)では既存値を保持する。
      connectedAt: existing?.connectedAt ?? DateTime.now(),
    );
    _ref.read(hubStateProvider.notifier).addOrUpdateClient(client);

    // 同一 UUID の再接続(BYE なし)の場合は、古いデコーダ/ジッター
    // バッファを先に破棄してからクリーンな状態で登録し直す。
    if (existing != null) {
      _mixer.removeClient(id);
    }
    _registerMixerClient(hello.uuid, id);
    // 復元した音量をマスター音量込みの実効値でネイティブミキサーへ即時反映
    _mixer.setVolume(id, effectiveVolume(hello.uuid));
  }

  /// クライアントの実効音量を返す。
  /// = (ミュートなら 0、そうでなければ個別 volume) × マスター音量。
  /// クライアントが未登録なら個別音量 1.0 扱いでマスター音量のみを返す。
  double effectiveVolume(String uuid) {
    final client = _ref.read(hubStateProvider)[uuid];
    if (client == null) return _masterVolume;
    return (client.isMuted ? 0.0 : client.volume) * _masterVolume;
  }

  /// ミキサーへクライアントを登録する。
  /// JitterBuffer が seq 断絶を検出したら送信側に RESYNC を返す。
  /// ip/port はコールバック発火時点の値を Provider から読む(クライアントが
  /// ポートを切り替えても追従できるように)。
  void _registerMixerClient(String uuid, int clientId) {
    _mixer.addClient(
      clientId,
      onResync: () {
        final current = _ref.read(hubStateProvider)[uuid];
        if (current != null) {
          _receiver.sendResync(current.ip, current.port, clientId);
        }
      },
    );
  }

  /// ジッターバッファの遅延プリセットを切り替える。
  /// 以後の接続に加え、接続中のクライアントのバッファも作り直して即時適用する。
  Future<void> setJitterPreset(JitterBufferPreset preset) async {
    if (_mixer.jitterPreset == preset) return;
    _mixer.jitterPreset = preset;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kJitterPresetKey, preset.name);

    // 接続中クライアントのバッファを新しい深さで再生成
    // (一瞬途切れるが、以降は新プリセットの遅延で安定する)
    for (final entry in _uuidToClientId.entries) {
      _mixer.removeClient(entry.value);
      _registerMixerClient(entry.key, entry.value);
      final client = _ref.read(hubStateProvider)[entry.key];
      if (client != null) {
        _mixer.setVolume(entry.value, effectiveVolume(entry.key));
      }
    }
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
    double volume = _masterVolume;
    if (uuid != null) {
      final client = _ref.read(hubStateProvider)[uuid];
      if (client != null) {
        // 一時停止中のはずのクライアントから音声が来た = クライアント側の
        // ローカル操作で再開された(後勝ちルール)。Hub の表示も追従する。
        if (client.isPaused) {
          _ref.read(hubStateProvider.notifier).setPaused(uuid, paused: false);
        }
      }
      volume = effectiveVolume(uuid);
    }
    _mixer.setVolume(packet.clientId, volume);
    _mixer.pushEncodedPacket(packet.clientId, packet.sequence, packet.opusBytes);
  }

  /// ミキサーのデコード済み音声レベル(20ms ごと)を間引いて UI へ反映する。
  void _handleClientLevel(int clientId, double level) {
    final uuid = _uuidOf(clientId);
    if (uuid == null) return;
    final now = DateTime.now();
    final last = _lastVuUpdate[uuid];
    if (last != null && now.difference(last) < _vuUpdateInterval) return;
    _lastVuUpdate[uuid] = now;
    _ref.read(hubStateProvider.notifier).updateVuLevel(uuid, level);
  }

  // ---- UI からの操作 ----

  /// クライアントの音量を変更し、ミキサーへ即時反映 + 永続化する。
  Future<void> setClientVolume(String uuid, double volume) async {
    _ref.read(hubStateProvider.notifier).setVolume(uuid, volume);
    final clientId = _uuidToClientId[uuid];
    final client = _ref.read(hubStateProvider)[uuid];
    if (clientId != null && client != null) {
      _mixer.setVolume(clientId, effectiveVolume(uuid));
    }
    await _persistSettings(uuid);
  }

  /// クライアントのミュートを切り替え、ミキサーへ即時反映 + 永続化する。
  Future<void> setClientMuted(String uuid, {required bool muted}) async {
    _ref.read(hubStateProvider.notifier).setMuted(uuid, muted: muted);
    final clientId = _uuidToClientId[uuid];
    final client = _ref.read(hubStateProvider)[uuid];
    if (clientId != null && client != null) {
      _mixer.setVolume(clientId, effectiveVolume(uuid));
    }
    await _persistSettings(uuid);
  }

  /// マスター音量を変更する(非破壊)。
  ///
  /// 各クライアントの個別 volume は書き換えず、_masterVolume だけを更新して
  /// 全クライアントの実効音量(volume × master)をミキサーへ再適用する。
  /// 値は SharedPreferences(`hub_master_volume`)へ永続化する。
  Future<void> setMasterVolume(double volume) async {
    _masterVolume = volume.clamp(0.0, 1.0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kMasterVolumeKey, _masterVolume);
    for (final entry in _uuidToClientId.entries) {
      _mixer.setVolume(entry.value, effectiveVolume(entry.key));
    }
  }

  // ---- 選択集合への一括操作 ----

  /// 選択集合を一時停止する。
  void pauseSelected(Set<String> uuids) {
    for (final uuid in uuids) {
      pauseClient(uuid);
    }
  }

  /// 選択集合を再開する。
  void resumeSelected(Set<String> uuids) {
    for (final uuid in uuids) {
      resumeClient(uuid);
    }
  }

  /// 選択集合の配信を停止させる。
  void stopSelected(Set<String> uuids) {
    for (final uuid in uuids) {
      stopClient(uuid);
    }
  }

  /// 選択集合のミュートを一括設定する。
  Future<void> muteSelected(Set<String> uuids, bool muted) async {
    for (final uuid in uuids) {
      await setClientMuted(uuid, muted: muted);
    }
  }

  /// 選択集合の音量を一括設定する。
  Future<void> setSelectedVolume(Set<String> uuids, double volume) async {
    for (final uuid in uuids) {
      await setClientVolume(uuid, volume);
    }
  }

  /// 全クライアントのミュートを解除する。
  Future<void> unmuteAll() async {
    final uuids = _ref.read(hubStateProvider).keys.toList();
    for (final uuid in uuids) {
      await setClientMuted(uuid, muted: false);
    }
  }

  /// クライアントを一覧から取り除く(切断済みエントリの整理用)。
  /// 永続化された音量設定は残るため、再接続すれば復元される。
  void removeClientEntry(String uuid) {
    final clientId = _uuidToClientId.remove(uuid);
    if (clientId != null) {
      _mixer.removeClient(clientId);
    }
    _lastVuUpdate.remove(uuid);
    _ref.read(hubStateProvider.notifier).removeClient(uuid);
  }

  Future<void> _persistSettings(String uuid) async {
    final client = _ref.read(hubStateProvider)[uuid];
    if (client == null) return;
    await _settingsStore.save(
      uuid,
      ClientSettings(volume: client.volume, isMuted: client.isMuted),
    );
  }

  // ---- リモート制御(Hub → Client) ----

  /// クライアントの配信を一時停止する(送信ゲートを閉じさせる)。
  /// 状態は楽観的に反映し、CMD が届かなければ onCommandDeliveryFailed で戻す。
  void pauseClient(String uuid) =>
      _sendCommandTo(uuid, RemoteCommandAction.pause);

  /// クライアントの配信を再開する。
  void resumeClient(String uuid) =>
      _sendCommandTo(uuid, RemoteCommandAction.resume);

  /// クライアントの配信自体を停止させる(キャプチャ停止)。
  /// iOS は Broadcast Extension を直接止められないため送信停止のみ保証。
  void stopClient(String uuid) =>
      _sendCommandTo(uuid, RemoteCommandAction.stop);

  /// アクティブな全クライアントを一時停止する。
  void pauseAll() {
    for (final client in _ref.read(hubStateProvider).values) {
      if (client.isActive && !client.isPaused) {
        pauseClient(client.id);
      }
    }
  }

  /// 一時停止中の全クライアントを再開する。
  void resumeAll() {
    for (final client in _ref.read(hubStateProvider).values) {
      if (client.isActive && client.isPaused) {
        resumeClient(client.id);
      }
    }
  }

  void _sendCommandTo(String uuid, RemoteCommandAction action) {
    final client = _ref.read(hubStateProvider)[uuid];
    final clientId = _uuidToClientId[uuid];
    if (client == null || clientId == null) return;
    // v1 クライアントは CMD を解釈できないので送らない
    if (client.protocolVersion < 2) {
      onCommandDeliveryFailed?.call(uuid, action);
      return;
    }
    _receiver.sendCommand(clientId, action, client.ip, client.port);
    // 楽観的に UI へ反映(未達なら _handleCommandFailed で戻す)
    switch (action) {
      case RemoteCommandAction.pause:
      case RemoteCommandAction.stop:
        _ref.read(hubStateProvider.notifier).setPaused(uuid, paused: true);
      case RemoteCommandAction.resume:
        _ref.read(hubStateProvider.notifier).setPaused(uuid, paused: false);
    }
  }

  /// CMD の再送が尽きた(クライアントに届かなかった)。楽観反映を戻す。
  void _handleCommandFailed(RemoteCommand command) {
    final uuid = _uuidOf(command.clientId);
    if (uuid == null) return;
    switch (command.action) {
      case RemoteCommandAction.pause:
      case RemoteCommandAction.stop:
        _ref.read(hubStateProvider.notifier).setPaused(uuid, paused: false);
      case RemoteCommandAction.resume:
        _ref.read(hubStateProvider.notifier).setPaused(uuid, paused: true);
    }
    onCommandDeliveryFailed?.call(uuid, command.action);
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

  // ---- 診断ポーリング ----

  /// 全 clientId のミキサー統計を集約し、lastSeen を ClientInfo から補完して
  /// hubDiagnosticsProvider へ流す。_uuidToClientId をそのまま辿るので
  /// clientId→uuid の逆引き線形探索(_uuidOf)を回避できる。
  void _pollDiagnostics() {
    final clients = _ref.read(hubStateProvider);
    final map = <String, ClientDiagnostics>{};
    for (final entry in _uuidToClientId.entries) {
      final uuid = entry.key;
      final stats = _mixer.statsOf(entry.value);
      final info = clients[uuid];
      if (stats == null && info == null) continue;
      map[uuid] = ClientDiagnostics(
        totalReceived: stats?.totalReceived ?? 0,
        totalDropped: stats?.totalDropped ?? 0,
        totalResynced: stats?.totalResynced ?? 0,
        bufferedFrames: stats?.bufferedFrames ?? 0,
        lastSeen: info?.lastSeen,
      );
    }
    _ref.read(hubDiagnosticsProvider.notifier).setAll(map);
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
