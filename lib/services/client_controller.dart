import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/client_link_stats.dart';
import '../models/control_messages.dart';
import '../providers/app_mode_provider.dart';
import '../providers/client_state_provider.dart';
import '../providers/discovered_hubs_provider.dart';
import 'device_identity_service.dart';
import 'discovery_service.dart';
import 'last_hub_store.dart';
import 'manual_hub_store.dart';
import 'mdns_discovery_service.dart';
import 'opus_encoder_service.dart';
import 'pcm_constants.dart';
import 'screen_audio_capture_service.dart';
import 'udp_sender_service.dart';

/// クライアント(送信側)のコアロジック。
///
/// 旧実装ではこの一式が client_screen.dart(UI の State)へ直書きされて
/// おり、テストも再利用もできなかった。[HubController] に倣ってサービスへ
/// 抽出し、UI は start / stop の呼び出しと provider 購読、そして一過性
/// メッセージ([messages])の表示だけを行う。
///
/// 役割:
///   - UDP ビーコン / mDNS による Hub 探索と発見集合への集約
///   - 前回接続 Hub(hubId)一致時の自動再接続、それ以外は手動ピッカー誘導
///   - 手動 IP 接続とその再接続ループ
///   - キャプチャ → Opus エンコード → UDP 送信パイプライン
///   - Hub からのリモート制御(PAUSE / RESUME / STOP)への追従
class ClientController {
  ClientController(
    this._ref, {
    ClientDiscoveryListener? discovery,
    ClientMdnsBrowser? mdnsBrowser,
    ScreenAudioCaptureService? capture,
    OpusEncoderService? encoder,
    UdpSenderService? sender,
    DeviceIdentityService? identity,
    ManualHubStore? manualStore,
    LastHubStore? lastHubStore,
    bool? isIOSOverride,
    bool? isAndroidOverride,
    MethodChannel? broadcastChannel,
    Duration statsPollInterval = const Duration(seconds: 2),
    Duration pruneInterval = const Duration(seconds: 4),
    Duration pruneMaxAge = const Duration(seconds: 8),
  })  : _discovery = discovery ?? ClientDiscoveryListener(),
        _mdnsBrowser = mdnsBrowser ?? ClientMdnsBrowser(),
        _capture = capture ?? ScreenAudioCaptureService(),
        _encoder = encoder ?? OpusEncoderService(),
        _sender = sender ?? UdpSenderService(),
        _identity = identity ?? DeviceIdentityService(),
        _manualStore = manualStore ?? ManualHubStore(),
        _lastHubStore = lastHubStore ?? LastHubStore(),
        _isIOSOverride = isIOSOverride,
        _isAndroidOverride = isAndroidOverride,
        _broadcastChannel = broadcastChannel ??
            const MethodChannel('com.example.local_audio_sync/broadcast'),
        _statsPollInterval = statsPollInterval,
        _pruneInterval = pruneInterval,
        _pruneMaxAge = pruneMaxAge;

  final Ref _ref;
  final ClientDiscoveryListener _discovery;
  final ClientMdnsBrowser _mdnsBrowser;
  final ScreenAudioCaptureService _capture;
  final OpusEncoderService _encoder;
  final UdpSenderService _sender;
  final DeviceIdentityService _identity;
  final ManualHubStore _manualStore;
  final LastHubStore _lastHubStore;
  final bool? _isIOSOverride;
  final bool? _isAndroidOverride;
  final MethodChannel _broadcastChannel;
  final Duration _statsPollInterval;
  final Duration _pruneInterval;
  final Duration _pruneMaxAge;

  bool get _isIOS => _isIOSOverride ?? Platform.isIOS;
  bool get _isAndroid => _isAndroidOverride ?? Platform.isAndroid;

  StreamSubscription? _discoverySub;
  StreamSubscription? _allHubsSub;
  StreamSubscription? _mdnsSub;
  StreamSubscription? _hubLostSub;
  StreamSubscription? _captureSub;
  Timer? _broadcastingPoll;
  Timer? _manualRetryTimer;
  Timer? _statsTimer;
  Timer? _pruneTimer;

