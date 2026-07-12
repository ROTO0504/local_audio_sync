import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class VuMeter extends StatelessWidget {
  final double level; // 0.0 - 1.0
  final double width;
  final double height;

  const VuMeter({
    super.key,
    required this.level,
    this.width = 8,
    this.height = 40,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.statusColors;
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: _VuPainter(
          level: level.clamp(0.0, 1.0),
          track: colors.vuTrack,
          low: colors.vuLow,
          mid: colors.vuMid,
          high: colors.vuHigh,
        ),
      ),
    );
  }
}

class _VuPainter extends CustomPainter {
  final double level;
  final Color track;
  final Color low;
  final Color mid;
  final Color high;

  _VuPainter({
    required this.level,
    required this.track,
    required this.low,
    required this.mid,
    required this.high,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Background track
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = track,
    );
    // Filled bar (bottom to top)
    final filledHeight = size.height * level;
    final color = level > 0.85
        ? high
        : level > 0.6
            ? mid
            : low;
    canvas.drawRect(
      Rect.fromLTWH(0, size.height - filledHeight, size.width, filledHeight),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_VuPainter old) =>
      old.level != level ||
      old.track != track ||
      old.low != low ||
      old.mid != mid ||
      old.high != high;
}
