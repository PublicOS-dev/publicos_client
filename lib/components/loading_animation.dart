import 'package:flutter/material.dart';

class ThreeDotsLoadingAnimation extends StatefulWidget {
  final Color dotColor;
  final double dotSize;
  final double spacing;

  const ThreeDotsLoadingAnimation({
    super.key,
    this.dotColor = Colors.blue,
    this.dotSize = 10.0,
    this.spacing = 5.0,
  });

  @override
  State<ThreeDotsLoadingAnimation> createState() => _ThreeDotsLoadingAnimationState();
}

class _ThreeDotsLoadingAnimationState extends State<ThreeDotsLoadingAnimation> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<int> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat();

    _animation = IntTween(begin: 0, end: 2).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(3, (index) {
            final bool isLarge = _animation.value == index;
            final double currentSize = isLarge ? widget.dotSize * 1.5 : widget.dotSize;
            // Animate size change
            return AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              width: currentSize,
              height: currentSize,
              margin: EdgeInsets.symmetric(horizontal: widget.spacing / 2),
              decoration: BoxDecoration(
                color: widget.dotColor,
                shape: BoxShape.circle,
              ),
            );
          }),
        );
      },
    );
  }
}
