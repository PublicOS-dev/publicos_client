import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

class ConstellationBackground extends StatefulWidget {
  final Color color;
  final Color secondaryColor;
  final double secondaryRatio;
  final int planetCount;
  final double maxConnectionDistance;

  /// Global horizontal parallax offset (px). Shifts the whole field on X and
  /// wraps seamlessly at the edges, so callers can scroll the starfield any
  /// distance (e.g. nudging it with a fly animation) without an edge seam.
  final double scrollX;

  const ConstellationBackground({
    super.key,
    this.color = const Color(0xFFFFFFFF),
    this.secondaryColor = const Color(0xFF14B8A6),
    this.secondaryRatio = 0.2,
    this.planetCount = 30,
    this.maxConnectionDistance = 350,
    this.scrollX = 0,
  });

  @override
  State<ConstellationBackground> createState() =>
      _ConstellationBackgroundState();
}

class _ConstellationBackgroundState extends State<ConstellationBackground>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final List<_Planet> _planets = [];
  final ValueNotifier<int> _tick = ValueNotifier(0);
  Size? _size;
  final math.Random _rng = math.Random();
  Duration _lastTick = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _tick.dispose();
    super.dispose();
  }

  void _initPlanets(Size size) {
    _planets.clear();
    for (int i = 0; i < widget.planetCount; i++) {
      final s = 4 + _rng.nextDouble() * 4;
      final moonCount = _rng.nextInt(3);
      final moons = <_Moon>[];
      for (int m = 0; m < moonCount; m++) {
        moons.add(
          _Moon(
            dist: s + 3 + _rng.nextDouble() * 6,
            angle: _rng.nextDouble() * math.pi * 2,
            speed:
                (0.15 + _rng.nextDouble() * 0.30) * (_rng.nextBool() ? 1 : -1),
            r: 2 * (0.6 + _rng.nextDouble() * 0.5),
          ),
        );
      }
      final isAccent = _rng.nextDouble() < widget.secondaryRatio;
      // Full visual reach from the planet centre (its own half-size, or the
      // farthest moon's orbit + radius) — used to recycle it only once it's
      // completely off-screen, and to size the seam duplicates.
      var ext = s / 2;
      for (final m in moons) {
        ext = math.max(ext, m.dist + m.r);
      }
      ext += 1;
      _planets.add(
        _Planet(
          x: _rng.nextDouble() * size.width,
          y: _rng.nextDouble() * size.height,
          vx: (_rng.nextDouble() - 0.5) * 9.0,
          vy: (_rng.nextDouble() - 0.5) * 9.0,
          size: s,
          rx: s * 0.45,
          moons: moons,
          color: isAccent ? widget.secondaryColor : widget.color,
          ext: ext,
        ),
      );
    }
  }

  void _onTick(Duration elapsed) {
    if (_size == null || _planets.isEmpty) {
      _lastTick = elapsed;
      return;
    }
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (dt <= 0 || dt > 0.1) return;

    final w = _size!.width;
    final h = _size!.height;

    for (final p in _planets) {
      p.x += p.vx * dt;
      p.y += p.vy * dt;
      // X rides the painter's modulo field (seamless under scrollX parallax), so
      // wrap by exactly one width to stay continuous — the painter draws edge
      // duplicates so a crossing planet is never clipped mid-seam. Y has no
      // parallax, so recycle a planet only once it's COMPLETELY off the top or
      // bottom (centre past the edge by its full extent), not the instant the
      // centre touches the edge.
      p.x %= w;
      if (p.x < 0) p.x += w;
      if (p.y < -p.ext) p.y = h + p.ext;
      if (p.y > h + p.ext) p.y = -p.ext;
      for (final m in p.moons) {
        m.angle += m.speed * dt;
      }
    }
    _tick.value = (_tick.value + 1) & 0xFFFFFF;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (_size == null || _size != size) {
          _size = size;
          if (_planets.isEmpty) _initPlanets(size);
        }
        return CustomPaint(
          size: size,
          painter: _ConstellationPainter(
            planets: _planets,
            color: widget.color,
            maxDist: widget.maxConnectionDistance,
            scrollX: widget.scrollX,
            repaint: _tick,
          ),
        );
      },
    );
  }
}

