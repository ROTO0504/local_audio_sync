import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/control_messages.dart';
import '../providers/app_mode_provider.dart';
import '../providers/client_state_provider.dart';
import '../services/device_identity_service.dart';
import '../services/discovery_service.dart';
import '../services/manual_hub_store.dart';
import '../services/mdns_discovery_service.dart';
import '../services/opus_encoder_service.dart';
import '../services/pcm_constants.dart';
import '../services/screen_audio_capture_service.dart';
import '../services/udp_sender_service.dart';
import '../widgets/broadcast_picker_button.dart';
import '../widgets/connection_status_badge.dart';
import '../widgets/vu_meter.dart';

/// Broadcast Upload Extension のバンドル ID。
/// Xcode でターゲットを作成するとき同じ値を Bundle Identifier に設定すること。
/// docs/iOS_BROADCAST_SETUP.md 参照。
const _broadcastExtensionBundleId =
    'com.example.localAudioSync.BroadcastExtension';

const _broadcastChannel = MethodChannel('com.example.local_audio_sync/broadcast');

class ClientScreen extends ConsumerStatefulWidget {
  const ClientScreen({super.key});

  @override
  ConsumerState<ClientScreen> createState() => _ClientScreenState();
}

class _ClientScreenState extends ConsumerState<ClientScreen> {
  final ClientDiscoveryListener _discovery = ClientDiscoveryListener();
  final ClientMdnsBrowser _mdnsBrowser = ClientMdnsBrowser();
  final ScreenAudioCaptureService _capture = ScreenAudioCaptureService();
  final OpusEncoderService _encoder = OpusEncoderService();
  final UdpSenderService _sender = UdpSenderService();
  final DeviceIdentityService _identity = DeviceIdentityService();
  final ManualHubStore _manualStore = ManualHubStore();

  StreamSubscription? _discoverySub;
  StreamSubscription? _mdnsSub;
  StreamSubscription? _hubLostSub;
  StreamSubscription? _captureSub;
  Timer? _broadcastingPoll;
  Timer? _manualRetryTimer;

  bool _connectingToHub = false;
  int _packetCount = 0;
  String? _captureError;
  bool _broadcastingActive = false;
  String? _deviceId;

  /// 手動接続中の接続先(null なら自動探索モード)。
  DiscoveredHub? _manualHub;

