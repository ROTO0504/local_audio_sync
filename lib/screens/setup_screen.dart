import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/app_mode.dart';
import '../providers/app_mode_provider.dart';

class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _nameController = TextEditingController(text: 'マイデバイス');
  bool _loading = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _select(AppMode mode) async {
    setState(() => _loading = true);
    await ref.read(deviceNameProvider.notifier).setName(_nameController.text.trim());
    await ref.read(appModeProvider.notifier).setMode(mode);
    if (!mounted) return;
    context.go(mode == AppMode.hub ? '/hub' : '/client');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.multitrack_audio, size: 72, color: Colors.blueAccent),
              const SizedBox(height: 24),
              const Text(
                'Local Audio Sync',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'ローカルネットワーク内で内部音声を集約・共有',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 40),

              // デバイス名フィールド
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'デバイス名',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.devices),
                ),
              ),
              const SizedBox(height: 32),

              const Text(
                '役割を選択してください',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),

              // Hub
              _RoleCard(
                icon: Icons.hub,
                title: 'Hub(集約・再生)',
                subtitle: '全クライアントの音声を受信してミックス再生\n(Windows 推奨)',
                color: Colors.deepPurple,
                onTap: _loading ? null : () => _select(AppMode.hub),
              ),
              const SizedBox(height: 12),

              // Client
              _RoleCard(
                icon: Icons.cell_tower,
                title: 'クライアント(送信)',
                subtitle: 'このデバイスで再生中の音声を Hub へ配信\n(iPhone / iPad / Mac / Windows / Android)',
                color: Colors.teal,
                onTap: _loading ? null : () => _select(AppMode.client),
              ),

              if (_loading) ...[
                const SizedBox(height: 24),
                const Center(child: CircularProgressIndicator()),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback? onTap;

  const _RoleCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: color.withValues(alpha: 0.15),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: color)),
                    const SizedBox(height: 4),
                    Text(subtitle,
                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.grey.shade400),
            ],
          ),
        ),
      ),
    );
  }
}
