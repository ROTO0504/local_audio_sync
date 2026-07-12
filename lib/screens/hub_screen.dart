import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/control_messages.dart';
import '../providers/app_mode_provider.dart';
import '../providers/hub_state_provider.dart';
import '../services/hub_controller.dart';
import 'hub/hub_desktop_view.dart';
import 'hub/hub_mobile_view.dart';
import 'hub_settings_screen.dart';

/// Hub(集約・再生側)の画面。
///
/// コアロジックは [HubController] に集約されており、ここでは start / stop の
/// 呼び出しと、幅に応じたレイアウト(デスクトップ / モバイル)の出し分けだけを
/// 行う。実際のクライアント一覧・ダッシュボード・一括操作は各 View に委譲する。
class HubScreen extends ConsumerStatefulWidget {
  const HubScreen({super.key});

  /// この幅以上をデスクトップ(マルチペイン)とみなす閾値。
  static const double desktopBreakpoint = 900;

  @override
  ConsumerState<HubScreen> createState() => _HubScreenState();
}

class _HubScreenState extends ConsumerState<HubScreen> {
  late final HubController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(hubControllerProvider);
    _controller.onCommandDeliveryFailed = _onCommandDeliveryFailed;
    _controller.start(ref.read(deviceNameProvider));
  }

  @override
  void dispose() {
    _controller.onCommandDeliveryFailed = null;
    _controller.stop();
    super.dispose();
  }

  void _onCommandDeliveryFailed(String uuid, RemoteCommandAction action) {
    if (!mounted) return;
    final client = ref.read(hubStateProvider)[uuid];
    final name = client?.name ?? uuid;
    final label = switch (action) {
      RemoteCommandAction.pause => '一時停止',
      RemoteCommandAction.resume => '再開',
      RemoteCommandAction.stop => '停止',
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$name への$label指示が届きませんでした')),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const HubSettingsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = ref.watch(deviceNameProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text('Hub — $name'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: '設定',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isDesktop =
              constraints.maxWidth >= HubScreen.desktopBreakpoint;
          return isDesktop
              ? const HubDesktopView()
              : const HubMobileView();
        },
      ),
    );
  }
}
