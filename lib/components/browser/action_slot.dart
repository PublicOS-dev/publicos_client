import 'package:flutter/material.dart';

/// One address-bar action, animated in and out.
///
/// The twin of publicos_desktop's `DeckSlot` (`widgets/browser/tab_deck.dart`),
/// which animates the same kind of right-pinned action cluster on the browser
/// deck. Same timings, same two motions; only the name differs, because the
/// client has no deck.
///
/// Give it the action's widget while the action applies and `null` once it does
/// not. It keeps the last child it was handed so the outgoing one still has
/// something to animate; a child simply dropped from the `Row` would be gone
/// before the first frame of an exit.
///
/// Two things move together, and both are needed (the motion is horizontal
/// only, with no vertical rise):
///
///  * **width** (`SizeTransition`, horizontal) — without it the neighbours jump
///    the instant an action appears. The address-bar row is pinned to the right
///    edge, so a width change shifts everything to its LEFT; animating the
///    width is what turns that shift into a slide.
///  * **opacity** — carries the change on its own if the motion is missed.
///
/// **In and out are deliberately not symmetrical.** Entering takes 200ms on an
/// ease-out; leaving takes 120ms and is mostly the fade (`easeIn`, so the
/// opacity goes early and the width closes after).
class ActionSlot extends StatefulWidget {
  final Widget? child;
  const ActionSlot({super.key, this.child});

  @override
  State<ActionSlot> createState() => _ActionSlotState();
}

class _ActionSlotState extends State<ActionSlot>
    with SingleTickerProviderStateMixin {
  static const Duration _kIn = Duration(milliseconds: 200);
  static const Duration _kOut = Duration(milliseconds: 120);

  late final AnimationController _ctrl;
  late final CurvedAnimation _curved;

  /// The last non-null child. Survives its own removal so it can be animated
  /// away; replaced only when a new one arrives.
  Widget? _last;

  @override
  void initState() {
    super.initState();
    _last = widget.child;
    _ctrl = AnimationController(
      vsync: this,
      duration: _kIn,
      reverseDuration: _kOut,
      // A slot that starts out visible starts settled: the row should not
      // play an entrance for every button just because the page mounted.
      value: widget.child != null ? 1.0 : 0.0,
    );
    _curved = CurvedAnimation(
      parent: _ctrl,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeIn,
    );
  }

  @override
  void didUpdateWidget(ActionSlot old) {
    super.didUpdateWidget(old);
    if (widget.child != null) {
      _last = widget.child;
      _ctrl.forward();
    } else {
      _ctrl.reverse();
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = _last;
    // Fully out and nothing pending: occupy no space at all.
    if (child == null || (_ctrl.isDismissed && widget.child == null)) {
      return const SizedBox.shrink();
    }

    return SizeTransition(
      axis: Axis.horizontal,
      // Collapse toward the LEFT edge, so a slot closing does not drag its
      // right-hand neighbours with it.
      alignment: Alignment.centerLeft,
      sizeFactor: _curved,
      child: FadeTransition(opacity: _curved, child: child),
    );
  }
}
