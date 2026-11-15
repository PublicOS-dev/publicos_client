import 'package:flutter/material.dart';

class AnimatedBalance extends StatefulWidget {
  final double balance;
  final TextStyle? style;
  final String suffix;
  final int decimalPlaces;
  final Duration animationDuration;

  const AnimatedBalance({
    super.key,
    required this.balance,
    this.style,
    this.suffix = ' ETH',
    this.decimalPlaces = 4,
    this.animationDuration = const Duration(milliseconds: 600),
  });

  @override
  State<AnimatedBalance> createState() => _AnimatedBalanceState();
}

class _AnimatedBalanceState extends State<AnimatedBalance>
    with SingleTickerProviderStateMixin {
  late double _displayedBalance;
  late AnimationController _controller;
  late Animation<double> _animation;
  bool _isAnimating = false;

  @override
  void initState() {
    super.initState();
    _displayedBalance = widget.balance;
    _controller = AnimationController(
      duration: widget.animationDuration,
      vsync: this,
    );
    _animation = Tween<double>(
      begin: _displayedBalance,
      end: _displayedBalance,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));
  }

  @override
  void didUpdateWidget(AnimatedBalance oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    if (oldWidget.balance != widget.balance) {
      _animateToNewBalance(widget.balance);
    }
  }

  void _animateToNewBalance(double newBalance) {
    if (_isAnimating || _displayedBalance == newBalance) return;

    setState(() {
      _isAnimating = true;
    });

    _animation = Tween<double>(
      begin: _displayedBalance,
      end: newBalance,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));

    _controller.reset();
    _controller.forward().then((_) {
      setState(() {
        _displayedBalance = newBalance;
        _isAnimating = false;
      });
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _buildAnimatedDigit(String currentChar, String newChar, bool isChanging) {
    if (!isChanging) {
      return Text(currentChar, style: widget.style);
    }

    return SizedBox(
      height: widget.style?.fontSize ?? 16.0,
      child: ClipRect(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final progress = _controller.value;
            
            if (progress < 0.5) {
              // First half: current digit slides up
              return Transform.translate(
                offset: Offset(0, -(widget.style?.fontSize ?? 16.0) * progress * 2),
                child: Text(currentChar, style: widget.style),
              );
            } else {
              // Second half: new digit slides in from below
              final slideProgress = (progress - 0.5) * 2;
              return Transform.translate(
                offset: Offset(0, (widget.style?.fontSize ?? 16.0) * (1 - slideProgress)),
                child: Text(newChar, style: widget.style),
              );
            }
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isAnimating) {
      // Static display when not animating
      return Text(
        '${_displayedBalance.toStringAsFixed(widget.decimalPlaces)}${widget.suffix}',
        style: widget.style,
      );
    }

    // Smooth numerical animation with subtle scale effect
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        // Add a subtle scale effect during animation
        final scaleValue = 1.0 + (0.05 * _controller.value * (1 - _controller.value) * 4);
        
        return Transform.scale(
          scale: scaleValue,
          child: Text(
            '${_animation.value.toStringAsFixed(widget.decimalPlaces)}${widget.suffix}',
            style: widget.style,
          ),
        );
      },
    );
  }
}