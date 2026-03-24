import 'package:flutter/material.dart';

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
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: _VuPainter(level: level.clamp(0.0, 1.0)),
      ),
    );
  }
}

class _VuPainter extends CustomPainter {
  final double level;
  _VuPainter({required this.level});

  @override
  void paint(Canvas canvas, Size size) {
    // Background
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = Colors.grey.shade800,
    );
    // Filled bar (bottom to top)
    final filledHeight = size.height * level;
    final color = level > 0.85
        ? Colors.red
        : level > 0.6
            ? Colors.orange
            : Colors.greenAccent;
    canvas.drawRect(
      Rect.fromLTWH(0, size.height - filledHeight, size.width, filledHeight),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_VuPainter old) => old.level != level;
}
