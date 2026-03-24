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
import '../services/udp_sender_service.dart';
import '../widgets/connection_status_badge.dart';
import '../widgets/vu_meter.dart';

const _broadcastChannel = MethodChannel('com.example.local_audio_sync/broadcast');

class ClientScreen extends ConsumerStatefulWidget {
  const ClientScreen({super.key});

  @override
  ConsumerState<ClientScreen> createState() => _ClientScreenState();
}

class _ClientScreenState extends ConsumerState<ClientScreen> {
  final ClientDiscoveryListener _discovery = ClientDiscoveryListener();
  final AudioCaptureService _capture = AudioCaptureService();
  final OpusEncoderService _encoder = OpusEncoderService();
  final UdpSenderService _sender = UdpSenderService();
  final _uuid = const Uuid().v4();

  StreamSubscription? _discoverySub;
  StreamSubscription? _captureSub;
  bool _connectingToHub = false;

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
      // Update VU level
      final level = AudioCaptureService.computeRmsLevel(pcmBytes);
      ref.read(clientStateProvider.notifier).updateVuLevel(level);

      // Encode and send
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(clientStateProvider);
    final name = ref.watch(deviceNameProvider);
    final isConnected = state.status == ClientConnectionStatus.connected;

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