  @override
  void initState() {
    super.initState();
    _encoder.init();
    _identity.getClientUuid().then((uuid) {
      if (mounted) setState(() => _deviceId = uuid);
    });
    // v2 Hub の PONG が途絶えたら、ビーコン喪失と同じ経路で再探索に戻す。
    _sender.onHubUnresponsive = () => _onHubLost();
    // Hub からのリモート制御。送信ゲートの開閉は UdpSenderService 内で
    // 処理済みなので、ここでは UI 状態とキャプチャの停止だけを行う。
    _sender.onRemoteCommand = _onRemoteCommand;
    _startDiscovery();
    if (Platform.isIOS) {
      // iOS では実際の音が来るのは Picker でユーザーがブロードキャストを
      // 開始した後。ここでは UDS の listener だけ起動しておく。
      _startCapturePipeline();
      _broadcastingPoll = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _refreshBroadcastingState(),
      );
    }
  }

  Future<void> _startDiscovery() async {
    ref.read(clientStateProvider.notifier).setSearching();
    try {
      // UDP ビーコンと mDNS の両方で探索する(どちらで見つかっても同じ
      // _onHubFound へ。接続中の重複発見はガードで無視される)。
      await _discovery.start();
      _discoverySub = _discovery.stream.listen(_onHubFound);
      _hubLostSub = _discovery.hubLostStream.listen((_) => _onHubLost());
      await _mdnsBrowser.start();
      _mdnsSub = _mdnsBrowser.stream.listen(_onHubFound);
    } catch (e) {
      _showSnack('Hub 検索の開始に失敗しました: $e');
    }
  }

  Future<void> _onHubLost() async {
    _sender.disconnect();
    _connectingToHub = false;
    if (!mounted) return;

    final manual = _manualHub;
    if (manual != null) {
      // 手動接続モードでは探索に戻らず、同じ接続先へ再接続を試み続ける
      debugPrint('[ClientScreen] 手動接続先への再接続を試みます');
      ref
          .read(clientStateProvider.notifier)
          .setConnecting(manual.ip, manual.port, hubName: manual.name);
      _showSnack('Hub への接続が切れました。再接続しています...');
      _scheduleManualReconnect();
    } else {
      debugPrint('[ClientScreen] Hub のビーコンが途絶えたので再探索状態に戻ります');
      ref.read(clientStateProvider.notifier).setSearching();
      _showSnack('Hub への接続を見失いました。再探索しています...');
    }
  }

  void _scheduleManualReconnect() {
    _manualRetryTimer?.cancel();
    _manualRetryTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      final manual = _manualHub;
      if (!mounted || manual == null || _sender.isConnected) {
        timer.cancel();
        return;
      }
      _onHubFound(manual);
    });
  }

  /// 探索(ビーコン + mDNS)を停止する。手動接続に切り替えるとき用。
  Future<void> _stopDiscovery() async {
    await _discoverySub?.cancel();
    _discoverySub = null;
    await _mdnsSub?.cancel();
    _mdnsSub = null;
    await _hubLostSub?.cancel();
    _hubLostSub = null;
    _discovery.stop();
    await _mdnsBrowser.stop();
  }

  /// IP:ポート指定で Hub に接続する(ブロードキャスト不達環境 / VPN / WAN 用)。
  Future<void> _connectManually(String ip, int port) async {
    _manualRetryTimer?.cancel();
    await _stopDiscovery();
    _sender.disconnect();
    _connectingToHub = false;

    final hub = DiscoveredHub(ip: ip, port: port, name: '手動接続');
    setState(() => _manualHub = hub);
    await _manualStore.add(ip, port);
    await _onHubFound(hub);
    // 初回接続に失敗した場合もリトライループに乗せる
    if (!_sender.isConnected) {
      _scheduleManualReconnect();
    }
  }

  /// 手動接続をやめて自動探索に戻る。
  Future<void> _returnToAutoDiscovery() async {
    _manualRetryTimer?.cancel();
    setState(() => _manualHub = null);
    _sender.disconnect();
    _connectingToHub = false;
    await _startDiscovery();
  }

  Future<void> _onHubFound(DiscoveredHub hub) async {
    if (_connectingToHub || _sender.isConnected) return;
    _connectingToHub = true;

    final state = ref.read(clientStateProvider);
    if (state.status == ClientConnectionStatus.connected) {
      _connectingToHub = false;
      return;
    }

    ref
        .read(clientStateProvider.notifier)
        .setConnecting(hub.ip, hub.port, hubName: hub.name);

    try {
      final name = ref.read(deviceNameProvider);
      final uuid = await _identity.getClientUuid();
      await _sender.connect(hub.ip, hub.port, name, uuid);
      ref.read(clientStateProvider.notifier).setConnected(uuid);

      // iOS 以外は接続後に直ちにキャプチャ起動。
      // iOS は initState で起動済み(Extension からの PCM 待ち)。
      if (!Platform.isIOS) {
        await _startCapturePipeline();
      }
    } catch (e) {
      ref.read(clientStateProvider.notifier).setDisconnected();
      _showSnack('Hub への接続に失敗しました: $e');
    } finally {
      _connectingToHub = false;
    }
  }

  Future<void> _startCapturePipeline() async {
    // Android のみ MediaProjection の許可が必要(iOS は Picker、その他は不要)。
    if (Platform.isAndroid) {
      final granted = await _capture.requestPermission();
      if (!granted) {
        _showSnack('画面音声キャプチャの権限が拒否されました。設定から許可してください。');
        return;
      }
      // フォアグラウンドサービスをここで起動(Android のバックグラウンド維持用)
      try {
        await _broadcastChannel.invokeMethod('startBroadcast');
      } catch (e) {
        debugPrint('startBroadcast 失敗: $e');
      }
    }

    try {
      await _capture.start();
      setState(() => _captureError = null);
    } catch (e) {
      setState(() => _captureError = e.toString());
      return;
    }

    _captureSub = _capture.pcmStream.listen(
      (pcmBytes) {
        if (pcmBytes.length != kBytesPerChunk) return; // 念のため
        final level = computePcm16RmsLevel(pcmBytes);
        ref.read(clientStateProvider.notifier).updateVuLevel(level);
        final opus = _encoder.encode(pcmBytes);
        if (opus != null && _sender.isConnected) {
          _sender.sendAudio(opus);
          if (mounted) setState(() => _packetCount++);
        }
      },
      onError: (Object err, StackTrace st) {
        if (mounted) setState(() => _captureError = err.toString());
      },
    );
  }

  Future<void> _refreshBroadcastingState() async {
    if (!Platform.isIOS) return;
    final active = await _capture.isBroadcastingActive();
    if (mounted && active != _broadcastingActive) {
      setState(() => _broadcastingActive = active);
    }
  }

  void _onRemoteCommand(RemoteCommandAction action) {
    if (!mounted) return;
    final notifier = ref.read(clientStateProvider.notifier);
    switch (action) {
      case RemoteCommandAction.pause:
        notifier.setPausedByHub(true);
        _showSnack('Hub が配信を一時停止しました');
      case RemoteCommandAction.resume:
        notifier.setPausedByHub(false);
        _showSnack('Hub が配信を再開しました');
      case RemoteCommandAction.stop:
        notifier.setPausedByHub(true);
        // iOS は Broadcast Extension を App 側から止められない(Picker 制約)
        // ため送信ゲートの閉止のみ。他 OS はキャプチャ自体を停止する。
        if (!Platform.isIOS) {
          _stopCaptureOnly();
        }
        _showSnack('Hub が配信を停止しました');
    }
  }

  /// キャプチャだけを止める(Hub との接続・PING は維持)。
  Future<void> _stopCaptureOnly() async {
    if (Platform.isAndroid) {
      try {
        await _broadcastChannel.invokeMethod('stopBroadcast');
      } catch (_) {}
    }
    await _captureSub?.cancel();
    _captureSub = null;
    await _capture.stop();
  }

  /// Hub による一時停止/停止からローカル操作で配信を再開する(後勝ち)。
  Future<void> _resumeFromHubPause() async {
    _sender.setPaused(false);
    ref.read(clientStateProvider.notifier).setPausedByHub(false);
    // STOP でキャプチャごと止まっている場合は取り直す(iOS は Extension が
    // 生きていればゲート開放だけで音が流れ始める)
    if (!Platform.isIOS && _captureSub == null) {
      await _startCapturePipeline();
    }
  }

  Future<void> _stop() async {
    if (Platform.isAndroid) {
      try {
        await _broadcastChannel.invokeMethod('stopBroadcast');
      } catch (_) {}
    }
    await _captureSub?.cancel();
    _captureSub = null;
    await _capture.stop();
    _sender.disconnect();
    _connectingToHub = false;
    ref.read(clientStateProvider.notifier).setDisconnected();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 手動接続ダイアログ(IP:ポート入力 + 接続履歴)。
  Future<void> _showManualConnectDialog() async {
    final history = await _manualStore.loadHistory();
    if (!mounted) return;

    final ipController = TextEditingController(text: _manualHub?.ip ?? '');
    final portController =
        TextEditingController(text: '${_manualHub?.port ?? kAudioPort}');

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Hub へ手動接続'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'ブロードキャストが届かないネットワーク(別セグメントや VPN 経由)では、'
                'Hub 画面に表示される IP:ポート を直接入力してください。',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ipController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Hub の IP アドレス',
                  hintText: '例: 192.168.1.10',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: portController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'ポート',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              if (history.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('最近の接続先',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                ...history.map(
                  (entry) => ListTile(
                    dense: true,
                    leading: const Icon(Icons.history, size: 18),
                    title: Text(entry, style: const TextStyle(fontSize: 13)),
                    onTap: () {
                      final parsed = ManualHubStore.parse(entry);
                      if (parsed == null) return;
                      Navigator.of(dialogContext).pop();
                      _connectManually(parsed.ip, parsed.port);
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (_manualHub != null)
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                _returnToAutoDiscovery();
              },
              child: const Text('自動探索に戻る'),
            ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () {
              final ip = ipController.text.trim();
              final port = int.tryParse(portController.text.trim());
              if (ip.isEmpty || port == null || port < 1 || port > 65535) {
                _showSnack('IP アドレスとポートを確認してください');
                return;
              }
              Navigator.of(dialogContext).pop();
              _connectManually(ip, port);
            },
            child: const Text('接続'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _broadcastingPoll?.cancel();
    _broadcastingPoll = null;
    _manualRetryTimer?.cancel();
    _manualRetryTimer = null;
    _stop();
    _discoverySub?.cancel();
    _mdnsSub?.cancel();
    _hubLostSub?.cancel();
    _discovery.dispose();
    _mdnsBrowser.dispose();
    _encoder.dispose();
    _capture.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(clientStateProvider);
    final name = ref.watch(deviceNameProvider);
    final isConnected = state.status == ClientConnectionStatus.connected;

    return Scaffold(
      appBar: AppBar(
        title: Text('クライアント — $name'),
        actions: [
          IconButton(
            icon: Icon(
              Icons.settings_ethernet,
              color: _manualHub != null ? Colors.orange : null,
            ),
            tooltip: 'Hub へ手動接続(IP 指定)',
            onPressed: _showManualConnectDialog,
          ),
          IconButton(
            icon: const Icon(Icons.swap_horiz),
            tooltip: '役割を切り替え',
            onPressed: () async {
              await _stop();
              await ref.read(appModeProvider.notifier).reset();
            },
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              VuMeter(level: state.vuLevel, width: 48, height: 140),
              const SizedBox(height: 24),
              ConnectionStatusBadge(status: state.status),
              if (state.isPausedByHub) ...[
                const SizedBox(height: 12),
                _PausedByHubBanner(onResume: _resumeFromHubPause),
              ],
              const SizedBox(height: 8),
              if (state.hubIp != null)
                Text(
                  state.hubName == null
                      ? 'Hub: ${state.hubIp}'
                      : 'Hub: ${state.hubName}(${state.hubIp})',
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
              if (_deviceId != null)
                Text(
                  'このデバイスの ID: ${_deviceId!.substring(0, 8)}',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                ),
              const SizedBox(height: 24),
              _BroadcastSection(
                isIOS: Platform.isIOS,
                isConnected: isConnected,
                broadcastingActive: _broadcastingActive,
                packetCount: _packetCount,
                captureError: _captureError,
                preferredExtensionId: _broadcastExtensionBundleId,
                manualTarget: _manualHub == null
                    ? null
                    : '${_manualHub!.ip}:${_manualHub!.port}',
                onStop: _stop,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Hub のリモート操作で配信が止められているときのバナー。
class _PausedByHubBanner extends StatelessWidget {
  final VoidCallback onResume;

  const _PausedByHubBanner({required this.onResume});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.orange.shade300),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.pause_circle, color: Colors.orange, size: 20),
              SizedBox(width: 8),
              Text(
                'Hub により配信が一時停止されています',
                style: TextStyle(fontSize: 13, color: Colors.deepOrange),
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextButton.icon(
            icon: const Icon(Icons.play_arrow, size: 18),
            label: const Text('このデバイスから配信を再開'),
            onPressed: onResume,
          ),
        ],
      ),
    );
  }
}

class _BroadcastSection extends StatelessWidget {
  final bool isIOS;
  final bool isConnected;
  final bool broadcastingActive;
  final int packetCount;
  final String? captureError;
  final String preferredExtensionId;

  /// 手動接続中の接続先(`ip:port`)。null なら自動探索モード。
  final String? manualTarget;
  final VoidCallback onStop;

  const _BroadcastSection({
    required this.isIOS,
    required this.isConnected,
    required this.broadcastingActive,
    required this.packetCount,
    required this.captureError,
    required this.preferredExtensionId,
    required this.manualTarget,
    required this.onStop,
  });

  String get _searchingLabel => manualTarget == null
      ? 'ローカルネットワーク内の Hub を探しています...'
      : '$manualTarget へ接続を試みています...';

  @override
  Widget build(BuildContext context) {
    if (isIOS) {
      return Column(
        children: [
          if (!isConnected)
            Text(
              _searchingLabel,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            )
          else
            Text(
              broadcastingActive
                  ? 'ブロードキャスト中  パケット: $packetCount'
                  : 'Hub に接続済み。下のボタンからブロードキャストを開始してください。',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: broadcastingActive ? Colors.green : Colors.orange,
              ),
            ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cell_tower, size: 28, color: Colors.blueAccent),
              const SizedBox(width: 12),
              BroadcastPickerButton(
                preferredExtensionBundleId: preferredExtensionId,
                size: 60,
              ),
              const SizedBox(width: 12),
              const Text(
                'タップして配信開始',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
            ],
          ),
          if (captureError != null) ...[
            const SizedBox(height: 12),
            Text(
              'エラー: $captureError',
              style: const TextStyle(fontSize: 12, color: Colors.red),
              textAlign: TextAlign.center,
            ),
          ],
          if (isConnected) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.stop_circle),
              label: const Text('Hub から切断'),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: onStop,
            ),
          ],
        ],
      );
    }

    // 非 iOS(Android / macOS / Windows)
    return Column(
      children: [
        if (!isConnected)
          Text(
            _searchingLabel,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey),
          )
        else
          Text(
            'ブロードキャスト中  パケット: $packetCount',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.green),
          ),
        if (captureError != null) ...[
          const SizedBox(height: 8),
          Text(
            'エラー: $captureError',
            style: const TextStyle(fontSize: 12, color: Colors.red),
            textAlign: TextAlign.center,
          ),
        ],
        if (isConnected) ...[
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.stop_circle),
            label: const Text('Hub から切断'),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: onStop,
          ),
        ],
      ],
    );
  }
}
