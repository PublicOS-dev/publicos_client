import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Feed snapping, mobile only. Two behaviours, both decided by the list that
/// owns the scroll view through [resolve]:
///
/// 1. A post's top edge that comes to rest within 15 % of the screen of the
///    feed header line eases onto it.
/// 2. A CLEAR swipe (a quick flick from touch-down, [PostSnap.clearSwipeMax])
///    moves exactly one post, whatever its height. A drag that ends in a
///    flick ("scroll then swipe") flings freely.
///
/// The physics only asks; [resolve] returns the scroll offset to settle on,
/// or null to keep the platform's normal fling.
class PostSnapPhysics extends ScrollPhysics {
  /// (current offset, release velocity, where the platform's own fling would
  /// come to rest) → target offset, or null for the platform's fling.
  final double? Function(double pixels, double velocity, double naturalEnd,
      {required bool inRange}) resolve;

  const PostSnapPhysics({required this.resolve, super.parent});

  /// Mobile only. The client also builds for Windows and the web, where a
  /// wheel does not swipe.
  static bool get enabled =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  PostSnapPhysics applyTo(ScrollPhysics? ancestor) =>
      PostSnapPhysics(resolve: resolve, parent: buildParent(ancestor));

  // A critically damped spring settles in a time ∝ 1/√(stiffness/mass), so
  // 4× the stiffness halves the settle time. The speed cap scales with the
  // stiffness to keep the same no-overshoot margin.
  static const double _maxSpringVelocity = 3600;

  static final _spring = SpringDescription.withDampingRatio(
    mass: 0.5,
    stiffness: 480,
    ratio: 1.0,
  );

  @override
  Simulation? createBallisticSimulation(
      ScrollMetrics position, double velocity) {
    final natural = super.createBallisticSimulation(position, velocity);
    // Where the platform's fling would stop: the "rest" a let-go snaps from.
    final naturalEnd = natural == null
        ? position.pixels
        : natural
            .x(10)
            .clamp(position.minScrollExtent, position.maxScrollExtent)
            .toDouble();
    // EVERY release consults the resolver, overscroll included: the release
    // is what consumes the resolver's "a finger is dragging" arm. Do not
    // return early on overscroll before asking: a pull-to-refresh would
    // leave the arm set, and the framework's own zero-velocity re-ask when
    // the loaded posts change the content size would snap the feed from a
    // dead stop, inside layout.
    final inRange = !position.outOfRange;
    final target =
        resolve(position.pixels, velocity, naturalEnd, inRange: inRange);
    // Overscroll (pull-to-refresh, the bounce at either end) is the parent's.
    if (!inRange) return natural;
    if (target == null || (target - position.pixels).abs() < 0.5) {
      return natural;
    }
    // A hard fling hands the spring a huge start speed, and even a critically
    // damped spring then overshoots the edge and comes back. Cap it: the
    // swipe already chose the target, the speed only needs to feel
    // continuous.
    final v = velocity.clamp(-_maxSpringVelocity, _maxSpringVelocity);
    return ScrollSpringSimulation(
      _spring,
      position.pixels,
      target.clamp(position.minScrollExtent, position.maxScrollExtent),
      v,
      tolerance: toleranceFor(position),
    );
  }
}

/// The whole snap decision, as one pure function. Taken ONCE, at the moment
/// the finger lifts; the physics then runs a single motion to the answer.
/// Nothing re-decides after the motion ends.
///
/// [posts] are the laid-out posts top to bottom, `top` in viewport
/// coordinates at [pixels]; [anchor] is the header line in the same
/// coordinates; [vh] the viewport height; [naturalEnd] where the platform's
/// fling would rest.
class PostSnap {
  /// A top edge resting within this share of the screen of the line snaps.
  static const double zone = 0.15;

  /// Release speed (px/s) that counts as a swipe rather than a let-go.
  static const double swipeVelocity = 400;

  /// A gesture whose drag lasted at most this long, touch to release, is a
  /// clear swipe and moves one post. Longer means the user scrolled first
  /// and the flick at the end only carries that scroll on. The user sets it
  /// in Reading settings (`loadSwipeSnapWindow` in feeds_settings_sheet).
  static Duration clearSwipeMax =
      const Duration(milliseconds: clearSwipeDefaultMs);

  /// Reader settings → Scrolling → *Swipe to snap*. Off =
  /// regular scrolling only: the resolver decides nothing, so every release
  /// is the platform's own fling (no one-post swipe, no ease onto the line).
  /// Same static-set-by-the-sheet shape as [clearSwipeMax].
  static bool snapOn = true;
  static const int clearSwipeDefaultMs = 250;
  static const int clearSwipeMinMs = 100;
  static const int clearSwipeMaxMs = 600;

  /// Edges within this many px of the line count as "on" it. A landing is
  /// only exact to the spring's tolerance, and a top resting 1-2 px below the
  /// line would otherwise make the post ABOVE the "current" one, so a swipe
  /// would read as a short-post scroll.
  static const double slack = 4;

