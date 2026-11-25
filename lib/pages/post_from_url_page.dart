import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:publicos_core/publicos_core.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:publicos_client/components/feeds/go_to_feed.dart';
import 'package:publicos_client/components/feeds/post_card.dart'
    show PostLayoutMode;
import 'package:publicos_client/components/feeds/post_detail_page.dart';
import 'package:publicos_client/components/phigital_loading_widget.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/theme/glass_theme.dart';
import 'package:publicos_client/utils/post_links.dart';

/// The `/post?url=` route: a post opened by its address.
///
/// Two callers. A social notification's tap passes the permalink alone: the
/// post is fetched from the URL's own host and shown, and back leaves. A route
/// so a cold-start tap can be parked until the account is selected.
///
/// A share link may also carry the feed an outside post lives in ([feed]) and
/// the tab it was found on ([foundAt] + [tabKey]). The post shows at once;
/// while the user reads, the tab and the feed are checked, and the first that
/// passes is slipped in UNDER this page ([_placeUnder]): the channel on the
/// profile when the tab still lists this feed, else the plain feed view when
/// the feed answered. Back is then an ordinary pop (the post leaves to the
/// right, the edge swipe works), onto exactly what a post opened from that feed
/// would leave behind. Nothing passed yet, or nothing passes: the screen the
/// user came from is still what is under it. An outside post that is gone from
/// its feed opens the article's own page in the in-app browser view, and this
/// page leaves the same way.
class PostFromUrlPage extends StatefulWidget {
  final String url;
  final String? feed;
  final String? foundAt;
  final String? tabKey;
  final bool ladder;

  const PostFromUrlPage({
    super.key,
    required this.url,
    this.feed,
    this.foundAt,
    this.tabKey,
    this.ladder = false,
  });

  @override
  State<PostFromUrlPage> createState() => _PostFromUrlPageState();
}

class _PostFromUrlPageState extends State<PostFromUrlPage> {
  Post? _post;
  bool _failed = false;
  ({PostLayoutMode layout, double title, double desc})? _prefs;

  // The ladder (share links only).
  Future<RefreshedFeedList>? _feedRead;
  Future<void>? _checks;
  Record? _tab; // the found-at tab, once verified
  bool _feedOk = false;
  String? _feedTitle;
  bool _placed = false;

  /// The address without a `#comment-<uid>` fragment.
  String get _url => widget.url.split('#').first;

  bool get _outside => postRefOf(_url) == null;

  /// The feed the post lives in: its channel for one of ours, the link's
  /// `feed` for an outside post.
  String? get _feedUrl {
    final base = channelBaseOf(_url);
    if (base != null) return '$base/json';
    final feed = widget.feed;
    return feed == null || feed.isEmpty ? null : feed;
  }

  @override
  void initState() {
    super.initState();
    final feedUrl = _feedUrl;
    if (widget.ladder && feedUrl != null) {
      // One read serves both: "does the feed answer" and, for an outside
      // post, "where is the item". Ours only needs the answer.
      _feedRead = PublicOSFeedLists.fetchPostsForFeed(
        feedUrl,
        limit: _outside ? null : 1,
      );
      _checks = _check(feedUrl);
    }
    _load();
  }

  Future<void> _load() async {
    Post? p;
    try {
      if (!_outside) {
        p = await fetchPostFromUrl(_url);
      } else if (_feedRead != null) {
        final feed = await _feedRead!;
        for (final item in feed.posts) {
          if (item.url == _url || item.externalUrl == _url) {
            p = item;
            break;
          }
        }
      }
    } catch (_) {}
    // The reader's layout + text sizes (F13): the page has no list behind
    // it to pass them down.
    final prefs = p == null ? null : await readerPostSettings();
    if (!mounted) return;
    setState(() {
      _post = p == null ? null : _stamp(p);
      _prefs = prefs;
      _failed = p == null;
    });
    if (p == null && _outside && widget.ladder) _openArticle();
  }

  /// The two checks behind the post. Never throws.
  Future<void> _check(String feedUrl) async {
    final at = widget.foundAt;
    final key = widget.tabKey;
    final tabRead = at != null && at.isNotEmpty && key != null && key.isNotEmpty
        ? verifiedFeedTab(at, key, _outside ? feedUrl : _url)
        : Future<Record?>.value(null);
    final feedOk = _feedRead!.then((_) => true, onError: (_) => false);

    final tab = await tabRead;
    String? title = (tab?.metadata['name'] as String?)?.trim();
    if ((title == null || title.isEmpty) && !_outside) {
      try {
        title = await feedTitleFor(_url, null);
      } catch (_) {}
    }
    final ok = await feedOk;
    if (!mounted) return;
    setState(() {
      _tab = tab;
      _feedOk = ok;
      _feedTitle = title == null || title.isEmpty ? null : title;
      final post = _post;
      if (post != null) _post = _stamp(post);
    });
    _placeUnder();
  }

