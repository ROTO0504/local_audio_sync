import 'package:flutter/material.dart';
import '../providers/client_state_provider.dart';

class ConnectionStatusBadge extends StatelessWidget {
  final ClientConnectionStatus status;

  const ConnectionStatusBadge({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      ClientConnectionStatus.searching => ('検索中...', Colors.orange),
      ClientConnectionStatus.connecting => ('接続中...', Colors.blue),
      ClientConnectionStatus.connected => ('接続済み', Colors.green),
      ClientConnectionStatus.disconnected => ('切断', Colors.red),
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
