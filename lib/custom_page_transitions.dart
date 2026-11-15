import 'package:flutter/material.dart';

/// Reusable transition builders for GoRouter's CustomTransitionPage.
///
/// The old PageRouteBuilder subclasses (FadeInPageTransition,
/// ExplorerToBrowserPageRoute) have been replaced by GoRouter's
/// CustomTransitionPage with these builders.

/// Slide-up + fade transition (used for Browser pages).
Widget browserTransitionBuilder(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  final slideAnimation = Tween<Offset>(
    begin: const Offset(0, 0.2),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: animation, curve: Curves.easeInOutCubic));

  final fadeAnimation = Tween<double>(
    begin: 0.0,
    end: 1.0,
  ).animate(CurvedAnimation(parent: animation, curve: Curves.easeInOutCubic));

  return SlideTransition(
    position: slideAnimation,
    child: FadeTransition(
      opacity: fadeAnimation,
      child: child,
    ),
  );
}

/// Simple fade transition (used for Explorer/home page).
Widget fadeTransitionBuilder(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  return FadeTransition(opacity: animation, child: child);
}