  bool _started = false;
  bool _connectingToHub = false;
  int _packetCount = 0;
  int _autoReconnectFailures = 0;

  /// 前回接続した Hub の hubId(一致した Hub のみ自動再接続する)。
  String? _lastHubId;

  /// 手動接続中の接続先(null なら自動探索モード)。
  DiscoveredHub? _manualHub;

  /// 手動接続中の接続先。null なら自動探索モード。
  DiscoveredHub? get manualHub => _manualHub;

  final StreamController<String> _messages =
      StreamController<String>.broadcast();

  /// 一過性のユーザー向けメッセージ(旧 SnackBar 相当)。画面が購読して表示する。
  Stream<String> get messages => _messages.stream;

  void _emit(String message) {
    if (!_messages.isClosed) _messages.add(message);
  }

  ClientStateNotifier get _clientState =>
      _ref.read(clientStateProvider.notifier);

  // ---- ライフサイクル ----

  /// 探索・エンコーダ初期化・自 ID 取得を行い、必要なら iOS の
  /// キャプチャパイプラインを立ち上げる。二重起動はガードする。
  Future<void> start() async {
    if (_started) return;
    _started = true;

    _encoder.init();
    _identity.getClientUuid().then((uuid) {
      _clientState.setDeviceId(uuid);
    });

    // 前回接続 Hub を復元(hubId 一致時のみ自動再接続の判定に使う)。
    final lastHub = await _lastHubStore.loadLastHub();
    _lastHubId = lastHub?.hubId;

    // v2 Hub の PONG が途絶えたら、ビーコン喪失と同じ経路で再探索に戻す。
    _sender.onHubUnresponsive = _onHubLost;
    // Hub からのリモート制御。送信ゲートの開閉は UdpSenderService 内で
    // 済んでいるので、ここでは UI 状態とキャプチャの停止だけを行う。
    _sender.onRemoteCommand = _onRemoteCommand;

    await _startDiscovery();

    // リンク統計を定期ポーリングして state へ載せる。
    _statsTimer =
        Timer.periodic(_statsPollInterval, (_) => _refreshLinkStats());
    // 発見集合から古い Hub を落とす。
    _pruneTimer = Timer.periodic(
      _pruneInterval,
      (_) => _ref.read(discoveredHubsProvider.notifier).pruneStale(_pruneMaxAge),
    );

    if (_isIOS) {
      // iOS では実際の音が来るのは Picker でユーザーが配信を開始した後。
      // ここでは UDS の listener だけ起動しておく。
      await _startCapturePipeline();
      _broadcastingPoll = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _refreshBroadcastingState(),
      );
    }
  }

  // ---- 探索 ----

  Future<void> _startDiscovery() async {
    _clientState.setSearching();
    try {
      await _discovery.start();
      _discoverySub = _discovery.stream.listen(_onDiscovered);
      _allHubsSub = _discovery.allHubsStream.listen(_upsertHub);
      _hubLostSub = _discovery.hubLostStream.listen((_) => _onBeaconLost());
      await _mdnsBrowser.start();
      _mdnsSub = _mdnsBrowser.stream.listen(_onDiscovered);
    } catch (e) {
      _emit('Hub 検索の開始に失敗しました: $e');
    }
  }

  /// 探索(ビーコン + mDNS)を停止する。手動接続に切り替えるとき用。
  Future<void> _stopDiscovery() async {
    await _discoverySub?.cancel();
    _discoverySub = null;
    await _allHubsSub?.cancel();
    _allHubsSub = null;
    await _mdnsSub?.cancel();
    _mdnsSub = null;
    await _hubLostSub?.cancel();
    _hubLostSub = null;
    _discovery.stop();
    await _mdnsBrowser.stop();
  }

  /// 発見集合へ Hub を積む(接続はしない)。
  void _upsertHub(DiscoveredHub hub) {
    _ref.read(discoveredHubsProvider.notifier).upsert(hub);
  }

  /// ビーコン / mDNS で Hub を発見したときの処理。
  ///
  /// first-wins は撤廃した。前回接続した hubId と一致する Hub が現れたときだけ
  /// 自動接続し、それ以外は集合へ積むだけでピッカーからの手動選択を促す。
  void _onDiscovered(DiscoveredHub hub) {
    _upsertHub(hub);
    final state = _ref.read(clientStateProvider);
    if (state.isManualMode) return; // 手動モードは独自の再接続ループを持つ
    if (_connectingToHub || _sender.isConnected) return;
    if (_lastHubId != null && hub.hubId == _lastHubId) {
      unawaited(connectTo(hub));
    }
  }

  /// ビーコン喪失(mDNS / UDP ビーコンが lossTimeout 途絶)時の処理。
  ///
  /// 接続中(音声送信・PONG が生きている)なら**切断しない**。ビーコンの間欠は
  /// 接続断ではなく、ここで切ると 5〜6 秒周期の再接続ループに陥りノイズ・音切れの
  /// 原因になる。実際の Hub 死は PONG タイムアウト([_onHubLost] を直接呼ぶ
  /// onHubUnresponsive)で検出する。未接続時のみ再探索状態へ戻す。
  void _onBeaconLost() {
    if (_sender.isConnected) {
      debugPrint('[ClientController] ビーコン途絶だが接続は健全 → 維持');
      return;
    }
    unawaited(_onHubLost());
  }

  Future<void> _onHubLost() async {
    _sender.disconnect();
    _connectingToHub = false;

    final manual = _manualHub;
    if (manual != null) {
      // 手動接続モードでは探索に戻らず、同じ接続先へ再接続を試み続ける。
      debugPrint('[ClientController] 手動接続先への再接続を試みます');
      _clientState.setConnecting(manual.ip, manual.port, hubName: manual.name);
      _emit('Hub への接続が切れました。再接続しています...');
      _scheduleManualReconnect();
    } else {
      // 自動モードでは探索に戻る。記憶 hubId が再び見つかれば
      // _onDiscovered が自動再接続する。
      debugPrint('[ClientController] Hub のビーコンが途絶えたので再探索へ戻ります');
      _clientState.setSearching();
      _emit('Hub への接続を見失いました。再探索しています...');
    }
  }

  void _scheduleManualReconnect() {
    _manualRetryTimer?.cancel();
    _manualRetryTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      final manual = _manualHub;
      if (manual == null || _sender.isConnected) {
        timer.cancel();
        return;
      }
      unawaited(connectTo(manual, manual: true));
    });
  }

  // ---- 接続 ----

  /// 指定 Hub へ接続する。ピッカー選択・自動再接続・手動接続の共通経路。
  ///
  /// 既に別 Hub に繋がっている場合は切り離してから繋ぎ直す。[manual] が真の
  /// ときは手動接続モードとして扱い、切断時に自動探索へ戻さず再接続を試みる。
  Future<void> connectTo(DiscoveredHub hub, {bool manual = false}) async {
    if (_connectingToHub) return;
    _connectingToHub = true;

    // 既存接続があれば片付ける(Hub 切替)。
    if (_sender.isConnected) {
      await _stopCaptureOnly();
      _sender.disconnect();
    }

    _manualHub = manual ? hub : null;
    _clientState.setManualMode(manual);

    final notifier = _clientState;
    notifier.setConnecting(hub.ip, hub.port, hubName: hub.name);
    notifier.setConnectedHubId(ClientDiscoveryListener.keyOf(hub));

    try {
      final name = _ref.read(deviceNameProvider);
      final uuid = await _identity.getClientUuid();
      await _sender.connect(hub.ip, hub.port, name, uuid);
      notifier.setConnected(uuid);
      _autoReconnectFailures = 0;

      // hubId を持つ Hub への接続だけ「前回 Hub」として記憶する。
      if (hub.hubId != null) {
        _lastHubId = hub.hubId;
        await _lastHubStore.saveLastHub(hub);
      }

      // iOS も含めキャプチャ(受信)を確実に起動する。冪等なので既に稼働中なら
      // 何もしない。iOS で受信リスナが何らかの理由で止まっていても、接続時に
      // ここで復帰し「接続しても音が来ない」状態を防ぐ。
      await _startCapturePipeline();
    } catch (e) {
      notifier.setDisconnected();
      _emit('Hub への接続に失敗しました: $e');
      _autoReconnectFailures++;
      if (_autoReconnectFailures >= 3 && !manual) {
        _emit('自動接続に繰り返し失敗しました。別の Hub を選ぶこともできます。');
      }
    } finally {
      _connectingToHub = false;
    }
  }

  /// IP:ポート指定で Hub に接続する(ブロードキャスト不達環境 / VPN / WAN 用)。
  Future<void> connectManually(String ip, int port) async {
    _manualRetryTimer?.cancel();
    await _stopDiscovery();

    final hub = DiscoveredHub(ip: ip, port: port, name: '手動接続');
    await _manualStore.add(ip, port);
    await connectTo(hub, manual: true);
    // 初回接続に失敗した場合もリトライループに乗せる。
    if (!_sender.isConnected) {
      _scheduleManualReconnect();
    }
  }

  /// 手動接続をやめて自動探索に戻る。
  Future<void> returnToAutoDiscovery() async {
    _manualRetryTimer?.cancel();
    _manualHub = null;
    _clientState.setManualMode(false);
    if (_sender.isConnected) {
      await _stopCaptureOnly();
    }
    _sender.disconnect();
    _connectingToHub = false;
    _ref.read(discoveredHubsProvider.notifier).clear();
    await _startDiscovery();
  }

  /// 手動接続の履歴(`ip:port`)を返す。ピッカーの手動タブが使う。
  Future<List<String>> loadManualHistory() => _manualStore.loadHistory();

  // ---- キャプチャパイプライン ----

  Future<void> _startCapturePipeline() async {
    // 冪等: 既に受信・購読中なら何もしない。iOS の自己修復ポーリングや
    // connectTo から何度呼ばれても二重購読・二重起動しない。
    if (_captureSub != null && _capture.isCapturing) return;

    // Android のみ MediaProjection の許可が必要(iOS は Picker、他は不要)。
    if (_isAndroid) {
      final granted = await _capture.requestPermission();
      if (!granted) {
        _emit('画面音声キャプチャの権限が拒否されました。設定から許可してください。');
        _clientState.setCaptureError('画面音声キャプチャの権限が拒否されました');
        return;
      }
      // フォアグラウンドサービスをここで起動(Android のバックグラウンド維持用)。
      try {
        await _broadcastChannel.invokeMethod('startBroadcast');
      } catch (e) {
        debugPrint('startBroadcast 失敗: $e');
      }
    }

    try {
      await _capture.start();
      _clientState.setCaptureError(null);
    } catch (e) {
      _clientState.setCaptureError(e.toString());
      return;
    }

    // 念のため古い購読が残っていれば張り替える(再起動時の二重購読防止)。
    await _captureSub?.cancel();
    _captureSub = _capture.pcmStream.listen(
      (pcmBytes) {
        if (pcmBytes.length != kBytesPerChunk) return; // 念のため
        final level = computePcm16RmsLevel(pcmBytes);
        _clientState.updateVuLevel(level);
        final opus = _encoder.encode(pcmBytes);
        if (opus != null && _sender.isConnected) {
          _sender.sendAudio(opus);
          _packetCount++;
          _clientState.setPacketCount(_packetCount);
        }
      },
      onError: (Object err, StackTrace st) {
        _clientState.setCaptureError(err.toString());
      },
    );
  }

  /// キャプチャだけを止める(Hub との接続・PING は維持)。
  Future<void> _stopCaptureOnly() async {
    // iOS は Extension が配信を続けるため、切断・一時停止・Hub 切替では受信を
    // 止めない(送信は _sender.isConnected ゲートで抑止)。ここで止めて放置すると
    // 受信リスナが二度と復帰せず「接続しても音が来ない」状態になる(既知の穴)。
    if (_isIOS) return;
    if (_isAndroid) {
      try {
        await _broadcastChannel.invokeMethod('stopBroadcast');
      } catch (_) {}
    }
    await _captureSub?.cancel();
    _captureSub = null;
    await _capture.stop();
  }

  Future<void> _refreshBroadcastingState() async {
    if (!_isIOS) return;
    // 自己修復: 受信リスナが止まっていたら復帰させる。iOS で「接続しても音が
    // 来ない/たまにしか来ない」の主因(受信リスナ停止)を毎秒チェックで塞ぐ。
    if (_started && !_capture.isCapturing) {
      debugPrint('[ClientController] iOS 受信リスナが停止 → 復帰させます');
      await _startCapturePipeline();
    }
    final active = await _capture.isBroadcastingActive();
    if (active != _ref.read(clientStateProvider).broadcastingActive) {
      _clientState.setBroadcasting(active);
    }
    // 診断テキスト(Extension の状態ファイル)も更新して UI に載せる。
    final diag = await _capture.broadcastDiagnostics();
    if (diag != _ref.read(clientStateProvider).broadcastDiagnostics) {
      _clientState.setBroadcastDiagnostics(diag);
    }
  }

  void _refreshLinkStats() {
    if (!_sender.isConnected) {
      _clientState.setLinkStats(null);
      return;
    }
    _clientState.setLinkStats(ClientLinkStats(
      sincePong: _sender.sincePong,
      consecutiveFailures: _sender.consecutiveFailures,
      sentPackets: _sender.sentPackets,
    ));
  }

  // ---- リモート制御 ----

  void _onRemoteCommand(RemoteCommandAction action) {
    final notifier = _clientState;
    switch (action) {
      case RemoteCommandAction.pause:
        notifier.setPausedByHub(true);
        _emit('Hub が配信を一時停止しました');
      case RemoteCommandAction.resume:
        notifier.setPausedByHub(false);
        _emit('Hub が配信を再開しました');
      case RemoteCommandAction.stop:
        notifier.setPausedByHub(true);
        // iOS は Broadcast Extension を App 側から止められない(Picker 制約)
        // ため送信ゲートの閉止のみ。他 OS はキャプチャ自体を停止する。
        if (!_isIOS) {
          unawaited(_stopCaptureOnly());
        }
        _emit('Hub が配信を停止しました');
    }
  }

  /// Hub による一時停止 / 停止からローカル操作で配信を再開する(後勝ち)。
  Future<void> resumeFromHubPause() async {
    _sender.setPaused(false);
    _clientState.setPausedByHub(false);
    // STOP でキャプチャごと止まっている場合は取り直す(iOS は Extension が
    // 生きていればゲート開放だけで音が流れ始める)。
    if (!_isIOS && _captureSub == null) {
      await _startCapturePipeline();
    }
  }

  // ---- 停止 ----

  /// ユーザー操作による切断(「Hub から切断」)。探索は止めない。
  Future<void> disconnect() async {
    if (_isAndroid) {
      try {
        await _broadcastChannel.invokeMethod('stopBroadcast');
      } catch (_) {}
    }
    // iOS は受信リスナを維持(Extension は配信継続。再接続で即座に音が復帰)。
    // 受信の完全停止は画面離脱時の stop() が担う。
    if (!_isIOS) {
      await _captureSub?.cancel();
      _captureSub = null;
      await _capture.stop();
    }
    _sender.disconnect();
    _connectingToHub = false;
    _manualHub = null;
    _clientState.setDisconnected();
  }

  /// 画面を離れる / 役割切替時の停止(探索も含めて片付ける)。
  Future<void> stop() async {
    _broadcastingPoll?.cancel();
    _broadcastingPoll = null;
    _manualRetryTimer?.cancel();
    _manualRetryTimer = null;
    _statsTimer?.cancel();
    _statsTimer = null;
    _pruneTimer?.cancel();
    _pruneTimer = null;
    await _stopDiscovery();
    // iOS は disconnect で受信を残すため、ここで確実に受信リスナを止める。
    await _captureSub?.cancel();
    _captureSub = null;
    await _capture.stop();
    await disconnect();
    _started = false;
  }

  /// provider 破棄時の完全解放。
  void dispose() {
    unawaited(stop());
    _discovery.dispose();
    _mdnsBrowser.dispose();
    _encoder.dispose();
    _capture.dispose();
    _messages.close();
  }
}
