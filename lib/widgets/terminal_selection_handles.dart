import 'package:flutter/material.dart';

/// A Material-style teardrop selection handle. Positioned by the caller
/// (typically via a [Positioned] in a [Stack]) at its own top-left; the
/// caller is responsible for computing the offset so the handle's *tip*
/// lands at the selection endpoint.
class TerminalSelectionHandle extends StatelessWidget {
  const TerminalSelectionHandle({
    super.key,
    required this.isStart,
    required this.onPanUpdate,
    this.onPanStart,
    this.onPanEnd,
  });

  /// True for the start (left) handle, false for the end (right) handle.
  final bool isStart;

  final GestureDragStartCallback? onPanStart;
  final GestureDragUpdateCallback onPanUpdate;
  final GestureDragEndCallback? onPanEnd;

  // Same size as Flutter's Material text-selection handles.
  static const double size = 22.0;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: onPanStart,
      onPanUpdate: onPanUpdate,
      onPanEnd: onPanEnd,
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _HandlePainter(color: color, isStart: isStart),
        ),
      ),
    );
  }
}

class _HandlePainter extends CustomPainter {
  const _HandlePainter({required this.color, required this.isStart});
  final Color color;
  final bool isStart;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final r = size.width / 2;
    // Circle fills the widget, plus a right-angle tab at the "tip" corner.
    // The caller positions the widget so the tab corner lands on the
    // selection endpoint.
    canvas.drawPath(
      Path()
        ..addOval(Rect.fromCircle(center: Offset(r, r), radius: r))
        ..addRect(
          isStart
              ? Rect.fromLTWH(r, 0, r, r) // tab at top-right for start handle
              : Rect.fromLTWH(0, 0, r, r), // tab at top-left for end handle
        ),
      paint,
    );
  }

  @override
  bool shouldRepaint(_HandlePainter old) =>
      old.color != color || old.isStart != isStart;
}
