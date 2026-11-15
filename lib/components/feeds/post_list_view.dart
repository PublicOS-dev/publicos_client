// The post-list RENDERER.
//
// One widget for every surface that shows a stream of posts. It receives
// posts and callbacks and owns what is about posts ON SCREEN: the scroll
// viewport, snapping (mobile only), one-video-at-a-time
// playback, the PostCard layout, the "New posts" chip, the tail loader and
// the empty content. It knows nothing about where posts come from — no fetch,
// no DB, no gate. Whole-view screens (loader, gated, gone, error) belong to
// PostSurface, horizontal to this widget, never inside it.
//
// Snapping and playback are the same measurement with two consumers: where
// each post sits in the viewport right now. That is why both live here.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:publicos_core/publicos_core.dart';
import 'package:publicos_client/widgets/post_playback_scope.dart';
import 'package:publicos_client/components/pixel_rain_loading_widget.dart';
import 'package:publicos_client/components/feeds/feed_favicon.dart';
import 'package:publicos_client/components/feeds/feeds_settings_sheet.dart'
    show loadSwipeSnapWindow;
import 'package:publicos_client/components/feeds/post_card.dart';
import 'package:publicos_client/components/feeds/post_snap_physics.dart';
import 'package:publicos_client/components/glass_contact_icon.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/providers/theme_provider.dart';
import 'package:publicos_client/theme/glass_theme.dart';
import 'package:publicos_client/widgets/shell_chrome_scope.dart';

/// A post's identity on a list: the bookmark key, the card key and the snap
/// measuring key all use it. Position never identifies a post — a refresh
/// that prepends one would slide every card's transient state onto its
/// neighbour.
String postIdentityKey(Post post) {
  if (post.uid.isNotEmpty) return '${post.uid}|${post.feedUrl ?? ''}';
  return '${post.title}|${post.feedUrl ?? ''}';
}

/// Posts that arrived behind a reader and are held, not injected: the
/// "New posts" offer. [count] is the source's number; [posts] draw the faces.
class HeldPosts {
  final int count;
  final List<Post> posts;
  const HeldPosts({required this.count, required this.posts});
}

/// What a source contributes to ONE card. Everything else on PostCard is the
/// renderer's (key, theme, contacts, text sizes, layout) or the surface's
/// (bookmarked state + toggle).
class PostHooks {
  final bool showFeedContext;
  final bool showGoToFeed;
  final bool showVoting;
  final void Function(int value)? onVote;
  final void Function(String feedUrl)? onMuteChannel;
  final void Function(String feedUrl)? onRemoveFeedFromList;
  final bool isUnavailable;
  final VoidCallback? onRefreshRequested;
  final VoidCallback? onDetailOpened;
  final VoidCallback? onPostUpdated;
  final VoidCallback? onPostDeleted;

  /// A line the source puts ABOVE the card (Explore's "#3 · 12 readers").
  /// Scrolls, snaps and keys with the card as one item.
  final Widget? above;

  const PostHooks({
    this.showFeedContext = false,
    this.showGoToFeed = true,
    this.showVoting = false,
    this.onVote,
    this.onMuteChannel,
    this.onRemoveFeedFromList,
    this.isUnavailable = false,
    this.onRefreshRequested,
    this.onDetailOpened,
    this.onPostUpdated,
    this.onPostDeleted,
    this.above,
  });
}

/// The "nothing here" message a source puts under the chrome: an icon, a
/// headline and a subline, placed in the scroll view so the header and the
/// pinned bar stay on screen (never a blank screen).
class PostListEmptyContent extends StatelessWidget {
  final IconData icon;
  final String headline;
  final String subline;