  /// [box]'s top as a SCROLL offset (where it sits in the list, not on
  /// screen), or null if it is not a laid-out list item.
  ///
  /// Why not the on-screen position: the snap is decided inside the
  /// pointer-up event, after the last drag delta moved the scroll offset but
  /// BEFORE the next layout, so `localToGlobal` still reports the previous
  /// frame. Every swipe would then aim a few px off the edge (more on a fast
  /// swipe). The layout offset does not go stale.
  static double? scrollOffsetOf(RenderBox box) {
    RenderObject? child = box;
    while (child != null && child.parent is! RenderSliverMultiBoxAdaptor) {
      child = child.parent;
    }
    if (child == null) return null;
    final pd = child.parentData;
    final sliver = child.parent! as RenderSliverMultiBoxAdaptor;
    if (pd is! SliverMultiBoxAdaptorParentData || pd.layoutOffset == null) {
      return null;
    }
    return sliver.constraints.precedingScrollExtent + pd.layoutOffset!;
  }

  static double? decide({
    required double pixels,
    required double velocity,
    required double naturalEnd,
    required List<({double top, double height})> posts,
    required double anchor,
    required double vh,
    required bool clearSwipe,
  }) {
    if (posts.isEmpty || vh <= 0) return null;
    // The post covering the line: the first whose bottom is past it.
    final i = posts.indexWhere((p) => p.top + p.height > anchor + slack);
    // A flick DOWN while the first post's top is below the line (the finger
    // pulled it off the line, or the channel header still shows) goes to the
    // very top: everything out, the rows above the first post included.
    // Without this, the let-go rule below would ease the first post back
    // onto the line whenever the fling would rest within the zone of it,
    // hiding those rows again.
    if (i >= 0 &&
        velocity <= -swipeVelocity &&
        posts[i].top > anchor + slack) {
      return 0;
    }
    if (clearSwipe && velocity.abs() >= swipeVelocity && i >= 0) {
      final cur = posts[i];
      if (cur.top > anchor + slack) {
        // The line is above the first post (the channel header still
        // shows): up lands that post on the line, down scrolls freely.
        if (velocity > 0) return pixels + (cur.top - anchor);
      } else {
        if (velocity > 0) {
          // Up: the next post's top (posts are contiguous).
          return pixels + (cur.top + cur.height - anchor);
        }
        if (anchor - cur.top > vh * zone) {
          // Down from deep inside the post: back to its own top.
          return pixels + (cur.top - anchor);
        }
        if (i > 0) return pixels + (posts[i - 1].top - anchor);
        return null;
      }
    }
    // A let-go, or a scroll that ended in a flick: rest where the platform would,
    // unless a post top lands within the zone of the line there.
    double? best;
    for (final p in posts) {
      final offset = pixels + (p.top - anchor); // scroll offset of that top
      final d = offset - naturalEnd;
      if (d.abs() <= vh * zone && (best == null || d.abs() < (best - naturalEnd).abs())) {
        best = offset;
      }
    }
    return best;
  }
}

/// The finger's own speed over the last moments of a drag (px/s, positive =
/// scrolling down the list). A short quick flick never counts as a fling for
/// Flutter's gesture recognizer (too little travel after the touch slop), so
/// it arrives at release with velocity 0 and would read as a let-go. This
/// keeps the recent drag deltas so the release can still be judged as a
/// swipe.
class DragSpeed {
  final List<(Duration, double)> _samples = [];
  Duration? _first;
  Duration? _last;

  void reset() {
    _samples.clear();
    _first = null;
    _last = null;
  }

  /// How long the drag has lasted, first move to last (the touch slop before
  /// the first move is a few ms on a flick).
  Duration get held =>
      (_first == null || _last == null) ? Duration.zero : _last! - _first!;

  /// A quick flick from touch-down, not a scroll that ended in one.
  bool get isClearSwipe => held <= PostSnap.clearSwipeMax;

  void add(DragUpdateDetails d) {
    final t = d.sourceTimeStamp;
    final dy = d.primaryDelta ?? d.delta.dy;
    if (t == null) return;
    _first ??= t;
    _last = t;
    _samples.add((t, dy));
    // Keep ~the last 100 ms.
    while (_samples.length > 2 &&
        t - _samples.first.$1 > const Duration(milliseconds: 100)) {
      _samples.removeAt(0);
    }
  }

  double get pxPerSecond {
    if (_samples.length < 2) return 0;
    final span = _samples.last.$1 - _samples.first.$1;
    if (span.inMicroseconds <= 0) return 0;
    var dy = 0.0;
    for (final s in _samples.skip(1)) {
      dy += s.$2;
    }
    // Finger up (negative dy) scrolls down the list (positive velocity).
    return -dy / (span.inMicroseconds / 1e6);
  }
}
