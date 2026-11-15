// Feed snap: the decision rules, and the snap
// running under a copy of the home shell's scroll-reactive bars, which is
// where a snap can land off the edge.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:publicos_client/components/feeds/post_snap_physics.dart';

typedef _Post = ({double top, double height});

void main() {
  group('PostSnap.decide', () {
    const vh = 800.0;
    // Tall, tall, short, short, tall; the first top sits on the line.
    List<_Post> posts({double shift = 0}) {
      final heights = [600.0, 600.0, 150.0, 150.0, 600.0];
      var top = shift;
      return [
        for (final h in heights) (top: (top += h) - h, height: h),
      ];
    }

    test('swipe up on a tall post goes to the next post top', () {
      final t = PostSnap.decide(
          pixels: 0, velocity: 2500, naturalEnd: 1500,
          posts: posts(), anchor: 0, vh: vh, clearSwipe: true);
      expect(t, 600);
    });

    test('a landing 2 px short still reads the tall post as current', () {
      // The old rule picked the post ABOVE (bottom at the line) here, so the
      // swipe fell through to a free scroll.
      final t = PostSnap.decide(
          pixels: 598, velocity: 2500, naturalEnd: 2000,
          posts: posts(shift: -598), anchor: 0, vh: vh, clearSwipe: true);
      expect(t, 1200);
    });

    test('scroll then swipe flings freely, then rests on a nearby top', () {
      final t = PostSnap.decide(
          pixels: 1200, velocity: 2500, naturalEnd: 1320,
          posts: posts(shift: -1200), anchor: 0, vh: vh, clearSwipe: false);
      expect(t, 1350); // next top within 15 % of where the fling stops
    });

    test('a clear swipe on a short post moves exactly one post', () {
      final t = PostSnap.decide(
          pixels: 1200, velocity: 2500, naturalEnd: 1900,
          posts: posts(shift: -1200), anchor: 0, vh: vh, clearSwipe: true);
      expect(t, 1350);
    });

    test('scroll then swipe on a tall post does not snap one post', () {
      final t = PostSnap.decide(
          pixels: 0, velocity: 2500, naturalEnd: 1000,
          posts: posts(), anchor: 0, vh: vh, clearSwipe: false);
      expect(t, isNull); // no top within 15 % of 1000
    });

    test('a clear swipe up with the header showing lands the first post', () {
      final t = PostSnap.decide(
          pixels: 0, velocity: 2500, naturalEnd: 900,
          posts: posts(shift: 200), anchor: 0, vh: vh, clearSwipe: true);
      expect(t, 200);
    });

    test('swipe down near a tall top goes to the previous post', () {
      final t = PostSnap.decide(
          pixels: 600, velocity: -2500, naturalEnd: 0,
          posts: posts(shift: -600), anchor: 0, vh: vh, clearSwipe: true);
      expect(t, 0);
    });

    test('a flick down from the first post goes to the very top', () {
      // A 58 px row above the first post. Snapped on it (58), the finger
      // pulled the list down 30 px. The fling would rest at 0, which is
      // within 15 % of the first top: it used to ease back onto the line.
      for (final clear in [true, false]) {
        final t = PostSnap.decide(
            pixels: 28, velocity: -2500, naturalEnd: 0,
            posts: posts(shift: 30), anchor: 0, vh: vh, clearSwipe: clear);
        expect(t, 0);
      }
    });

    test('a let-go far from any top keeps the platform rest', () {
      final t = PostSnap.decide(
          pixels: 300, velocity: 0, naturalEnd: 300,
          posts: posts(shift: -300), anchor: 0, vh: vh, clearSwipe: true);
      expect(t, isNull);
    });
  });

  testWidgets('swipes land exactly on post tops under the shell bars',
      (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final harness = GlobalKey<_HarnessState>();
    await tester.pumpWidget(MaterialApp(home: _Harness(key: harness)));
    final h = harness.currentState!;

    // Three swipes up, each starting on a tall post: each must land the next
    // post's top exactly on the line, with the bars hiding on the way.
    for (var n = 1; n <= 3; n++) {
      await tester.fling(find.byType(CustomScrollView),
          const Offset(0, -250), 3000);
      await tester.pumpAndSettle();
      expect(h.topOffsetOf(n), closeTo(0, 1.0),
          reason: 'swipe $n: post $n top vs line');
    }
    expect(h.chrome.value, 0, reason: 'bars hidden after snapping down');
  });

  testWidgets('short fast swipes (bars half-shown at release) land exactly',
      (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final harness = GlobalKey<_HarnessState>();
    await tester.pumpWidget(MaterialApp(home: _Harness(key: harness)));
    final h = harness.currentState!;

    await tester.fling(find.byType(CustomScrollView),
        const Offset(0, -30), 2000);
    await tester.pumpAndSettle();
    expect(h.topOffsetOf(1), closeTo(0, 1.0));
    expect(h.chrome.value, 0);

    // And back down: a swipe down near a top goes to the previous post. It
    // is the FIRST swipe down with the bars hidden, so the finger reveals
    // nothing; the post lands exactly, and since it is the first post the
    // list is at the very top, where the top rule shows the bars. (The
    // second-swipe rule away from the top is in the next test.)
    await tester.fling(find.byType(CustomScrollView),
        const Offset(0, 30), 2000);
    await tester.pumpAndSettle();
    expect(h.topOffsetOf(0), closeTo(0, 1.0));
    expect(h.chrome.value, 1, reason: 'at the very top the bars show');
  });

  testWidgets('the snap and its settling never move the bars; the finger does',
      (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final harness = GlobalKey<_HarnessState>();
    await tester.pumpWidget(MaterialApp(home: _Harness(key: harness)));
    final h = harness.currentState!;

    // A hard swipe up: the finger's 250 px consume the whole bar, the snap
    // runs with the bars hidden and leaves them hidden.
    await tester.fling(find.byType(CustomScrollView),
        const Offset(0, -250), 3000);
    await tester.pumpAndSettle();
    expect(h.chrome.value, 0);
    expect(h.topOffsetOf(1), closeTo(0, 1.0));

    // A slow 20 px drag down, no fling: the first downward drag with the
    // bars hidden, so it only scrolls. The snap that follows (15 % zone) must
    // not reveal anything on its own.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 20));
    await tester.pumpAndSettle();
    expect(h.chrome.value, 0, reason: 'the first drag down only scrolls');

    // The second: 20/56 shown at the let-go, under half, so it finishes
    // hidden. It still counted as a downward drag.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 20));
    await tester.pumpAndSettle();
    expect(h.chrome.value, 0, reason: 'under half at let-go → hidden');

    // A 40 px drag down: 40/56 shown at the let-go, past half → shown.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 40));
    await tester.pumpAndSettle();
    expect(h.chrome.value, 1, reason: 'past half at let-go → shown');

    // An upward drag hides the bars and starts the count again: the next
    // drag down only scrolls, the one after it reveals.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(h.chrome.value, 0);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 40));
    await tester.pumpAndSettle();
    expect(h.chrome.value, 0, reason: 'first drag down after an upward one');
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 40));
    await tester.pumpAndSettle();
    expect(h.chrome.value, 1, reason: 'second drag down reveals');
  });
}