  const PostListEmptyContent({
    super.key,
    required this.icon,
    required this.headline,
    required this.subline,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 56, 32, 32),
      child: Column(
        children: [
          Icon(icon, size: 56, color: tokens.textDim),
          const SizedBox(height: 14),
          Text(
            headline,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              color: tokens.starkWhite,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subline,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: tokens.textDim, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class PostListView extends StatefulWidget {
  final List<Post> posts;
  final Map<String, Contact> contacts;
  final bool awaitingContacts;

  /// Scroll-away items above the posts, in order (a list's locked-feeds
  /// banner, then the channel header). Empty for a surface with no chrome.
  final List<Widget> leading;

  /// The item that scrolls up with [leading] and then sticks (the sort bar).
  /// The renderer backs it and keys it: its bottom edge is the snap's header
  /// line.
  final Widget? pinned;

  /// Bottom-right action (the compose button). The renderer makes it follow
  /// the home shell's bottom nav.
  final Widget? floatingAction;

  final HeldPosts? held;
  final VoidCallback? onApplyHeld;

  /// A host with a header to dock the "N new" chip in (the feeds view):
  /// after 2 s the floating chip fades and this gets the compact chip to
  /// show there, then null when the offer is gone. Null = always float.
  final ValueChanged<Widget?>? onHeldDocked;

  final bool loadingMore;
  final bool canLoadMore;
  final VoidCallback? onLoadMore;
  final Future<void> Function() onRefresh;

  final PostHooks Function(BuildContext context, Post post) hooksFor;
  final bool Function(Post post) isBookmarked;
  final void Function(Post post) onBookmarkToggled;

  /// What to show under the chrome when there are no posts. Built by the
  /// source (it knows what "nothing here" means for it); usually a
  /// [PostListEmptyContent].
  final Widget empty;

  final double titleTextSize;
  final double descriptionTextSize;
  final int? bodyMaxChars;
  final PostLayoutMode layoutMode;

  final ScrollController scrollController;

  /// Extra top inset applied INSIDE the scroll view. The browser's channel
  /// tab passes its expanded address-bar overhang so the list starts below
  /// the expanded header and its scroll drives the header collapse 1:1.
  final double topInset;
  final Color? color;

  const PostListView({
    super.key,
    required this.posts,
    required this.contacts,
    required this.awaitingContacts,
    this.leading = const [],
    this.pinned,
    this.floatingAction,
    this.held,
    this.onApplyHeld,
    this.onHeldDocked,
    this.loadingMore = false,
    this.canLoadMore = false,
    this.onLoadMore,
    required this.onRefresh,
    required this.hooksFor,
    required this.isBookmarked,
    required this.onBookmarkToggled,
    required this.empty,
    required this.titleTextSize,
    required this.descriptionTextSize,
    this.bodyMaxChars,
    required this.layoutMode,
    required this.scrollController,
    this.topInset = 0,
    this.color,
  });

  @override
  State<PostListView> createState() => _PostListViewState();
}

class _PostListViewState extends State<PostListView> {
  // The "N new" chip's dock. With a host that docks it
  // ([PostListView.onHeldDocked]) the floating chip shows for [_kFloatFor],
  // then fades and the host shows the compact chip in its header; with none
  // (bookmarks, a browser tab, the feed reader) it keeps floating.
  static const Duration _kFloatFor = Duration(seconds: 2);
  Timer? _dockTimer;
  bool _docked = false;
  bool get _showFloat => widget.onHeldDocked == null || !_docked;

  void _syncHeld(HeldPosts? old) {
    if (widget.onHeldDocked == null) return;
    final held = widget.held;
    if (held == null) {
      _dockTimer?.cancel();
      _dockTimer = null;
      if (_docked) {
        _docked = false;
        _reportDock(clear: true);
      }
      return;
    }
    if (_docked) {
      // Still docked: a new batch only refreshes the header's copy.
      if (!identical(old, held)) _reportDock();
      return;
    }
    if (_dockTimer == null) {
      _dockTimer = Timer(_kFloatFor, () {
        _dockTimer = null;
        if (!mounted || widget.held == null) return;
        setState(() => _docked = true);
        _reportDock();
      });
    }
  }

  /// Post-frame: the host's setState must not land inside our build.
  void _reportDock({bool clear = false}) {
    final cb = widget.onHeldDocked;
    if (cb == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (clear) {
        cb(null);
        return;
      }
      if (!mounted || widget.held == null || !_docked) return;
      cb(_buildNewPostsChip(GlassTokens.of(context), compact: true));
    });
  }
  /// Picks the one inline video that plays on this list.
  final PostPlaybackController _playback = PostPlaybackController();

  @override
  void initState() {
    super.initState();
    _syncHeld(null);
    widget.scrollController.addListener(_onScroll);
    if (PostSnapPhysics.enabled) loadSwipeSnapWindow();
  }

  @override
  void didUpdateWidget(PostListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncHeld(oldWidget.held);
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController.removeListener(_onScroll);
      widget.scrollController.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    _dockTimer?.cancel();
    // Leaving while docked: take the chip out of the host's header.
    if (_docked) {
      final cb = widget.onHeldDocked;
      WidgetsBinding.instance.addPostFrameCallback((_) => cb?.call(null));
    }
    widget.scrollController.removeListener(_onScroll);
    _pastSecond.dispose();
    _playback.dispose();
    super.dispose();
  }

  /// Posts safe to render: drops any whose `createdAt` is in the future.
  /// A future date renders as "-Nd" via [Post.formattedDate]
  /// (post.dart `formattedDate` — `now.difference(createdAt)` goes negative),
  /// which is a misconfigured / future-dated post. Filtered here at render so
  /// every source and every page is covered in one place.
  List<Post> get _visiblePosts {
    final now = DateTime.now();
    // One card per identity: the snap key is a GlobalKey per identity, and
    // two rows sharing one corrupts the element tree (the framework's
    // "_elements.contains(element)" assertion while scrolling).
    final seen = <String>{};
    return [
      for (final p in widget.posts)
        if (!p.createdAt.isAfter(now) && seen.add(postIdentityKey(p))) p,
    ];
  }

  // -----------------------------------------------------------------------
  // LOAD MORE — the renderer owns the viewport, so it fires the threshold
  // -----------------------------------------------------------------------

  // -----------------------------------------------------------------------
  // BACK TO TOP: once the reader is past the second post, a small animated
  // button above the "+" takes the list back to the top.
  // -----------------------------------------------------------------------

  /// True once the post on the header line is the third or a later one.
  final ValueNotifier<bool> _pastSecond = ValueNotifier<bool>(false);
  bool _pastCheckQueued = false;

  /// Measured after the frame, never inside the scroll callback: a scroll
  /// notification can arrive inside layout.
  void _queuePastSecondCheck() {
    if (_pastCheckQueued) return;
    _pastCheckQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pastCheckQueued = false;
      if (!mounted || !widget.scrollController.hasClients) return;
      final viewport = _viewportKey.currentContext?.findRenderObject();
      if (viewport is! RenderBox || !viewport.hasSize) return;
      final anchor = _anchorIn(viewport);
      final pixels = widget.scrollController.position.pixels;
      final posts = _visiblePosts;
      for (var i = 0; i < posts.length; i++) {
        final ro = _snapKeys[postIdentityKey(posts[i])]
            ?.currentContext
            ?.findRenderObject();
        if (ro is! RenderBox || !ro.attached || !ro.hasSize) continue;
        final offset = PostSnap.scrollOffsetOf(ro);
        if (offset == null) continue;
        // The first laid-out post whose bottom is past the line covers it.
        if (offset - pixels + ro.size.height > anchor + PostSnap.slack) {
          _pastSecond.value = i >= 2;
          return;
        }
      }
    });
  }

  void _backToTop() {
    final c = widget.scrollController;
    if (!c.hasClients) return;
    final pos = c.position;
    // From deep in the list, start three screens out: a short run that does
    // not build every post on the way.
    final near = pos.minScrollExtent + pos.viewportDimension * 3;
    if (pos.pixels > near) c.jumpTo(near);
    c.animateTo(
      pos.minScrollExtent,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  /// The small button, above the "+" (which is 56 px, 16 px from the
  /// corner): smaller, with the same 22 px icon and the same fill. It grows in
  /// with a small bounce and shrinks out, and leaves with the bottom nav
  /// like the "+".
  Widget _buildBackToTop(GlassTokens tokens) {
    return Positioned(
      // 36 px, centred over the "+":
      // 16 + (56 - 36) / 2.
      right: 26,
      bottom: 16 + 56 + 10,
      child: ShellChromeFollower(
        height: 36,
        bottomMargin: 16 + 56 + 10,
        child: ValueListenableBuilder<bool>(
          valueListenable: _pastSecond,
          builder: (context, past, child) => IgnorePointer(
            ignoring: !past,
            child: AnimatedSlide(
              offset: past ? Offset.zero : const Offset(0, 1.2),
              duration: const Duration(milliseconds: 320),
              curve: past ? Curves.easeOutBack : Curves.easeInCubic,
              child: AnimatedScale(
                scale: past ? 1 : 0,
                duration: const Duration(milliseconds: 320),
                curve: past ? Curves.easeOutBack : Curves.easeInCubic,
                child: child,
              ),
            ),
          ),
          child: Material(
            color: Color.alphaBlend(tokens.glassFill, tokens.background),
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _backToTop,
              child: SizedBox(
                width: 36,
                height: 36,
                child: Icon(
                  Icons.keyboard_arrow_up_rounded,
                  size: 22,
                  color: tokens.starkWhite,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _onScroll() {
    _queuePastSecondCheck();
    if (!widget.canLoadMore || widget.loadingMore) return;
    final controller = widget.scrollController;
    if (!controller.hasClients) return;
    final maxScroll = controller.position.maxScrollExtent;
    if (maxScroll <= 0) return;
    if (controller.offset >= maxScroll * 0.8) {
      widget.onLoadMore?.call();
    }
  }

  // -----------------------------------------------------------------------
  // SNAP (mobile only): post tops ease onto the header
  // line when they rest close to it; a clear swipe moves one post.
  // -----------------------------------------------------------------------

  final _viewportKey = GlobalKey();
  final _sortBarKey = GlobalKey();

  /// The pinned sort bar's height as last laid out (0 without one), and the
  /// height a post has under it (see `_buildList`).
  double _sortBarHeight = 0;
  double? _postViewport;
  double? _listHeight;
  double? _listWidth;

  void _measureSortBar() {
    if (!mounted) return;
    final bar = _sortBarKey.currentContext?.findRenderObject();
    final h = bar is RenderBox && bar.hasSize ? bar.size.height : 0.0;
    if (h != _sortBarHeight) setState(() => _sortBarHeight = h);
  }
  final Map<String, GlobalKey> _snapKeys = {};

  /// The offset a physics snap is heading to. Held until the scroll ends so a
  /// relayout mid-flight (which re-asks the physics) can't move a second post.
  double? _snapTarget;

  /// True from a finger drag until its scroll ends: only the user's own
  /// scrolls snap, never scroll-to-top or a programmatic jump.
  bool _userScroll = false;

  /// True while the finger is on the list. The physics is only answered at
  /// the moment of release: a fling restarted by a relayout mid-flight asks
  /// again, and must keep the platform's fling.
  bool _dragActive = false;

  /// The finger's recent speed, for flicks too short to count as a fling.
  final _dragSpeed = DragSpeed();

  GlobalKey _snapKeyFor(Post post) =>
      _snapKeys.putIfAbsent(postIdentityKey(post), () => GlobalKey());

  /// The header line, in viewport coordinates: the pinned sort bar's bottom
  /// edge when there is one, else the viewport top (which already sits under
  /// the feed header, or under the browser's collapsed address strip).
  double _anchorIn(RenderBox viewport) {
    final bar = _sortBarKey.currentContext?.findRenderObject();
    if (bar is RenderBox && bar.attached && bar.hasSize) {
      final top = bar.localToGlobal(Offset.zero, ancestor: viewport).dy;
      return (top + bar.size.height).clamp(0.0, viewport.size.height);
    }
    return 0;
  }

  /// Every laid-out post, top to bottom, as (top in viewport, height). The
  /// top comes from the post's layout offset minus the LIVE scroll offset
  /// ([PostSnap.scrollOffsetOf] explains why not `localToGlobal`).
  List<({double top, double height})> _laidOutPosts(RenderBox viewport) {
    final out = <({double top, double height})>[];
    final pixels = widget.scrollController.position.pixels;
    for (final post in _visiblePosts) {
      final ro =
          _snapKeys[postIdentityKey(post)]?.currentContext?.findRenderObject();
      if (ro is! RenderBox || !ro.attached || !ro.hasSize) continue;
      final offset = PostSnap.scrollOffsetOf(ro);
      if (offset == null) continue;
      out.add((top: offset - pixels, height: ro.size.height));
    }
    return out;
  }

  /// The physics' question at the moment the finger lifts: where should the
  /// list settle? The rules live in [PostSnap.decide]; this only measures.
  double? _resolveSnap(double pixels, double velocity, double naturalEnd,
      {required bool inRange}) {
    if (_snapTarget != null) return _snapTarget;
    // Decide ONCE, at release. Later asks (a relayout restarting the motion,
    // possibly mid-layout) keep whatever motion is running; with no arm and
    // no held target they get nothing, so a content-size change at rest
    // never starts a motion.
    if (!_dragActive) return null;
    _dragActive = false;
    // Swipe to snap OFF: regular scrolling. Checked AFTER consuming the arm,
    // so the one-decision-per-release rule holds either way.
    if (!PostSnap.snapOn) return null;
    // The release consumed the arm. An overscroll release (pull-to-refresh,
    // the edge bounce) decides nothing: the parent physics owns it.
    if (!inRange) return null;
    if (velocity.abs() < PostSnap.swipeVelocity) {
      final finger = _dragSpeed.pxPerSecond;
      if (finger.abs() >= PostSnap.swipeVelocity) velocity = finger;
    }
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return null;
    final vh = viewport.size.height;
    final anchor = _anchorIn(viewport);
    final target = PostSnap.decide(
      pixels: pixels,
      velocity: velocity,
      naturalEnd: naturalEnd,
      posts: _laidOutPosts(viewport),
      anchor: anchor,
      vh: vh,
      clearSwipe: _dragSpeed.isClearSwipe,
    );
    if (target == null) return null;
    final pos = widget.scrollController.position;
    _snapTarget =
        target.clamp(pos.minScrollExtent, pos.maxScrollExtent).toDouble();
    // [SNAP] tagged logs: pair with the "landed" line to see how far off the
    // edge a snap ends.
    debugPrint('[SNAP] resolve v=${velocity.toStringAsFixed(0)} '
        'held=${_dragSpeed.held.inMilliseconds}ms '
        'px=${pixels.toStringAsFixed(1)} natural=${naturalEnd.toStringAsFixed(1)} '
        'anchor=${anchor.toStringAsFixed(1)} vh=${vh.toStringAsFixed(0)} '
        'target=${_snapTarget!.toStringAsFixed(1)}');
    return _snapTarget;
  }

  bool _onSnapNotification(ScrollNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _userScroll = true;
      _dragActive = true;
      _dragSpeed.reset();
      _snapTarget = null;
    } else if (n is ScrollUpdateNotification) {
      final d = n.dragDetails;
      if (d != null) _dragSpeed.add(d);
    } else if (n is ScrollEndNotification) {
      final hadTarget = _snapTarget != null;
      _snapTarget = null;
      if (!_userScroll) return false;
      _userScroll = false;
      if (hadTarget) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _settleLanding());
      }
    }
    return false;
  }

  /// [SNAP] where the nearest post top ended up relative to the line.
  double? _logLanding() {
    if (!mounted || !widget.scrollController.hasClients) return null;
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return null;
    final anchor = _anchorIn(viewport);
    double? off;
    for (final p in _laidOutPosts(viewport)) {
      final d = p.top - anchor;
      if (off == null || d.abs() < off.abs()) off = d;
    }
    debugPrint('[SNAP] landed px=${widget.scrollController.position.pixels.toStringAsFixed(1)} '
        'anchor=${anchor.toStringAsFixed(1)} nearestTopOff=${off?.toStringAsFixed(1)}');
    return off;
  }

  /// A snap that landed off the line because the posts changed height while
  /// it was in flight (a hero sized late, the bars hiding) eases the rest of
  /// the way onto the nearest post top, so the snap and the layout always
  /// agree. Not a user scroll, so it does not report a landing itself.
  void _settleLanding() {
    final off = _logLanding();
    if (off == null || off.abs() < 1) return;
    // The very top is a landing of its own (a flick down from the first
    // post, PostSnap.decide): the first post sits below the line there by
    // the height of the rows above it, and that is not a miss. Without this
    // the settle would pull the list straight back onto the first post.
    if (widget.scrollController.position.pixels <=
        widget.scrollController.position.minScrollExtent) {
      return;
    }
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return;
    // Further than this and it was not a near miss: leave it alone.
    if (off.abs() > viewport.size.height * 0.4) return;
    final pos = widget.scrollController.position;
    final to = (pos.pixels + off)
        .clamp(pos.minScrollExtent, pos.maxScrollExtent)
        .toDouble();
    if ((to - pos.pixels).abs() < 1) return;
    debugPrint('[SNAP] settle by ${off.toStringAsFixed(1)}');
    widget.scrollController.animateTo(
      to,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
    );
  }

  // -----------------------------------------------------------------------
  // BUILD
  // -----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // One inline video at a time on this list; the scope also feeds the
    // list's scroll notifications to the controller (post_playback_scope).
    return PostPlaybackScope.wrap(
      controller: _playback,
      child: Builder(builder: _buildList),
    );
  }

  Widget _buildList(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = GlassTokens.of(context);

    // The "New posts" chip floats OVER the list, never inside it — the whole
    // point is that it must not move the content the reader is looking at.
    final body = Stack(
      children: [
        // The list's own height, less the pinned bar and the bottom inset, is
        // what a post has on screen once its top sits on the header line. A
        // card caps its hero against it (`PostCard.viewportHeight`).
        LayoutBuilder(
          builder: (context, constraints) {
            // The TALLEST the list has been (reset when the width changes,
            // e.g. a rotation): the hosts hide their bars on a scroll down
            // and show them on a scroll up, which resizes this list. The
            // hero is sized for the bars-hidden list, as tall as possible,
            // and never shrinks when the bars come back: a cap that follows
            // the live height would resize every hero on each direction
            // change and move the post tops under a snap in flight. It can
            // still GROW once,
            // when the bars first hide; `_settleLanding` covers that.
            if (constraints.hasBoundedHeight) {
              final h = constraints.maxHeight -
                  MediaQuery.paddingOf(context).bottom;
              if (_listWidth != constraints.maxWidth) {
                _listWidth = constraints.maxWidth;
                _listHeight = h;
              } else if (_listHeight == null || h > _listHeight!) {
                _listHeight = h;
              }
            }
            final listHeight = _listHeight;
            _postViewport =
                listHeight == null ? null : listHeight - _sortBarHeight;
            WidgetsBinding.instance
                .addPostFrameCallback((_) => _measureSortBar());
            return _buildScrollView(theme, tokens);
          },
        ),
        if (widget.held != null)
          Positioned(
            // Below the browser's expanded header overhang — at plain 12 the
            // chip would sit under the address-bar overlay's touch absorber
            // and be unreachable in that layout.
            top: 12 + widget.topInset,
            left: 0,
            right: 0,
            // Fades once the host has docked it in its header.
            child: IgnorePointer(
              ignoring: !_showFloat,
              child: AnimatedOpacity(
                opacity: _showFloat ? 1 : 0,
                duration: const Duration(milliseconds: 220),
                child: Center(child: _buildNewPostsChip(tokens)),
              ),
            ),
          ),
      ],
    );

    final fab = widget.floatingAction;
    if (fab == null) {
      // The host draws the "+" (the Feeds tab): only our small button.
      if (!HostPostButtonScope.of(context)) return body;
      return Stack(children: [body, _buildBackToTop(tokens)]);
    }
    return Stack(
      children: [
        body,
        _buildBackToTop(tokens),
        // 16, matching the Feeds post button.
        // Inside the home shell it leaves with the bottom nav; elsewhere
        // (the Browser's channel tab) the follower is a no-op.
        Positioned(
          right: 16,
          bottom: 16,
          child: ShellChromeFollower(child: fab),
        ),
      ],
    );
  }

  Widget _buildScrollView(ThemeData theme, GlassTokens tokens) {
    // An empty list still renders the scroll view, so the leading chrome and
    // the pinned bar stay on screen and the "no posts" message sits under
    // them (an empty sort result must not blank the screen).
    final posts = _visiblePosts;
    final pinned = widget.pinned;
    final indexByKey = <Key, int>{
      for (var i = 0; i < posts.length; i++) _snapKeyFor(posts[i]): i,
    };

    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      color: widget.color ?? theme.colorScheme.primary,
      // Keep the pull spinner below the browser's expanded header overhang.
      edgeOffset: widget.topInset,
      child: NotificationListener<ScrollNotification>(
        onNotification: PostSnapPhysics.enabled ? _onSnapNotification : null,
        child: CustomScrollView(
          key: _viewportKey,
          controller: widget.scrollController,
          // Pull-to-refresh must work on an empty or short feed too. On mobile
          // the snap physics rides on top.
          physics: PostSnapPhysics.enabled
              ? PostSnapPhysics(
                  resolve: _resolveSnap,
                  parent: const AlwaysScrollableScrollPhysics(),
                )
              : const AlwaysScrollableScrollPhysics(),
          slivers: [
            // The scroll travel the browser's header collapse consumes 1:1 —
            // must be INSIDE the scroll view so content rises with the header.
            if (widget.topInset > 0)
              SliverToBoxAdapter(child: SizedBox(height: widget.topInset)),
            for (final w in widget.leading) SliverToBoxAdapter(child: w),
            if (pinned != null)
              PinnedHeaderSliver(
                // The bar is transparent by design; when pinned it floats over
                // posts, so back it with the app background the top and bottom
                // bars use (not surfaceDeep, a darker black that breaks the
                // look) plus a hairline so it reads as a header edge
                // once stuck.
                child: DecoratedBox(
                  key: _sortBarKey,
                  decoration: BoxDecoration(
                    color: tokens.background.withValues(alpha: 0.95),
                    border: Border(
                      bottom: BorderSide(color: tokens.borderSubtle, width: 1),
                    ),
                  ),
                  child: pinned,
                ),
              ),
            if (posts.isEmpty)
              SliverToBoxAdapter(child: widget.empty)
            else
              SliverList.builder(
                itemCount: posts.length,
                // A post inserted at the top shifts every index; this lets the
                // list find each keyed card at its new index instead of
                // rebuilding by position and moving GlobalKeys between rows
                // mid-frame (which breaks the element tree).
                findChildIndexCallback: (key) => indexByKey[key],
                // The KeyedSubtree is the snap's measuring handle.
                itemBuilder: (context, index) => KeyedSubtree(
                  key: _snapKeyFor(posts[index]),
                  child: _buildPostCard(context, posts[index], theme),
                ),
              ),
            if (widget.loadingMore)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: const Center(
                    child: PixelRainLoadingWidget(
                      size: 18,
                      showShadows: false,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPostCard(BuildContext context, Post post, ThemeData theme) {
    final hooks = widget.hooksFor(context, post);
    final card = PostCard(
      // Identity, not position. Without this the State is reused BY INDEX, so a
      // refresh that prepends a post slides every card's transient state (the
      // optimistic reaction delta, the on-screen translation) onto its
      // neighbour.
      key: ValueKey(postIdentityKey(post)),
      post: post,
      theme: theme,
      resolvedContacts: widget.contacts,
      awaitingContacts: widget.awaitingContacts,
      titleTextSize: widget.titleTextSize,
      descriptionTextSize: widget.descriptionTextSize,
      bodyMaxChars: widget.bodyMaxChars,
      layoutMode: widget.layoutMode,
      viewportHeight: _postViewport,
      isBookmarked: widget.isBookmarked(post),
      onBookmarkToggled: () => widget.onBookmarkToggled(post),
      showVoting: hooks.showVoting,
      onVote: hooks.onVote,
      showFeedContext: hooks.showFeedContext,
      showGoToFeed: hooks.showGoToFeed,
      onMuteChannel: hooks.onMuteChannel,
      onRemoveFeedFromList: hooks.onRemoveFeedFromList,
      isUnavailable: hooks.isUnavailable,
      onRefreshRequested: hooks.onRefreshRequested,
      onDetailOpened: hooks.onDetailOpened,
      onPostUpdated: hooks.onPostUpdated,
      onPostDeleted: hooks.onPostDeleted,
    );
    final above = hooks.above;
    if (above == null) return card;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [above, card],
    );
  }

  // -----------------------------------------------------------------------
  // THE "NEW POSTS" OFFER
  // -----------------------------------------------------------------------

  /// Posts arriving during a refresh are date-sorted, so they belong ABOVE what
  /// the reader is currently looking at. Injecting them would shove the page
  /// down mid-sentence — the classic feed-reader sin, and cache-first makes it
  /// MORE likely because the reader started sooner. So the source holds them,
  /// and this offers them. Tapping applies them and scrolls to the top, so the
  /// reader goes DOWN into what is new instead of hunting for where they were.
  ///
  /// The chip shows WHO is new: the faces of up
  /// to four distinct authors among the held posts, newest first, each drawn
  /// by the post card's own avatar rules ([_newPostFace]), overlapped, then
  /// the count. Glass surface, hairline border, no arrow.
  /// [compact]: the header's copy, smaller and flat (no drop shadow).
  Widget _buildNewPostsChip(GlassTokens tokens, {bool compact = false}) {
    final held = widget.held;
    if (held == null) return const SizedBox.shrink();
    final n = held.count;
    final faces = _newPostFaces(held, tokens);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onApplyHeld,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: compact
              ? EdgeInsets.fromLTRB(faces == null ? 10 : 3, 3, 10, 3)
              : EdgeInsets.fromLTRB(faces == null ? 14 : 6, 6, 14, 6),
          decoration: BoxDecoration(
            color: tokens.surfaceElevated,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: tokens.borderMedium, width: 1),
            boxShadow: compact ? null : [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (faces != null) ...[faces, const SizedBox(width: 8)],
              Text(
                context.l10n.postsListNewCount(n),
                style: TextStyle(
                  color: tokens.starkWhite,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static const double _kNewFace = 22;
  static const double _kNewFaceStride = 15;
  static const int _kNewFacesMax = 4;

  /// The held posts the reader has not seen, newest first: the ones whose
  /// uid is not on screen. The count stays the source's; this only picks faces.
  List<Post> _newPostsIn(HeldPosts held) {
    final shown = {for (final p in widget.posts) p.uid};
    return [
      for (final p in held.posts)
        if (!shown.contains(p.uid)) p,
    ];
  }

  /// Up to four distinct authors' faces, overlapped right over left so the
  /// newest stays in front. Null when nothing is new by uid.
  Widget? _newPostFaces(HeldPosts held, GlassTokens tokens) {
    final seen = <String>{};
    final picked = <Post>[];
    for (final p in _newPostsIn(held)) {
      final key = (p.postAuthorAddress?.isNotEmpty ?? false)
          ? p.postAuthorAddress!.toLowerCase()
          : (p.feedUrl ?? '');
      if (!seen.add(key)) continue;
      picked.add(p);
      if (picked.length == _kNewFacesMax) break;
    }
    if (picked.isEmpty) return null;
    return SizedBox(
      width: _kNewFace + _kNewFaceStride * (picked.length - 1),
      height: _kNewFace,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = picked.length - 1; i >= 0; i--)
            Positioned(
              left: _kNewFaceStride * i,
              child: DecoratedBox(
                // A rim in the chip's own colour so overlapped faces part.
                decoration: BoxDecoration(
                  color: tokens.surfaceElevated,
                  borderRadius: BorderRadius.circular((_kNewFace + 3) * 0.4),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(1.5),
                  child: _newPostFace(picked[i], tokens),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// One author's face at [_kNewFace], the post card's rules in order: the
  /// resolved contact, an identicon of a signed-but-unresolved address, the
  /// feed's favicon when the post has no signed author, the RSS glyph.
  Widget _newPostFace(Post post, GlassTokens tokens) {
    final addr = post.postAuthorAddress;
    if (addr != null && addr.isNotEmpty) {
      final contact = widget.contacts[addr] ??
          widget.contacts.entries
              .where((e) => e.key.toLowerCase() == addr.toLowerCase())
              .map((e) => e.value)
              .firstOrNull;
      return contact != null
          ? GlassContactIcon(contact: contact, size: _kNewFace)
          : GlassContactIcon(address: addr, size: _kNewFace);
    }
    final feedUrl = post.feedUrl;
    if (feedUrl != null && feedUrl.isNotEmpty) {
      return FeedFavicon(
        feedUrl: feedUrl,
        size: _kNewFace,
        cornerRadius: _kNewFace * 0.4,
        faviconFirst: true,
      );
    }
    return Container(
      width: _kNewFace,
      height: _kNewFace,
      decoration: BoxDecoration(
        color: ThemeProvider.amberAccent,
        borderRadius: BorderRadius.circular(_kNewFace * 0.4),
      ),
      child: const Icon(Icons.rss_feed, color: Colors.white, size: 13),
    );
  }
}
