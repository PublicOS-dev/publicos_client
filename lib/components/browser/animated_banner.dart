import 'dart:math';
import 'package:flutter/material.dart';

class Star {
  double x;
  double y;
  double size;
  double baseOpacity;
  double angle;
  double speed;

  Star({
    required this.x,
    required this.y,
    required this.size,
    required this.baseOpacity,
    required this.angle,
    required this.speed,
  });
}

class AnimatedStarryNight extends StatefulWidget {
  final bool isCollapsed;

  const AnimatedStarryNight({
    super.key,
    this.isCollapsed = false,
  });

  @override
  State<AnimatedStarryNight> createState() => _AnimatedStarryNightState();
}

class _AnimatedStarryNightState extends State<AnimatedStarryNight> with SingleTickerProviderStateMixin {
  static const int maxStars = 80;
  static const double minStarSize = 1.0;
  static const double maxStarSize = 4.0;
  static const double baseSpeed = 0.04;
  static const double spawnChance = 0.35;
  static const double edgeFadeDistance = 20.0;
  static const double minAngle = 84.0;
  static const double maxAngle = 90.0;
  static const double spawnY = 105.0;
  static const double sideSpawnWidth = 20.0;

  late AnimationController _controller;
  final Random _random = Random();
  final List<Star> _stars = [];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();

    _populateInitialStars();
    _controller.addListener(_updateStars);
  }

  Star _createInitialStar() {
    final x = _random.nextDouble() * 100;
    final y = _random.nextDouble() * 100;
    final angleInDegrees = minAngle + _random.nextDouble() * (maxAngle - minAngle);
    final angleInRadians = _degreesToRadians(angleInDegrees);
    final size = minStarSize + _random.nextDouble() * (maxStarSize - minStarSize);
    final speed = baseSpeed * (1 + size / maxStarSize);

    return Star(
      x: x,
      y: y,
      size: size,
      baseOpacity: _random.nextDouble() * 0.8 + 0.2,
      angle: angleInRadians,
      speed: speed,
    );
  }

  void _populateInitialStars() {
    final starCount = widget.isCollapsed ? (maxStars ~/ 2) : maxStars;
    for (int i = 0; i < starCount; i++) {
      _stars.add(_createInitialStar());
    }
  }

  double _degreesToRadians(double degrees) => degrees * pi / 180.0;

  Star _createRandomStar() {
    double spawnX;
    final spawnLocation = _random.nextDouble();

    if (spawnLocation < 0.33) {
      spawnX = -sideSpawnWidth + _random.nextDouble() * sideSpawnWidth;
    } else if (spawnLocation < 0.66) {
      spawnX = 100 + _random.nextDouble() * sideSpawnWidth;
    } else {
      spawnX = _random.nextDouble() * 100;
    }

    final angleInDegrees = minAngle + _random.nextDouble() * (maxAngle - minAngle);
    final angleInRadians = _degreesToRadians(angleInDegrees);
    final size = minStarSize + _random.nextDouble() * (maxStarSize - minStarSize);
    final speed = baseSpeed * (1 + size / maxStarSize);

    return Star(
      x: spawnX,
      y: spawnY,
      size: size,
      baseOpacity: _random.nextDouble() * 0.8 + 0.2,
      angle: angleInRadians,
      speed: speed,
    );
  }

  double _calculateEdgeFadeMultiplier(Star star) {
    double fadeMultiplier = 1.0;

    if (star.y > (100 - edgeFadeDistance)) {
      fadeMultiplier = (105 - star.y) / edgeFadeDistance;
    }
    if (star.y < edgeFadeDistance) {
      fadeMultiplier = min(fadeMultiplier, star.y / edgeFadeDistance);
    }
    if (star.x < edgeFadeDistance) {
      fadeMultiplier = min(fadeMultiplier, star.x / edgeFadeDistance);
    }
    if (star.x > (100 - edgeFadeDistance)) {
      fadeMultiplier = min(fadeMultiplier, (100 - star.x) / edgeFadeDistance);
    }

    return fadeMultiplier.clamp(0.0, 1.0);
  }

  void _updateStars() {
    setState(() {
      for (int i = _stars.length - 1; i >= 0; i--) {
        Star star = _stars[i];
        final dx = star.speed * cos(star.angle);
        final dy = -star.speed * sin(star.angle);

        star.x += dx;
        star.y += dy;

        if (star.y < -5 || star.x < -20 || star.x > 120) {
          _stars.removeAt(i);
          continue;
        }
      }

      final maxAllowedStars = widget.isCollapsed ? (maxStars ~/ 2) : maxStars;
      if (_stars.length < maxAllowedStars && _random.nextDouble() < spawnChance) {
        _stars.add(_createRandomStar());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: StarryNightPainter(
                stars: _stars,
                isCollapsed: widget.isCollapsed,
                statusBarHeight: MediaQuery.of(context).viewPadding.top,
              ),
              size: Size.infinite,
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

class StarryNightPainter extends CustomPainter {
  final List<Star> stars;
  final bool isCollapsed;
  final double statusBarHeight;

  StarryNightPainter({
    required this.stars,
    required this.isCollapsed,
    required this.statusBarHeight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()..color = Colors.white;
    final double totalHeight = size.height + statusBarHeight;

    for (final star in stars) {
      final double x = (star.x / 100) * size.width;
      final double y = (star.y / 100) * totalHeight;

      final double edgeFadeMultiplier = (_AnimatedStarryNightState()._calculateEdgeFadeMultiplier(star));
      final double finalOpacity = star.baseOpacity * edgeFadeMultiplier * (isCollapsed ? 0.7 : 1.0);

      paint.color = Colors.white.withOpacity(finalOpacity);
      canvas.drawCircle(Offset(x, y), star.size * (isCollapsed ? 0.7 : 1.0), paint);
    }
  }

  @override
  bool shouldRepaint(StarryNightPainter oldDelegate) => true;
}
