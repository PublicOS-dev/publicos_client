import 'package:publicos_core/publicos_core.dart';
import 'package:flutter/material.dart';
import 'package:publicos_client/components/feeds/header_slot.dart';
import 'package:flutter/services.dart';
import 'package:publicos_client/components/glass_contact_icon.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/components/feeds/feed_favicon.dart';
import 'package:publicos_client/components/feeds/channel_signin_dialogs.dart';
import 'package:publicos_client/components/feeds/feeds_settings_sheet.dart';
import 'package:publicos_client/components/feeds/post_card.dart' show PostLayoutMode;
import 'package:publicos_client/components/pixel_rain_loading_widget.dart';
import 'package:publicos_client/router_helpers.dart';
import 'package:publicos_client/pages/compose_post_page.dart';
import 'package:publicos_client/pages/channel_settings_page.dart';
import 'package:publicos_client/pages/create_channel_page.dart';
import 'package:publicos_client/components/feeds/discover_browser.dart';
import 'package:publicos_client/components/feeds/edit_list_sheet.dart';
import 'package:publicos_client/components/feeds/manage_lists_sheet.dart';
import 'package:publicos_client/components/feeds/list_header_card.dart';
import 'package:publicos_client/components/feeds/feeds_navigation_drawer.dart';
import 'package:publicos_client/components/feeds/bookmarks_view.dart';
import 'package:publicos_client/components/feeds/explore_view.dart';
import 'package:publicos_client/components/feeds/feed_source.dart';
import 'package:publicos_client/components/feeds/posts_list.dart';
import 'package:publicos_client/providers/theme_provider.dart';
import 'package:publicos_client/theme/glass_theme.dart';
import 'package:publicos_client/widgets/content_metrics_listener.dart';
import 'package:publicos_client/widgets/shell_chrome_scope.dart';
import 'package:publicos_client/utils/favicon_utils.dart';
import 'package:zero_cached_image/zero_cached_image.dart';
import 'package:publicos_client/pages/manage_server_page.dart';
import 'package:publicos_client/router.dart';
import 'package:publicos_client/components/pixel_rain_loading_label.dart';
import 'package:flutter/cupertino.dart';
class RssFeedsView extends StatefulWidget {
  final Color color;
  final String searchQuery;

  const RssFeedsView({
    super.key,
    required this.color,
    required this.searchQuery,
  });

  @override
  State<RssFeedsView> createState() => RssFeedsViewState();
}

/// The Feeds header's icon slot: the status bar avatar's size, so the
/// header icon centres under it and the title starts under the account name.
const double _kHeaderIconSlot = 40;

