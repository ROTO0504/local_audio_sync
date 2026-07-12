import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';

/// Hub のリモート操作で配信が止められているときのバナー。
class PausedByHubBanner extends StatelessWidget {
  final VoidCallback onResume;

  const PausedByHubBanner({super.key, required this.onResume});

  @override
  Widget build(BuildContext context) {
    final paused = context.statusColors.paused;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.m,
        vertical: AppSpacing.s,
      ),
      decoration: BoxDecoration(
        color: paused.withValues(alpha: 0.12),
        borderRadius: AppRadius.allM,
        border: Border.all(color: paused.withValues(alpha: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.pause_circle, color: paused, size: 20),
              AppSpacing.gapS,
              Text(
                'Hub により配信が一時停止されています',
                style: TextStyle(fontSize: 13, color: paused),
              ),
            ],
          ),
          AppSpacing.gapXs,
          TextButton.icon(
            icon: const Icon(Icons.play_arrow, size: 18),
            label: const Text('このデバイスから配信を再開'),
            onPressed: onResume,
          ),
        ],
      ),
    );
  }
}