/// A copy of the parts that matter: explorer.dart's scroll-reactive bars
/// (body padding tracks the chrome, a hide consumes the scroll delta with
/// forcePixels unless a snap runs) around a list wired like posts_list.dart.
class _Harness extends StatefulWidget {
  const _Harness({super.key});
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> with TickerProviderStateMixin {
  static const heights = [700.0, 700.0, 700.0, 700.0, 150.0, 150.0, 700.0];
  late final chrome = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 120), value: 1);
  final controller = ScrollController();
  final viewportKey = GlobalKey();
  final keys = List.generate(heights.length, (_) => GlobalKey());
  double? target;
  bool dragActive = false;
  final speed = DragSpeed();

  double topOffsetOf(int i) {
    final vp = viewportKey.currentContext!.findRenderObject() as RenderBox;
    final ro = keys[i].currentContext!.findRenderObject() as RenderBox;
    return ro.localToGlobal(Offset.zero, ancestor: vp).dy;
  }

  double? resolve(double pixels, double velocity, double naturalEnd,
      {required bool inRange}) {
    if (target != null) return target;
    if (!dragActive) return null;
    dragActive = false;
    if (!inRange) return null;
    if (velocity.abs() < PostSnap.swipeVelocity) {
      final finger = speed.pxPerSecond;
      if (finger.abs() >= PostSnap.swipeVelocity) velocity = finger;
    }
    final vp = viewportKey.currentContext!.findRenderObject() as RenderBox;
    final posts = <({double top, double height})>[];
    for (final k in keys) {
      final ro = k.currentContext?.findRenderObject();
      if (ro is! RenderBox || !ro.hasSize) continue;
      final offset = PostSnap.scrollOffsetOf(ro);
      if (offset == null) continue;
      posts.add((top: offset - pixels, height: ro.size.height));
    }
    final t = PostSnap.decide(
        pixels: pixels, velocity: velocity, naturalEnd: naturalEnd,
        posts: posts, anchor: 0, vh: vp.size.height,
        clearSwipe: speed.isClearSwipe);
    if (t == null) return null;
    final pos = controller.position;
    target = t.clamp(pos.minScrollExtent, pos.maxScrollExtent);
    return target;
  }

  bool listNotification(ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is ScrollStartNotification && n.dragDetails != null) {
      dragActive = true;
      speed.reset();
      target = null;
    } else if (n is ScrollUpdateNotification) {
      if (n.dragDetails != null) speed.add(n.dragDetails!);
    } else if (n is ScrollEndNotification) {
      target = null;
    }
    return false;
  }

  // explorer.dart's second-swipe state.
  int downSwipes = 0;
  double dragNet = 0;
  bool dragOpen = false;
  bool dragMayReveal = true;
  static const double swipeCountSlop = 8;

  void closeDrag() {
    if (!dragOpen) return;
    dragOpen = false;
    if (dragNet <= -swipeCountSlop) {
      downSwipes++;
    } else if (dragNet >= swipeCountSlop) {
      downSwipes = 0;
    }
  }

  /// explorer.dart's rule: the finger moves the chrome in both directions
  /// (consume + offset correction); anything without drag
  /// details only finishes a part-way bar to the nearer end. With the bars
  /// fully hidden the first downward drag only scrolls and the next one
  /// reveals; an upward drag
  /// starts the count again.
  bool shellNotification(ScrollNotification n) {
    if (n is ScrollStartNotification) {
      if (n.dragDetails != null) {
        closeDrag();
        dragOpen = true;
        dragNet = 0;
        dragMayReveal = chrome.value > 0.0 || downSwipes >= 1;
      }
    } else if (n is ScrollUpdateNotification) {
      final delta = n.scrollDelta ?? 0;
      if (n.dragDetails == null) {
        closeDrag();
        finish();
      } else if (delta < 0 && !dragMayReveal) {
        dragNet += delta;
      } else if (delta != 0 && !n.metrics.outOfRange) {
        dragNet += delta;
        final shown = chrome.value;
        final consumed = delta > 0
            ? math.min(delta, shown * kToolbarHeight)
            : -math.min(-delta, (1 - shown) * kToolbarHeight);
        final pos = Scrollable.maybeOf(n.context!)?.position;
        if (consumed != 0 && pos != null) {
          final corrected = pos.pixels - consumed;
          if (corrected >= pos.minScrollExtent &&
              corrected <= pos.maxScrollExtent) {
            chrome.value = shown - consumed / kToolbarHeight;
            // ignore: invalid_use_of_protected_member
            pos.forcePixels(corrected);
          }
        }
      }
    } else if (n is ScrollEndNotification) {
      closeDrag();
      if (n.metrics.pixels <= 0) {
        if (chrome.value < 1) chrome.forward();
      } else {
        finish();
      }
    }
    return false;
  }

  void finish() {
    final v = chrome.value;
    if (v <= 0 || v >= 1 || chrome.isAnimating) return;
    if (v >= 0.5) {
      chrome.forward();
    } else {
      chrome.reverse();
    }
  }

  @override
  void dispose() {
    chrome.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: shellNotification,
      child: AnimatedBuilder(
        animation: chrome,
        builder: (context, child) => Padding(
          padding: EdgeInsets.only(
              top: kToolbarHeight * chrome.value,
              bottom: 56 * chrome.value),
          child: child,
        ),
        child: NotificationListener<ScrollNotification>(
          onNotification: listNotification,
          child: CustomScrollView(
            key: viewportKey,
            controller: controller,
            physics: PostSnapPhysics(
              resolve: resolve,
              parent: const AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              SliverList.builder(
                itemCount: heights.length,
                itemBuilder: (_, i) => SizedBox(
                  key: keys[i],
                  height: heights[i],
                  child: i == 0
                      ? const SizedBox.expand(key: ValueKey('list'))
                      : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