class _Planet {
  double x;
  double y;
  double vx;
  double vy;
  final double size;
  final double rx;
  final List<_Moon> moons;
  final Color color;

  /// Full visual reach from the centre (half-size or farthest moon), used to
  /// recycle the planet only when it's completely off-screen and to draw the
  /// horizontal seam duplicates.
  final double ext;

  _Planet({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.size,
    required this.rx,
    required this.moons,
    required this.color,
    required this.ext,
  });
}

class _Moon {
  final double dist;
  double angle;
  final double speed;
  final double r;

  _Moon({
    required this.dist,
    required this.angle,
    required this.speed,
    required this.r,
  });
}

class _ConstellationPainter extends CustomPainter {
  final List<_Planet> planets;
  final Color color;
  final double maxDist;
  final double scrollX;

  _ConstellationPainter({
    required this.planets,
    required this.color,
    required this.maxDist,
    required this.scrollX,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    // Wrapped horizontal positions: scrollX shifts the whole field on X and
    // wraps at the edges, so a parallax scroll never reveals a seam. Lines and
    // dots use the same wrapped x so cross-seam pairs read as far apart (no long
    // line draws across the screen) — matching how planets already wrap on drift.
    final xs = [
      for (final p in planets) ((p.x + scrollX) % w + w) % w,
    ];

    final linePaint = Paint()..style = PaintingStyle.stroke;
    for (int i = 0; i < planets.length; i++) {
      for (int j = i + 1; j < planets.length; j++) {
        final dx = xs[i] - xs[j];
        final dy = planets[i].y - planets[j].y;
        final dist = math.sqrt(dx * dx + dy * dy);
        if (dist < maxDist) {
          final intensity = 1 - dist / maxDist;
          final alpha = intensity * intensity * 0.12;
          linePaint
            ..color = color.withValues(alpha: alpha)
            ..strokeWidth = 0.5 + intensity * 0.8;
          canvas.drawLine(
            Offset(xs[i], planets[i].y),
            Offset(xs[j], planets[j].y),
            linePaint,
          );
        }
      }
    }

    for (int k = 0; k < planets.length; k++) {
      final p = planets[k];
      final cx = xs[k];
      _drawPlanet(canvas, p, cx);
      // Wrap-around copies: a planet within its extent of the left/right seam is
      // also drawn on the opposite edge, so it stays whole as it crosses instead
      // of being clipped the moment its centre reaches the edge.
      if (cx < p.ext) _drawPlanet(canvas, p, cx + w);
      if (cx > w - p.ext) _drawPlanet(canvas, p, cx - w);
    }
  }

  /// Draws a planet (its body + soft shadow + orbiting moons) centred at [cx].
  /// Factored out so the same planet can be drawn again at a wrapped x for the
  /// horizontal seam.
  void _drawPlanet(Canvas canvas, _Planet p, double cx) {
    _drawRRect(canvas, cx, p.y, p.size, p.size, p.rx, p.color, 0.25);
    _drawRRect(canvas, cx, p.y + 1, p.size, p.size, p.rx, p.color, 0.08);
    for (final m in p.moons) {
      final mx = cx + math.cos(m.angle) * m.dist;
      final my = p.y + math.sin(m.angle) * m.dist;
      _drawRRect(canvas, mx, my, m.r * 2, m.r * 2, m.r * 0.4, p.color, 0.2);
    }
  }

  void _drawRRect(
    Canvas canvas,
    double cx,
    double cy,
    double w,
    double h,
    double r,
    Color color,
    double alpha,
  ) {
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy), width: w, height: h),
      Radius.circular(r),
    );
    canvas.drawRRect(rect, Paint()..color = color.withValues(alpha: alpha));
  }

  @override
  bool shouldRepaint(_ConstellationPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.maxDist != maxDist ||
      oldDelegate.scrollX != scrollX;
}
