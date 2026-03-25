import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../providers/app_mode_provider.dart';
import '../providers/client_state_provider.dart';
import '../services/audio_capture_service.dart';
import '../services/discovery_service.dart';
import '../services/opus_encoder_service.dart';
import '../services/screen_audio_capture_service.dart';
import '../services/udp_sender_service.dart';
import '../widgets/connection_status_badge.dart';
import '../widgets/vu_meter.dart';

const _broadcastChannel = MethodChannel('com.example.local_audio_sync/broadcast');

enum _AudioSource { microphone, screenAudio }

class ClientScreen extends ConsumerStatefulWidget {
  const ClientScreen({super.key});

  @override
  ConsumerState<ClientScreen> createState() => _ClientScreenState();
}

class _ClientScreenState extends ConsumerState<ClientScreen> {
  final ClientDiscoveryListener _discovery = ClientDiscoveryListener();
  final AudioCaptureService _capture = AudioCaptureService();
  final ScreenAudioCaptureService _screenCapture = ScreenAudioCaptureService();
  final OpusEncoderService _encoder = OpusEncoderService();
  final UdpSenderService _sender = UdpSenderService();
  final _uuid = const Uuid().v4();

  StreamSubscription? _discoverySub;
  StreamSubscription? _captureSub;
  bool _connectingToHub = false;
  _AudioSource _audioSource = _AudioSource.microphone;

  @override
  void initState() {
    super.initState();
    _encoder.init();
    _startDiscovery();
  }

  Future<void> _startDiscovery() async {
    ref.read(clientStateProvider.notifier).setSearching();
    await _discovery.start();
    _discoverySub = _discovery.stream.listen(_onHubFound);
  }

  Future<void> _onHubFound(DiscoveredHub hub) async {
    if (_connectingToHub || _sender.isConnected) return;
    _connectingToHub = true;

    final state = ref.read(clientStateProvider);
    if (state.status == ClientConnectionStatus.connected) return;

    ref.read(clientStateProvider.notifier).setConnecting(hub.ip, hub.port);

    try {
      final name = ref.read(deviceNameProvider);
      await _sender.connect(hub.ip, hub.port, name, _uuid);
      ref.read(clientStateProvider.notifier).setConnected(_uuid);
      await _startBroadcast();
    } catch (e) {
      ref.read(clientStateProvider.notifier).setDisconnected();
      _connectingToHub = false;
    }
  }

  Future<void> _startBroadcast() async {
    if (_audioSource == _AudioSource.screenAudio &&
        (Platform.isAndroid || Platform.isIOS)) {
      await _startScreenAudioBroadcast();
    } else {
      await _startMicBroadcast();
    }
  }

  Future<void> _startMicBroadcast() async {
    final hasPermission = await _capture.requestPermission();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission denied')),
        );
      }
      return;
    }

    if (Platform.isAndroid) {
      await _broadcastChannel.invokeMethod('startBroadcast');
    }

    await _capture.start();
    _captureSub = _capture.pcmStream.listen((pcmBytes) {
      final level = AudioCaptureService.computeRmsLevel(pcmBytes);
      ref.read(clientStateProvider.notifier).updateVuLevel(level);
      final opus = _encoder.encode(pcmBytes);
      if (opus != null) _sender.sendAudio(opus);
    });
  }

  Future<void> _startScreenAudioBroadcast() async {
    // Android needs an explicit MediaProjection permission dialog first.
    if (Platform.isAndroid) {
      final granted = await _screenCapture.requestPermission();
      if (!granted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Screen audio permission denied')),
          );
        }
        _connectingToHub = false;
        ref.read(clientStateProvider.notifier).setDisconnected();
        return;
      }
    }

    await _screenCapture.start();
    _captureSub = _screenCapture.pcmStream.listen((pcmBytes) {
      final level = AudioCaptureService.computeRmsLevel(pcmBytes);
      ref.read(clientStateProvider.notifier).updateVuLevel(level);
      final opus = _encoder.encode(pcmBytes);
      if (opus != null) _sender.sendAudio(opus);
    });
  }

  Future<void> _stop() async {
    if (Platform.isAndroid) {
      await _broadcastChannel.invokeMethod('stopBroadcast');
    }
    await _captureSub?.cancel();
    _captureSub = null;
    await _capture.stop();
    await _screenCapture.stop();
    _sender.disconnect();
    _connectingToHub = false;
    ref.read(clientStateProvider.notifier).setDisconnected();
  }

  @override
  void dispose() {
    _stop();
    _discoverySub?.cancel();
    _discovery.stop();
    _encoder.dispose();
    _capture.dispose();
    _screenCapture.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(clientStateProvider);
    final name = ref.watch(deviceNameProvider);
    final isConnected = state.status == ClientConnectionStatus.connected;
    final canSwitchSource = !isConnected && (Platform.isAndroid || Platform.isIOS);

    return Scaffold(
      appBar: AppBar(
        title: Text('Client — $name'),
        actions: [
          IconButton(
            icon: const Icon(Icons.swap_horiz),
            tooltip: 'Switch role',
            onPressed: () async {
              await _stop();
              await ref.read(appModeProvider.notifier).reset();
            },
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Audio source toggle (iOS / Android only, disabled while connected)
              if (Platform.isAndroid || Platform.isIOS) ...[
                SegmentedButton<_AudioSource>(
                  segments: const [
                    ButtonSegment(
                      value: _AudioSource.microphone,
                      icon: Icon(Icons.mic),
                      label: Text('マイク'),
                    ),
                    ButtonSegment(
                      value: _AudioSource.screenAudio,
                      icon: Icon(Icons.screen_share),
                      label: Text('画面の音'),
                    ),
                  ],
                  selected: {_audioSource},
                  onSelectionChanged: canSwitchSource
                      ? (set) => setState(() => _audioSource = set.first)
                      : null,
                ),
                const SizedBox(height: 24),
              ],

              // VU Meter
              AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                child: VuMeter(
                  level: state.vuLevel,
                  width: 40,
                  height: 120,
                ),
              ),
              const SizedBox(height: 24),

              // Status badge
              ConnectionStatusBadge(status: state.status),
              const SizedBox(height: 12),

              if (state.hubIp != null)
                Text(
                  'Hub: ${state.hubIp}',
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
              const SizedBox(height: 32),

              // Start / Stop button
              if (isConnected)
                FilledButton.icon(
                  icon: const Icon(Icons.stop_circle),
                  label: const Text('Stop Broadcasting'),
                  style: FilledButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: _stop,
                )
              else
                const Text(
                  'Searching for Hub on the local network...',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