class RssFeedsViewState extends State<RssFeedsView>
    with SingleTickerProviderStateMixin {
  List<Channel> _channels = [];
  List<FeedList> _lists = [];

  // The feeds selection — the single source of truth for "what am I looking
  // at". Holds one of: a [FeedList], a [Channel], a [FeedsView] enum value
  // (discover / bookmarks), or null during the cold-start window before
  // `_loadData` bootstraps a default. The four modes can't desync because
  // there is only one field; the getters below are the content-checks every
  // read site shares, and `_select` is the only writer outside `_loadData`.
  Object? _selected;

  FeedList? get _selectedList {
    final s = _selected;
    return s is FeedList ? s : null;
  }

  Channel? get _selectedChannel {
    final s = _selected;
    return s is Channel ? s : null;
  }

  bool get _isViewingBookmarks => _selected == FeedsView.bookmarks;
  bool get _isViewingDiscover => _selected == FeedsView.discover;
  bool get _isViewingExplore => _selected == FeedsView.explore;

  bool _isLoading = true;

  // Posts-layer loading, reported up from the active PostsList via
  // `onLoadingChanged`. Combined with `_isLoading` (the lists/channels
  // metadata load) into the single spinner overlay in `build`, so a cold start
  // or a selection change shows ONE continuous animation instead of the shell
  // spinner handing off to a freshly-mounted PostsList spinner (which reset the
  // orbit to its start position). Set eagerly wherever we already know a
  // PostsList is about to (re)mount and load, so the overlay never blinks off
  // in the one-frame gap before PostsList reports its own loading.
  bool _postsLoading = false;

  /// Phase 2 of the two-phase feed load is in flight — the cached posts are
  /// ALREADY on screen and the network is revalidating behind them.
  ///
  /// Deliberately NOT folded into `_postsLoading`: that one drives the blocking
  /// spinner ("you have nothing to look at yet"), and once the cache paints
  /// instantly that message is simply false. Refreshing earns a peripheral hint
  /// in the header instead — it must never take the page away from a reader who
  /// is already reading.
  bool _postsRefreshing = false;

  /// The "N new" chip once the list has docked it here.
  Widget? _dockedNewChip;

  /// Bumped when this view's own compose flow saves a post — PostsList sees
  /// the change in didUpdateWidget and re-fetches, applying directly (no
  /// "New posts" chip) so the author sees their post immediately.
  int _postsRefreshTick = 0;

  /// Re-keys the list header so it recounts after a list change.
  /// Who the selected list follows, for the scroll-away card and the inline
  /// header's mini stack. Loaded with the roster and again after the list
  /// was managed; null while loading or when the selection is not a list.
  ListFollowSummary? _listSummary;
  int _listSummaryGen = 0;

  /// The list card is an item of the scroll view (a `SliverToBoxAdapter`
  /// before the posts), so it leaves with the content. True once it has
  /// fully left the top: the inline header then shows the mini stack beside
  /// Manage, and takes it back when the card returns. Position only, never
  /// scroll activity, like `_scrolledUnder`.
  final ValueNotifier<bool> _listCardGone = ValueNotifier<bool>(false);
  final GlobalKey _listCardKey = GlobalKey();

  Future<void> _loadListSummary() async {
    final gen = ++_listSummaryGen;
    final sel = _selected;
    if (sel is! FeedList || sel.isSingle) {
      if (_listSummary != null) setState(() => _listSummary = null);
      return;
    }
    // The roster ranks the tiles: latest posters first.
    final summary = await ListFollowSummary.load(sel.id, roster: _roster);
    if (!mounted || gen != _listSummaryGen) return;
    setState(() => _listSummary = summary);
  }

  final ScrollController _scrollController = ScrollController();

  /// The header's divider shows only once the content has scrolled:
  /// at the top it takes the background's colour. A notifier,
  /// not page state: only the divider listens, the page never rebuilds for
  /// it. Fed through [ContentMetricsListener] by whatever list the body
  /// shows (PostsList, Explore, Bookmarks…), position only, never scroll
  /// activity (a setState from a scroll-start that fires inside layout
  /// bricks the page).
  final ValueNotifier<bool> _scrolledUnder = ValueNotifier<bool>(false);

  void _onContentMetrics(ScrollMetrics m) {
    _scrolledUnder.value = m.extentBefore > 0;
    // The card's own height decides when it is gone; once scrolled out of the
    // viewport it may be unmounted, and then it is gone by definition. Coming
    // back is slower than going: the stack leaves the
    // header only once half the card is showing again, so a small drag near
    // the edge does not flip it.
    final card = _listCardKey.currentContext?.size?.height;
    final before = m.extentBefore;
    if (before <= 0) {
      _listCardGone.value = false;
    } else if (card == null || before >= card) {
      _listCardGone.value = true;
    } else if (before < card / 2) {
      _listCardGone.value = false;
    }
  }

  // Text size settings — read once here so the settings sheet can edit
  // them live; passed down to PostsList as overrides.
  double _titleTextSize = 16.0;
  double _descriptionTextSize = 14.0;
  // Trim-long-posts setting. null = show full; positive int = char budget
  // applied across summary + body in PostCard.
  int? _trimChars;
  // Reading layout — compact (default microblog) or wide (flat-padded body).
  // Lives next to font sizes so the settings sheet edits a single bag.
  PostLayoutMode _layoutMode = PostLayoutMode.compact;

  // Header/drawer-only contact resolution map. Populated by
  // `_loadSingleListMetadata` for the single-flagged via-line. The body
  // (PostsList) keeps its own separate map for post bodies — by design,
  // no coupling.
  Map<String, Contact> _resolvedContacts = {};

  // URLs of channels the user has pinned as router tabs. Mirrors the
  // logic on `ManageServerPage`: each entry is the JSON-feed URL for an
  // owned channel that has a matching `RouterSubtype.channel` record on the
  // user's contact. Used to render the Add-as-Tab toggle in the drawer.
  Set<String> _tabUrls = const <String>{};

  // First feed of each is_single list, keyed by list id. Drives single-row
  // rendering in the drawer + inline header. Populated by _loadData.
  Map<int, ListFeed> _singleFeedByListId = {};

  /// Singles whose channel the owner deleted (their row is in
  /// [_singleFeedByListId] AS STORED, so the header keeps its name + via).
  /// The roster marks the feed gone → "Channel not found".
  Set<int> _goneSingleListIds = {};

  /// Sign-in preference for the current single-feed surface.
  /// Null on multi-feed surfaces AND for feeds whose
  /// server never advertised envelope support — either way, no toggle in the
  /// header. Refreshed after every roster change and load/refresh completion,
  /// because the row is DISCOVERED during a fetch: the first load of a
  /// supporting feed is exactly when it appears.
  ChannelSigninPref? _signinPref;

  /// The RULE's answer for the current single feed — what the key glyph
  /// shows (never the raw column).
  bool _signinEffective = false;

  // Drawer state
  late AnimationController _drawerController;
  OverlayEntry? _drawerEntry;


  String get _selectedItemName {
    switch (_selected) {
      case FeedsView.discover:
        return context.l10n.feedsViewDiscover;
      case FeedsView.bookmarks:
        return context.l10n.feedsViewBookmarks;
      case FeedsView.explore:
        return context.l10n.feedsViewExplore;
      case Channel ch:
        return ch.name;
      case FeedList list:
        return list.name;
      default:
        // Empty — only ever hit in the brief cold-start window before
        // `_loadData` bootstraps a selection. Was 'Channels', which read as
        // a (wrong) concrete selection and visibly flashed before
        // 'Following'; an empty title resolves straight into the real one.
        return '';
    }
  }

  // ── The roster (the HOST derives) ────────────────────────────────────────
  //
  // `_roster` is the resolved List<FeedSource> for the current selection —
  // null while deriving (the unified spinner covers the gap; `_select` clears
  // it synchronously so a stale roster never renders under a new selection).
  // Any mutation that changes what a list contains re-derives by going
  // through `_loadData`, which ends in `_deriveRoster()`.
  List<FeedSource>? _roster;
  int? _rosterListId;
  int _rosterGeneration = 0;

  /// The current SSP server base URL — fallback for channels whose `Channel`
  /// carries no serverAddress. Resolved once per `_loadData` (local DB read).
  String? _defaultServerUrl;

  /// The one feed URL of a single-feed surface (a channel pick or a
  /// single-flagged list), null on multi-feed rosters. The sign-in toggle
  /// only exists where identity attaches to exactly one endpoint.
  String? get _singleRosterUrl {
    final roster = _roster;
    return (roster != null && roster.length == 1) ? roster.first.url : null;
  }

  /// Re-query the sign-in pref for the current surface. Cheap (one PK read),
  /// so it runs after every roster change and load completion; the
  /// stale-guard re-checks the URL after the await so a mid-flight selection
  /// change can't paint another feed's pref.
  Future<void> _refreshSigninPref() async {
    final url = _singleRosterUrl;
    if (url == null) {
      if (_signinPref != null && mounted) {
        setState(() {
          _signinPref = null;
          _signinEffective = false;
        });
      }
      return;
    }
    final pref = await PublicOSChannelSignin.getPref(url);
    final effective =
        pref == null ? false : await PublicOSChannelSignin.shouldSign(url);
    if (!mounted || _singleRosterUrl != url) return;
    setState(() {
      _signinPref = pref;
      _signinEffective = effective;
    });
  }

  /// Derive the roster from the current selection.
  ///
  /// Channel pick → a roster of one (the channel IS its `/json` url — the
  /// Channel object is not needed to load). Single-flagged list → its one
  /// wrapped feed, presented as the feed itself (no listId). Regular list →
  /// `resolveListItems` (stored rows ∪ followed accounts' channels − mutes),
  /// mapped 1:1 into FeedSources, passed with the listId for the verbs.
  Future<void> _deriveRoster() async {
    await _deriveRosterSelection();
    await _refreshSigninPref();
    await _loadListSummary();
  }

  Future<void> _deriveRosterSelection() async {
    final gen = ++_rosterGeneration;
    final selected = _selected;

    if (selected is Channel) {
      final owner = selected.ownerAddress ??
          AppStateNotifier.currentMyContact?.publicosAddress?.eip55With0x ??
          '';
      final server = selected.serverAddress ?? _defaultServerUrl;
      if (owner.isEmpty || server == null || server.isEmpty) {
        setState(() {
          _roster = const [];
          _rosterListId = null;
        });
        return;
      }
      final base = server.endsWith('/')
          ? server.substring(0, server.length - 1)
          : server;
      final url = '$base/api/$owner/channels/${selected.slug}/json';
      // MY CHANNELS: when this channel is a tab
      // on the viewer's own profile, the posts carry that tab as where they
      // were found, so a pin's "Go to feed" lands on it. Same exact-URL match
      // as the drawer's tab indicator, so the two always agree.
      final me = PublicOS.myPublicosAddress;
      String? tabKey;
      if (me != null) {
        try {
          final records =
              await PublicOSContacts.getRecordsByType(RecordType.router);
          for (final r in records) {
            if (r.routerSubtype == RouterSubtype.channel && r.value == url) {
              tabKey = r.key;
              break;
            }
          }
        } catch (_) {}
      }
      if (!mounted || gen != _rosterGeneration) return;
      setState(() {
        _roster = [
          FeedSource(
            url: url,
            title: selected.name,
            foundAtAccountAddress: tabKey != null ? me : null,
            recordKey: tabKey,
          ),
        ];
        _rosterListId = null;
      });
      return;
    }

    if (selected is FeedList) {
      // Single-flagged lists render as the wrapped feed itself — a roster of
      // one with its via, and NO listId (the surface is the feed's own page,
      // not a list).
      if (selected.isSingle) {
        final feed = _singleFeedByListId[selected.id];
        if (feed != null) {
          final foundAtAddr = feed.feedFoundAtAccountAddress;
          setState(() {
            _roster = [
              FeedSource(
                url: feed.feedUrl,
                title: feed.feedTitle,
                foundAtContact: (foundAtAddr != null && foundAtAddr.isNotEmpty)
                    ? _resolvedContacts[foundAtAddr]
                    : null,
                foundAtAccountAddress: foundAtAddr,
                recordKey: feed.feedRecordKey,
                gone: _goneSingleListIds.contains(selected.id),
              ),
            ];
            _rosterListId = null;
          });
          return;
        }
        // Metadata not loaded yet — the resolver below covers it (a single
        // list resolves to its one feed, which is the same roster).
      }
      List<FollowedFeed> followed;
      try {
        followed = await PublicOSFollows.resolveListItems(selected.id);
      } catch (_) {
        followed = const [];
      }
      if (!mounted || gen != _rosterGeneration) return;
      // The single metadata landed while we resolved — it is the authority
      // (it knows a gone channel; the resolver above silently drops it).
      if (selected.isSingle && _singleFeedByListId[selected.id] != null) {
        return _deriveRosterSelection();
      }
      setState(() {
        _roster = followed.map(FeedSource.fromFollowedFeed).toList();
        _rosterListId = selected.isSingle ? null : selected.id;
      });
      return;
    }

    // Bookmarks / Discover / no selection — no post roster.
    setState(() {
      _roster = null;
      _rosterListId = null;
    });
  }

  /// Stable identity for the current source — drives the `ValueKey` so a
  /// selection change rebuilds the PostsList with fresh state.
  String get _sourceKey {
    switch (_selected) {
      case FeedsView.bookmarks:
        return 'bookmarks';
      case FeedsView.explore:
        return 'explore';
      case Channel ch:
        return 'channel-${ch.id}';
      case FeedList list:
        if (list.isSingle && _singleFeedByListId[list.id] != null) {
          return 'single-${list.id}';
        }
        return 'list-${list.id}';
      default:
        return 'none';
    }
  }

  @override
  void initState() {
    super.initState();

    _drawerController = AnimationController(
      duration: const Duration(milliseconds: 240),
      vsync: this,
    );

    _loadData();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final titleSizeRecord =
          await PublicOSSettings.getSetting('rss_feeds_title_text_size');
      final descSizeRecord =
          await PublicOSSettings.getSetting('rss_feeds_description_text_size');
      final trimRecord =
          await PublicOSSettings.getSetting('rss_feeds_trim_chars');
      final layoutRecord =
          await PublicOSSettings.getSetting('rss_feeds_layout_mode');
      if (mounted) {
        setState(() {
          if (titleSizeRecord != null) {
            _titleTextSize = double.parse(titleSizeRecord.value);
          }
          if (descSizeRecord != null) {
            _descriptionTextSize = double.parse(descSizeRecord.value);
          }
          if (trimRecord != null) {
            final parsed = int.tryParse(trimRecord.value);
            _trimChars = (parsed != null && parsed > 0) ? parsed : null;
          }
          if (layoutRecord != null) {
            _layoutMode = parsePostLayoutMode(layoutRecord.value);
          }
        });
      }
    } catch (e) {
      print('Error loading RSS feed settings: $e');
    }
  }

  @override
  void dispose() {
    _scrolledUnder.dispose();
    _listCardGone.dispose();
    _removeDrawerEntry();
    _drawerController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _removeDrawerEntry() {
    _drawerEntry?.remove();
    _drawerEntry = null;
  }

  void _toggleDrawer() {
    if (_drawerEntry != null) {
      _closeDrawer();
    } else {
      _openDrawer();
    }
  }

  void _openDrawer() {
    if (_drawerEntry != null) return;
    _drawerEntry = OverlayEntry(builder: _buildDrawerOverlay);
    Overlay.of(context, rootOverlay: true).insert(_drawerEntry!);
    _drawerController.forward();
  }

  void _closeDrawer() {
    if (_drawerEntry == null) return;
    _drawerController.reverse().then((_) {
      if (!mounted) return;
      _removeDrawerEntry();
    });
  }

  @override
  void didUpdateWidget(RssFeedsView oldWidget) {
    super.didUpdateWidget(oldWidget);
  }

  void showSettingsSheet() {
    showFeedsSettingsSheet(
      context,
      titleSize: _titleTextSize,
      bodySize: _descriptionTextSize,
      trimChars: _trimChars,
      layoutMode: _layoutMode,
      onTitleChanged: (size) => setState(() => _titleTextSize = size),
      onBodyChanged: (size) => setState(() => _descriptionTextSize = size),
      onTrimChanged: (chars) => setState(() => _trimChars = chars),
      onLayoutChanged: (mode) => setState(() => _layoutMode = mode),
      // The very next fetch honours the new posture — the sheet's own rule.
      onAutoSigninChanged: (_) => setState(() => _postsRefreshTick++),
    );
  }

  Future<void> _navigateToServerManagement(String? serverAddress) async {
    // Use the same resolved URL that channels actually use (user selection -> SSP -> custom)
    String? resolvedAddress = serverAddress ?? await PublicOSSsp.getActiveFeedServerUrl();

    if (resolvedAddress == null || !mounted) return;

    final sspInfo = await PublicOSSsp.getSSPServerInfo();
    final isSSP = sspInfo != null && sspInfo.apiUrl == resolvedAddress;
    final label = isSSP ? (sspInfo!.title.isNotEmpty ? sspInfo.title : sspInfo.slug) : resolvedAddress;

    Navigator.push(context, CupertinoPageRoute(
      builder: (_) => ManageServerPage(
        serverUrl: resolvedAddress!,
        serverLabel: label,
        isSSP: isSSP,
        sspSlug: isSSP ? sspInfo!.slug : null,
      ),
    ));
  }

  /// Opens ChannelSettingsPage for a channel the user owns — the one screen
  /// for everything per-channel. Separate from
  /// `_navigateToServerManagement` — that still handles the server-wide
  /// concerns (media quota, channel list, tab router records) via the
  /// drawer's "Manage server" row.
  ///
  /// Pops with `true` when the channel was deleted — we drop the selection
  /// and trigger a reload. For rename/edit it pops with `null` (the page
  /// handles its own in-page refresh), so we just re-pull the channel list
  /// to pick up the new slug/name.
  Future<void> _openManageChannelPage(Channel channel) async {
    final result = await Navigator.of(context).push<bool>(
      CupertinoPageRoute(
        builder: (_) => ChannelSettingsPage(channel: channel),
      ),
    );
    if (!mounted) return;
    if (result == true) {
      // Deleted — drop selection if it's still the one we opened.
      setState(() {
        if (_selectedChannel?.id == channel.id) {
          _selected = null;
        }
      });
    }
    // Refresh either way so renamed channels pick up the new slug/name.
    _loadData(silent: true);
  }

  /// JSON-feed URL for [channel], or null if we can't synthesize it (no
  /// server address on the channel, or the local account isn't loaded
  /// yet). The shape must match `ManageServerPage._channelJsonUrl` so
  /// records written by either path round-trip through the same equality
  /// check.
  String? _channelJsonUrl(Channel channel) {
    final addr = PublicOS.myPublicosAddress;
    final server = channel.serverAddress;
    if (addr == null || server == null) return null;
    return '$server/api/$addr/channels/${channel.slug}/json';
  }

  /// Reads every `RouterSubtype.channel` record on the local contact into
  /// `_tabUrls`. Called from `_loadData()` and after each tab mutation
  /// so the drawer rows can render their isInTabs state from membership
  /// on a synced Set.
  Future<void> _loadExistingTabUrls() async {
    try {
      final records =
          await PublicOSContacts.getRecordsByType(RecordType.router);
      final urls = records
          .where((r) => r.routerSubtype == RouterSubtype.channel)
          .map((r) => r.value)
          .toSet();
      if (mounted) setState(() => _tabUrls = urls);
    } catch (_) {}
  }

  /// Pin [channel] as a router tab by writing an `rss.<slug>` router
  /// record. Mirrors `ManageServerPage._addChannelAsTab`.
  Future<void> _addChannelAsTab(Channel channel) async {
    final url = _channelJsonUrl(channel);
    if (url == null) return;
    final record = Record.asRouter(
      key: 'rss.${channel.slug}',
      routerSubtype: RouterSubtype.channel,
      value: url,
      name: channel.name,
      expiration: DateTime.now().add(const Duration(days: 365)),
    );
    final ok = await PublicOSContacts.setRecord(record);
    if (ok && mounted) await _onTabsChanged();
  }

  /// Remove the router tab pointing at [channel]'s JSON URL. Mirrors
  /// `ManageServerPage._removeChannelFromTabs`.
  Future<void> _removeChannelFromTab(Channel channel) async {
    final url = _channelJsonUrl(channel);
    if (url == null) return;
    try {
      final records =
          await PublicOSContacts.getRecordsByType(RecordType.router);
      final tab = records.firstWhere(
        (r) => r.routerSubtype == RouterSubtype.channel && r.value == url,
        orElse: () => throw StateError('Tab not found'),
      );
      final ok = await PublicOSContacts.deleteRecord(tab.key);
      if (ok && mounted) await _onTabsChanged();
    } catch (_) {
      // Record was already gone — refresh anyway to drop any stale state.
      if (mounted) await _onTabsChanged();
    }
  }

  /// A channel was added to or removed from the profile's tabs: refresh the
  /// drawer's indicators AND re-derive the roster, so an open MY CHANNELS
  /// pick picks up (or drops) its tab right away and a pin made now is right.
  Future<void> _onTabsChanged() async {
    await _loadExistingTabUrls();
    if (mounted && _selected is Channel) await _deriveRoster();
  }

  Future<void> _showCreateChannelPage() async {
    final created = await Navigator.of(context).push<Channel>(
      CupertinoPageRoute(builder: (_) => const CreateChannelPage()),
    );
    if (created != null && mounted) _loadData();
  }

  // The DEFAULT list \u2014 the one onboarding seeds and the empty state
  // bootstraps. It is NOT special: renameable, deletable, and behaves exactly
  // like every other list. This name is only a bootstrap default; once the
  // user renames it nothing here matches anymore, which is the point.
  static const String _defaultListName = 'Following';
  static const String _defaultListIcon = '\uD83D\uDC7E';

  /// Bootstrap a starter list for a user who has NO lists at all, so the feeds
  /// view is never a dead end.
  ///
  /// Gated on "zero lists", NOT on "no list named Following" — that difference
  /// is the whole point. Keying it on the name made the default list
  /// undeletable and unrenameable in practice: `_loadData` runs on init, on
  /// pull-to-refresh, and right after any list mutation, so deleting it
  /// resurrected it on the very next load, and renaming it spawned a second
  /// empty one beside the renamed list. Deleting your LAST list still gets you
  /// a fresh one, which is the only case a bootstrap is actually for.
  Future<List<FeedList>> _ensureDefaultList(List<FeedList> fetched) async {
    if (fetched.isNotEmpty) return fetched;
    try {
      final created = await PublicOSFeedLists.createList(
        _defaultListName,
        icon: _defaultListIcon,
      );
      if (created == null) return fetched;
      return [...fetched, created];
    } catch (_) {
      return fetched;
    }
  }

  /// Pin the default list to the top while it exists; preserve server order
  /// for the rest. A presentation choice, not a behavioral one.
  List<FeedList> _sortDefaultFirst(List<FeedList> lists) {
    final following = lists.where((l) => l.name == _defaultListName);
    final rest = lists.where((l) => l.name != _defaultListName);
    return [...following, ...rest];
  }

  // There is no cold-start fallback for an empty Following: an empty list is
  // a fine place to land, and onboarding seeds the PublicOS *account* follow,
  // so the default list has content from first boot without anyone counting
  // rows to prove it.

  /// Public refresh hook — re-pulls lists + channels.
  ///
  /// [silent] — when true, does NOT show the loading spinner. The previous
  /// content stays on screen while the fetch runs in the background and
  /// state swaps in once it completes. Used by the explorer shell when
  /// popping back from a pushed route (browser / post detail / etc.) so
  /// the feeds view doesn't flash a spinner on every pop.
  ///
  /// Default (loud) is used by the bottom-nav tap and by the initial mount.
  Future<void> refresh({bool silent = false}) => _loadData(silent: silent);

  /// Open / close the lists drawer. The shell calls it when the bottom-nav
  /// Feeds button (a hamburger while Feeds is showing) is tapped again.
  void toggleDrawer() => _toggleDrawer();

  Future<void> _loadData({bool silent = false}) async {
    if (!mounted) return;

    if (!silent) setState(() => _isLoading = true);

    try {
      final futures = await Future.wait([
        PublicOSFeedLists.getUserLists(),
        PublicOSChannels.getChannelsFromAllServers(),
      ]);

      final fetchedLists = futures[0] as List<FeedList>;
      final channelsResponse =
          futures[1] as FeedServerApiResponse<ChannelListResponse>;

      final lists = _sortDefaultFirst(await _ensureDefaultList(fetchedLists));

      if (!mounted) return;

      // Bootstrap a default view only on a genuine cold start — when nothing
      // is selected at all. `_selected == null` is the *whole* check:
      // Discover and Bookmarks are values of the same field, so a re-entrant
      // load (silent route-pop refresh, `onFeedFollowed`) cannot be
      // mistaken for "no selection".
      //
      // Or when the selected list no longer exists. `_selected`
      // holds the FeedList itself, so a list deleted while it is open
      // (Manage Lists, another device, a sync) would stay selected: the header
      // would fall back to the bare list shape, missing the single's favicon,
      // over posts from a list that is gone. It lands where a fresh open does.
      final sel = _selected;
      final selectedListGone =
          sel is FeedList && !lists.any((l) => l.id == sel.id);
      final needsInitialSelect = _selected == null || selectedListGone;

      // Cold-start landing: the first list. `_sortDefaultFirst` has already
      // floated the default list to the top, so that is what a fresh user
      // opens on.
      //
      // No emptiness test, deliberately. The old version counted
      // `getFeedsInList` rows and bounced to a hunted-down Newsletter single
      // whenever Following had none — which, since onboarding started seeding
      // the ACCOUNT rather than channel snapshots, is the normal state of a
      // healthy Following list. An empty list is a fine place to land, so
      // there is nothing to detect and nowhere to bounce to.
      final Object? initialSelection =
          needsInitialSelect && lists.isNotEmpty ? lists.first : null;

      if (!mounted) return;

      final channels =
          channelsResponse.success && channelsResponse.data != null
              ? channelsResponse.data!.channels
              : <Channel>[];

      // Fallback server base for channels that carry no serverAddress —
      // needed to build a channel pick's feed url. Local DB read.
      try {
        _defaultServerUrl =
            (await PublicOSSsp.getCurrentFeedServer())?.feedServerAddress;
      } catch (_) {}
      if (!mounted) return;

      setState(() {
        _lists = lists;
        _channels = channels;
        if (needsInitialSelect) {
          _selected = initialSelection ??
              (channels.isNotEmpty ? channels.first : null);
        }
        if (!silent) {
          _isLoading = false;
          // A loud load drops the body to a SizedBox while `_isLoading`, so
          // clearing it remounts PostsList, which then loads its posts. Bridge
          // the unified spinner across that handoff (same overlay element, no
          // animation reset) until the remounted PostsList reports done.
          if (_selectionShowsPosts(_selected)) {
            _postsLoading = true;
          }
        }
      });

      // The host derives the roster — every path through _loadData
      // (cold start, silent refresh, list mutation callbacks) re-derives, so
      // roster changes always reach PostsList as a fresh `feeds` value.
      _deriveRoster();

      // Fire-and-forget — populate single-list metadata for the drawer +
      // inline header. Doesn't block initial render.
      _loadSingleListMetadata(lists);
      // Same shape — the drawer's Add-as-Tab toggle needs the current
      // set of pinned router URLs but the row state isn't blocking on it.
      _loadExistingTabUrls();
      // PostsList owns post loading and refreshes itself on source change /
      // pull-to-refresh — no explicit per-source load call here.
    } catch (e) {
      if (mounted) {
        setState(() {
          _lists = [];
          _channels = [];
          if (!silent) _isLoading = false;
        });
      }
    }
  }

  /// Per-`is_single`-list: pull the first feed and resolve its
  /// `feedFoundAtAccountAddress` contact. Drives drawer + inline-header
  /// single-row rendering. Updates `_singleFeedByListId` and merges any
  /// newly-resolved contacts into `_resolvedContacts` on completion.
  Future<void> _loadSingleListMetadata(List<FeedList> lists) async {
    final singles = lists.where((l) => l.isSingle).toList();
    if (singles.isEmpty) {
      if (mounted && _singleFeedByListId.isNotEmpty) {
        setState(() => _singleFeedByListId = {});
      }
      return;
    }
    // Collect every single's first feed FIRST, then re-resolve the whole set in
    // one pass. `resolveListFeeds` resolves each owner once per call, so N
    // singles owned by the same account cost one profile read, not N.
    final storedRows = <ListFeed>[];
    for (final list in singles) {
      try {
        final feeds = await PublicOSFeedLists.getFeedsInList(list.id);
        if (feeds.isNotEmpty) storedRows.add(feeds.first);
      } catch (_) {
        // Skip — list survives without single rendering, falls back to
        // multi-feed shape.
      }
    }

    // A single that carries a `feedRecordKey` is a CHANNEL follow, so its
    // stored URL is only a snapshot — re-resolve it against the owner's current
    // records before rendering. A row with NO record key is a direct/raw URL
    // and passes through verbatim (there is no owner to ask). A channel the
    // owner has since deleted comes back as GONE: the single keeps its stored
    // row (name + via for the header) and the roster renders "Channel not
    // found" instead of fetching.
    List<ListFeed> rows;
    List<ListFeed> goneRows = const [];
    try {
      final resolved = await PublicOSFollows.resolveListFeedsDetailed(storedRows);
      rows = resolved.live;
      goneRows = resolved.gone;
    } catch (_) {
      rows = storedRows; // resolution is best-effort; stale beats empty
    }

    final feedsByList = <int, ListFeed>{};
    final goneIds = {for (final r in goneRows) r.listId};
    final addressesToResolve = <String>{};
    for (final row in [...rows, ...goneRows]) {
      feedsByList[row.listId] = row;
      final addr = row.feedFoundAtAccountAddress;
      if (addr != null && addr.isNotEmpty) addressesToResolve.add(addr);
    }
    if (!mounted) return;
    final newContacts = Map<String, Contact>.from(_resolvedContacts);
    for (final address in addressesToResolve) {
      if (newContacts.containsKey(address)) continue;
      try {
        var contact = await PublicOSContacts.searchContacts(address);
        contact ??= await PublicOSContacts.resolveByIdentifier(address);
        if (contact != null) newContacts[address] = contact;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _singleFeedByListId = feedsByList;
      _goneSingleListIds = goneIds;
      _resolvedContacts = newContacts;
    });
    // The roster may have derived before this landed (cold open falls back to
    // `resolveListItems`, which drops a gone channel → an empty roster → "No
    // posts yet"). Re-derive only when the open single disagrees.
    final sel = _selected;
    if (sel is FeedList && sel.isSingle) {
      final r = _roster;
      final gone = goneIds.contains(sel.id);
      if (r != null && (r.length != 1 || r.first.gone != gone)) {
        _deriveRoster();
      }
    }
  }

  /// "Unfollow" on the Channel-not-found screen of a single: delete the
  /// single list (exactly what Manage Lists' trash does), then reload —
  /// `_loadData` re-lands when the selected list no longer exists.
  Future<void> _unfollowSingle(FeedList list) async {
    final ok = await PublicOSFeedLists.deleteList(list.id);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.manageListsSheetFailedDeleteList)),
      );
      return;
    }
    await _loadData();
  }

  /// The single entry point for changing the feeds selection. `selection`
  /// is a [FeedList], a [Channel], or a [FeedsView] value — assigning it is
  /// the whole state change; there are no sibling flags to clear, so the
  /// modes cannot desync. No-ops when the selection is unchanged.
  ///
  /// PostsList re-loads via its `didUpdateWidget` + `ValueKey(_sourceKey)`
  /// rebuild on source change — no loader call needed here.
  void _select(Object? selection) {
    if (_sameSelection(_selected, selection)) return;
    setState(() {
      _selected = selection;
      // The new body starts at the top; attaching fires no scroll event.
      _scrolledUnder.value = false;
      _listCardGone.value = false;
      // A different selection remounts PostsList (its ValueKey changes) and it
      // will load — keep the unified spinner up from this frame so there's no
      // gap before PostsList reports its own loading.
      _postsLoading = _selectionShowsPosts(selection);
      // Cleared synchronously so a stale roster never renders under the new
      // selection; `_deriveRoster` repopulates it.
      _roster = null;
      _rosterListId = null;
    });
    _deriveRoster();
  }

  /// Whether [selection] renders a `PostsList` (vs Discover's own browser or
  /// the onboarding empty state). Drives the eager `_postsLoading` bridge.
  bool _selectionShowsPosts(Object? selection) =>
      selection != null && selection != FeedsView.discover;

  /// PostsList load-state reported up — the other half of the unified spinner.
  void _onPostsLoadingChanged(bool loading) {
    if (!mounted || _postsLoading == loading) return;
    setState(() => _postsLoading = loading);
    // A finished load is when a first-seen advertisement lands its pref row —
    // re-check so the sign-in toggle appears without a reopen.
    if (!loading) _refreshSigninPref();
  }

  /// Selection equality. Lists and channels are compared by id — `_loadData`
  /// rebuilds them as fresh instances on every refresh, so identity would
  /// miss — everything else (the [FeedsView] enum values, null) by `==`.
  static bool _sameSelection(Object? a, Object? b) {
    if (a is FeedList && b is FeedList) return a.id == b.id;
    if (a is Channel && b is Channel) return a.id == b.id;
    return a == b;
  }

  Future<void> _showNewPostBottomSheet() async {
    // Inside one of the user's own channels the post targets it; anywhere
    // else (a list, Bookmarks, Discover) the channel last posted to, then
    // the first in the list.
    final initial = _selectedChannel ??
        await ComposePostPage.lastPostedChannel(_channels);
    if (!mounted) return;
    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => ComposePostPage(
          channels: _channels,
          initialChannel: initial,
          // PostsList owns the post list; bump its refreshTick so it re-fetches
          // and applies directly (no "New posts" chip) — the author should see
          // their post land, not be offered it. (A bare setState here did
          // nothing: the ValueKey derives from the selection, which hasn't
          // changed, so the State survived and never reloaded.)
          onPostSaved: () {
            if (mounted) setState(() => _postsRefreshTick++);
          },
        ),
      ),
    );
  }

  /// Opens the rename + change-icon sheet for the selected list.
  /// View-feeds + remove-feeds lives inside the Manage Lists sheet.
  Future<void> _showEditListBottomSheet() async {
    if (_selectedList == null) return;
    final updated = await showEditListSheet(context, existing: _selectedList);
    if (updated == null || !mounted) return;
    // Re-load lists so the drawer + selection picks up the new name/icon.
    await _loadData();
  }

  /// Dismissing a manage sheet re-derives the roster from the database and
  /// hands it to PostsList, which patches its deck against what it was showing
  /// (posts of removed feeds out, added feeds fetched and slotted in by date)
  /// and does nothing when the roster came back the same. No dirty flag from
  /// the sheet (it cannot be trusted), no reload tick (reloading the whole
  /// deck every time makes it flicker). The list header re-reads its
  /// counts in place.
  Future<void> _showManageListsBottomSheet() async {
    await showManageListsSheet(
      context,
      lists: _lists,
      onListsChanged: () {},
    );
    // Lists can be renamed or deleted here, so the metadata reloads too.
    if (!mounted) return;
    await _loadData(silent: true);
    await _rederiveAfterListChange();
  }

  Future<void> _showManageListSheet(FeedList list) async {
    await showManageListSheet(
      context,
      list: list,
      onChanged: () {},
    );
    await _rederiveAfterListChange();
  }

  Future<void> _rederiveAfterListChange() async {
    if (!mounted) return;
    await _deriveRoster();
  }

  /// The content beneath the unified spinner overlay. Always returns a real
  /// widget (never gated to a spinner here — the overlay owns that), so the
  /// Stack's content slot keeps a stable position across loads.
  Widget _buildContent(ThemeData theme) {
    if (_isViewingDiscover) {
      return DiscoverBrowser(onFeedFollowed: _loadData);
    }
    // While the lists/channels metadata loads there's no selection yet — render
    // nothing under the overlay (the onboarding empty state would otherwise
    // flash behind the spinner).
    if (_isLoading) return const SizedBox.shrink();
    // Bookmarks leave the feed abstraction — their own surface.
    // Explore: what the network is reading, from the user's own SSP. Own
    // surface like Bookmarks — no roster.
    if (_isViewingExplore) {
      return ExploreView(
        color: widget.color,
        titleTextSize: _titleTextSize,
        descriptionTextSize: _descriptionTextSize,
        bodyMaxChars: _trimChars,
        layoutMode: _layoutMode,
        scrollController: _scrollController,
        showFullScreenLoader: false,
        onLoadingChanged: _onPostsLoadingChanged,
      );
    }
    if (_isViewingBookmarks) {
      return BookmarksView(
        color: widget.color,
        titleTextSize: _titleTextSize,
        descriptionTextSize: _descriptionTextSize,
        bodyMaxChars: _trimChars,
        layoutMode: _layoutMode,
        scrollController: _scrollController,
        showFullScreenLoader: false,
        onLoadingChanged: _onPostsLoadingChanged,
      );
    }
    if (_selected == null) return _buildOnboardingState(theme);
    final roster = _roster;
    // Roster still deriving — the unified spinner (raised in `_select` /
    // `_loadData`) covers this gap; render nothing beneath it.
    if (roster == null) return const SizedBox.shrink();
    return PostsList(
      // Bumping the key on selection change forces a fresh State instance —
      // cleaner than relying on didUpdateWidget when bookmarks toggle vs.
      // list/channel switches.
      key: ValueKey(_sourceKey),
      // Inside Feeds the forum compose button shows only on a forum channel
      // selection; everywhere else the view's own post button is there.
      showNewPostButton: _selectedChannel?.isOpen ?? false,
      feeds: roster,
      listId: _rosterListId,
      displayName: _selectedItemName,
      color: widget.color,
      titleTextSize: _titleTextSize,
      descriptionTextSize: _descriptionTextSize,
      bodyMaxChars: _trimChars,
      layoutMode: _layoutMode,
      scrollController: _scrollController,
      // Unified spinner: PostsList stays blank while loading and reports its
      // load state up; the overlay in `build` shows the single spinner.
      showFullScreenLoader: false,
      refreshTick: _postsRefreshTick,
      // A regular list (not a single) shows who it follows where a channel
      // shows its description.
      listHeader: switch (_selected) {
        FeedList l when _rosterListId == l.id => (inset) => ListHeaderCard(
              key: _listCardKey,
              summary: _listSummary,
              leftInset: inset,
              onManage: () => _showManageListSheet(l),
            ),
        _ => null,
      },
      onLoadingChanged: _onPostsLoadingChanged,
      onUnfollowGone: switch (_selected) {
        FeedList l when l.isSingle => () => _unfollowSingle(l),
        _ => null,
      },
      onHeldDocked: (w) {
        if (!mounted) return;
        setState(() => _dockedNewChip = w);
      },
      onRefreshingChanged: (v) {
        if (!mounted || _postsRefreshing == v) return;
        setState(() => _postsRefreshing = v);
        if (!v) _refreshSigninPref();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // The post button is always there in Feeds, as long as
    // you own a channel to post to: the compose page's picker chooses where
    // when no channel is selected. A forum channel keeps PostsList's own
    // button (it posts INTO the forum), so ours steps aside there.
    final showFab = _channels.isNotEmpty && !(_selectedChannel?.isOpen ?? false);

    return Column(
      children: [
        // Inline tappable header — shows current selection, opens drawer
        _buildInlineHeader(theme),
        // Content area wrapped in Scaffold for floating action button.
        // The shell already lifted this body above the system's bottom inset
        // but leaves the inset in MediaQuery, so the Scaffold would place the
        // FAB above it a second time (the post button would float higher than
        // PostsList's forum button). Clear it here.
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeBottom: true,
            child: Scaffold(
            backgroundColor: Colors.transparent,
            // The content layer and a single unified spinner overlay. The
            // overlay is the LAST child in every phase and carries a stable
            // key, so Flutter reuses the same element (and its running orbit
            // controller) across the metadata->posts handoff instead of
            // disposing + recreating it — that recreation was the visible
            // "jump back to start" of the doubled animation.
            body: Stack(
              children: [
                Positioned.fill(
                  child: ContentMetricsListener(
                    onMetrics: _onContentMetrics,
                    // The list stacks its "back to top" button above our
                    // "+" when we draw one.
                    child: HostPostButtonScope(
                      shown: showFab,
                      child: _buildContent(theme),
                    ),
                  ),
                ),
                if (!_isViewingDiscover && (_isLoading || _postsLoading))
                  const Positioned.fill(
                    key: ValueKey('feeds_unified_loader'),
                    child: PixelRainLoadingCorner(),
                  ),
              ],
            ),
            floatingActionButton: showFab
                ? Builder(builder: (context) {
                    final tokens = GlassTokens.of(context);
                    // No border, the status bar's fill; the Scaffold's 16 px
                    // margin, the same 16 as PostsList's forum button. It
                    // leaves and returns with the bottom nav.
                    return ShellChromeFollower(
                      child: FloatingActionButton(
                        heroTag: 'feeds_view_fab',
                        onPressed: _showNewPostBottomSheet,
                        // The Contacts search box's colour (glassFill
                        // over the app background), made opaque so posts
                        // don't show through.
                        backgroundColor: Color.alphaBlend(
                            tokens.glassFill, tokens.background),
                        foregroundColor: tokens.starkWhite,
                        elevation: 0,
                        highlightElevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Icon(Icons.add_rounded, size: 22),
                      ),
                    );
                  })
                : null,
          ),
          ),
        ),
      ],
    );
  }

  /// Full-screen drawer overlay rendered via root Overlay so it covers
  /// AppBar + BottomNav. Selection state stays in this view; the drawer
  /// widget just invokes the same callbacks as before.
  Widget _buildDrawerOverlay(BuildContext overlayContext) {
    final screenWidth = MediaQuery.of(overlayContext).size.width;
    final panelWidth = screenWidth - 60;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeDrawer();
      },
      child: AnimatedBuilder(
        animation: _drawerController,
        builder: (context, _) {
          final v = _drawerController.value;
          return Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: _closeDrawer,
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.45 * v),
                  ),
                ),
              ),
              Positioned(
                top: 0,
                bottom: 0,
                left: 0,
                right: 60,
                child: Transform.translate(
                  offset: Offset(-panelWidth * (1 - v), 0),
                  child: Material(
                    color: Colors.transparent,
                    child: FeedsNavigationDrawer(
                      lists: _lists,
                      channels: _channels,
                      selected: _selected,
                      singleFeedByListId: _singleFeedByListId,
                      resolvedContacts: _resolvedContacts,
                      onListSelected: (list) {
                        _select(list);
                        _closeDrawer();
                      },
                      onChannelSelected: (channel) {
                        _select(channel);
                        _closeDrawer();
                      },
                      onBookmarksSelected: () {
                        _select(FeedsView.bookmarks);
                        _closeDrawer();
                      },
                      onExploreSelected: () {
                        _select(FeedsView.explore);
                        _closeDrawer();
                      },
                      onDiscoverSelected: () {
                        _select(FeedsView.discover);
                        _closeDrawer();
                      },
                      onManageLists: () {
                        _closeDrawer();
                        _showManageListsBottomSheet();
                      },
                      onCreateChannel: () {
                        _closeDrawer();
                        _showCreateChannelPage();
                      },
                      onSettings: () {
                        _closeDrawer();
                        showSettingsSheet();
                      },
                      onManageServer: () {
                        _closeDrawer();
                        _navigateToServerManagement(null);
                      },
                      onManageChannel: (channel) {
                        _closeDrawer();
                        _openManageChannelPage(channel);
                      },
                      tabUrls: _tabUrls,
                      onAddAsTab: _addChannelAsTab,
                      onRemoveFromTab: _removeChannelFromTab,
                      onClose: _closeDrawer,
                      onEditList: (list) {
                        // Every list is editable now — the default list is a
                        // default, not a fixture. Renaming it just means the
                        // bootstrap name stops matching, which is fine.
                        _selected = list;
                        _closeDrawer();
                        _showEditListBottomSheet();
                      },
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// The sign-in consent dialog. One surface for both
  /// advertised modes: `optional` explains the trade and offers the choice;
  /// `required` states that reading this feed identifies you anyway. The
  /// action flips the stored pref and bumps the refresh tick so the very next
  /// fetch honors it — turning it ON should land a verified read immediately,
  /// not on some later visit.
  /// The key menu: Allow · Deny ·
  /// Forget, current state on top. Writes the decision and refetches under
  /// the new posture right away.
  Future<void> _showSigninMenu() async {
    final pref = _signinPref;
    final url = _singleRosterUrl;
    if (pref == null || url == null) return;
    final choice = await showChannelSigninMenu(
      context,
      pref: pref,
      effective: _signinEffective,
    );
    if (choice == null || !mounted) return;
    await PublicOSChannelSignin.setDecision(url, choice.decision);
    await _refreshSigninPref();
    if (!mounted) return;
    // Refetch under the new identity posture right away.
    setState(() => _postsRefreshTick++);
  }

  Widget _buildInlineHeader(ThemeData theme) {
    final tokens = GlassTokens.of(context);
    // On forum channels the sort bar (just below us) provides its own
    // bottom underline — drop ours so we don't render two parallel lines.
    final isForumBody =
        _selectedChannel != null && _selectedChannel!.isOpen;

    // Single-flagged-list short-circuit — center body becomes
    // [favicon] feed_name · via [icon] displayName.
    final selList = _selectedList;
    final singleFeed = (selList != null && selList.isSingle)
        ? _singleFeedByListId[selList.id]
        : null;
    final isSingleSurface = selList != null &&
        selList.isSingle &&
        singleFeed != null &&
        !_isViewingBookmarks &&
        _selectedChannel == null;

    Widget centerBody;
    if (isSingleSurface) {
      centerBody = _buildSingleHeaderBody(
        feed: singleFeed,
        tokens: tokens,
      );
    } else {
      Widget leadingIcon;
      if (_isViewingBookmarks) {
        leadingIcon = Icon(Icons.bookmark_rounded,
            size: 20, color: tokens.fallbackAccent);
      } else if (_selectedChannel != null && _selectedChannel!.isOpen) {
        leadingIcon =
            Icon(Icons.forum_outlined, size: 20, color: tokens.starkWhite);
      } else if (_selectedChannel != null) {
        leadingIcon = _buildChannelHeaderIcon(_selectedChannel!);
      } else if (_selectedList != null &&
          _selectedList!.icon != null &&
          _selectedList!.icon!.isNotEmpty) {
        leadingIcon =
            Text(_selectedList!.icon!, style: const TextStyle(fontSize: 18));
      } else if (_selectedList != null) {
        leadingIcon =
            Icon(Icons.list_alt_rounded, size: 20, color: tokens.textDim);
      } else {
        leadingIcon =
            Icon(Icons.rss_feed_rounded, size: 20, color: tokens.textDim);
      }
      centerBody = Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // One slot for every icon kind, the drawer's rule:
          // emoji, favicon and channel icon centre in it, so
          // titles start on one line. Its size and left edge copy the status
          // bar's avatar (40 px at 12 px), so the title lines up with the
          // account name above.
          SizedBox(
            width: _kHeaderIconSlot,
            child: Center(child: leadingIcon),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              _selectedItemName,
              style: TextStyle(
                color: tokens.starkWhite,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }

    // SSP management shortcut for owned channels — only thing that can
    // appear on the right side.
    Widget? trailing;
    if (_selectedChannel != null && !_isViewingBookmarks) {
      final isOwned = _channels.any((c) => c.id == _selectedChannel!.id);
      if (isOwned) {
        trailing = InkResponse(
          onTap: () => _openManageChannelPage(_selectedChannel!),
          radius: 18,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(Icons.tune_rounded, size: 18, color: tokens.textDim),
          ),
        );
      }
    }

    // A regular list: once the scroll-away card has left the top, the list's
    // mini stack rides at the right edge, sliding up into place and back
    // down when the card returns. It is the one
    // door to "Manage [list]" up here; the card is the door at the top
    // (there is no separate tune button for lists).
    Widget? listStack;
    if (selList != null &&
        !selList.isSingle &&
        !_isViewingBookmarks &&
        _selectedChannel == null) {
      final list = selList;
      final summary = _listSummary;
      if (summary != null && !summary.isEmpty) {
        listStack = ValueListenableBuilder<bool>(
          valueListenable: _listCardGone,
          // The icons fly in from the right one by one when the card
          // leaves, and out to the right when it returns (a HeaderSlot like
          // the rest of the right group, rising from below while its width
          // opens, would read as a diagonal).
          builder: (_, gone, __) => ListMiniStackFlyIn(
            show: gone,
            summary: summary,
            tokens: tokens,
            onTap: () => _showManageListSheet(list),
            padding: const EdgeInsets.only(right: 4),
          ),
        );
      }
    }

    // Whole header is a single tap target that opens the drawer. Inner
    // tap surfaces (the via segment's InkWell on single-flagged headers,
    // the trailing channel-tune button) absorb their taps via their own
    // InkWell / InkResponse, so they don't bubble up here.
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _toggleDrawer,
        // Only the divider follows the scroll: the builder is the one thing
        // that rebuilds when the list leaves or returns to its top.
        child: ValueListenableBuilder<bool>(
          valueListenable: _scrolledUnder,
          builder: (_, scrolled, __) => AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            decoration: BoxDecoration(
              border: isForumBody
                  ? null
                  : Border(
                      bottom: BorderSide(
                        color: scrolled
                            ? tokens.borderSubtle
                            : tokens.borderSubtle.withValues(alpha: 0),
                        width: 0.5,
                      ),
                    ),
            ),
            // 12 on top: 8 px more air under the status bar.
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
            child: Row(
              children: [
                // Icon + title (+ via line for singles), left-aligned since the
                // hamburger lives in the bottom nav. The
                // row itself still opens the drawer.
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      // 8 (container) + 2 = 10: 2 px left of the status bar
                      // avatar's edge.
                      padding: const EdgeInsets.only(left: 2, right: 8),
                      child: centerBody,
                    ),
                  ),
                ),
                // Right group, in order: [refresh hint] [new posts] [sign-in
                // key] [list faces] [channel tune]. Each is a HeaderSlot:
                // it rises in from the header's bottom,
                // and when it leaves its width closes so the others slide
                // over. The title gives way (Expanded) instead of a fixed
                // right inset.
                HeaderSlot(
                  child: _postsRefreshing
                      ? const Padding(
                          padding: EdgeInsets.only(right: 6),
                          child: PixelRainLoadingWidget(size: 16, showShadows: false),
                        )
                      : null,
                ),
                HeaderSlot(
                  child: _dockedNewChip == null
                      ? null
                      : Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: _dockedNewChip,
                        ),
                ),
                HeaderSlot(
                  child: _signinPref == null
                      ? null
                      : InkResponse(
                    onTap: _showSigninMenu,
                    radius: 18,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        _signinEffective
                            ? Icons.vpn_key_rounded
                            : Icons.vpn_key_off_rounded,
                        size: 18,
                        // starkWhite to match the menu glyph: signed-in is a
                        // state, not a call to action.
                        color: _signinEffective
                            ? tokens.starkWhite
                            : tokens.textDim,
                      ),
                    ),
                  ),
                ),
                if (listStack != null) listStack,
                HeaderSlot(child: trailing),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Center body for a single-flagged list header: favicon + feed name +
  /// optional `via [icon] displayName`. The via segment is tappable
  /// independently of the parent so it opens the discovery contact's
  /// profile without bubbling up.
  Widget _buildSingleHeaderBody({
    required ListFeed feed,
    required GlassTokens tokens,
  }) {
    final feedName = (feed.feedTitle != null && feed.feedTitle!.isNotEmpty)
        ? feed.feedTitle!
        : (Uri.tryParse(feed.feedUrl)?.host ?? feed.feedUrl);
    final foundAtAddr = feed.feedFoundAtAccountAddress;
    final foundAt = (foundAtAddr != null && foundAtAddr.isNotEmpty)
        ? _resolvedContacts[foundAtAddr]
        : null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Same 40 px slot as every header icon (see the list/channel branch).
        SizedBox(
          width: _kHeaderIconSlot,
          child: Center(child: FeedFavicon(feedUrl: feed.feedUrl, size: 32)),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            feedName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: tokens.starkWhite,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
        ),
        if (foundAt != null) ...[
          const SizedBox(width: 8),
          Text('·',
              style: TextStyle(color: tokens.textDim, fontSize: 12)),
          const SizedBox(width: 8),
          Flexible(child: _buildHeaderViaLine(foundAt, tokens)),
        ],
      ],
    );
  }

  Widget _buildChannelHeaderIcon(Channel channel) {
    const double size = 32; // the list emoji's 24 + 8
    const double radius = 4;
    final fallback = Icon(Icons.rss_feed_rounded, size: size, color: ThemeProvider.tealPrimary);

    final faviconUrl = channel.serverAddress != null
        ? FaviconUtils.getFaviconUrl(channel.serverAddress!)
        : null;

    Widget faviconOrFallback = faviconUrl != null
        ? ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: ZeroCachedImage(
              imageUrl: faviconUrl,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => fallback,
            ),
          )
        : fallback;

    if (channel.iconUrl != null && channel.iconUrl!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: ZeroCachedImage(
          imageUrl: channel.iconUrl!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) => faviconOrFallback,
        ),
      );
    }

    return faviconOrFallback;
  }

  /// `via [14px GlassContactIcon] displayName` for the inline header. Tappable
  /// only on the via segment — outer InkWell still toggles the drawer.
  Widget _buildHeaderViaLine(Contact contact, GlassTokens tokens) {
    final hasProfile = contact.publicosAddress != null &&
        contact.publicosAddress!.eip55With0x !=
            '0x0000000000000000000000000000000000000000';
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(context.l10n.feedsViewVia,
            style: TextStyle(color: tokens.textDim, fontSize: 12)),
        const SizedBox(width: 5),
        GlassContactIcon(contact: contact, size: 14),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            contact.displayName ?? '—',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: tokens.starkWhite.withValues(alpha: 0.85),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
    if (!hasProfile) return row;
    return InkWell(
      onTap: () => AppNav.toContact(context, contact),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
        child: row,
      ),
    );
  }

  /// Empty state shown when no channel, list, or bookmarks view is selected.
  /// Per-source empty states (bookmarks empty, list empty, channel empty,
  /// locked-feeds banner) all live inside PostsList now.
  Widget _buildOnboardingState(ThemeData theme) {
    final tokens = GlassTokens.of(context);
    return RefreshIndicator(
      key: const ValueKey('onboarding'),
      onRefresh: () => _loadData(),
      color: tokens.starkWhite,
      backgroundColor: tokens.surfaceElevated,
      child: ListView(
        controller: _scrollController,
        children: [
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.5,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.rss_feed_rounded,
                    size: 56,
                    color: tokens.textDim,
                  ),
                  const SizedBox(height: 14),
                  Text(
                    context.l10n.feedsViewOnboardingTitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      color: tokens.starkWhite,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      context.l10n.feedsViewOnboardingSubtitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: tokens.textDim,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

}
