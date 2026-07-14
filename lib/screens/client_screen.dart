import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_mode_provider.dart';
import '../providers/client_controller_provider.dart';
import '../providers/client_state_provider.dart';
import '../theme/app_spacing.dart';
import '../widgets/client/action_banner.dart';
import '../widgets/client/broadcast_section.dart';
import '../widgets/client/connection_card.dart';
import '../widgets/client/hub_picker.dart';
import '../widgets/client/paused_by_hub_banner.dart';
import 'client_settings_screen.dart';

/// Broadcast Upload Extension のバンドル ID。
/// Xcode でターゲットを作成するとき同じ値を Bundle Identifier に設定すること。
/// docs/ios/README.md 参照。
const _broadcastExtensionBundleId =
    'com.roto0504.localAudioSync.BroadcastExtension';

/// クライアント画面。接続ロジックは [ClientController] に委譲し、この画面は
/// provider の購読と一過性メッセージ(旧 SnackBar)の表示に徹する。
class ClientScreen extends ConsumerStatefulWidget {
  const ClientScreen({super.key});

  @override
  ConsumerState<ClientScreen> createState() => _ClientScreenState();
}

class _ClientScreenState extends ConsumerState<ClientScreen> {
  StreamSubscription<String>? _messageSub;

  @override
  void initState() {
    super.initState();
    final controller = ref.read(clientControllerProvider);
    // 一過性メッセージは SnackBar で表示する(恒常状態はカードが担う)。
    _messageSub = controller.messages.listen(_showSnack);
    // フレーム後に起動(初回 build 前に provider を書き換えないため)。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.start();
    });
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    super.dispose();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(clientStateProvider);
    final name = ref.watch(deviceNameProvider);
    final controller = ref.read(clientControllerProvider);
    final isConnected = state.status == ClientConnectionStatus.connected;

    return Scaffold(
      appBar: AppBar(
        title: Text('クライアント — $name'),
        actions: [
          IconButton(
            icon: const Icon(Icons.list),
            tooltip: 'Hub を選ぶ',
            onPressed: () => HubPicker.show(context),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: '設定',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ClientSettingsScreen(),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: AppSpacing.screenPadding,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ConnectionCard(state: state),
                  if (state.isPausedByHub) ...[
                    AppSpacing.gapM,
                    PausedByHubBanner(onResume: controller.resumeFromHubPause),
                  ],
                  if (state.status == ClientConnectionStatus.disconnected) ...[
                    AppSpacing.gapM,
                    ActionBanner(
                      onRetry: () {
                        final manual = controller.manualHub;
                        if (manual != null) {
                          controller.connectManually(manual.ip, manual.port);
                        } else {
                          controller.returnToAutoDiscovery();
                        }
                      },
                      onOpenPicker: () => HubPicker.show(context),
                      onReturnToAuto: state.isManualMode
                          ? controller.returnToAutoDiscovery
                          : null,
                    ),
                  ],
                  AppSpacing.gapL,
                  BroadcastSection(
                    isIOS: Platform.isIOS,
                    isConnected: isConnected,
                    broadcastingActive: state.broadcastingActive,
                    packetCount: state.packetCount,
                    captureError: state.captureError,
                    preferredExtensionId: _broadcastExtensionBundleId,
                    manualTarget: controller.manualHub == null
                        ? null
                        : '${controller.manualHub!.ip}:${controller.manualHub!.port}',
                    onStop: controller.disconnect,
                    diagnostics: state.broadcastDiagnostics,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
