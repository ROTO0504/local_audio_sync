import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../providers/app_mode_provider.dart';
import '../providers/client_state_provider.dart';
import '../services/discovery_service.dart';
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
  final ScreenAudioCaptureService _capture = ScreenAudioCaptureService();
  final OpusEncoderService _encoder = OpusEncoderService();
  final UdpSenderService _sender = UdpSenderService();
  final _uuid = const Uuid().v4();

  StreamSubscription? _discoverySub;
  StreamSubscription? _hubLostSub;
  StreamSubscription? _captureSub;
  Timer? _broadcastingPoll;

  bool _connectingToHub = false;
  int _packetCount = 0;
  String? _captureError;
  bool _broadcastingActive = false;

  @override
  void initState() {
    super.initState();
    _encoder.init();
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
      await _discovery.start();
      _discoverySub = _discovery.stream.listen(_onHubFound);
      _hubLostSub = _discovery.hubLostStream.listen((_) => _onHubLost());
    } catch (e) {
      _showSnack('Hub 検索の開始に失敗しました: $e');
    }
  }

  Future<void> _onHubLost() async {
    debugPrint('[ClientScreen] Hub のビーコンが途絶えたので再探索状態に戻ります');
    _sender.disconnect();
    _connectingToHub = false;
    if (mounted) {
      ref.read(clientStateProvider.notifier).setSearching();
      _showSnack('Hub への接続を見失いました。再探索しています...');
    }
  }

  Future<void> _onHubFound(DiscoveredHub hub) async {
    if (_connectingToHub || _sender.isConnected) return;
    _connectingToHub = true;

    final state = ref.read(clientStateProvider);
    if (state.status == ClientConnectionStatus.connected) {
      _connectingToHub = false;
      return;
    }

    ref.read(clientStateProvider.notifier).setConnecting(hub.ip, hub.port);

    try {
      final name = ref.read(deviceNameProvider);
      await _sender.connect(hub.ip, hub.port, name, _uuid);
      ref.read(clientStateProvider.notifier).setConnected(_uuid);

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

  @override
  void dispose() {
    _broadcastingPoll?.cancel();
    _broadcastingPoll = null;
    _stop();
    _discoverySub?.cancel();
    _hubLostSub?.cancel();
    _discovery.dispose();
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
              const SizedBox(height: 8),
              if (state.hubIp != null)
                Text(
                  'Hub: ${state.hubIp}',
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
              const SizedBox(height: 24),
              _BroadcastSection(
                isIOS: Platform.isIOS,
                isConnected: isConnected,
                broadcastingActive: _broadcastingActive,
                packetCount: _packetCount,
                captureError: _captureError,
                preferredExtensionId: _broadcastExtensionBundleId,
                onStop: _stop,
              ),
            ],
          ),
        ),
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
  final VoidCallback onStop;

  const _BroadcastSection({
    required this.isIOS,
    required this.isConnected,
    required this.broadcastingActive,
    required this.packetCount,
    required this.captureError,
    required this.preferredExtensionId,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    if (isIOS) {
      return Column(
        children: [
          if (!isConnected)
            const Text(
              'ローカルネットワーク内の Hub を探しています...',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
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
          const Text(
            'ローカルネットワーク内の Hub を探しています...',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
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
