import 'package:flutter/material.dart';

/// The home shell's chrome animation, placed above the tab bodies so a tab
/// can move its own floating pieces with the AppBar + BottomNav.
///
/// [shown] is the shell's `_chromeAnim`: 1 = chrome in place, 0 = slid away
/// (scroll-reactive chrome). [bottomInset] is the system
/// bottom inset the shell already lifted the body above, handed down here
/// because a tab may have stripped it from `MediaQuery` (Feeds does).
///
/// Looked up without a dependency: the animation object lives as long as the
/// shell, and listeners attach through [AnimatedBuilder], not rebuilds.
class ShellChromeScope extends InheritedWidget {
  const ShellChromeScope({
    super.key,
    required this.shown,
    required this.bottomInset,
    required super.child,
  });

  final Animation<double> shown;
  final double bottomInset;

  static ShellChromeScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ShellChromeScope>();

  @override
  bool updateShouldNotify(ShellChromeScope old) =>
      shown != old.shown || bottomInset != old.bottomInset;
}

/// Tells a post list that its HOST draws the "+" post button over it (the
/// Feeds tab's own button lives in the tab's Scaffold, outside the list), so
/// the list can stack its "back to top" button above that spot. A list that
/// draws the "+" itself (a forum channel) does not need it.
class HostPostButtonScope extends InheritedWidget {
  const HostPostButtonScope({
    super.key,
    required this.shown,
    required super.child,
  });

  final bool shown;

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<HostPostButtonScope>()
          ?.shown ??
      false;

  @override
  bool updateShouldNotify(HostPostButtonScope old) => shown != old.shown;
}

/// Slides [child] down off the screen as the shell's chrome hides, and
/// back up as it shows: the '+' button hides with the bottom nav, animated
/// downwards to hide and upwards to show, following the nav.
///
/// Meant for a button sitting [bottomMargin] px above the tab body's bottom
/// edge. The body already grows by the nav's height while the chrome hides,
/// so the child is carried down that far by layout; this adds the rest
/// ([height] + [bottomMargin] + the system inset) so it ends fully below the
/// screen edge, and fades it like the nav. Without a [ShellChromeScope]
/// above (the Browser's channel tab, any plain page) it is a no-op.
class ShellChromeFollower extends StatelessWidget {
  const ShellChromeFollower({
    super.key,
    this.height = 56,
    this.bottomMargin = 16,
    required this.child,
  });

  final double height;
  final double bottomMargin;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scope = ShellChromeScope.maybeOf(context);
    if (scope == null) return child;
    final extent = height + bottomMargin + scope.bottomInset;
    return AnimatedBuilder(
      animation: scope.shown,
      builder: (context, child) {
        final v = scope.shown.value;
        return Transform.translate(
          offset: Offset(0, extent * (1 - v)),
          child: Opacity(opacity: v, child: child),
        );
      },
      child: child,
    );
  }
}
