import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/client_info.dart';
import '../providers/hub_state_provider.dart';
import 'vu_meter.dart';

class ClientTile extends ConsumerWidget {
  final ClientInfo client;

  const ClientTile({super.key, required this.client});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hub = ref.read(hubStateProvider.notifier);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            // Activity indicator
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: client.isActive ? Colors.green : Colors.grey,
              ),
            ),
            const SizedBox(width: 10),

            // Client name + IP
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    client.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    client.ip,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),

            // VU meter
            VuMeter(
              level: client.lastPcmChunk != null ? 0.5 : 0.0,
              height: 32,
            ),
            const SizedBox(width: 12),

            // Volume slider
            SizedBox(
              width: 100,
              child: Slider(
                value: client.isMuted ? 0 : client.volume,
                min: 0,
                max: 1,
                onChanged: client.isMuted
                    ? null
                    : (v) => hub.setVolume(client.id, v),
              ),
            ),

            // Volume % label
            SizedBox(
              width: 48,
              child: Text(
                client.isMuted ? 'ミュート' : '${(client.volume * 100).round()}%',
                style: TextStyle(
                  fontSize: 11,
                  color: client.isMuted ? Colors.red : Colors.black87,
                ),
                textAlign: TextAlign.center,
              ),
            ),

            // Mute button
            IconButton(
              icon: Icon(
                client.isMuted ? Icons.volume_off : Icons.volume_up,
                size: 20,
                color: client.isMuted ? Colors.red : Colors.black54,
              ),
              onPressed: () =>
                  hub.setMuted(client.id, muted: !client.isMuted),
            ),
          ],
        ),
      ),
    );
  }
}
