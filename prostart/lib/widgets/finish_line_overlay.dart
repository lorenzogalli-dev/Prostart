import 'package:flutter/material.dart';

/// The finish line: drawn through two handles and extended across the image,
/// since the timing uses the whole line, not the segment.
class FinishLineOverlay extends StatelessWidget {
  final Offset a, b;
  final bool locked;
  final void Function(Offset a, Offset b) onChanged;
  final VoidCallback onDone;

  const FinishLineOverlay({
    super.key,
    required this.a,
    required this.b,
    required this.locked,
    required this.onChanged,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        Offset px(Offset n) => Offset(n.dx * size.width, n.dy * size.height);
        Offset norm(Offset p) => Offset(
          (p.dx / size.width).clamp(0.0, 1.0),
          (p.dy / size.height).clamp(0.0, 1.0),
        );
        Widget handle(Offset n, bool first) => Positioned(
          left: px(n).dx - 22,
          top: px(n).dy - 22,
          child: GestureDetector(
            onPanUpdate: locked
                ? null
                : (d) {
                    final moved = norm(px(n) + d.delta);
                    first ? onChanged(moved, b) : onChanged(a, moved);
                  },
            onPanEnd: locked ? null : (_) => onDone(),
            child: Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                  border: Border.all(color: const Color(0xFFFF3B30), width: 4),
                  boxShadow: const [
                    BoxShadow(color: Colors.black54, blurRadius: 6),
                  ],
                ),
              ),
            ),
          ),
        );
        return Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(painter: _LinePainter(px(a), px(b))),
              ),
            ),
            if (!locked) handle(a, true),
            if (!locked) handle(b, false),
          ],
        );
      },
    );
  }
}

class _LinePainter extends CustomPainter {
  final Offset a, b;
  _LinePainter(this.a, this.b);

  @override
  void paint(Canvas canvas, Size size) {
    final d = b - a;
    if (d.distance < 1) return;
    // Extend far beyond both ends; the canvas clips it.
    final u = d / d.distance * (size.height + size.width) * 2;
    final paint = Paint()
      ..color = const Color(0xFFFF3B30)
      ..strokeWidth = 3;
    canvas.drawLine(a - u, b + u, paint);
  }

  @override
  bool shouldRepaint(_LinePainter old) => old.a != a || old.b != b;
}

