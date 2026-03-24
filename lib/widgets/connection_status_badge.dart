import 'package:flutter/material.dart';
import '../providers/client_state_provider.dart';

class ConnectionStatusBadge extends StatelessWidget {
  final ClientConnectionStatus status;

  const ConnectionStatusBadge({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      ClientConnectionStatus.searching => ('Searching...', Colors.orange),
      ClientConnectionStatus.connecting => ('Connecting...', Colors.blue),
      ClientConnectionStatus.connected => ('Connected', Colors.green),
      ClientConnectionStatus.disconnected => ('Disconnected', Colors.red),
    };
    return Chip(
      avatar: CircleAvatar(
        backgroundColor: color,
        radius: 6,
      ),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      backgroundColor: color.withValues(alpha: 0.15),
      padding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }
}