  /// Slip the page back should land on in UNDER this one.
  ///
  /// go_router has no "insert below", so the page stack is rebuilt by hand:
  /// this page's match (and anything pushed over it) comes off, the new page
  /// goes on, and the SAME match objects go back on top. Their page keys are
  /// unchanged, so the Navigator keeps their state and nothing on screen
  /// moves. `router.push` builds on `routerDelegate.currentConfiguration`,
  /// which is what `setNewRoutePath` sets. HACK over go_router 14 internals
  /// (`RouteMatchList.push/remove`, `ImperativeRouteMatch`): re-check on a
  /// go_router upgrade. Any surprise leaves the stack as it was, and back
  /// returns to the screen the user came from.
  void _placeUnder() {
    if (_placed || !mounted) return;
    final feedUrl = _feedUrl;
    String? location;
    Object? extra;
    if (_tab != null) {
      location = '/publicosAddress/${widget.foundAt}/tab/${widget.tabKey}';
      extra = _tab;
    } else if (_feedOk && feedUrl != null) {
      location = Uri(path: '/feed', queryParameters: {
        'url': feedUrl,
        if (_feedTitle != null) 'title': _feedTitle!,
      }).toString();
    }
    if (location == null) return;
    try {
      final router = GoRouter.of(context);
      final myKey = GoRouterState.of(context).pageKey;
      final delegate = router.routerDelegate;
      var list = delegate.currentConfiguration;
      final all = list.matches;
      final at = all.indexWhere(
          (m) => m is ImperativeRouteMatch && m.pageKey == myKey);
      if (at < 0) return;
      final above = all.sublist(at);
      if (above.any((m) => m is! ImperativeRouteMatch)) return;
      final under =
          router.configuration.findMatch(Uri.parse(location), extra: extra);
      if (under.isError) return;
      for (final m in above.reversed) {
        list = list.remove(m);
      }
      list = list.push(ImperativeRouteMatch(
        pageKey: ValueKey<String>('under-${myKey.value}'),
        matches: under,
        completer: Completer<Object?>(),
      ));
      for (final m in above) {
        list = list.push(m as ImperativeRouteMatch);
      }
      _placed = true;
      delegate.setNewRoutePath(list);
    } catch (e) {
      debugPrint('PostFromUrlPage: could not place $location under: $e');
    }
  }

  /// [post] as a share link shows it: the via only when the tab verified.
  Post _stamp(Post post) {
    if (!widget.ladder) return post;
    final base = post.copyWith(feedUrl: _feedUrl, feedTitle: _feedTitle);
    return _tab != null
        ? base.copyWith(
            feedFoundAtAccountAddress: widget.foundAt,
            feedRecordKey: widget.tabKey,
          )
        : base.copyWith(clearFeedFoundAt: true);
  }

  /// An outside post that is no longer in its feed: its own page, in the
  /// in-app browser view. Whatever the checks say is what the user finds
  /// when they close it.
  Future<void> _openArticle() async {
    final uri = Uri.tryParse(_url);
    if (uri != null) {
      try {
        final mode = await supportsLaunchMode(LaunchMode.inAppBrowserView)
            ? LaunchMode.inAppBrowserView
            : LaunchMode.externalApplication;
        await launchUrl(uri, mode: mode);
      } catch (_) {}
    }
    // The checks have placed the channel or the feed under this page by
    // now, when there is one; leaving shows it.
    await _checks;
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final post = _post;
    if (post != null) {
      final prefs = _prefs;
      return PostDetailPage(
        post: post,
        layoutMode: prefs?.layout ?? PostLayoutMode.compact,
        titleTextSize: prefs?.title ?? 16.0,
        descriptionTextSize: prefs?.desc ?? 14.0,
      );
    }
    final tokens = GlassTokens.of(context);
    return Scaffold(
      backgroundColor: tokens.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: tokens.starkWhite),
      ),
      body: Center(
        child: _failed
            ? Text(
                context.l10n.notificationsScreenPostUnavailable,
                style: TextStyle(color: tokens.textDim, fontSize: 14),
              )
            : const PhigitalLoadingWidget(size: 28, showShadows: false),
      ),
    );
  }
}
