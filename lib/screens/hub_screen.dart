import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/client_info.dart';
import '../providers/app_mode_provider.dart';
import '../providers/hub_state_provider.dart';
import '../services/audio_mixer_service.dart';
import '../services/discovery_service.dart';
import '../services/udp_receiver_service.dart';
import '../widgets/client_tile.dart';

class HubScreen extends ConsumerStatefulWidget {
  const HubScreen({super.key});

  @override
  ConsumerState<HubScreen> createState() => _HubScreenState();
}

class _HubScreenState extends ConsumerState<HubScreen> {
  final HubBeaconSender _beacon = HubBeaconSender();
  final UdpReceiverService _receiver = UdpReceiverService();
  final AudioMixerService _mixer = AudioMixerService();
  final Map<String, int> _uuidToClientId = {};
  int _nextClientId = 1;
  Timer? _staleTimer;

  @override
  void initState() {
    super.initState();
    AudioMixerService.initFfi();
    _startHub();
  }

  Future<void> _startHub() async {
    final name = ref.read(deviceNameProvider);

    // Wire up receiver callbacks
    _receiver.onClientHello = (name, uuid, ip, port) {
      final existing = _uuidToClientId[uuid];
      final id = existing ?? _nextClientId++;
      _uuidToClientId[uuid] = id;
      _receiver.sendAckHello(ip, port, id);

      final client = ClientInfo(
        id: uuid,
        name: name,
        ip: ip,
        port: port,
        lastSeen: DateTime.now(),
      );
      ref.read(hubStateProvider.notifier).addOrUpdateClient(client);

      // If the client is reconnecting (same UUID, no BYE was sent), remove stale
      // mixer state first so addClient starts with a clean decoder/jitter buffer.
      if (existing != null) {
        _mixer.removeClient(id);
      }
      // JitterBuffer が seq 断絶を検出したら送信側に RESYNC を返す。
      // 現在登録されている ip/port は Provider から読む(クライアントが port を
      // 切り替えても追従できるよう、コールバック発火時の値を使う)。
      _mixer.addClient(
        id,
        onResync: () {
          final current = ref.read(hubStateProvider)[uuid];
          if (current != null) {
            _receiver.sendResync(current.ip, current.port, id);
          }
        },
      );
    };

    _receiver.onClientPing = (clientId) {
      final uuid = _uuidToClientId.entries
          .where((e) => e.value == clientId)
          .map((e) => e.key)
          .firstOrNull;
      if (uuid != null) {
        ref.read(hubStateProvider.notifier).updateLastSeen(uuid);
      }
    };

    _receiver.onClientBye = (clientId) {
      final uuid = _uuidToClientId.entries
          .where((e) => e.value == clientId)
          .map((e) => e.key)
          .firstOrNull;
      if (uuid != null) {
        ref.read(hubStateProvider.notifier).removeClient(uuid);
        _uuidToClientId.remove(uuid);
        _mixer.removeClient(clientId);
      }
    };

    _receiver.onAudioPacket = (packet, ip) {
      // Apply per-client volume from provider state
      final uuid = _uuidToClientId.entries
          .where((e) => e.value == packet.clientId)
          .map((e) => e.key)
          .firstOrNull;
      double volume = 1.0;
      if (uuid != null) {
        final client = ref.read(hubStateProvider)[uuid];
        if (client != null) {
          volume = client.isMuted ? 0.0 : client.volume;
        }
      }
      _mixer.setVolume(packet.clientId, volume);
      _mixer.pushEncodedPacket(packet.clientId, packet.sequence, packet.opusBytes);
    };

    await _receiver.start();
    await _beacon.start(name);

    // Mark stale clients every 10s and release their mixer resources.
    _staleTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted) return; // widget may have been disposed between ticks
      final clients = ref.read(hubStateProvider);
      final now = DateTime.now();
      for (final entry in clients.entries) {
        if (now.difference(entry.value.lastSeen).inSeconds > 10) {
          ref.read(hubStateProvider.notifier).markInactive(entry.key);
          // Also clean up the native mixer slot so the audio callback stops
          // iterating over the dead client's ring buffer and native Opus
          // decoder resources are freed promptly.
          final clientId = _uuidToClientId[entry.key];
          if (clientId != null) {
            _mixer.removeClient(clientId);
            // Keep the UUID mapping so that a reconnecting client reuses the
            // same numeric ID; addClient will reinitialise its state cleanly.
          }
        }
      }
    });
  }

  @override
  void dispose() {
    // Null out callbacks first so any in-flight UDP events cannot touch
    // the already-disposed Riverpod state or mixer after this point.
    _receiver.onClientHello = null;
    _receiver.onClientPing = null;
    _receiver.onClientBye = null;
    _receiver.onAudioPacket = null;

    _staleTimer?.cancel();
    _beacon.stop();
    _receiver.stop();
    _mixer.removeAllClients(); // release all native Opus decoders
    AudioMixerService.destroyFfi();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clients = ref.watch(hubStateProvider);
    final name = ref.watch(deviceNameProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text('Hub — $name'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: '設定',
            onPressed: _showSettings,
          ),
        ],
      ),
      body: clients.isEmpty
          ? const _EmptyState()
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    '${clients.length} 台のクライアントが接続中',
                    style: const TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ),
                ...clients.values.map((c) => ClientTile(client: c)),
              ],
            ),
    );
  }

  void _showSettings() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Hub 設定'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.volume_up),
              title: const Text('すべての音量を 100% にする'),
              onTap: () {
                ref.read(hubStateProvider.notifier).setMasterVolumeAll(1.0);
                Navigator.of(context).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.volume_mute),
              title: const Text('すべてミュート'),
              onTap: () {
                final clients = ref.read(hubStateProvider);
                for (final id in clients.keys) {
                  ref.read(hubStateProvider.notifier).setMuted(id, muted: true);
                }
                Navigator.of(context).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.swap_horiz),
              title: const Text('クライアントモードへ切替'),
              onTap: () async {
                Navigator.of(context).pop();
                await ref.read(appModeProvider.notifier).reset();
                if (mounted) context.mounted;
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.wifi_find, size: 64, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          Text(
            'クライアントを待っています...',
            style: TextStyle(fontSize: 18, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 8),
          Text(
            '他のデバイスでアプリを起動し、「クライアント」を選択してください',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
